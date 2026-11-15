"""Who is behind a message handle: a contact, the owner, or not a person at all.

WHY (v1.0.117 walk, tracker P13)
================================
The end-of-day brief said "Waiting on a reply from you" and listed five raw
phone numbers, one of them the OWNER'S OWN mobile. The reply-debt producer
named each thread by its raw chat.db handle (``counterpart = display_name or
handle``; a 1:1 chat has no display_name), nothing ever mapped a handle to the
Contacts person behind it, and its owner test read only
``OSTLER_IMESSAGE_SELF_HANDLES``, which the process that serves
``/api/v1/reply-debt`` (ical-server) is never given. So every handle went out
as digits and the owner's own self-chat counted as somebody waiting.

This module is the one place a surface asks "who is this handle?". It is pure
stdlib and does no I/O: callers hand it the People graph rows and the owner's
handles, so it is unit-testable with a fictional owner and contacts.

THREE ANSWERS, never two
------------------------
* a CONTACT: the handle matches a phone or email identifier on a graph Person
  with a real human name. Phones are compared in a canonical international
  form, so ``07700 900123``, ``+44 7700 900123`` and ``447700900123`` are one
  number when the owner's country is +44.
* the OWNER: the handle is one of the owner's handles. "The owner's handles"
  is EVERY phone and email we can attribute to the owner: the installer's
  me-card values, the configured self-handles, and every identifier on any
  graph Person that already holds one of those (the me-card person carries the
  owner's other numbers and addresses).
* NOT A PERSON: an SMS short code (3 to 8 digits, no country code), an
  alphanumeric sender id ("BANK", "Uber"), a business-chat urn, or a
  no-reply / one-time-passcode mailbox. These never appear on a list of people.

Anything else is an UNRESOLVED person: a real number or address that is not
in Contacts. Surfaces must say so ("someone not in your contacts" / "Unknown
number") and never print the raw digits as if they were a name.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Dict, Iterable, Mapping, Optional

# Kinds a handle can be. PERSON_KINDS are the only ones that name a human.
KIND_PHONE = "phone"
KIND_EMAIL = "email"
KIND_SHORT_CODE = "short_code"
KIND_SENDER_ID = "sender_id"
KIND_NO_REPLY = "no_reply"
KIND_EMPTY = "empty"
PERSON_KINDS = frozenset({KIND_PHONE, KIND_EMAIL})

# What a surface shows for a real but uncarded handle. The brief says it in a
# sentence; a table cell says it as a label.
UNRESOLVED_LABEL = "Unknown number"
UNRESOLVED_EMAIL_LABEL = "Unknown sender"
UNRESOLVED_PHRASE = "someone not in your contacts"

# ITU-T E.164 country calling codes. Used ONLY to read the owner's own country
# from the owner's own international number when DEFAULT_COUNTRY_CODE was not
# configured, never to guess a contact's country.
_CALLING_CODES = frozenset(
    {1, 7, 20, 27, 30, 31, 32, 33, 34, 36, 39, 40, 41, 43, 44, 45, 46, 47, 48,
     49, 51, 52, 53, 54, 55, 56, 57, 58, 60, 61, 62, 63, 64, 65, 66, 81, 82, 84,
     86, 90, 91, 92, 93, 94, 95, 98, 211, 212, 213, 216, 218, 220, 221, 222,
     223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237,
     238, 239, 240, 241, 242, 243, 244, 245, 246, 248, 249, 250, 251, 252, 253,
     254, 255, 256, 257, 258, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269,
     290, 291, 297, 298, 299, 350, 351, 352, 353, 354, 355, 356, 357, 358, 359,
     370, 371, 372, 373, 374, 375, 376, 377, 378, 380, 381, 382, 383, 385, 386,
     387, 389, 420, 421, 423, 500, 501, 502, 503, 504, 505, 506, 507, 508, 509,
     590, 591, 592, 593, 594, 595, 596, 597, 598, 599, 670, 672, 673, 674, 675,
     676, 677, 678, 679, 680, 681, 682, 683, 685, 686, 687, 688, 689, 690, 691,
     692, 850, 852, 853, 855, 856, 880, 886, 960, 961, 962, 963, 964, 965, 966,
     967, 968, 970, 971, 972, 973, 974, 975, 976, 977, 992, 993, 994, 995, 996,
     998}
)

_NO_REPLY_LOCAL = re.compile(
    r"^(?:no[-_.]?reply|do[-_.]?not[-_.]?reply|donotreply|mailer[-_.]?daemon|"
    r"postmaster|bounces?|notifications?|notify|alerts?|otp|verify|"
    r"verification|security[-_.]?code|auto[-_.]?confirm)(?:[-_.+].*)?$",
    re.IGNORECASE,
)
_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_PHONE_CHARS = re.compile(r"^\+?[\d\s\-().]+$")
# A national-format match falls back to the trailing digits. Eight is the
# shortest subscriber number we key on (several countries use 8-digit mobiles).
_SUFFIX_LEN = 8


def _text(value) -> str:
    """A SPARQL binding may arrive as a plain string or as {"value": ...}."""
    if isinstance(value, Mapping):
        value = value.get("value", "")
    return unicodedata.normalize("NFC", str(value or "")).strip()


def _strip_scheme(handle: str) -> str:
    h = handle.strip()
    for prefix in ("tel:", "sms:", "mailto:", "imessage:"):
        if h.lower().startswith(prefix):
            return h[len(prefix):].strip()
    return h


def canon_phone(raw: str, default_cc: Optional[int] = None) -> str:
    """Canonical international form ``+<digits>`` or ``""`` when ``raw`` is not
    a phone number we can place.

    ``default_cc`` is the OWNER's country calling code. A national-format
    number (leading 0, or a bare subscriber number) is placed in that country;
    without it a national number cannot be placed and returns ``""`` (callers
    then fall back to a unique trailing-digits match, never a guess).
    """
    h = _strip_scheme(_text(raw))
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
    digits = re.sub(r"\D", "", _strip_scheme(_text(raw)))
    return digits[-_SUFFIX_LEN:] if len(digits) >= _SUFFIX_LEN else ""


def canon_email(raw: str) -> str:
    h = _strip_scheme(_text(raw)).lower()
    return h if _EMAIL.match(h) else ""


def classify_handle(handle: str) -> str:
    """The SHAPE of a handle, before any lookup.

    A short code is digits only, 3 to 8 of them, with no ``+``: a mobile
    number always has more digits than that once its country is known, and a
    contact who IS carded under a short number is still resolved first by
    :meth:`HandleDirectory.resolve`, which checks the address book before it
    consults the shape.
    """
    h = _strip_scheme(_text(handle))
    if not h:
        return KIND_EMPTY
    if h.lower().startswith("urn:biz:"):
        return KIND_SENDER_ID
    if "@" in h:
        if not _EMAIL.match(h):
            return KIND_SENDER_ID
        local = h.split("@", 1)[0]
        return KIND_NO_REPLY if _NO_REPLY_LOCAL.match(local) else KIND_EMAIL
    if _PHONE_CHARS.match(h):
        digits = re.sub(r"\D", "", h)
        if not h.startswith("+") and 3 <= len(digits) <= 8:
            return KIND_SHORT_CODE
        if len(digits) >= 7:
            return KIND_PHONE
        return KIND_SHORT_CODE
    # Letters with no @: an alphanumeric sender id ("BANK", "Uber", "AB-CD").
    return KIND_SENDER_ID


def default_country_code(env: Mapping[str, str], owner_handles: Iterable[str] = ()) -> Optional[int]:
    """The owner's country calling code: ``DEFAULT_COUNTRY_CODE`` when the
    installer wrote it, else read from the owner's OWN ``+`` number."""
    raw = (env.get("DEFAULT_COUNTRY_CODE") or "").strip().lstrip("+")
    if raw.isdigit():
        return int(raw)
    for h in list(owner_handles) or owner_handles_from_env(env):
        h = _text(h)
        if not h.startswith("+"):
            continue
        digits = re.sub(r"\D", "", h)
        for n in (1, 2, 3):
            if int(digits[:n] or 0) in _CALLING_CODES:
                return int(digits[:n])
    return None


