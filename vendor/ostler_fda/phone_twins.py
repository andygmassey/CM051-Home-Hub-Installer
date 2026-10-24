"""A number-named (provisional) person is the Contacts person who holds that
number, when exactly one named person holds it.

WHY (P13, v1.0.117 walk). The Front Page and the brief showed raw numbers for
people the owner HAS in Contacts. Measured on the walk box (counts only): 41
Person nodes named by a "+" number, all ``displayNameProvisional``, 39 from
WhatsApp and 2 from iMessage; 14 of them carry a phone identifier that sits on
another Person, and for all 14 the other Person is a Contacts card, created
FIRST, and the only other holder of that number.

Root cause: ``pwg_ingest.ingest_whatsapp`` and ``ingest_imessage`` mint
``uuid5(handle)`` and ask only "did I already create this URI?" (``_live_person``),
never "does somebody already hold this number?", so a contact who messages the
owner after their card was written got a second, number-named node. The one
sweep that folds exact twins (``dedupe_merge.run``) runs once, at install,
so twins minted later stay split. And it compares identifier STRINGS, so a
card stored in national form ("07700 900123") never meets the "+44..." handle.

THE HOUSEHOLD RULE. Same name plus a shared detail is one person; a shared
detail alone is not (a household landline on two family cards). A provisional
node has no name of its own, only the number, so it is folded ONLY when
exactly ONE named person holds that number. Two or more named holders means
the number is shared, and the node is left alone: guessing would hand one
person's messages to another.

Stdlib only. The phone canonicalisation is the same as CM048
``handle_identity.canon_phone`` (the owner's country from
``DEFAULT_COUNTRY_CODE``, else read from the owner's own "+" number in
``USER_PHONE``; a unique trailing-8-digit match when no country is known).
"""
from __future__ import annotations

import os
import re
from typing import Callable, Dict, Iterable, Mapping, Optional, Set

PWG = "https://schema.ostler.ai/ontology#"
_PHONE_CHARS = re.compile(r"^\+?[\d\s\-().]+$")
_SUFFIX_LEN = 8
_CALLING_CODES = frozenset(
    {1, 7, 20, 27, 30, 31, 32, 33, 34, 36, 39, 40, 41, 43, 44, 45, 46, 47, 48,
     49, 51, 52, 53, 54, 55, 56, 57, 58, 60, 61, 62, 63, 64, 65, 66, 81, 82, 84,
     86, 90, 91, 92, 93, 94, 95, 98, 212, 213, 216, 234, 254, 255, 256, 260,
     263, 351, 352, 353, 354, 355, 356, 357, 358, 359, 370, 371, 372, 380, 381,
     385, 386, 420, 421, 852, 853, 855, 880, 886, 960, 961, 962, 965, 966, 971,
     972, 973, 974, 977}
)

# The one SELECT the index needs: every live Person's phone identifiers, its
# display name(s), whether its name is provisional, and whether it is carded.
INDEX_QUERY = (
    f"PREFIX pwg: <{PWG}>\n"
    "SELECT ?p ?v ?name ?prov ?uid WHERE {\n"
    "  ?p a pwg:Person ; pwg:hasIdentifier ?i .\n"
    '  ?i pwg:identifierType "phone" ; pwg:identifierValue ?v .\n'
    "  OPTIONAL { ?p pwg:displayName ?name }\n"
    "  OPTIONAL { ?p pwg:displayNameProvisional ?prov }\n"
    "  OPTIONAL { ?p pwg:hasIdentifier ?u . "
    '?u pwg:identifierType "icloud_contact_uid" ; pwg:identifierValue ?uid }\n'
    "}"
)


def _val(binding) -> str:
    if isinstance(binding, Mapping):
        binding = binding.get("value", "")
    return str(binding or "").strip()


def default_country_code(env: Mapping[str, str] = os.environ) -> Optional[int]:
    raw = (env.get("DEFAULT_COUNTRY_CODE") or "").strip().lstrip("+")
    if raw.isdigit():
        return int(raw)
    owner = (env.get("USER_PHONE") or "").strip()
    if owner.startswith("+"):
        digits = re.sub(r"\D", "", owner)
        for n in (1, 2, 3):
            if digits[:n] and int(digits[:n]) in _CALLING_CODES:
                return int(digits[:n])
    return None


