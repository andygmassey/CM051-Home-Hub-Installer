"""Emit the Front Page artefacts the Hub/app surfaces serve.

Producer side of the Front Page. On each tick it:

  1. obtains the interest profile (re-compiled from the live graph, or read from
     the already-emitted ``interest_profile.json`` artefact when ``--from-artefact``),
  2. best-effort reads the install settling signal (so a fresh install shows the
     calm "still settling in" card instead of a thin page),
  3. reads the local card-state store (dismiss / snooze / complete),
  4. builds the card feed (``frontpage.build_frontpage``), and
  5. writes ``front_page.json`` + ``front_page.html`` atomically under
     ``~/.ostler/editor/`` (the well-known path the Doctor route reads).

No external network calls beyond the read-only Oxigraph query the Phase-0
compiler already makes. Stdlib only.

Paths (env overrides, mirroring CM059's other artefacts):
  * OSTLER_EDITOR_DIR        - dir for front_page.{json,html} (default ~/.ostler/editor)
  * OSTLER_INTEREST_PROFILE  - interest_profile.json to read with --from-artefact
  * OSTLER_HYDRATION_PROGRESS_FILE / OSTLER_STATE_DIR - settling signal inputs
  * OSTLER_EDITOR_CARD_STATES - the per-card state store
  * OSTLER_EDITOR_ENTITLEMENT_GATE - set to enforce the Pro front_page_feed
    entitlement (fail-closed; see entitlement.py + the design note)
  * OSTLER_EDITOR_ENTITLEMENTS_FILE - entitlement sidecar path override

CLI: python3 -m compiler.emit_frontpage [--oxigraph URL] [--from-artefact]
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone

from compiler import frontpage as fp
from compiler import interest_profile as ip
from compiler import corrections as corr_mod
from compiler import render_frontpage as rf
from compiler import card_ledger as cl
from compiler import entitlement as ent

DEFAULT_EDITOR_DIR = os.path.expanduser("~/.ostler/editor")
DEFAULT_STATE_DIR = os.path.expanduser("~/.ostler/state")
FEED_NAME = "front_page.json"
HTML_NAME = "front_page.html"
CARD_STATES_NAME = "card_states.json"
LEDGER_NAME = "card_ledger.json"


def editor_dir() -> str:
    return os.path.expanduser(os.environ.get("OSTLER_EDITOR_DIR", DEFAULT_EDITOR_DIR))


def _state_dir() -> str:
    return os.path.expanduser(os.environ.get("OSTLER_STATE_DIR", DEFAULT_STATE_DIR))


def _read_json(path: str):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def read_settling() -> dict | None:
    """Best-effort settling hint from CM051/CM044's shared sidecars.

    Reads the per-channel hydration progress (overall done/total) the install
    writes at ~/.ostler/state/hydration_progress.json. Returns a small dict
    ``{"pct", "days_remaining", "any_working"}`` the feed builder understands,
    or ``None`` when no signal exists / hydration is settled. Never raises - a
    missing signal simply means "not settling", which is the right default for
    an established install."""
    path = os.environ.get("OSTLER_HYDRATION_PROGRESS_FILE") or os.path.join(
        _state_dir(), "hydration_progress.json")
    progress = _read_json(os.path.expanduser(path))
    if not isinstance(progress, dict):
        return None
    overall = progress.get("overall") or {}
    done = int(overall.get("done") or 0)
    total = int(overall.get("total") or 0)
    failed = int(overall.get("failed") or 0)
    if total <= 0 or done + failed >= total:
        return None  # nothing queued, or backlog settled -> no settling card
    pct = max(1, min(99, int(round(done / total * 100))))
    return {"pct": pct, "any_working": True}


def read_card_states() -> dict | None:
    path = os.environ.get("OSTLER_EDITOR_CARD_STATES") or os.path.join(
        editor_dir(), CARD_STATES_NAME)
    data = _read_json(os.path.expanduser(path))
    return data if isinstance(data, dict) else None


def ledger_path() -> str:
    return os.environ.get("OSTLER_EDITOR_CARD_LEDGER") or os.path.join(
        editor_dir(), LEDGER_NAME)


def read_signals() -> dict | None:
    """Best-effort live-signal payloads from the loopback ical-server (E2).

    Loopback-only by the guard inside ``signals.fetch_signals``; each endpoint is
    independently optional. Any failure -> ``None`` (the feed simply omits the
    live signal cards), never an error. Set ``OSTLER_EDITOR_DISABLE_SIGNALS`` to
    skip the fetch entirely (e.g. demo builds, or a box with no ical-server)."""
    if os.environ.get("OSTLER_EDITOR_DISABLE_SIGNALS"):
        return None
    base = os.environ.get("OSTLER_PWG_PEOPLE_BASE_URL", "http://127.0.0.1:8090")
    try:
        from compiler import signals as sig
        return sig.fetch_signals(base) or None
    except Exception as exc:  # noqa: BLE001 - a signal fetch never breaks a feed
        print(f"front-page: live signals unavailable "
              f"({type(exc).__name__}: {exc})", file=sys.stderr)
        return None


def read_scout_cards(profile: dict, now: datetime, ledger) -> list | None:
    """Best-effort scout cards (E3). Consent-gated fail-closed inside
    ``scouts.run_scouts`` - a scout whose flag in scout_consent.json is not
    literally true is never called, so with no consent granted this returns
    ``None`` and the feed is byte-identical to the pre-scout output. Set
    ``OSTLER_EDITOR_DISABLE_SCOUTS`` to skip scouts entirely. Any failure ->
    ``None``, never an error."""
    if os.environ.get("OSTLER_EDITOR_DISABLE_SCOUTS"):
        return None
    try:
        from compiler import scout_external as se
        from compiler import scouts as sc
        consent = sc.load_consent()
        registered = sc.default_scouts()
        cards = sc.run_scouts(registered, profile, now,
                              ledger=ledger, consent=consent)
        # E4: consent offers for external scouts that could actually deliver
        # (wired + free-tier + matching taste) but have no consent entry yet.
        # In this build no registered external scout is wired, so this adds
        # nothing on a live box - the machinery is proven by injected tests.
        cards.extend(se.consent_offer_cards(registered, profile, consent, now))
        return cards or None
    except Exception as exc:  # noqa: BLE001 - a scout never breaks a feed
        print(f"front-page: scouts unavailable "
              f"({type(exc).__name__}: {exc})", file=sys.stderr)
        return None


def _atomic_write(path: str, text: str) -> str:
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    return path


def _obtain_profile(oxigraph_url: str | None, from_artefact: bool) -> dict:
    if from_artefact:
        art_path = os.path.expanduser(os.environ.get(
            "OSTLER_INTEREST_PROFILE",
            os.path.join(os.path.expanduser("~/.ostler/preferences"),
                         "interest_profile.json")))
        art = _read_json(art_path)
        if isinstance(art, dict) and art.get("interests") is not None:
            # the flat emitter artefact -> rebuild minimal domain blocks so the
            # feed builder (which groups by domain) can consume it
            return _profile_from_flat(art)
    corrections = corr_mod.load_corrections()
    return ip.build_from_live(oxigraph_url, corrections=corrections)


def _profile_from_flat(art: dict) -> dict:
    """Reconstruct the grouped profile shape from the flat emitter artefact."""
    domains: dict[str, list] = {}
    dislikes: list = []
    for it in art.get("interests", []):
        if it.get("polarity") == "dislike":
            dislikes.append(it)
        else:
            domains.setdefault(it.get("domain", "Other"), []).append(it)
    blocks = [{"domain": d, "count": len(v), "interests": v}
              for d, v in domains.items()]
    return {
        "schema_version": art.get("schema_version", "0.1"),
        "domains": blocks,
        "dislikes": dislikes,
        "stats": art.get("stats", {"interests": sum(len(b["interests"]) for b in blocks)}),
    }


def emit(oxigraph_url: str | None = None, *, from_artefact: bool = False,
         now: datetime | None = None) -> dict:
    """Build + write the Front Page artefacts. Returns
    ``{"feed": <path>, "html": <path>, "phase": ..., "cards": n}``.

    Falls back to an empty (settling-only) feed if the profile cannot be
    obtained, so a fresh / mid-hydration install still gets a graceful page."""
    now = now or datetime.now(timezone.utc)
    settling = read_settling()
    card_states = read_card_states()
    led_path = ledger_path()
    ledger = cl.load_ledger(led_path)
    signals = read_signals()
    demo = bool(os.environ.get("OSTLER_DEMO_MODE"))
    # Pro entitlement (entitlement.py): None = enforcement off (default until
    # the daemon-side sidecar writer ships), else a fail-closed boolean.
    entitled = ent.front_page_entitled(now)
    try:
        profile = _obtain_profile(oxigraph_url, from_artefact)
        scout_cards = None if demo else read_scout_cards(profile, now, ledger)
        explore = not os.environ.get("OSTLER_EDITOR_DISABLE_EXPLORATION")
        feed = fp.build_frontpage(profile, now=now, settling=settling,
                                  card_states=card_states, ledger=ledger,
                                  signals=signals, scout_cards=scout_cards,
                                  demo=demo, entitled=entitled,
                                  exploration=explore)
    except Exception as exc:  # graph down / artefact missing -> never blank
        print(f"front-page: profile unavailable ({type(exc).__name__}: {exc}); "
              "emitting settling-only feed", file=sys.stderr)
        feed = fp.empty_frontpage(now=now, settling=settling)

    out_dir = editor_dir()
    feed_path = _atomic_write(os.path.join(out_dir, FEED_NAME),
                              json.dumps(feed, indent=2, ensure_ascii=False))
    html_path = _atomic_write(os.path.join(out_dir, HTML_NAME), rf.render(feed))

    # Reconcile the ledger with the ids actually emitted this tick (records first
    # emission, refreshes last, prunes stale) so next tick's created_utc is
    # stable and age decay bites. Best-effort: a ledger write failure must never
    # fail the feed we already wrote.
    try:
        emitted_ids = [c["id"] for c in feed.get("cards", [])]
        cl.save_ledger(cl.reconcile(ledger, emitted_ids, now), led_path)
    except Exception as exc:  # noqa: BLE001
        print(f"front-page: ledger update skipped ({type(exc).__name__}: {exc})",
              file=sys.stderr)

    return {"feed": feed_path, "html": html_path,
            "phase": feed.get("phase"), "cards": feed.get("card_count", 0)}


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(description="Emit the Front Page card feed artefacts.")
    p.add_argument("--oxigraph",
                   default=os.environ.get("OSTLER_OXIGRAPH_URL", "http://localhost:7878"))
    p.add_argument("--from-artefact", action="store_true",
                   help="read interest_profile.json instead of re-compiling")
    args = p.parse_args(argv)
    res = emit(args.oxigraph, from_artefact=args.from_artefact)
    print(f"front-page: {res['cards']} cards (phase={res['phase']}) -> "
          f"{res['feed']} + {res['html']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
