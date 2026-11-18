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


MINOR_FLAG_KEYS = ("about_minor", "child", "minor", "is_minor")
_NOT_MINOR_TEXT = frozenset({"", "false", "0", "no", "none"})


def _flag_says_minor(value: Any) -> bool:
    """Any value other than None, False, 0 or a false-word is "minor" (fail closed):
    "yes", "TRUE", 2 and True all read as minor (CB134 red-team M08-M10, A22)."""
    if value is None or value is False:
        return False
    if isinstance(value, int) and not isinstance(value, bool) and value == 0:
        return False
    if isinstance(value, str) and value.strip().lower() in _NOT_MINOR_TEXT:
        return False
    return True


def _is_about_minor(preference: Dict[str, Any]) -> bool:
    """True when ANY minor flag, at the top level or inside ``extra``, says minor.
    ``extra`` may be a JSON string: it is parsed, and an unparseable one fails closed."""
    import json
    if any(_flag_says_minor(preference.get(k)) for k in MINOR_FLAG_KEYS):
        return True
    extra = preference.get("extra")
    if isinstance(extra, str):
        try:
            extra = json.loads(extra)
        except ValueError:
            return True  # cannot read the record's flags: fail closed
    if extra is None:
        return False
    if not isinstance(extra, dict):
        return True
    return any(_flag_says_minor(extra.get(k)) for k in MINOR_FLAG_KEYS)


# ---------------------------------------------------------------------------
# CM051 DIVERGENCE (CB134, 18 Nov 2026). Recorded in
# vendor/divergences/cm019_preferences_usage_journal.UNRECORDED.md.
#
# The enrichment look-up gate is NOT the upstream rule above. Ruling of 18 Nov 2026
# (verbatim, see the divergence record): "L0/L1 only, never L2 (Recommended)"
# and "I cannot launch without the data enrichment. End of." So a look-up may
# send the subject string of an L0 or L1 item; an L2, L3, unlevelled, unknown,
# or unstamped-L0 (legacy-ambiguous) item is refused. The shared scale table is
# NOT changed for this: 135 adds the dedicated enrichment destination row
# (CB135-ENRICHMENT-L1-DESTINATION).
#
# Legacy numeric compartments, mapped by PWG services/ingest/src/parsers/base.py
# (SENSITIVE_LEVEL and FINANCIAL_LEVEL = 1 mean personal location, third-party
# people and spend, so legacy 1 is NOT publishable; lines 58-59, 70-71, 74):
# legacy 2, 4 and 6 may map to L0/L1; legacy 0, 1, 3 and 5 are refused.
# Health (legacy 0, HEALTH_LEVEL, base.py line 71) is refused whatever its number.
#
# Category exclusions apply whatever the level (Archie 18 Nov 2026): person
# names, locations, addresses, finance, health, dietary and anything about a
# minor are never looked up.
# ---------------------------------------------------------------------------

ENRICH_CANONICAL_ALLOWED = frozenset({"L0", "L1"})
ENRICH_LEGACY_ALLOWED = frozenset({"2", "4", "6"})
REASON_CATEGORY = "category_excluded"
_EXCLUDED_CATEGORIES = frozenset({
    "person", "people", "contact", "contacts", "name", "names",
    "location", "locations", "address", "addresses", "home",
    "finance", "financial", "money", "spend", "spending",
    "health", "health_record", "medical", "dietary", "diet",
    "minor", "minors", "child", "children",
})


def _excluded_category(preference: Dict[str, Any]) -> bool:
    try:  # package context (enricher)
        from .derive.sensitive import never_read_categories
    except ImportError:  # top-level import (tests put enrich/src on sys.path)
        from derive.sensitive import never_read_categories
    category = str(preference.get("category") or "").strip().lower()
    if not category:
        return False
    return category in _EXCLUDED_CATEGORIES or category in set(never_read_categories())


def _enrich_legacy_reason(value: Any) -> Optional[str]:
    token = _legacy_token(value)
    if token is None:
        return REASON_UNKNOWN_LEVEL
    if token in ENRICH_LEGACY_ALLOWED:
        return None
    return "level_legacy_" + token


