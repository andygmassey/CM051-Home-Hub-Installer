"""Per-item privacy gate for outbound public lookups.

consent.py answers "did the owner allow online look-ups at all?". This module
answers the second question, per item: "may THIS item leave the Mac?". Both
must say yes. The consent gate stays exactly as it is; this one runs after it.

An item is refused, and no request is made for it, when ANY of these holds:

  * its privacy level is anything other than publishable (canonical L2);
  * its privacy level is missing or unrecognised (fail closed);
  * it is about a minor (``extra.about_minor``, stamped at ingest from the
    owner's minors registry).

WHICH LEVELS MAY GO OUT. The canonical ladder (services/mcp/src/privacy_model.py)
is NOT ordered by digit: L0 is owner-private / never-share (the MOST
restrictive), L1 is private but assistant-usable, L2 is trusted / publishable,
L3 is body-private / index-only. An online look-up hands the item's subject to
a third party, which is publishing it, so only L2 qualifies.

Producers write two shapes, and both are read:

  * ``privacy_level``: the canonical string (L0..L3).
  * ``compartment_level``: the legacy integer, written by every ingest parser
    via ParsedPreference.to_payload (services/ingest/src/parsers/base.py).

Legacy integers allowed out: 2 (L2Trusted), 4 (L4Public), 6 (L6Broadcast).
Refused: 0 (L0Personal), 1 (L1Family), 3 (L3Community) and 5. Five is refused
even though privacy_model maps L5Commercial to L2, because the Apple notes and
health producers write 5 meaning "HIGHEST PRIVACY" (services/ingest/src/parsers/
apple.py). Two producers disagree on what 5 means, so it is read the safe way.

When both fields are present, BOTH must allow; either one refusing refuses.

Logging is counts only: the gate returns a reason code, never the subject.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

# Canonical string levels that may be sent to a public host.
OUTBOUND_ALLOWED_LEVELS = frozenset({"L2"})
_CANONICAL = frozenset({"L0", "L1", "L2", "L3"})

# Legacy compartment (integer or named node) -> may it go out?
_LEGACY_ALLOWED = {
    "0": False, "l0personal": False,
    "1": False, "l1family": False, "l1private": False,
    "2": True, "l2trusted": True,
    "3": False, "l3community": False,
    "4": True, "l4public": True,
    "5": False, "l5commercial": False,
    "6": True, "l6broadcast": True,
}

# Reason codes (stable; used as counter keys).
REASON_UNKNOWN_LEVEL = "level_unknown"
REASON_MINOR = "minor"


def _level_reason(value: Any) -> Optional[str]:
    """None if this one level value allows outbound, else a reason code."""
    if value is None or isinstance(value, bool):
        return REASON_UNKNOWN_LEVEL
    if isinstance(value, int):
        allowed = _LEGACY_ALLOWED.get(str(value))
        if allowed is None:
            return REASON_UNKNOWN_LEVEL
        return None if allowed else "level_legacy_%d" % value
    if isinstance(value, str):
        token = value.strip()
        if token.upper() in _CANONICAL:
            level = token.upper()
            return None if level in OUTBOUND_ALLOWED_LEVELS else "level_" + level
        if "#" in token:
            token = token.rsplit("#", 1)[-1]
        elif "/" in token:
            token = token.rsplit("/", 1)[-1]
        if token.startswith("pwg:"):
            token = token[4:]
        allowed = _LEGACY_ALLOWED.get(token.lower())
        if allowed is None:
            return REASON_UNKNOWN_LEVEL
        return None if allowed else "level_legacy_" + token.lower()
    return REASON_UNKNOWN_LEVEL


def _is_about_minor(preference: Dict[str, Any]) -> bool:
    extra = preference.get("extra")
    flags = [preference.get("about_minor")]
    if isinstance(extra, dict):
        flags.append(extra.get("about_minor"))
    # Fail closed: any present value other than None/False means "minor".
    return any(f is not None and f is not False for f in flags)


def outbound_refusal(preference: Dict[str, Any]) -> Optional[str]:
    """Return None when the item may be sent to a public host, else why not.

    The reason is a short code ("level_L3", "level_unknown", "minor", ...),
    safe to count and log. It never contains the item's subject or id.
    """
    if not isinstance(preference, dict):
        return REASON_UNKNOWN_LEVEL
    if _is_about_minor(preference):
        return REASON_MINOR
    present = [
        preference[k] for k in ("privacy_level", "compartment_level") if k in preference
    ]
    if not present:
        return REASON_UNKNOWN_LEVEL
    for value in present:
        reason = _level_reason(value)
        if reason is not None:
            return reason
    return None


def outbound_allowed(preference: Dict[str, Any]) -> bool:
    return outbound_refusal(preference) is None
