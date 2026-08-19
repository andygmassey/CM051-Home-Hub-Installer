"""Front Page feedback wire (E1, J-2): one card tap -> a durable correction.

The three per-card feedback controls map 1:1 onto the ``CorrectionStore`` verbs
that ``interest_profile.apply_corrections`` already folds into every recompile
(corrections always win over inferred signal):

    "Spot on"    -> strengthen(interest_id)     (reinforce)
    "Not me"     -> weaken(interest_id)          (keep, rank down)
    "Don't show" -> drop(interest_id)   AND      (terminal: never surface again)
                    card_states[card_id] = {"state": "dismissed_forever"}

``add`` ("tell Ostler something you're into") is a section-header affordance, not
a per-card control, so it is not part of this tap wire.

After the correction is persisted the feed is **re-emitted immediately** (a cheap
``emit_frontpage.emit(from_artefact=True)`` re-apply of corrections/states to the
already-compiled profile), so the UI change survives a reload without waiting for
the hourly launchd tick.

This is the Python handler both feedback surfaces share: the Hub API POST route
(HR015, E2) and the macOS Hub Tauri command call the same store shape. The Python
side reuses ``CorrectionStore`` directly; the one non-Python writer (the Rust
Tauri command) must stay byte-compatible with the store JSON - the contract test
in ``contract/`` gates that drift.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone

from compiler import corrections as corr_mod

# UI label / verb -> canonical CorrectionStore verb. Accept both the human
# control labels and the canonical verbs so callers (Hub, iOS, tests) are free to
# send either.
_ACTION_ALIASES = {
    "spot_on": "strengthen",
    "spot-on": "strengthen",
    "spoton": "strengthen",
    "not_me": "weaken",
    "not-me": "weaken",
    "notme": "weaken",
    "dont_show": "drop",
    "don't_show": "drop",
    "dont-show": "drop",
    "dismiss": "drop",
    "strengthen": "strengthen",
    "weaken": "weaken",
    "drop": "drop",
}

CARD_STATES_NAME = "card_states.json"


def normalise_action(action: str) -> str | None:
    """Map a UI label or verb to a canonical CorrectionStore verb, or None.
    Separator-insensitive: 'Spot on', 'spot_on' and 'spot-on' all normalise."""
    key = (action or "").strip().lower().replace(" ", "_").replace("-", "_")
    return _ACTION_ALIASES.get(key)


def parse_consent_action(action: str) -> tuple[str, str] | None:
    """Parse the E4 consent verbs a consent card's action carries:
    ``consent_grant:<key>`` / ``consent_revoke:<key>`` (spec section 2.1
    consent-card example). Returns ``(verb, key)`` only for a well-formed
    verb AND a plain ``[a-z0-9_]+`` key - anything else is ``None``, so a
    mangled action string can never touch the consent file."""
    import re as _re
    text = (action or "").strip().lower()
    m = _re.fullmatch(r"(consent_grant|consent_revoke):([a-z0-9_]+)", text)
    if not m:
        return None
    return m.group(1), m.group(2)


def _editor_dir() -> str:
    return os.path.expanduser(
        os.environ.get("OSTLER_EDITOR_DIR", "~/.ostler/editor"))


def _card_states_path(editor_dir: str) -> str:
    return os.environ.get("OSTLER_EDITOR_CARD_STATES") or os.path.join(
        editor_dir, CARD_STATES_NAME)


def _corrections_path(editor_dir: str) -> str:
    return os.environ.get("OSTLER_EDITOR_CORRECTIONS") or os.path.join(
        editor_dir, "interest_corrections.json")


def write_card_state(card_id: str, state: dict, editor_dir: str | None = None) -> str:
    """Merge a per-card state entry into card_states.json atomically. Used by
    ``drop`` (dismissed_forever) and, later, snooze/complete."""
    editor_dir = editor_dir or _editor_dir()
    path = _card_states_path(editor_dir)
    states: dict = {}
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as fh:
                loaded = json.load(fh)
            if isinstance(loaded, dict):
                states = loaded
        except Exception:
            states = {}  # a corrupt store is replaced, never fatal
    states[card_id] = state
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(states, fh, indent=2, ensure_ascii=False)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    return path


def _artefact_sources(card_id: str, editor_dir: str) -> list[str]:
    """Resolve a card's ``sources`` (E3 scout provenance - e.g. the newsletter
    affinity keys a digest tap trains) from the current feed artefact. Used
    when the caller did not pass them: existing surfaces send only
    (card_id, interest_id), and the artefact is the shared truth both already
    read. Best-effort: any failure -> ``[]``."""
    try:
        path = os.path.join(editor_dir, "front_page.json")
        with open(path, encoding="utf-8") as fh:
            feed = json.load(fh)
        for card in feed.get("cards", []):
            if card.get("id") == card_id:
                srcs = card.get("sources")
                if isinstance(srcs, list):
                    return [s for s in srcs if isinstance(s, str) and s]
                return []
    except Exception:  # noqa: BLE001 - provenance lookup is best-effort
        pass
    return []


def record_feedback(card_id: str, interest_id: str | None, action: str, *,
                    editor_dir: str | None = None, reemit: bool = True,
                    now: datetime | None = None,
                    sources: list | None = None) -> dict:
    """Route one card tap through the CorrectionStore and re-emit the feed.

    ``sources`` (E3) is the card's provenance-key list (e.g. a newsletter
    digest's ``["newsletter::<slug>", ...]`` affinity keys). When present -
    passed by the caller, or resolved from the feed artefact for a card that
    carries them - the correction verb is applied to each source key, so
    "not me" on a digest lowers the source newsletters' affinity weights in
    the next compile (A-E3-2). Cards without sources keep the E1 behaviour:
    the verb applies to ``interest_id``.

    Returns ``{"ok": bool, "action": <verb>, "card_id", "interest_id",
    "dismissed": bool, "reemitted": bool, "error"?}``. Never raises for the
    ordinary "bad action / missing interest_id" cases - it returns ``ok: False``
    with an error string so a UI handler can stay simple.
    """
    editor_dir = editor_dir or _editor_dir()

    # E4 consent verbs: a tap on a consent card writes the per-domain flag
    # (literal true/false - the only shapes has_consent grants on) and
    # re-emits, so the next tick's scouts see it. No CorrectionStore involved.
    consent_action = parse_consent_action(action)
    if consent_action is not None:
        verb, key = consent_action
        from compiler import scouts as sc
        try:
            sc.write_consent(key, verb == "consent_grant")
        except Exception as exc:  # noqa: BLE001 - a UI handler stays simple
            return {"ok": False, "action": verb, "card_id": card_id,
                    "consent_key": key, "error": f"consent write failed: {exc}"}
        if verb == "consent_grant":
            # The offer is answered: the card completes rather than lingering.
            write_card_state(card_id, {"state": "completed"}, editor_dir)
        return {"ok": True, "action": verb, "card_id": card_id,
                "consent_key": key, "granted": verb == "consent_grant",
                "reemitted": _reemit(now) if reemit else False}

    verb = normalise_action(action)
    if verb is None:
        return {"ok": False, "action": action, "card_id": card_id,
                "interest_id": interest_id, "error": "unknown action"}

    keys: list[str] = []
    if verb in ("strengthen", "weaken", "drop"):
        keys = [s for s in (sources or []) if isinstance(s, str) and s]
        if not keys and not interest_id:
            keys = _artefact_sources(card_id, editor_dir)
        if not keys and interest_id:
            keys = [interest_id]
        if not keys:
            return {"ok": False, "action": verb, "card_id": card_id,
                    "interest_id": interest_id,
                    "error": "interest_id required for a correction verb"}

    store = corr_mod.CorrectionStore(path=_corrections_path(editor_dir))
    for key in keys:
        if verb == "strengthen":
            store.strengthen(key)
        elif verb == "weaken":
            store.weaken(key)
        elif verb == "drop":
            store.drop(key)

    dismissed = False
    if verb == "drop":
        # A terminal drop also hides this specific card for ever.
        write_card_state(card_id, {"state": "dismissed_forever"}, editor_dir)
        dismissed = True

    reemitted = False
    if reemit:
        reemitted = _reemit(now)

    return {"ok": True, "action": verb, "card_id": card_id,
            "interest_id": interest_id, "dismissed": dismissed,
            "reemitted": reemitted}


def _reemit(now: datetime | None) -> bool:
    """Immediately re-emit the feed from the cached profile artefact (cheap: no
    graph query). Best-effort - a re-emit failure does not undo the correction,
    which is already durable; the next hourly tick will pick it up regardless."""
    try:
        from compiler import emit_frontpage as ef
        ef.emit(from_artefact=True, now=now or datetime.now(timezone.utc))
        return True
    except Exception:
        return False
