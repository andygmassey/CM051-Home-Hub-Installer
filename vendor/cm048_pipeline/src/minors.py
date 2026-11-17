"""The owner-set MINOR flag, as CM048 reads it (Andy, 2026-10-19).

The owner marks a person as under 18 in CM041 (``POST
/api/v1/people/{slug}/minor``), which writes a ``pwg:MinorFlag`` record in
the default graph with the same keying as a do-not-suggest record:

    <rec> a pwg:MinorFlag ;
          pwg:suppressedPerson <person uri> ;    (the identity cluster)
          pwg:suppressedName "exact display name" ;
          pwg:suppressedIdentifier "personal identifier value" ;
          pwg:suppressedSlug "display-name-slug" .

Shared contract fixture: tests/fixtures/minor_flag_contract.json (the same
file is checked against CM041's real writer there).

What CM048 does with it:
  * step 07 writes NO fact whose subject is a minor (Qdrant fact points and
    Oxigraph fact triples). The conversation itself, its summary and its
    four-artefact bundle are untouched: the owner can still find it.
  * a conversation with a minor among its participants never auto-pushes a
    todo to Reminders (reminders_push.decide_push).

FOLLOWS JOINED IDENTITIES. A flagged person's identifiers are read LIVE
from the person node(s) (and every node merged into them), so a handle
joined later through people join (CM041 #223 / CM048 #94) is covered
without rewriting the record. The record's own identifiers are the
backstop for a re-synced node.

FAILS CLOSED. :func:`load` raises :class:`MinorCheckUnavailable` when the
store cannot be queried: the caller must not write facts or push a todo it
could not check. Never an empty index for "could not look".
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from typing import Iterable, Optional, Set

from . import handle_resolver

PWG = "https://schema.ostler.ai/ontology#"


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
    "@", and for a phone-shaped value its digits (so "+44 7700 900123",
    "447700900123" and a WhatsApp "447700900123@s.whatsapp.net" meet)."""
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


def load(oxigraph_url: str) -> MinorIndex:
    """Read every MinorFlag record and the flagged people's CURRENT
    identifiers. Raises MinorCheckUnavailable on any store failure."""
    if not oxigraph_url:
        raise MinorCheckUnavailable("no oxigraph_url configured")
    try:
        rows = handle_resolver._select(
            f"PREFIX pwg: <{PWG}> "
            "SELECT ?r ?p ?name ?idv ?slug WHERE { ?r a pwg:MinorFlag . "
            "OPTIONAL { ?r pwg:suppressedPerson ?p } "
            "OPTIONAL { ?r pwg:suppressedName ?name } "
            "OPTIONAL { ?r pwg:suppressedIdentifier ?idv } "
            "OPTIONAL { ?r pwg:suppressedSlug ?slug } }",
            oxigraph_url,
        )
        idx = MinorIndex()
        slug_only: Set[str] = set()
        recs_with_person: Set[str] = set()
        for r in rows:
            if _v(r, "p"):
                idx.person_uris.add(_v(r, "p"))
                recs_with_person.add(_v(r, "r"))
            if _v(r, "name"):
                idx.names.add(name_key(_v(r, "name")))
            if _v(r, "idv"):
                idx.identifiers |= value_keys(_v(r, "idv"))
        for r in rows:
            if _v(r, "slug"):
                idx.slugs.add(slug_key(_v(r, "slug")))
                if _v(r, "r") not in recs_with_person:
                    slug_only.add(_v(r, "slug"))
        if idx.person_uris:
            vals = " ".join(f"<{u}>" for u in sorted(idx.person_uris))
            for r in handle_resolver._select(
                f"PREFIX pwg: <{PWG}> "
                "SELECT DISTINCT ?node ?v ?n WHERE { "
                f"VALUES ?p {{ {vals} }} "
                # the flagged node itself and every node merged into (or
                # out of) it, along whole chains
                "?node (pwg:mergedInto|^pwg:mergedInto)* ?p . "
                "OPTIONAL { ?node pwg:hasIdentifier ?i . ?i pwg:identifierValue ?v } "
                "OPTIONAL { ?node pwg:displayName ?n } }",
                oxigraph_url,
            ):
                if _v(r, "node"):
                    idx.person_uris.add(_v(r, "node"))
                if _v(r, "v"):
                    idx.identifiers |= value_keys(_v(r, "v"))
                if _v(r, "n"):
                    idx.names.add(name_key(_v(r, "n")))
        return idx
    except handle_resolver.StoreQueryError as exc:
        raise MinorCheckUnavailable(str(exc)) from exc


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
