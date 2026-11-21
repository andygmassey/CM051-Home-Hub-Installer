"""Attendee -> existing Person resolution. Resolve-only: never mints.

The pipeline's standing rule (cm048 ``ingest._participant_identity_triples``,
vendor/cm048_pipeline/src/ingest.py:705-724) is that a Person node is never
fabricated from a name we cannot key. This module holds the same line for
meeting attendees: an attendee is LINKED to a person who already exists, by
email (exact) or by full name (exact, unique), or it stays plain text.

A single first name is never looked up and never minted. ``PersonDirectory``
deliberately has no create method.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional, Protocol

from .model import Attendee

# Labels diarisation tools emit when they do not know a name.
_GENERIC_LABEL = re.compile(
    r"^(speaker|guest|unknown|participant|attendee|user)\b[\s_-]*\d*$", re.I
)


class PersonDirectory(Protocol):
    def find_by_email(self, email: str) -> Optional[str]: ...
    def find_by_full_name(self, name: str) -> Optional[str]: ...


@dataclass(frozen=True)
class LinkedAttendee:
    name: str
    email: str
    person_uri: Optional[str]
    how: str  # owner | email | full_name | unresolved | single_name | generic


def _tokens(name: str) -> list[str]:
    return [t for t in re.split(r"\s+", name.strip()) if t]


def resolve_attendees(
    attendees: tuple[Attendee, ...],
    directory: Optional[PersonDirectory],
    *,
    owner_name: str = "",
    owner_email: str = "",
) -> list[LinkedAttendee]:
    out: list[LinkedAttendee] = []
    seen: set[str] = set()
    for a in attendees:
        name = (a.name or "").strip()
        email = (a.email or "").strip().lower()
        key = email or name.lower()
        if not key or key in seen:
            continue
        seen.add(key)
        if (owner_email and email == owner_email.lower()) or (
            owner_name and name.lower() == owner_name.lower()
        ):
            out.append(LinkedAttendee(name, email, None, "owner"))
            continue
        if not name and not email:
            continue
        if name and _GENERIC_LABEL.match(name) and not email:
            out.append(LinkedAttendee(name, email, None, "generic"))
            continue
        uri: Optional[str] = None
        how = "unresolved"
        if directory is not None and email:
            uri = directory.find_by_email(email)
            how = "email" if uri else "unresolved"
        if uri is None and name and "@" not in name:
            if len(_tokens(name)) < 2:
                # First name only: too ambiguous to match, never minted.
                out.append(LinkedAttendee(name, email, None, "single_name"))
                continue
            if directory is not None:
                uri = directory.find_by_full_name(name)
                how = "full_name" if uri else "unresolved"
        out.append(LinkedAttendee(name or email, email, uri, how))
    return out


class OxigraphPersonDirectory:
    """Read-only lookups through the vendored CM041 IdentityResolver.

    Email goes through ``find_by_identifier`` (cm041/identity_resolver/
    resolver.py:769), which follows merge tombstones. Full name is an exact,
    case-insensitive displayName match that must return exactly ONE person;
    two people sharing a name stays unresolved. No fuzzy tier: the resolver's
    own fuzzy match (resolver.py:1030) is for contact sync, not for a name
    typed by a transcription tool.

    NOT exercised against a live Oxigraph in CI (needs a graph); the policy
    around it is tested with a fake directory.
    """

    def __init__(self, resolver) -> None:
        self._r = resolver

    def find_by_email(self, email: str) -> Optional[str]:
        from identity_resolver.normalise import normalise_email

        try:
            return self._r.find_by_identifier("email", normalise_email(email))
        except Exception:  # noqa: BLE001 -- a graph hiccup leaves it unlinked
            return None

    def find_by_full_name(self, name: str) -> Optional[str]:
        from identity_resolver.resolver import PWG, _escape

        sparql = (
            "SELECT DISTINCT ?p WHERE { "
            f"?p <{PWG}displayName> ?n . "
            f'FILTER(LCASE(STR(?n)) = "{_escape(name.strip().lower())}") '
            "} LIMIT 3"
        )
        try:
            rows = self._r._sparql_query(sparql)["results"]["bindings"]
        except Exception:  # noqa: BLE001
            return None
        uris = {self._r.follow_merge_chain(r["p"]["value"]) for r in rows}
        return next(iter(uris)) if len(uris) == 1 else None
