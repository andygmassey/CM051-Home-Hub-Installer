"""Record one Front Page card tap as a durable correction.

WHY THIS FILE EXISTS. The Front Page renders "Spot on" / "Not me" / "Don't
show" on every card. MEASURED 2026-09-13 on a walked box: tapping them did
NOTHING. The page's only handlers were two onclick functions that add a CSS
class, there was no fetch, no form and no endpoint anywhere in the daemon's 31
routes, and ~/.ostler/editor/interest_corrections.json had never been written.

Worse than a dead button: the handler adds a "chosen" class, so the control
LIGHTS UP as though the tap registered. The customer is told their correction
landed and it went nowhere.

Everything underneath was already built and tested. cm059-editor's
compiler/feedback.py record_feedback() routes a tap through CorrectionStore and
re-emits the feed, and interest_profile.apply_corrections folds corrections into
every recompile. Its own docstring names the missing piece: "the Hub API POST
route". That route is what this adds. No new storage, no second mechanism --
thin HTTP plumbing onto the handler that already exists, exactly as
duplicate_decision.py is for the wiki's Combine / Different buttons.
"""
from __future__ import annotations

import inspect
import os
import sys

_EDITOR_DIRS = (
    os.environ.get("OSTLER_EDITOR_HOME", ""),
    os.path.expanduser("~/.ostler/services/cm059-editor"),
)

# The three card verbs, plus the labels the UI actually prints. feedback.py
# normalises both, but validating here keeps an unknown verb a 400 rather than
# a 500 from deep inside the store.
_ACTIONS = {"strengthen", "weaken", "drop", "spot on", "not me", "don't show"}

# ``add`` is the FOURTH verb and it is a different shape from the other three.
#
# WHY IT IS HERE. CM059 PR #24 renders a masthead control ("Tell Ostler what
# you're into") that POSTs ``{action:'add', subject}`` to this very endpoint.
# The allowlist above excludes "add" and ``validate_payload`` demanded a
# ``card_id`` that a masthead control has no concept of, so a customer typing
# an interest and pressing Add got HTTP 400 and a "not saved" line. The store
# side was never the problem: ``CorrectionStore.add`` has existed and been
# folded into every recompile by ``interest_profile.apply_corrections`` the
# whole time.
#
# Aliases match CM059's ``feedback._ACTION_ALIASES`` exactly, including its
# separator-insensitivity, so the two normalisers cannot answer differently
# for the same string.
_ADD_ACTIONS = {"add", "add_interest", "add-interest", "add interest"}

# CorrectionStore.add's own default. Named here because the response has to be
# able to say which category was stored when the caller sent none.
_DEFAULT_ADD_CATEGORY = "user_added"


# Origins a browser may issue this WRITE from. MEASURED 2026-09-13 on a box:
# the Doctor's own routes on :8089 answer 200 with NO credential at all
# (/api/v1/sources proves it), and the app's only middleware is CORS with
# allow_origins=["*"]. The 401 seen elsewhere on that port comes from a
# DIFFERENT scheme entirely, a paired-device bearer, which the service token
# does not satisfy either.
#
# 🔴 SO AN Authorization HEADER HERE WOULD BE DECORATION, and shipping one
# would be worse than shipping nothing: it would look like security to the next
# reader while enforcing nothing (Archie stopped me adding exactly that).
#
# What IS real: this route WRITES to the customer's store, and with a wildcard
# CORS policy any page they open can issue the write. allow_credentials=False
# limits reading the answer back, but a write does not need to read. So the
# origin is checked here rather than left to a middleware that permits all of
# them. A request with no Origin at all is allowed: that is a same-process or
# curl caller, not a browser acting on a page's behalf.
_ALLOWED_ORIGIN_HOSTS = ("127.0.0.1", "localhost", "[::1]", "::1")


def origin_is_local(origin: str | None) -> bool:
    """True when a browser Origin is loopback, or absent entirely."""
    if not origin:
        return True          # non-browser caller; CORS does not apply
    o = origin.strip().lower()
    for scheme in ("http://", "https://"):
        if o.startswith(scheme):
            o = o[len(scheme):]
            break
    else:
        return False         # an origin we cannot parse is not a local one
    host = o.split("/")[0].rsplit(":", 1)[0] if not o.startswith("[") else o.split("]")[0] + "]"
    return host in _ALLOWED_ORIGIN_HOSTS


class ValidationError(Exception):
    def __init__(self, detail: str, status: int = 400):
        super().__init__(detail)
        self.detail = detail
        self.status = status


def _load_feedback_module():
    for d in _EDITOR_DIRS:
        if d and os.path.isdir(d):
            if d not in sys.path:
                sys.path.insert(0, d)
            try:
                from compiler import feedback  # noqa: PLC0415
                return feedback
            except Exception as exc:  # noqa: BLE001
                raise ValidationError(
                    f"the editor's feedback module is present but would not "
                    f"import: {exc}", 500) from exc
    raise ValidationError(
        "the Front Page editor is not installed on this box, so a card tap has "
        "nowhere to go. This is CANNOT-RECORD, not a silent success.", 503)


