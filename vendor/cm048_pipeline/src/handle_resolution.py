"""Handle-to-person resolution for the inner-circle consumer.

Resolves a message handle (phone or email) to a graph Person, by the same
identifier path the graph already uses: a Person carries a PersonIdentifier
with identifierType and identifierValue, and a merged person carries a
mergedInto tombstone. This follows that tombstone to its survivor. It mirrors
CM041 identity_resolver find_by_identifier, which returns LIMIT 1 with no
ordering and so can pick an arbitrary carrier. Here, two live carriers are
AMBIGUOUS and refused, never picked.

Normalisation:
  phone: only an international (+) number that phonenumbers says is valid,
         rendered as E.164. National format (no +) is refused, never guessed
         to a region. A WhatsApp LID is neither a phone nor an email.
  email: stripped and lowercased; must look like an address.

Statuses: resolved (exactly one live person), unresolved (no carrier),
ambiguous (two or more live carriers), invalid (the handle cannot be normalised),
business_sender (an alphanumeric or '#' business ID: not a person, excluded).
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable, Optional

import phonenumbers

KINDS = ("phone", "email")
_EMAIL = re.compile(r"[^@\s]+@[^@\s]+\.[^@\s]+")
_MAX_HOPS = 16


def normalise_handle(raw) -> Optional[tuple]:
    if raw is None:
        return None
    s = str(raw).strip()
    if not s:
        return None
    if "@" in s:
        v = s.lower()
        return ("email", v) if _EMAIL.fullmatch(v) else None
    if s.startswith("+"):
        try:
            parsed = phonenumbers.parse(s, None)
        except phonenumbers.NumberParseException:
            return None
        if phonenumbers.is_valid_number(parsed):
            return ("phone", phonenumbers.format_number(parsed, phonenumbers.PhoneNumberFormat.E164))
        return None
    return None


# A business or alphanumeric sender ID: a brand or bank name, or a '#'-prefixed
# business ID, carried where a handle goes. Letters, spaces and the '#' prefix
# only. Any digit, '@', '+', ';' or other punctuation disqualifies it, so a
# number, an address, a chat GUID or a LID is never classed as a business.
_BUSINESS = re.compile(r"#?[A-Za-z][A-Za-z ]{0,30}")


def is_business_sender(raw) -> bool:
    s = str(raw or "").strip()
    if not s or len(s) > 32:
        return False
    return _BUSINESS.fullmatch(s) is not None


def _follow(person: str, merged_into: dict) -> str:
    seen = {person}
    cur = person
    for _ in range(_MAX_HOPS):
        nxt = merged_into.get(cur)
        if not nxt or nxt in seen:
            return cur
        seen.add(nxt)
        cur = nxt
    return cur


def index_from_rows(rows: Iterable[tuple], *, merged_into: dict, stats: Optional[dict] = None) -> dict:
    """rows: (person_id, identifier_type, identifier_value). Returns {(kind, value): {person_id}}.

    Identifier values that cannot be normalised are left out and counted in
    stats["unnormalisable_identifiers"]. They are never guessed in.
    """
    idx: dict = {}
    for person, id_type, id_value in rows:
        if id_type not in KINDS:
            continue
        key = normalise_handle(id_value)
        if key is None:
            if stats is not None:
                stats["unnormalisable_identifiers"] = stats.get("unnormalisable_identifiers", 0) + 1
            continue
        idx.setdefault(key, set()).add(_follow(person, merged_into))
    return idx


@dataclass(frozen=True)
class Resolution:
    status: str
    person_id: Optional[str]
    candidates: int


def resolve(handle, index: dict) -> Resolution:
    key = normalise_handle(handle)
    if key is None:
        # A business sender is not a person and is never resolved or guessed.
        if is_business_sender(handle):
            return Resolution("business_sender", None, 0)
        return Resolution("invalid", None, 0)
    carriers = index.get(key, set())
    if not carriers:
        return Resolution("unresolved", None, 0)
    if len(carriers) == 1:
        return Resolution("resolved", next(iter(carriers)), 1)
    return Resolution("ambiguous", None, len(carriers))
