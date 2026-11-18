"""Per-item privacy gate for outbound public lookups.

consent.py answers "did the owner allow online look-ups at all?". This module
answers the second question, per item: "may THIS item leave the Mac?". Both
must say yes. The consent gate stays exactly as it is; this one runs after it.

An item is refused, and no request is made for it, when ANY of these holds:

  * its canonical level may not go to ``others`` (privacy design PR 3);
  * its privacy level is missing or unrecognised (fail closed);
  * it is about a minor (``extra.about_minor``, stamped at ingest from the
    owner's minors registry).

WHICH LEVELS MAY GO OUT. An online look-up hands the item's subject to a third
party, so its destination is ``others``. The decision for a canonical string
level is made ONLY by the vendored canonical helper
(services/common/pwg_privacy.py, sha-pinned; ``outbound_ok``): on the canonical
scale (L0 public ... L3 owner-only) only L0 may go to others; L1 only in a
redacted form no look-up produces, so it is refused; L2 and L3 never. An L0
WITHOUT the scale stamp is LEGACY (old PWG L0 meant owner-private) and is
refused through ``legacy_l0_guard`` until the relabel. No level logic lives in
this file for canonical strings.

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

import sys
from pathlib import Path
from typing import Any, Dict, Optional

# The vendored canonical helper (services/common). No fallback: a missing
# helper fails loudly at import rather than letting anything out.
_COMMON_DIR = Path(__file__).resolve().parents[2] / "common"
if _COMMON_DIR.is_dir() and str(_COMMON_DIR) not in sys.path:
    sys.path.insert(0, str(_COMMON_DIR))
import pwg_privacy  # noqa: E402

# An online look-up sends the subject to a third party.
OUTBOUND_DESTINATION = "others"
# The payload key a reader must fetch alongside the level (the scale stamp).
PRIVACY_SCALE_KEY = pwg_privacy.CANONICAL_SCALE_KEY

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
        if pwg_privacy.parse_privacy_level(token):
            # Canonical strings are decided in outbound_refusal by the helper,
            # which needs the whole record (the scale stamp).
            return _canonical_reason({"privacy_level": token})
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


def _canonical_reason(record: Dict[str, Any]) -> Optional[str]:
    """None if the canonical helper lets this record go to others, else why not."""
    level = pwg_privacy.effective_level(record)
    if pwg_privacy.outbound_ok(record, destination=OUTBOUND_DESTINATION):
        return None
    if pwg_privacy.legacy_l0_guard(record):
        return "level_legacy_L0"
    return "level_" + str(level)


def _legacy_token(value: Any) -> Optional[str]:
    """The lookup key a legacy compartment value is filed under, or None."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        token = value.strip()
        if "#" in token:
            token = token.rsplit("#", 1)[-1]
        elif "/" in token:
            token = token.rsplit("/", 1)[-1]
        if token.startswith("pwg:"):
            token = token[4:]
        return token.lower()
    return None


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
    if preference.get("privacy_level") is None:
        # No canonical level. A legacy compartment alone is LEGACY-AMBIGUOUS and
        # the scale reads it as L3 (legacy and missing = L3): never outbound,
        # whatever its number. Only a recognised legacy value gets a reason code.
        legacy = preference.get("compartment_level")
        token = _legacy_token(legacy)
        if token is None or token not in _LEGACY_ALLOWED:
            return REASON_UNKNOWN_LEVEL
        return "level_legacy_" + token
    present = [
        preference[k] for k in ("privacy_level", "compartment_level") if k in preference
    ]
    if not present:
        return REASON_UNKNOWN_LEVEL
    for key in ("privacy_level", "compartment_level"):
        if key not in preference:
            continue
        value = preference[key]
        if key == "privacy_level" and isinstance(value, str) and pwg_privacy.parse_privacy_level(value):
            # The record the helper reads: the level and its scale stamp.
            reason = _canonical_reason({
                "privacy_level": value,
                pwg_privacy.CANONICAL_SCALE_KEY: preference.get(pwg_privacy.CANONICAL_SCALE_KEY),
            })
        else:
            reason = _level_reason(value)
        if reason is not None:
            return reason
    return None


def outbound_allowed(preference: Dict[str, Any]) -> bool:
    return outbound_refusal(preference) is None