def validate_payload(body) -> dict:
    if not isinstance(body, dict):
        raise ValidationError("body must be a JSON object")
    action = (body.get("action") or "").strip()

    # The add verb first, because it is the one that must NOT be asked for a
    # card_id. A masthead control has no card.
    if action.lower() in _ADD_ACTIONS:
        subject = (body.get("subject") or "").strip()
        if not subject:
            raise ValidationError("subject is required for the add action")
        domain = body.get("domain")
        if domain is not None:
            domain = str(domain).strip() or None
        category = body.get("category")
        if category is not None:
            category = str(category).strip() or None
        return {"card_id": None, "action": "add", "interest_id": None,
                "subject": subject, "domain": domain, "category": category}

    card_id = (body.get("card_id") or "").strip()
    if not card_id:
        raise ValidationError("card_id is required")
    if action.lower() not in _ACTIONS:
        raise ValidationError(
            f"unknown action {action!r}; expected one of "
            f"{', '.join(sorted(_ACTIONS | _ADD_ACTIONS))}")
    interest_id = body.get("interest_id")
    if interest_id is not None:
        interest_id = str(interest_id).strip() or None
    return {"card_id": card_id, "action": action, "interest_id": interest_id,
            "subject": None, "domain": None, "category": None}


def record(normalised: dict) -> dict:
    """Write the correction. Raises ValidationError; never returns a bare ok.

    🔴 THE RESULT MUST SAY WHAT WAS WRITTEN. Returning {"ok": true} would put
    this endpoint in the same class as the buttons it replaces: a success
    report that is not evidence of anything.
    """
    feedback = _load_feedback_module()

    if normalised["action"] == "add":
        return _record_add(feedback, normalised)

    verb = feedback.normalise_action(normalised["action"])
    if not verb:
        raise ValidationError(f"unknown action {normalised['action']!r}")
    try:
        out = feedback.record_feedback(
            normalised["card_id"], normalised["interest_id"], verb)
    except Exception as exc:  # noqa: BLE001
        raise ValidationError(f"could not record the tap: {exc}", 500) from exc
    _refuse_if_not_ok(out)
    result = {"status": "recorded", "action": verb,
              "card_id": normalised["card_id"]}
    if isinstance(out, dict):
        for k in ("path", "corrections_path", "reemitted", "applied_to"):
            if k in out:
                result[k] = out[k]
    return result


def _refuse_if_not_ok(out) -> None:
    """A handler that answered ``ok: False`` REFUSED the write. Say so.

    🔴 This used to be missing, and its absence is the same defect the whole
    file exists to kill. ``record_feedback`` never raises for the ordinary
    refusals (unknown action, no interest_id, no subject) -- it returns
    ``{"ok": False, "error": ...}``. Without this check the route turned that
    into ``{"status": "recorded"}`` with HTTP 200: a refusal wearing the
    clothes of a success, exactly like the button that lit up and wrote
    nothing.
    """
    if isinstance(out, dict) and out.get("ok") is False:
        raise ValidationError(
            str(out.get("error") or "the editor refused the correction"), 400)


def _record_add(feedback, normalised: dict) -> dict:
    """Persist one "tell Ostler what you're into" subject.

    TWO PATHS, and the response says which one ran.

    1. The installed editor already knows the verb (CM059 PR #24 onward):
       ``record_feedback`` grew ``subject`` / ``domain`` / ``category``
       keywords and an ``add`` branch. Use it, so there is one writer.
    2. The installed editor predates it. CM051 vendors CM059 at a pin that
       does NOT carry #24 -- measured against ``vendor/cm059_editor`` --
       where ``normalise_action("add")`` returns None and passing
       ``subject=`` is a TypeError. Calling it anyway would turn the Add
       button from a 400 into a 500, which is not a fix. So this falls back
       to the same place #24's branch goes: ``CorrectionStore.add``, against
       the same store path resolved by the same module, then the same cheap
       re-emit. The row written is the row #24 writes.

    The capability is PROBED, not inferred from a version: the signature must
    carry ``subject`` AND the normaliser must know the verb. Either alone
    would be a guess.
    """
    subject = normalised["subject"]
    domain = normalised["domain"]
    category = normalised["category"]

    try:
        params = inspect.signature(feedback.record_feedback).parameters
        native = ("subject" in params
                  and feedback.normalise_action("add") == "add")
    except Exception:  # noqa: BLE001 - an unprobeable module is not a native one
        native = False

    if native:
        try:
            out = feedback.record_feedback(
                None, None, "add", subject=subject,
                domain=domain, category=category)
        except Exception as exc:  # noqa: BLE001
            raise ValidationError(
                f"could not record the interest: {exc}", 500) from exc
        _refuse_if_not_ok(out)
        result = {"status": "recorded", "action": "add", "subject": subject,
                  "domain": domain,
                  "category": category or _DEFAULT_ADD_CATEGORY,
                  "via": "editor_feedback_module"}
        if isinstance(out, dict) and "reemitted" in out:
            result["reemitted"] = out["reemitted"]
        return result

    try:
        from compiler import corrections as corr_mod  # noqa: PLC0415
    except Exception as exc:  # noqa: BLE001
        raise ValidationError(
            f"the editor's correction store would not import: {exc}",
            500) from exc

    try:
        editor_dir = feedback._editor_dir()
        store = corr_mod.CorrectionStore(
            path=feedback._corrections_path(editor_dir))
        add_kwargs = {}
        if domain:
            add_kwargs["domain"] = domain
        if category:
            add_kwargs["category"] = category
        store.add(subject, **add_kwargs)
    except Exception as exc:  # noqa: BLE001
        raise ValidationError(
            f"could not record the interest: {exc}", 500) from exc

    # Same re-emit the other verbs get, and the same honest caveat #24 writes
    # down: a brand-new interest has no row in the already-compiled artefact,
    # so it cannot appear until the next FULL recompile. The re-emit is still
    # run, for consistency and because it is harmless.
    reemitted = False
    try:
        reemitted = bool(feedback._reemit(None))
    except Exception:  # noqa: BLE001 - a failed re-emit does not undo the write
        reemitted = False

    return {"status": "recorded", "action": "add", "subject": subject,
            "domain": domain, "category": category or _DEFAULT_ADD_CATEGORY,
            "reemitted": reemitted, "via": "correction_store"}
