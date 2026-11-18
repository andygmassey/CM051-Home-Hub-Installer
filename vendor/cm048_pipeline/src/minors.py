"""The owner-set MINOR flag, as the vendored CM048 reads it (CM051 adaptation).

ADAPTED FROM CM048 #98 (05affaf1). #98 reads a ``pwg:MinorFlag`` record in
Oxigraph, which only the still-open CM041 #226 writes; the CM041 setter that
SHIPS in this tree (``api_people_set_minor``, ical-server) writes the owner's
registry file ``~/.ostler/minors.json`` instead. This module keeps #98's
behaviour and index API and reads the shipped file.

  * step 07 writes NO fact whose subject is a minor.
  * a conversation with a minor among its participants never auto-pushes a
    todo to Reminders.
  * FAILS CLOSED: a present-but-unreadable registry raises MinorCheckUnavailable
    (no facts, no pushes for the run). An absent file means nobody is flagged.

Registry shape: {"version": 1, "minors": [{"slug", "names": [...],
"identifiers": [...]}]}. See vendor/divergences/cm048_pipeline.UNRECORDED.md.
"""
from __future__ import annotations

import json
import logging
import os
import re
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Optional, Set

logger = logging.getLogger(__name__)


class MinorCheckUnavailable(RuntimeError):
    """The minor flag could not be read. Not the same as "nobody is a minor"."""


def name_key(name: str) -> str:
    """NFC + casefold + collapsed whitespace (CM041 _suppression_name_key)."""
    n = unicodedata.normalize("NFC", name or "")
    return " ".join(n.casefold().split())