def outbound_refusal(preference: Dict[str, Any]) -> Optional[str]:
    """CM051 enrichment look-up gate (see the divergence note above).

    None when the subject may be sent to a look-up, else a reason code (counts
    only, never the subject). Order: not a dict, minor, excluded category,
    then the level.
    """
    if not isinstance(preference, dict):
        return REASON_UNKNOWN_LEVEL
    if _is_about_minor(preference):
        return REASON_MINOR
    if _excluded_category(preference):
        return REASON_CATEGORY
    level = preference.get("privacy_level")
    legacy = preference.get("compartment_level")
    if level is None:
        # Unlevelled, or legacy-only: the legacy number decides, nothing else.
        if legacy is None:
            return REASON_UNKNOWN_LEVEL
        return _enrich_legacy_reason(legacy)
    if isinstance(level, bool) or not isinstance(level, str):
        return REASON_UNKNOWN_LEVEL
    token = level.strip().upper()
    if token not in ENRICH_CANONICAL_ALLOWED:
        return "level_" + token if token in {"L2", "L3"} else REASON_UNKNOWN_LEVEL
    if token == "L0" and preference.get(PRIVACY_SCALE_KEY) != pwg_privacy.CANONICAL_SCALE_VALUE:
        return "level_legacy_L0"  # an unstamped L0 is legacy-ambiguous (old PWG L0 = owner-private)
    if legacy is not None:
        reason = _enrich_legacy_reason(legacy)
        if reason is not None:
            return reason
    return None


def outbound_allowed(preference: Dict[str, Any]) -> bool:
    return outbound_refusal(preference) is None


# ---------------------------------------------------------------------------
# CM051 DIVERGENCE (CB134, Archie's venue ruling, 18 Nov 2026): a business or
# venue NAME may be looked up as the name only. Never an address, coordinates,
# postcode, dates, visit counts, or "home" / "work" / "near me" labels. Never
# looked up, whatever the level: (a) Art. 9-type venues (clinic, hospital, GP,
# pharmacy, therapist, dentist, places of worship, political venues,
# sexual-health venues, law firms, rehab); (b) a venue name that contains a
# person name from the owner's contacts.
# ---------------------------------------------------------------------------

VENUE_CATEGORIES = frozenset({"place", "venue", "restaurant"})
REASON_VENUE_SHAPE = "venue_not_a_name"
REASON_VENUE_ART9 = "venue_art9"
REASON_VENUE_CONTACT = "venue_contains_contact_name"

_VENUE_LOCATION_WORDS = frozenset({"home", "work", "office", "near", "address", "postcode"})
_ART9_VENUE_WORDS = frozenset({
    "clinic", "clinics", "hospital", "hospitals", "gp", "surgery", "pharmacy", "chemist",
    "therapist", "therapy", "counselling", "counseling", "psychiatrist", "psychologist",
    "dentist", "dental", "church", "chapel", "mosque", "temple", "synagogue", "gurdwara",
    "cathedral", "party", "campaign", "sexual", "sexhealth", "clinic", "rehab",
    "lawyer", "lawyers", "solicitor", "solicitors", "law",
})


def _tokens(text: str):
    import re
    import unicodedata
    folded = unicodedata.normalize("NFKD", str(text))
    folded = "".join(ch for ch in folded if not unicodedata.combining(ch))
    return [t for t in re.split(r"[^a-z0-9]+", folded.lower()) if t]


def contact_match(name: str, contact_names) -> bool:
    """True when every token of some owner contact name appears in ``name``.
    Case, diacritics, whitespace, punctuation and "Last, First" order are all
    ignored, because the comparison is on the token set."""
    toks = set(_tokens(name))
    for person in contact_names or ():
        want = set(_tokens(person))
        if want and want <= toks:
            return True
    return False


def person_shaped(label: str) -> bool:
    """A free-text label that reads as a person's name: two or three alphabetic
    words, each capitalised, no digits. A heuristic: it over-refuses two- and
    three-word proper nouns, and it is the cost of the interest rule."""
    words = str(label or "").split()
    if not 2 <= len(words) <= 3:
        return False
    for w in words:
        if not w.isalpha() or not w[0].isupper():
            return False
    return True


def _venue_shape_refusal(name: str) -> Optional[str]:
    import re
    if re.search(r"\d", name) or any(ch in name for ch in ",@/#"):
        return REASON_VENUE_SHAPE          # digits, commas or symbols: an address, a date or a count
    if any(t in _VENUE_LOCATION_WORDS for t in _tokens(name)):
        return REASON_VENUE_SHAPE          # a location label, not a name
    return None


def _venue_art9_refusal(name: str) -> Optional[str]:
    if any(t in _ART9_VENUE_WORDS for t in _tokens(name)):
        return REASON_VENUE_ART9
    return None


def _venue_contact_refusal(name: str, contact_names=frozenset()) -> Optional[str]:
    toks = set(_tokens(name))
    for person in contact_names:
        if set(_tokens(person)) and set(_tokens(person)) <= toks:
            return REASON_VENUE_CONTACT
    return None


def venue_name_refusal(subject: str, category: str, contact_names=frozenset()) -> Optional[str]:
    """None when this venue subject may be looked up as a name, else a reason code."""
    if str(category or "").strip().lower() not in VENUE_CATEGORIES:
        return None
    name = str(subject or "")
    if not name.strip():
        return REASON_VENUE_SHAPE
    return (_venue_shape_refusal(name)
            or _venue_art9_refusal(name)
            or _venue_contact_refusal(name, contact_names))
