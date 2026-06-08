from __future__ import annotations

import hashlib
import logging
import uuid
from datetime import datetime, timezone
from typing import Dict, List, Optional

import httpx

from .models import MatchResult, PersonIdentity
from .normalise import _jaro_winkler, normalise_email, normalise_phone

logger = logging.getLogger(__name__)

PWG = "https://pwg.dev/ontology#"


class IdentityResolver:

    def __init__(
        self,
        oxigraph_url: str,
        default_country_code: int = 852,
        timeout: float = 30.0,
    ):
        self.oxigraph_url = oxigraph_url.rstrip("/")
        self.default_country_code = default_country_code
        self._client = httpx.Client(timeout=timeout)
        # Resolution health counters - the safety net's audit trail (#660).
        # Every contact that hits a resolver query error degrades to "create
        # as new" (a recoverable possible-duplicate) rather than being dropped
        # by the import loop, and is counted here so a degraded import can
        # never silently pass for a clean one. See log_resolution_summary().
        self.stats: dict[str, int] = {"total": 0, "degraded": 0}
        # CX-126 (#660): in-memory fuzzy-candidate index. _fuzzy_match used to
        # re-run an unbounded "SELECT all persons" against Oxigraph for EVERY
        # contact -> O(n^2). On a real LinkedIn export (3,810 connections) that
        # query measured 8s at ~900 people and grows super-linearly, so the
        # install crawled then effectively hung. We now load the candidate set
        # ONCE (lazily, on the first fuzzy match) and append each newly-created
        # person via register_person(), so matching is in-memory (microseconds)
        # with identical results. None = not yet loaded.
        self._fuzzy_candidates: Optional[List[Dict[str, Optional[str]]]] = None

    # -- Public API -----------------------------------------------------------

    def resolve(
        self,
        identity: PersonIdentity,
        use_fuzzy: bool = True,
    ) -> MatchResult:
        """Resolve an identity to an existing person node.

        Args:
            identity: The incoming person identity to match.
            use_fuzzy: If False, skip Tier 3 fuzzy name matching. Callers with
                strong identifiers (e.g. iCloud UID from contact sync) should
                pass False to avoid false matches via first-name collisions
                (e.g. "Sandra Andersson" matching "Sandra Stewart" via
                Jaro-Winkler prefix bonus on "Sand").

        Safety net (#660): this method NEVER raises a resolver-query error. If
        any tier's Oxigraph call fails (a 30s timeout against a large graph, a
        transport error, or a 5xx), the contact degrades to a "new" result so
        the caller still creates a person node - a recoverable possible-
        duplicate that Tidy Contacts can later merge - rather than the import
        loop catching the exception and silently dropping the row (the
        ~1,300-contact loss the O(n^2) stall would otherwise have caused). The
        degradation is logged per-contact and counted in `self.stats`.
        """
        self.stats["total"] += 1
        try:
            return self._resolve_tiers(identity, use_fuzzy=use_fuzzy)
        except httpx.HTTPError as exc:
            self.stats["degraded"] += 1
            logger.warning(
                "Resolver degraded for '%s' (%s: %s) - creating as NEW to "
                "avoid dropping the contact; review via log_resolution_summary()",
                identity.display_name,
                type(exc).__name__,
                exc,
            )
            return MatchResult(
                person_uri=None,
                match_type="new",
                confidence=0.0,
                details=(
                    f"Resolver degraded ({type(exc).__name__}); created as new "
                    "to avoid dropping the contact"
                ),
            )

    def _resolve_tiers(
        self,
        identity: PersonIdentity,
        use_fuzzy: bool = True,
    ) -> MatchResult:
        """Tiered match logic. May raise httpx.HTTPError on a query failure;
        the public resolve() wraps this and degrades to "new" so a failure
        never drops a contact. TNM's in-memory candidate index lands inside the
        Tier-3 path here; this error boundary sits outside it by design."""
        # Tier 1: Exact match on any single identifier
        for id_type, id_value in self._iter_identifiers(identity):
            person_uri = self.find_by_identifier(id_type, id_value)
            if person_uri:
                return MatchResult(
                    person_uri=person_uri,
                    match_type="exact_identifier",
                    confidence=1.0,
                    details=f"Matched on {id_type}={id_value}",
                )

        # Tier 2: Cross-identifier match — check if any person has ANY identifier
        found_uris: dict[str, tuple[str, str]] = {}
        for id_type, id_value in self._iter_identifiers(identity):
            uri = self.find_by_identifier(id_type, id_value)
            if uri and uri not in found_uris:
                found_uris[uri] = (id_type, id_value)

        if len(found_uris) == 1:
            uri = next(iter(found_uris))
            id_type, id_value = found_uris[uri]
            return MatchResult(
                person_uri=uri,
                match_type="cross_identifier",
                confidence=0.95,
                details=f"Cross-identifier match via {id_type}={id_value}",
            )
        if len(found_uris) > 1:
            # Multiple different persons matched — potential merge candidate.
            # Return the first but log the conflict.
            uris = list(found_uris.keys())
            logger.warning(
                "Cross-identifier conflict: identifiers map to multiple persons %s",
                uris,
            )
            return MatchResult(
                person_uri=uris[0],
                match_type="cross_identifier",
                confidence=0.6,
                details=f"Conflict: identifiers map to {len(uris)} persons: {uris}",
            )

        # Tier 3: Fuzzy name match (skipped when caller has strong identifiers)
        if use_fuzzy and identity.display_name:
            fuzzy = self._fuzzy_match(
                identity.display_name,
                identity.organization,
                exclude_linkedin_url=identity.linkedin_url,
            )
            if fuzzy:
                return fuzzy

        # Tier 4: No match - signal that a new person should be created
        return MatchResult(
            person_uri=None,
            match_type="new",
            confidence=0.0,
            details="No matching person found",
        )

    def resolution_summary(self) -> dict[str, int]:
        """Resolution health counters for the current resolver instance.

        Callers driving a bulk import should read this at the end of the run.
        A non-zero `degraded` means some contacts were created as new
        (possible duplicates) because their resolver query failed mid-import -
        the rows were preserved, not dropped, but dedup did not run for them.
        """
        return dict(self.stats)

    def log_resolution_summary(self) -> None:
        """Emit a single end-of-run line; ERROR (not silent) if any contact
        degraded, so a partially-failed import can never read as a clean one.
        Wire this into the import loop after the final contact (#660)."""
        degraded = self.stats["degraded"]
        total = self.stats["total"]
        if degraded:
            logger.error(
                "Identity resolution finished with %d/%d contacts DEGRADED to "
                "new (rows preserved as possible duplicates, NOT dropped). The "
                "resolver was failing queries mid-import - investigate before "
                "trusting dedup; affected contacts can be merged via Tidy "
                "Contacts. See #660.",
                degraded,
                total,
            )
        else:
            logger.info(
                "Identity resolution finished cleanly: %d contacts, 0 degraded.",
                total,
            )

    def create_person(self, identity: PersonIdentity, user_id: str) -> str:
        short_id = uuid.uuid4().hex[:12]
        person_uri = f"{PWG}person_{short_id}"
        now = datetime.now(timezone.utc).isoformat()

        triples = [
            f"<{person_uri}> a <{PWG}Person>",
            f'<{person_uri}> <{PWG}displayName> "{_escape(identity.display_name)}"',
            f'<{person_uri}> <{PWG}privacyLevel> "L2"',
            f'<{person_uri}> <{PWG}createdAt> "{now}"^^<http://www.w3.org/2001/XMLSchema#dateTime>',
            f"<{person_uri}> <{PWG}belongsToUser> <{PWG}user_{_escape(user_id)}>",
        ]

        if identity.given_name:
            triples.append(
                f'<{person_uri}> <{PWG}givenName> "{_escape(identity.given_name)}"'
            )
        if identity.family_name:
            triples.append(
                f'<{person_uri}> <{PWG}familyName> "{_escape(identity.family_name)}"'
            )
        if identity.organization:
            triples.append(
                f'<{person_uri}> <{PWG}organization> "{_escape(identity.organization)}"'
            )

        # Add identifiers
        for id_type, id_value in self._iter_identifiers(identity):
            id_uri = self._identifier_uri(short_id, id_type, id_value)
            triples.extend(
                [
                    f"<{person_uri}> <{PWG}hasIdentifier> <{id_uri}>",
                    f"<{id_uri}> a <{PWG}PersonIdentifier>",
                    f'<{id_uri}> <{PWG}identifierType> "{id_type}"',
                    f'<{id_uri}> <{PWG}identifierValue> "{_escape(id_value)}"',
                ]
            )

        sparql = f"INSERT DATA {{ {' . '.join(triples)} . }}"
        self._sparql_update(sparql)
        logger.info("Created person %s (%s)", person_uri, identity.display_name)
        return person_uri

    def add_identifier(
        self, person_uri: str, id_type: str, id_value: str, label: Optional[str] = None
    ) -> None:
        short_id = _extract_short_id(person_uri)
        id_uri = self._identifier_uri(short_id, id_type, id_value)

        triples = [
            f"<{person_uri}> <{PWG}hasIdentifier> <{id_uri}>",
            f"<{id_uri}> a <{PWG}PersonIdentifier>",
            f'<{id_uri}> <{PWG}identifierType> "{id_type}"',
            f'<{id_uri}> <{PWG}identifierValue> "{_escape(id_value)}"',
        ]
        if label:
            triples.append(
                f'<{id_uri}> <{PWG}identifierLabel> "{_escape(label)}"'
            )

        sparql = f"INSERT DATA {{ {' . '.join(triples)} . }}"
        self._sparql_update(sparql)

    def update_person(self, person_uri: str, **kwargs: str) -> None:
        allowed = {
            "display_name": "displayName",
            "given_name": "givenName",
            "family_name": "familyName",
            "organization": "organization",
            "job_title": "jobTitle",
            "relationship": "relationship",
            "how_we_met": "howWeMet",
            "notes": "notes",
            "contact_type": "contactType",
        }

        for key, value in kwargs.items():
            predicate = allowed.get(key)
            if not predicate:
                raise ValueError(f"Unknown person property: {key}")

            # Delete existing value then insert new one
            sparql = (
                f"DELETE {{ <{person_uri}> <{PWG}{predicate}> ?old }} "
                f"WHERE {{ <{person_uri}> <{PWG}{predicate}> ?old }} ; "
                f'INSERT DATA {{ <{person_uri}> <{PWG}{predicate}> "{_escape(value)}" }}'
            )
            self._sparql_update(sparql)

    def merge_persons(self, keep_uri: str, discard_uri: str) -> None:
        now = datetime.now(timezone.utc).isoformat()

        # 1. Move identifiers
        self._sparql_update(
            f"DELETE {{ <{discard_uri}> <{PWG}hasIdentifier> ?id }} "
            f"INSERT {{ <{keep_uri}> <{PWG}hasIdentifier> ?id }} "
            f"WHERE {{ <{discard_uri}> <{PWG}hasIdentifier> ?id }}"
        )

        # 2. Move facts
        self._sparql_update(
            f"DELETE {{ ?fact <{PWG}aboutPerson> <{discard_uri}> }} "
            f"INSERT {{ ?fact <{PWG}aboutPerson> <{keep_uri}> }} "
            f"WHERE {{ ?fact <{PWG}aboutPerson> <{discard_uri}> }}"
        )

        # 3. Move meeting attendee links
        self._sparql_update(
            f"DELETE {{ ?meeting <{PWG}meetingAttendee> <{discard_uri}> }} "
            f"INSERT {{ ?meeting <{PWG}meetingAttendee> <{keep_uri}> }} "
            f"WHERE {{ ?meeting <{PWG}meetingAttendee> <{discard_uri}> }}"
        )

        # 4. Merge scalar properties — copy non-null values from discard to keep
        #    (only where keep doesn't already have a value)
        scalar_props = [
            "displayName", "givenName", "familyName", "organization",
            "jobTitle", "relationship", "howWeMet", "notes",
        ]
        for prop in scalar_props:
            self._sparql_update(
                f"INSERT {{ <{keep_uri}> <{PWG}{prop}> ?val }} "
                f"WHERE {{ "
                f"  <{discard_uri}> <{PWG}{prop}> ?val . "
                f"  FILTER NOT EXISTS {{ <{keep_uri}> <{PWG}{prop}> ?existing }} "
                f"}}"
            )

        # 5. Mark discard as merged
        self._sparql_update(
            f"INSERT DATA {{ "
            f"  <{discard_uri}> <{PWG}mergedInto> <{keep_uri}> . "
            f'  <{discard_uri}> <{PWG}mergedAt> "{now}"^^<http://www.w3.org/2001/XMLSchema#dateTime> '
            f"}}"
        )

        logger.info("Merged %s into %s", discard_uri, keep_uri)

    def find_by_identifier(self, id_type: str, id_value: str) -> Optional[str]:
        sparql = (
            f"SELECT ?person WHERE {{ "
            f"  ?person <{PWG}hasIdentifier> ?id . "
            f'  ?id <{PWG}identifierType> "{id_type}" ; '
            f'      <{PWG}identifierValue> "{_escape(id_value)}" . '
            f"}} LIMIT 1"
        )
        results = self._sparql_query(sparql)
        bindings = results.get("results", {}).get("bindings", [])
        if bindings:
            return bindings[0]["person"]["value"]
        return None

    # -- Private helpers ------------------------------------------------------

    def _fuzzy_match(
        self, name: str, org: Optional[str] = None,
        exclude_linkedin_url: Optional[str] = None,
    ) -> Optional[MatchResult]:
        # CX-126 (#660): match against the in-memory candidate index, loaded
        # once and appended on create, instead of re-running an unbounded
        # all-persons SELECT for every contact (the O(n^2) that hung the
        # install). Identical match results; microseconds instead of seconds.
        if self._fuzzy_candidates is None:
            self._load_fuzzy_candidates()

        best_uri: Optional[str] = None
        best_score: float = 0.0
        best_name: str = ""
        org_confirmed = False

        for row in self._fuzzy_candidates:
            candidate_name = row.get("name") or ""
            if not candidate_name:
                continue
            score = _jaro_winkler(name.lower(), candidate_name.lower())

            # Hard blocker: if BOTH the incoming identity and the candidate
            # have LinkedIn URLs and they are DIFFERENT, this is definitely
            # not the same person. Two different LinkedIn profiles = two
            # different people, regardless of name similarity.
            if exclude_linkedin_url:
                candidate_linkedin = row.get("linkedinUrl")
                if candidate_linkedin and candidate_linkedin != exclude_linkedin_url:
                    continue

            if score > best_score:
                best_score = score
                best_uri = row["person"]
                best_name = candidate_name
                candidate_org = row.get("org")
                org_confirmed = (
                    org is not None
                    and candidate_org is not None
                    and org.lower() == candidate_org.lower()
                )

        # Threshold tiers:
        # - 0.85 + org confirmed → high-confidence match
        # - 0.93 no org → still reliable (typos, stylised variants, etc.)
        # - 0.85–0.93 no org → NOT a match. Jaro-Winkler's 4-char prefix
        #   bonus pushes first-name collisions ("Sandra Andersson" ~
        #   "Sandra Stewart" scored 0.867) above 0.85 on shared-prefix alone,
        #   which blew up our People Graph on 2026-04-11. We still log
        #   these as candidates so they can be reviewed, but we don't
        #   return a match. See CM043/TODO.md follow-ups for context.
        if best_score > 0.85 and org_confirmed:
            return MatchResult(
                person_uri=best_uri,
                match_type="fuzzy_name",
                confidence=best_score,
                details=f"Fuzzy match: '{name}' ~ '{best_name}' (score={best_score:.3f}, org confirmed)",
            )

        if best_score >= 0.93:
            return MatchResult(
                person_uri=best_uri,
                match_type="fuzzy_name",
                confidence=best_score * 0.8,
                details=f"Fuzzy match: '{name}' ~ '{best_name}' (score={best_score:.3f}, high similarity no org)",
            )

        if best_score > 0.85:
            # Log-only: shared-prefix first-name collisions live here
            logger.info(
                "Fuzzy name candidate (below threshold, not matched): '%s' ~ '%s' (score=%.3f)",
                name,
                best_name,
                best_score,
            )

        return None

    def _load_fuzzy_candidates(self) -> None:
        """Load all person nodes into the in-memory fuzzy-candidate index ONCE.

        Replaces the per-contact "SELECT all persons" that made _fuzzy_match
        O(n^2) (CX-126 #660): the identical query, run a single time. Every
        subsequent fuzzy match iterates this list in memory, and
        register_person() keeps it current for persons created during the run.
        """
        sparql = (
            f"SELECT ?person ?name ?org ?linkedinUrl WHERE {{ "
            f"  ?person a <{PWG}Person> ; "
            f"          <{PWG}displayName> ?name . "
            f"  OPTIONAL {{ ?person <{PWG}organization> ?org }} "
            f"  OPTIONAL {{ "
            f"    ?person <{PWG}hasIdentifier> ?lid . "
            f'    ?lid <{PWG}identifierType> "linkedin_url" ; '
            f"         <{PWG}identifierValue> ?linkedinUrl . "
            f"  }} "
            f"}}"
        )
        results = self._sparql_query(sparql)
        bindings = results.get("results", {}).get("bindings", [])
        candidates: List[Dict[str, Optional[str]]] = []
        for row in bindings:
            candidates.append(
                {
                    "person": row.get("person", {}).get("value"),
                    "name": row.get("name", {}).get("value"),
                    "org": row.get("org", {}).get("value"),
                    "linkedinUrl": row.get("linkedinUrl", {}).get("value"),
                }
            )
        self._fuzzy_candidates = candidates

    def register_person(
        self,
        person_uri: str,
        name: str,
        org: Optional[str] = None,
        linkedin_url: Optional[str] = None,
    ) -> None:
        """Append a newly-created person to the in-memory fuzzy index.

        A caller that creates a NEW person after resolve() returns no match
        must call this so later contacts in the same run dedupe against it --
        parity with the old query-Oxigraph-every-time behaviour. No-op when the
        index has not been loaded yet (a later first load will include the
        person anyway).
        """
        if self._fuzzy_candidates is None or not name:
            return
        self._fuzzy_candidates.append(
            {
                "person": person_uri,
                "name": name,
                "org": org,
                "linkedinUrl": linkedin_url,
            }
        )

    def _iter_identifiers(
        self, identity: PersonIdentity
    ) -> list[tuple[str, str]]:
        ids: list[tuple[str, str]] = []

        if identity.icloud_uid:
            ids.append(("icloud_contact_uid", identity.icloud_uid))

        for phone in identity.phones:
            normalised = normalise_phone(phone, self.default_country_code)
            ids.append(("phone", normalised))

        for email in identity.emails:
            ids.append(("email", normalise_email(email)))

        for lid in identity.whatsapp_lids:
            ids.append(("whatsapp_lid", lid))

        if identity.linkedin_url:
            ids.append(("linkedin_url", identity.linkedin_url))

        return ids

    @staticmethod
    def _identifier_uri(person_short_id: str, id_type: str, id_value: str) -> str:
        value_hash = hashlib.md5(id_value.encode()).hexdigest()[:6]
        return f"{PWG}id_{person_short_id}_{id_type}_{value_hash}"

    def _sparql_query(self, sparql: str) -> dict:
        resp = self._client.post(
            f"{self.oxigraph_url}/query",
            content=sparql,
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
        )
        resp.raise_for_status()
        return resp.json()

    def _sparql_update(self, sparql: str) -> None:
        resp = self._client.post(
            f"{self.oxigraph_url}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _extract_short_id(person_uri: str) -> str:
    # person_uri is like "https://pwg.dev/ontology#person_abc123def456"
    prefix = f"{PWG}person_"
    if person_uri.startswith(prefix):
        return person_uri[len(prefix):]
    # Fallback: use last segment
    return person_uri.rsplit("_", 1)[-1]