def slug_key(value: str) -> str:
    """Fold a slug or a CM048 subject tail ("tom_coe", "tom-coe") to one key."""
    v = unicodedata.normalize("NFKD", (value or "").strip().casefold())
    v = "".join(c for c in v if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", "-", v).strip("-")


def value_keys(value: str) -> Set[str]:
    """Comparable forms of an identifier value: casefolded, without a leading
    "@", and for a phone-shaped value its digits (so a spaced
    international form, a bare country-code form and a WhatsApp jid meet)."""
    v = (value or "").strip()
    if not v:
        return set()
    out = {v.casefold()}
    if v.startswith("@"):
        out.add(v[1:].casefold())
    local = v.split("@", 1)[0] if v.endswith(("whatsapp.net", "@lid", "@c.us")) else v
    digits = re.sub(r"\D", "", local)
    if len(digits) >= 7 and re.fullmatch(r"[+\d\s().\-]+", local or ""):
        out.add("tel:" + digits)
    return out


@dataclass
class MinorIndex:
    person_uris: Set[str] = field(default_factory=set)
    identifiers: Set[str] = field(default_factory=set)   # value_keys forms
    names: Set[str] = field(default_factory=set)          # name_key forms
    slugs: Set[str] = field(default_factory=set)          # slug_key forms

    def __bool__(self) -> bool:
        return bool(self.person_uris or self.identifiers or self.names or self.slugs)

    def matches_value(self, value: str) -> bool:
        return bool(value_keys(value) & self.identifiers)

    def matches_name(self, name: str) -> bool:
        return bool(name) and name_key(name) in self.names


def _v(row: dict, k: str) -> str:
    return (row.get(k) or {}).get("value", "")


def registry_path() -> Path:
    """The shipped registry the owner's setter writes (CM041
    ``api_people_set_minor``): OSTLER_MINORS_FILE if set, else
    ~/.ostler/minors.json. Same rule as ical-server ``_minors_path``."""
    override = os.environ.get("OSTLER_MINORS_FILE")
    return Path(override) if override else Path.home() / ".ostler" / "minors.json"


def load(_unused: str = "") -> MinorIndex:
    """Read the shipped registry. The argument is ignored and kept only so
    the call sites match CM048 #98 (which read a pwg:MinorFlag record that no
    shipped writer produces).

    FILE ABSENT = nobody is flagged (an empty index). FILE PRESENT BUT
    UNREADABLE OR MALFORMED raises :class:`MinorCheckUnavailable`: the whole
    run writes no facts and pushes no todos, with one loud line (no name,
    slug or identifier is ever logged)."""
    p = registry_path()
    if not p.exists():
        return MinorIndex()
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        entries = data["minors"]
        if (not isinstance(data, dict) or not isinstance(entries, list)
                or not all(isinstance(e, dict) for e in entries)):
            raise TypeError("shape")
        idx = MinorIndex()
        for e in entries:
            for n in e.get("names") or []:
                if isinstance(n, str) and name_key(n):
                    idx.names.add(name_key(n))
            for v in e.get("identifiers") or []:
                if isinstance(v, str):
                    idx.identifiers |= value_keys(v)
            sl = e.get("slug")
            if isinstance(sl, str) and slug_key(sl):
                idx.slugs.add(slug_key(sl))
        return idx
    except Exception as exc:  # noqa: BLE001 -- fail closed for the whole run
        logger.error("minors registry unreadable (%s): NO facts written and "
                     "NO todos pushed this run", type(exc).__name__)
        raise MinorCheckUnavailable(type(exc).__name__) from None


def _participant_values(entry) -> Iterable[str]:
    if isinstance(entry, str):
        yield entry
        return
    if not isinstance(entry, dict):
        return
    for k in ("handle", "jid", "phone", "email", "id", "chat_identifier",
              "instagram", "instagram_username", "telegram_id",
              "telegram_user_id", "telegram_username", "github_login",
              "linear_user_id", "account_id", "atlassian_account_id",
              "slack_user"):
        v = entry.get(k)
        if isinstance(v, str):
            yield v
    ids = entry.get("identifiers")
    if isinstance(ids, dict):
        for v in ids.values():
            if isinstance(v, str):
                yield v


def _participant_name(entry) -> str:
    if isinstance(entry, str):
        return entry
    if isinstance(entry, dict):
        for k in ("name", "display", "display_name", "displayName", "label"):
            v = entry.get(k)
            if isinstance(v, str) and v.strip():
                return v
    return ""


def _is_user(entry) -> bool:
    if isinstance(entry, dict):
        return bool(entry.get("is_user") or entry.get("is_owner")
                    or str(entry.get("role") or "").lower() in ("user", "owner", "self"))
    return isinstance(entry, str) and entry.strip().lower() in ("user", "me")


def participant_is_minor(entry, idx: MinorIndex, person_uri: Optional[str] = None) -> bool:
    """A participant is a minor when its joined Person is flagged, or any of
    its identifiers, or its exact display name, belongs to a flagged person.
    The owner is never a minor (owners are 18+)."""
    if not idx or _is_user(entry):
        return False
    if person_uri and person_uri in idx.person_uris:
        return True
    if any(idx.matches_value(v) for v in _participant_values(entry)):
        return True
    return idx.matches_name(_participant_name(entry))


def conversation_has_minor(metadata: dict, idx: MinorIndex) -> bool:
    parts = (metadata or {}).get("participants") or []
    if isinstance(parts, dict):
        parts = list(parts.values())
    return any(participant_is_minor(p, idx) for p in parts)


def fact_is_about_minor(fact: dict, metadata: dict, idx: MinorIndex) -> bool:
    """The fact's ``subject`` ("user", "other:<slug or id>", or a participant
    id after _fix_speaker_subjects) names a flagged person."""
    if not idx or not isinstance(fact, dict):
        return False
    subj = str(fact.get("subject") or "").strip()
    if not subj or subj.lower() == "user":
        return False
    tail = subj.split(":", 1)[1] if subj.lower().startswith("other:") else subj
    if idx.matches_value(tail) or idx.matches_value(subj):
        return True
    if slug_key(tail) and slug_key(tail) in idx.slugs:
        return True
    if idx.matches_name(tail.replace("_", " ")):
        return True
    # The subject names a participant (by id or name) who is a minor.
    parts = (metadata or {}).get("participants") or []
    if isinstance(parts, dict):
        parts = list(parts.values())
    for p in parts:
        vals = {x for v in _participant_values(p) for x in value_keys(v)}
        nm = _participant_name(p)
        names = {slug_key(nm), name_key(nm)} - {""}
        if (value_keys(tail) & vals) or (slug_key(tail) in names) \
                or (name_key(tail.replace("_", " ")) in names):
            if participant_is_minor(p, idx):
                return True
    return False