def canon_phone(raw: str, default_cc: Optional[int] = None) -> str:
    h = (raw or "").strip()
    if h.lower().endswith("@s.whatsapp.net"):
        h = "+" + h.split("@", 1)[0]
    if not h or "@" in h or not _PHONE_CHARS.match(h):
        return ""
    digits = re.sub(r"\D", "", h)
    if len(digits) < 7:
        return ""
    if h.startswith("+"):
        return "+" + digits
    if digits.startswith("00"):
        return "+" + digits[2:]
    if default_cc:
        cc = str(default_cc)
        if digits.startswith("0"):
            return "+" + cc + digits[1:]
        if digits.startswith(cc) and len(digits) >= len(cc) + 8:
            return "+" + digits
        return "+" + cc + digits
    return ""


def phone_suffix(raw: str) -> str:
    h = (raw or "").split("@", 1)[0]
    digits = re.sub(r"\D", "", h)
    return digits[-_SUFFIX_LEN:] if len(digits) >= _SUFFIX_LEN else ""


def is_real_name(name: str) -> bool:
    n = (name or "").strip()
    if not n or "@" in n:
        return False
    if re.fullmatch(r"\+?[\d \-().]+", n):
        return False
    return any(c.isalpha() for c in n)


class PhoneTwinIndex:
    """Who holds each phone number, split into NAMED holders (a real human
    name that is not marked provisional) and everyone else."""

    def __init__(self, rows: Iterable[Mapping], default_cc: Optional[int] = None):
        self.default_cc = default_cc
        names: Dict[str, Set[str]] = {}
        prov: Set[str] = set()
        carded: Set[str] = set()
        phones: Dict[str, Set[str]] = {}
        for r in rows:
            p = _val(r.get("p"))
            if not p:
                continue
            v = _val(r.get("v"))
            if v:
                phones.setdefault(p, set()).add(v)
            n = _val(r.get("name"))
            if n:
                names.setdefault(p, set()).add(n)
            if _val(r.get("prov")).lower() in ("true", "1"):
                prov.add(p)
            if _val(r.get("uid")):
                carded.add(p)
        self.phones = phones
        self.carded = carded
        self.named: Set[str] = {
            p for p in phones
            if any(is_real_name(n) for n in names.get(p, ())) and (p not in prov or p in carded)
        }
        self._by_canon: Dict[str, Set[str]] = {}
        self._by_suffix: Dict[str, Set[str]] = {}
        for p in self.named:
            for v in phones[p]:
                c = canon_phone(v, default_cc)
                if c:
                    self._by_canon.setdefault(c, set()).add(p)
                s = phone_suffix(v)
                if s:
                    self._by_suffix.setdefault(s, set()).add(p)

    def named_holders(self, phone: str) -> Set[str]:
        c = canon_phone(phone, self.default_cc)
        if c and c in self._by_canon:
            return set(self._by_canon[c])
        if self.default_cc is not None:
            # With the owner's country known every stored form canonicalises,
            # so a miss is a miss: no trailing-digit guess across countries.
            return set()
        s = phone_suffix(phone)
        return set(self._by_suffix.get(s, ())) if s else set()

    def holder_for(self, phone: str, exclude: str = "") -> Optional[str]:
        """The single named person holding ``phone``, else None (nobody, or a
        shared number: the household rule)."""
        holders = self.named_holders(phone) - {exclude}
        return next(iter(holders)) if len(holders) == 1 else None

    def is_unnamed(self, person: str) -> bool:
        return person in self.phones and person not in self.named and person not in self.carded


def load_index(query: Callable[[str], list], env: Mapping[str, str] = os.environ) -> PhoneTwinIndex:
    """Build the index with ``query`` (a SPARQL SELECT returning bindings).
    Lets the caller's store errors propagate: "could not look" must never be
    read as "nobody holds it"."""
    return PhoneTwinIndex(query(INDEX_QUERY), default_country_code(env))


__all__ = ["PhoneTwinIndex", "load_index", "canon_phone", "phone_suffix",
           "default_country_code", "is_real_name", "INDEX_QUERY"]