OWNER_HANDLE_ENV_VARS = (
    "USER_PHONE",
    "USER_EMAIL",
    "OSTLER_IMESSAGE_SELF_HANDLES",
    "OSTLER_OWNER_HANDLES",
    "WIKI_OPERATOR_EMAILS",
    "WIKI_OPERATOR_PHONES",
)


def owner_handles_from_env(env: Mapping[str, str]) -> list[str]:
    """Every owner phone and email the installer handed this process."""
    out: list[str] = []
    for var in OWNER_HANDLE_ENV_VARS:
        for part in (env.get(var) or "").split(","):
            part = part.strip()
            if part and part not in out:
                out.append(part)
    return out


def _name_key(name: str) -> str:
    return " ".join(_text(name).casefold().split())


OWNER_NAME_ENV_VARS = ("USER_NAME", "WIKI_OPERATOR_NAME")


def owner_names_from_env(env: Mapping[str, str]) -> list[str]:
    return [env.get(v, "").strip() for v in OWNER_NAME_ENV_VARS if (env.get(v) or "").strip()]


def is_real_name(name: str) -> bool:
    n = _text(name)
    if not n or "@" in n:
        return False
    if re.fullmatch(r"\+?[\d \-().]+", n):
        return False
    return any(c.isalpha() for c in n)


@dataclass(frozen=True)
class Resolution:
    kind: str                 # one of the KIND_* constants
    name: Optional[str]       # the contact's display name when carded
    is_owner: bool

    @property
    def is_person(self) -> bool:
        return self.kind in PERSON_KINDS and not self.is_owner

    @property
    def resolved(self) -> bool:
        return self.name is not None


