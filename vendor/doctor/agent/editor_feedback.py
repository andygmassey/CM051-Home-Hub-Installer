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
    card_id = (body.get("card_id") or "").strip()
    if not card_id:
        raise ValidationError("card_id is required")
    action = (body.get("action") or "").strip()
    if action.lower() not in _ACTIONS:
        raise ValidationError(
            f"unknown action {action!r}; expected one of "
            f"{', '.join(sorted(_ACTIONS))}")
    interest_id = body.get("interest_id")
    if interest_id is not None:
        interest_id = str(interest_id).strip() or None
    return {"card_id": card_id, "action": action, "interest_id": interest_id}


def record(normalised: dict) -> dict:
    """Write the correction. Raises ValidationError; never returns a bare ok.

    🔴 THE RESULT MUST SAY WHAT WAS WRITTEN. Returning {"ok": true} would put
    this endpoint in the same class as the buttons it replaces: a success
    report that is not evidence of anything.
    """
    feedback = _load_feedback_module()
    verb = feedback.normalise_action(normalised["action"])
    if not verb:
        raise ValidationError(f"unknown action {normalised['action']!r}")
    try:
        out = feedback.record_feedback(
            normalised["card_id"], normalised["interest_id"], verb)
    except Exception as exc:  # noqa: BLE001
        raise ValidationError(f"could not record the tap: {exc}", 500) from exc
    result = {"status": "recorded", "action": verb,
              "card_id": normalised["card_id"]}
    if isinstance(out, dict):
        for k in ("path", "corrections_path", "reemitted", "applied_to"):
            if k in out:
                result[k] = out[k]
    return result
