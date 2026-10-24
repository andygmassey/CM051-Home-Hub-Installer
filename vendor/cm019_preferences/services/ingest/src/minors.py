"""Producer of ``extra.about_minor``: the owner's minors registry, stamped at write.

Owner decision 2026-10-19 (project_minors_flag): the owner can mark a contact as a minor.
Minors' data is stored and searchable but never derived, nudged or suggested. The
derive readers (services/enrich/src/derive/readers.py ``_not_minor``) drop any
point carrying ``extra.about_minor``; THIS module is what writes that flag, at the
single choke point every parser's output passes through (``pipeline._process_batch``).

Registry contract (JSON file, owner-set; the setter UI/endpoint is NOT in this repo):

    {"version": 1, "minors": [
        {"slug": "sam-example", "names": ["Sam Example"],
         "identifiers": ["+447700900123", "sam@example.test", "@sam_example"]}]}

Path: env OSTLER_MINORS_FILE, else ~/.ostler/minors.json. FILE ABSENT = nobody is
flagged. FILE PRESENT BUT UNREADABLE = fail closed (raise): an unknown registry must
not be read as "no minors". A point is about a minor when its subject or any
participant-bearing or title/summary-like ``extra`` field names a flagged
person (whole-name match) or carries a flagged identifier (others
case-insensitive). Phones are compared on their NATIONAL SIGNIFICANT NUMBER:
digits only, a leading ``00`` or ``+`` country code and the trunk ``0``
stripped, then a suffix match of at least 8 digits (Hong Kong numbers are 8),
so ``+447700900123``, ``+44 7700 900123``, ``00447700900123`` and
``07700 900123`` are the same phone in either direction.

An unreadable registry raises here; the pipeline then stamps EVERY item in the
batch about_minor (stored, never derived) and flags the batch. It never drops
the data and never reads "unknown" as "no minors".
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any, Iterable, List, Optional

DEFAULT_PATH = Path.home() / ".ostler" / "minors.json"
# extra keys whose values name the other party / participants of a conversation.
PARTICIPANT_KEYS = ("contact", "chat_name", "participants", "participant", "sender", "recipient",
                    "recipients", "author", "with", "person", "people", "handle", "from", "to",
                    "attendees", "thread", "counterpart")
# extra keys holding free text that can NAME a person ("Tom's swimming lesson").
TEXT_KEYS = ("title", "summary", "name", "description", "event", "event_title", "notes",
             "subject", "caption", "label", "topic")
MIN_PHONE_DIGITS = 8   # floor for a suffix match (Hong Kong numbers are 8 digits)


class MinorsRegistryError(RuntimeError):
    pass


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9@+.]+", " ", str(s).lower()).strip()


def _digits(s: str) -> str:
    return re.sub(r"\D", "", str(s))


def national_number(raw: str) -> str:
    """Digits of a phone with the international prefix and trunk 0 removed.

    ``+44 7700 900123`` -> ``447700900123`` -> (no trunk) kept as is, and
    ``07700 900123`` -> ``7700900123``. The comparison below is a SUFFIX
    match, so the country code left on an international form never matters."""
    d = _digits(raw)
    if d.startswith("00"):
        d = d[2:]
    return d.lstrip("0") if d.startswith("0") else d


def same_phone(a: str, b: str) -> bool:
    """True when two phone strings are the same number, either written form."""
    x, y = national_number(a), national_number(b)
    if len(x) < MIN_PHONE_DIGITS or len(y) < MIN_PHONE_DIGITS:
        return False
    short, long_ = (x, y) if len(x) <= len(y) else (y, x)
    return long_.endswith(short)


def _strings(v: Any) -> Iterable[str]:
    if v is None:
        return
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for x in v.values():
            yield from _strings(x)
    elif isinstance(v, (list, tuple, set)):
        for x in v:
            yield from _strings(x)
    else:
        yield str(v)


class MinorsRegistry:
    def __init__(self, entries: Optional[List[dict]] = None):
        self._names: List[str] = []
        self._ids: List[str] = []
        self._phones: List[str] = []
        for e in entries or []:
            self._names += [_norm(n) for n in e.get("names", []) if _norm(n)]
            for i in e.get("identifiers", []):
                d = national_number(i)
                if len(d) >= MIN_PHONE_DIGITS and not re.search(r"[a-z@]", str(i).lower()):
                    self._phones.append(d)
                elif str(i).strip():
                    self._ids.append(str(i).strip().lower())

    @classmethod
    def load(cls, path: Optional[Path] = None) -> "MinorsRegistry":
        p = Path(path or os.environ.get("OSTLER_MINORS_FILE") or DEFAULT_PATH)
        if not p.exists():
            return cls()
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
            entries = data["minors"]
            if not isinstance(entries, list):
                raise TypeError("minors must be a list")
        except Exception as exc:  # fail closed: do not read "unknown" as "none"
            raise MinorsRegistryError(f"minors registry {p} is unreadable: {exc}") from exc
        return cls(entries)

    def __bool__(self) -> bool:
        return bool(self._names or self._ids or self._phones)

    def names_a_minor(self, text: str) -> bool:
        n = f" {_norm(text)} "
        low = str(text).lower()
        if any(f" {name} " in n for name in self._names):
            return True
        if any(i in low for i in self._ids):
            return True
        # Every phone-shaped run in the text, compared on its national number.
        for run in re.findall(r"\+?[\d][\d\s().\-]{6,}\d", str(text)):
            if any(same_phone(run, p) for p in self._phones):
                return True
        return False

    def is_about_minor(self, pref) -> bool:
        if not self:
            return False
        texts = [pref.subject or ""]
        extra = pref.extra or {}
        for k in PARTICIPANT_KEYS + TEXT_KEYS:
            texts += list(_strings(extra.get(k)))
        return any(self.names_a_minor(t) for t in texts if t)

    @staticmethod
    def stamp_all(prefs: Iterable) -> int:
        """Fail-closed stamp: EVERY preference is treated as about a minor."""
        n = 0
        for p in prefs:
            p.extra = dict(p.extra or {})
            p.extra["about_minor"] = True
            n += 1
        return n

    def stamp(self, prefs: Iterable) -> int:
        """Set extra.about_minor=True on every preference about a flagged person."""
        n = 0
        for p in prefs:
            if self.is_about_minor(p):
                p.extra = dict(p.extra or {})
                p.extra["about_minor"] = True
                n += 1
        return n