class HandleDirectory:
    """Look a handle up against the People graph and the owner's handles."""

    def __init__(
        self,
        rows: Iterable[Mapping] = (),
        owner_handles: Iterable[str] = (),
        default_cc: Optional[int] = None,
        owner_names: Iterable[str] = (),
    ):
        self.default_cc = default_cc
        own_names = {_name_key(n) for n in owner_names if _name_key(n)}
        self._phone: Dict[str, str] = {}
        self._suffix: Dict[str, Optional[str]] = {}
        self._email: Dict[str, str] = {}
        self._owner_phone: set[str] = set()
        self._owner_suffix: set[str] = set()
        self._owner_email: set[str] = set()

        by_person: Dict[str, list[tuple[str, str]]] = {}
        names: Dict[str, str] = {}
        owner_persons: set[str] = set()
        for r in rows:
            person = _text(r.get("p") or r.get("person"))
            itype = _text(r.get("type")).lower()
            val = _text(r.get("val") or r.get("value"))
            if not person or not val:
                continue
            by_person.setdefault(person, []).append((itype, val))
            name = _text(r.get("name"))
            if name and person not in names:
                names[person] = name
            if _text(r.get("is_owner")).lower() in ("true", "1"):
                owner_persons.add(person)

        for h in owner_handles:
            self._add_owner(h)
        # EVERY owner handle: the owner node, and the owner's me-card person
        # (a Person that holds an owner handle AND carries the owner's own
        # name), contribute all their handles. The name is required so that a
        # family member whose card also lists a shared household address or
        # landline is never folded into the owner.
        for person, idents in by_person.items():
            if person in owner_persons:
                continue
            if _name_key(names.get(person, "")) in own_names and any(
                self._is_owner_value(t, v) for t, v in idents
            ):
                owner_persons.add(person)
        for person in owner_persons:
            for t, v in by_person.get(person, []):
                if t in ("phone", "email"):
                    self._add_owner(v)

        for person, idents in by_person.items():
            if person in owner_persons:
                continue
            name = names.get(person, "")
            if not is_real_name(name):
                continue
            for t, v in idents:
                if t == "phone":
                    key = canon_phone(v, default_cc)
                    if key:
                        self._phone.setdefault(key, name)
                    suf = phone_suffix(v)
                    if suf:
                        prev = self._suffix.get(suf, name)
                        # A suffix shared by two DIFFERENT names is ambiguous
                        # and must never pick one: None marks it unusable.
                        self._suffix[suf] = name if prev == name else None
                elif t == "email":
                    key = canon_email(v)
                    if key:
                        self._email.setdefault(key, name)

    def _add_owner(self, handle: str) -> None:
        e = canon_email(handle)
        if e:
            self._owner_email.add(e)
            return
        p = canon_phone(handle, self.default_cc)
        if p:
            self._owner_phone.add(p)
        s = phone_suffix(handle)
        if s and classify_handle(handle) == KIND_PHONE:
            self._owner_suffix.add(s)

    def _is_owner_value(self, itype: str, val: str) -> bool:
        if itype == "email":
            return canon_email(val) in self._owner_email
        if itype == "phone":
            return self.is_owner(val)
        return False

    @property
    def owner_handle_count(self) -> int:
        return len(self._owner_phone) + len(self._owner_email)

    def is_owner(self, handle: str) -> bool:
        e = canon_email(handle)
        if e:
            return e in self._owner_email
        if classify_handle(handle) != KIND_PHONE:
            return False
        p = canon_phone(handle, self.default_cc)
        if p and p in self._owner_phone:
            return True
        s = phone_suffix(handle)
        return bool(s) and s in self._owner_suffix

    def name_for(self, handle: str) -> Optional[str]:
        e = canon_email(handle)
        if e:
            return self._email.get(e)
        p = canon_phone(handle, self.default_cc)
        if p and p in self._phone:
            return self._phone[p]
        s = phone_suffix(handle)
        if s and _PHONE_CHARS.match(_strip_scheme(_text(handle))):
            return self._suffix.get(s)
        return None

    def resolve(self, handle: str) -> Resolution:
        if self.is_owner(handle):
            return Resolution(kind=classify_handle(handle), name=None, is_owner=True)
        name = self.name_for(handle)
        if name:
            kind = KIND_EMAIL if canon_email(handle) else KIND_PHONE
            return Resolution(kind=kind, name=name, is_owner=False)
        return Resolution(kind=classify_handle(handle), name=None, is_owner=False)


def unresolved_label(kind: str) -> str:
    return UNRESOLVED_EMAIL_LABEL if kind == KIND_EMAIL else UNRESOLVED_LABEL


__all__ = [
    "KIND_PHONE", "KIND_EMAIL", "KIND_SHORT_CODE", "KIND_SENDER_ID",
    "KIND_NO_REPLY", "KIND_EMPTY", "PERSON_KINDS",
    "UNRESOLVED_LABEL", "UNRESOLVED_EMAIL_LABEL", "UNRESOLVED_PHRASE",
    "canon_phone", "canon_email", "phone_suffix", "classify_handle",
    "default_country_code", "owner_handles_from_env", "is_real_name",
    "OWNER_HANDLE_ENV_VARS", "OWNER_NAME_ENV_VARS", "owner_names_from_env", "Resolution", "HandleDirectory", "unresolved_label",
]
