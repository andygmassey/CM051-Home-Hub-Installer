from __future__ import annotations

import hashlib
import logging
import uuid
from datetime import datetime, timezone
from typing import Dict, List, Optional

import httpx

from .canonical_name import choose_canonical_display_name
from .compartment import (
    UserCompartment,
    assert_default_graph_isolated,
    normalise_user_id,
    resolve_compartment,
)
from .models import MatchResult, PersonIdentity
from .normalise import _jaro_winkler, normalise_email, normalise_phone

logger = logging.getLogger(__name__)

PWG = "https://pwg.dev/ontology#"

# Store URLs proven this process to NOT be in --union-default-graph mode
# (AUDIT_4 HIGH-1 guard). Probed on the FIRST secondary-compartment wire
# operation per store, then cached: the happy path is one set-membership
# check. The primary compartment never consults or populates this -- its
# wire path is byte-identical to the pre-groundwork code by golden test.
_NON_UNION_VERIFIED_STORES: set[str] = set()


class IdentityResolver:

    def __init__(
        self,
        oxigraph_url: str,
        default_country_code: int = 852,
        timeout: float = 30.0,
        compartment: Optional[UserCompartment] = None,
    ):
        self.oxigraph_url = oxigraph_url.rstrip("/")
        self.default_country_code = default_country_code
        # Multiuser groundwork: every resolver is bound to exactly one
        # user compartment. Default = the primary compartment, which maps
        # to EXACTLY today's single-user layout (default graph, plain
        # /query endpoint, unchanged update payloads) -- see
        # identity_resolver/compartment.py and MULTIUSER_GROUNDWORK.md.
        self.compartment = (
            compartment if compartment is not None else resolve_compartment()
        )
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
        # VENDOR GRAFT NOTE: upstream's opt-in bulk snapshot
        # (begin_bulk/end_bulk/_fuzzy_snapshot) and the vendor twin's
        # always-on lazy index (_fuzzy_candidates, above) solve the same
        # O(handles x persons) problem. This vendored copy keeps ONE store
        # (the twin's _fuzzy_candidates, whose two-flat-queries loader is
        # the proven fix for the Oxigraph OPTIONAL-join stall) and keeps
        # upstream's bulk() API as a thin delegate onto it, so both
        # upstream call sites (resolver.bulk(), _register_in_snapshot)
        # and twin call sites (register_person) work unchanged.
        self._bulk_fuzzy: bool = False

    # -- Bulk-mode lifecycle --------------------------------------------------

    def begin_bulk(self) -> None:
        """Enter bulk-resolve mode: pre-load the fuzzy-candidate index ONCE.

        Bulk imports (e.g. iMessage hydration) resolve thousands of handles
        in a tight loop. The vendored resolver's fuzzy index is lazy-loaded
        on first use anyway; begin_bulk() forces the load up front and marks
        bulk mode for observability.

        Idempotent: calling it again refreshes the index from Oxigraph.
        Always pair with ``end_bulk()`` (or use ``bulk()`` as a context
        manager) so a later single-shot caller does not silently read a
        stale snapshot.
        """
        self._load_fuzzy_candidates()
        self._bulk_fuzzy = True
        logger.info(
            "IdentityResolver bulk mode ON (%d fuzzy candidates snapshotted)",
            len(self._fuzzy_candidates or []),
        )

    def end_bulk(self) -> None:
        """Exit bulk-resolve mode and drop the snapshot (lazy reload later)."""
        self._bulk_fuzzy = False
        self._fuzzy_candidates = None

    def bulk(self) -> "_BulkContext":
        """Context manager: ``with resolver.bulk(): ...`` for bulk imports."""
        return _BulkContext(self)

    # -- Public API -----------------------------------------------------------

    def resolve(
        self,
        identity: PersonIdentity,
        use_fuzzy: bool = True,
        merge_on_resolve: bool = True,
    ) -> MatchResult:
        """Resolve an identity to an existing person node.

        Args:
            identity: The incoming person identity to match.
            use_fuzzy: If False, skip Tier 3 fuzzy name matching. Callers with
                strong identifiers (e.g. iCloud UID from contact sync) should
                pass False to avoid false matches via first-name collisions
                (e.g. "Sandra Andersson" matching "Sandra Stewart" via
                Jaro-Winkler prefix bonus on "Sand").
            merge_on_resolve: If True (default), when the incoming identity's
                EXACT identifiers span more than one existing node, collapse
                those nodes into one at resolve time (RULE 1: a shared exact
                identifier always merges) and return the survivor. This closes
                the ingest-time over-split gap where, previously, the first
                identifier match short-circuited and a second identifier
                pointing at a different node was never noticed. Set False to
                get pure read-only matching with no graph writes.

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
            return self._resolve_tiers(
                identity, use_fuzzy=use_fuzzy, merge_on_resolve=merge_on_resolve,
            )
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
        merge_on_resolve: bool = True,
    ) -> MatchResult:
        """Tiered match logic. May raise httpx.HTTPError on a query failure;
        the public resolve() wraps this and degrades to "new" so a failure
        never drops a contact. TNM's in-memory candidate index lands inside the
        Tier-3 path here; this error boundary sits outside it by design."""
        # Tier 1: Exact match on any single identifier.
        #
        # Collect EVERY node any incoming exact identifier points at, not just
        # the first. The old code returned on the first identifier hit, so an
        # incoming contact carrying e.g. a phone on node A and an email on node
        # B never noticed B existed -- leaving a permanent duplicate that only a
        # later batch pass might catch. We honour RULE 1 here: a shared exact
        # identifier (E.164 phone / normalised email / iCloud UID / etc.) always
        # merges, ignoring names and source. No fuzzy logic in this tier.
        found_uris: dict[str, tuple[str, str]] = {}
        for id_type, id_value in self._iter_identifiers(identity):
            uri = self.find_by_identifier(id_type, id_value)
            if (
                uri
                and uri not in found_uris
                and self._identifier_match_trustworthy(id_type, uri, identity)
            ):
                found_uris[uri] = (id_type, id_value)

        if len(found_uris) == 1:
            uri = next(iter(found_uris))
            id_type, id_value = found_uris[uri]
            return MatchResult(
                person_uri=uri,
                match_type="exact_identifier",
                confidence=1.0,
                details=f"Matched on {id_type}={id_value}",
            )

        if len(found_uris) > 1:
            uris = list(found_uris.keys())
            if merge_on_resolve:
                # RULE 1 collapse: keep the first node, fold the rest into it.
                # merge_persons() moves identifiers/facts/meeting links and
                # canonicalises the survivor's displayName (so a real Contacts
                # name wins over a raw handle). Idempotent: re-ingesting the
                # same identity finds a single node and falls into the branch
                # above.
                keep_uri = uris[0]
                for discard_uri in uris[1:]:
                    self.merge_persons(keep_uri, discard_uri)
                logger.info(
                    "Ingest-time merge: collapsed %d nodes sharing exact "
                    "identifiers into %s",
                    len(uris), keep_uri,
                )
                return MatchResult(
                    person_uri=keep_uri,
                    match_type="exact_identifier_merged",
                    confidence=1.0,
                    details=(
                        f"Merged {len(uris)} nodes sharing exact identifiers "
                        f"into {keep_uri}"
                    ),
                )
            # Read-only mode: surface the conflict without mutating the graph.
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

    def create_person(
        self,
        identity: PersonIdentity,
        user_id: str,
        consent_id: Optional[str] = None,
    ) -> str:
        """Mint a new Person node.

        ``user_id`` is the owner the node belongs to (already explicit
        here -- this method is the reference for the "no implicit me"
        groundwork discipline). ``consent_id``, when supplied by an ingest
        caller, is stamped as ``pwg:consentId`` -- the pointer back to the
        per-source opt-in grant that authorised the ingest (groundwork
        discipline 4: revocation / forget-what-this-source-brought-in
        becomes a real query). Default ``None`` writes exactly the same
        triples as before the groundwork.

        ``user_id`` is interpolated into the ``pwg:belongsToUser`` IRI --
        an ownership stamp that is now the isolation key -- so it must be
        IRI-safe. It is **normalised** (not strictly validated) up front:
        every caller in the estate passes ``config.USER_ID`` (the operator's
        own id, e.g. ``meeting_syncer``), which is the free-text answer to
        install.sh's "What should your assistant call you?" -- ``Andy``,
        ``Mrs Smith``, ``andy@home`` -- and the operator's data write MUST
        NOT crash on a non-canonical value. :func:`normalise_user_id` folds
        any value into a slug that satisfies the id grammar by construction,
        so it can never break out of the IRI (injection-proof, audit P11)
        AND never raises. The string escaper is still the wrong tool for an
        IRI context; normalisation forbids every IRI metacharacter instead.
        """
        user_id = normalise_user_id(user_id)
        short_id = uuid.uuid4().hex[:12]
        person_uri = f"{PWG}person_{short_id}"
        now = datetime.now(timezone.utc).isoformat()

        # Choose ONE canonical display name. Prefer a real Contacts name
        # (given+family); reject junk values like unix logins ("root"), bare
        # emails or automation aliases so they never seed a person's identity.
        # Falls back to the supplied display_name so the node is never nameless.
        display_name = (
            choose_canonical_display_name(
                [identity.display_name] if identity.display_name else [],
                given_name=identity.given_name,
                family_name=identity.family_name,
            )
            or identity.display_name
        )

        triples = [
            f"<{person_uri}> a <{PWG}Person>",
            f'<{person_uri}> <{PWG}displayName> "{_escape(display_name)}"',
            f'<{person_uri}> <{PWG}privacyLevel> "L2"',
            f'<{person_uri}> <{PWG}createdAt> "{now}"^^<http://www.w3.org/2001/XMLSchema#dateTime>',
            # user_id normalised above to match ^[a-z0-9][a-z0-9_-]{0,63}$,
            # so it cannot break out of the IRI (no escaping needed or wanted).
            f"<{person_uri}> <{PWG}belongsToUser> <{PWG}user_{user_id}>",
        ]

        if consent_id:
            triples.append(
                f'<{person_uri}> <{PWG}consentId> "{_escape(consent_id)}"'
            )

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
        # Keep the bulk fuzzy snapshot current: a person minted earlier in
        # the same bulk run must be a fuzzy candidate for later handles so a
        # run does not create N duplicates of the same new contact.
        self._register_in_snapshot(
            person_uri, display_name, identity.organization,
            identity.linkedin_url,
        )
        return person_uri

    def _register_in_snapshot(
        self, person_uri: str, name: Optional[str],
        org: Optional[str] = None, linkedin: Optional[str] = None,
    ) -> None:
        """Append a newly-minted person to the in-memory fuzzy index.

        Upstream API kept for its callers (e.g. the linkedin_messages
        path); in this vendored copy it is a thin delegate onto
        ``register_person`` -- the twin's single always-on candidate
        store -- so both registration APIs feed the same index. Safe to
        over-call: a duplicate row only costs a redundant Jaro-Winkler
        comparison, it cannot cause an over-merge.
        """
        if not name:
            return
        self.register_person(person_uri, name, org=org, linkedin_url=linkedin)

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

        # 6. Collapse any accumulated displayName values on the kept node to a
        #    single canonical value. Step 4 copies every displayName from the
        #    discard when keep has none, so a merge can leave the node with
        #    several (e.g. "Jane Doe", "root", "me@..."). Pick one.
        self.canonicalise_display_name(keep_uri)

        logger.info("Merged %s into %s", discard_uri, keep_uri)

    def canonicalise_display_name(self, person_uri: str) -> Optional[str]:
        """Collapse a person's possibly-multiple displayName values to ONE.

        Reads every ``pwg:displayName`` plus ``givenName``/``familyName`` on the
        node, chooses the canonical value (real Contacts name preferred, system
        aliases / bare emails / phone numbers rejected), then DELETE-then-INSERTs
        the single chosen value. No-op if the node has zero or one displayName.

        Returns the chosen display name (or None if the node had no usable name).
        """
        results = self._sparql_query(
            f"SELECT ?name ?given ?family WHERE {{ "
            f"  <{person_uri}> <{PWG}displayName> ?name . "
            f"  OPTIONAL {{ <{person_uri}> <{PWG}givenName> ?given }} "
            f"  OPTIONAL {{ <{person_uri}> <{PWG}familyName> ?family }} "
            f"}}"
        )
        bindings = results.get("results", {}).get("bindings", [])
        if len(bindings) <= 1:
            return bindings[0]["name"]["value"] if bindings else None

        candidates = [b["name"]["value"] for b in bindings if b.get("name")]
        given = next(
            (b["given"]["value"] for b in bindings if b.get("given")), None
        )
        family = next(
            (b["family"]["value"] for b in bindings if b.get("family")), None
        )

        canonical = choose_canonical_display_name(
            candidates, given_name=given, family_name=family
        )
        if not canonical:
            return None

        self._sparql_update(
            f"DELETE {{ <{person_uri}> <{PWG}displayName> ?old }} "
            f"WHERE {{ <{person_uri}> <{PWG}displayName> ?old }} ; "
            f'INSERT DATA {{ <{person_uri}> <{PWG}displayName> "{_escape(canonical)}" }}'
        )
        logger.info(
            "Canonicalised displayName for %s -> %r (was %d values)",
            person_uri, canonical, len(candidates),
        )
        return canonical

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

    # Identifier types that a different person can legitimately also carry:
    # a reused family email address, a shared office switchboard number. A
    # match on one of these is NOT by itself proof of same-person, so we only
    # trust it when the display names also agree -- otherwise a one-shot import
    # would collapse e.g. a mother/daughter who reused an email, or two
    # colleagues on the same DID line (BW-1). The unique-by-construction
    # identifiers (icloud_contact_uid, linkedin_url, whatsapp_lid) are always
    # trusted. The strict exact-normalised-name check is deliberately
    # conservative: name VARIANTS (e.g. "Granny Ritchie" / "Margaret Ritchie")
    # stay separate rather than risk a wrong merge -- relaxing that to a fuzzy
    # threshold is the BW-2 design follow-up.
    _SHAREABLE_ID_TYPES = {"email", "phone"}

    @staticmethod
    def _normalise_name(name: Optional[str]) -> str:
        return " ".join((name or "").strip().lower().split())

    def _person_display_name(self, person_uri: str) -> Optional[str]:
        sparql = (
            f"SELECT ?name WHERE {{ <{person_uri}> <{PWG}displayName> ?name }} "
            f"LIMIT 1"
        )
        results = self._sparql_query(sparql)
        bindings = results.get("results", {}).get("bindings", [])
        if bindings:
            return bindings[0]["name"]["value"]
        return None

    def _identifier_match_trustworthy(
        self, id_type: str, matched_uri: str, identity: PersonIdentity
    ) -> bool:
        """Whether an identifier match should be acted on (BW-1).

        Unique identifiers are always trusted. A SHAREABLE identifier
        (email/phone) is trusted only when the incoming and matched display
        names are present and equal once normalised; otherwise we cannot
        prove same-person, so we decline the match and let the caller create a
        new node (a recoverable duplicate that Tidy Contacts can merge) rather
        than risk an irreversible wrong merge.
        """
        if id_type not in self._SHAREABLE_ID_TYPES:
            return True
        incoming = self._normalise_name(identity.display_name)
        if not incoming:
            return False
        existing = self._normalise_name(self._person_display_name(matched_uri))
        if not existing:
            return False
        return incoming == existing

    # -- Private helpers ------------------------------------------------------

    def _fuzzy_match(
        self, name: str, org: Optional[str] = None,
        exclude_linkedin_url: Optional[str] = None,
    ) -> Optional[MatchResult]:
        # CX-126 (#660): match against the in-memory candidate index, loaded
        # once and appended on create, instead of re-running an unbounded
        # all-persons SELECT for every contact (the O(n^2) that hung the
        # install). Identical match results; microseconds instead of seconds.
        # (Upstream's bulk-mode snapshot branch is subsumed by this always-on
        # index -- begin_bulk() pre-loads the same store.)
        if self._fuzzy_candidates is None:
            self._load_fuzzy_candidates()

        best_uri: Optional[str] = None
        best_score: float = 0.0
        best_name: str = ""
        best_org_conflict = False

        # Best candidate that ALSO shares the organisation, tracked separately.
        # A same-name+same-org match is the strongest signal and is preferred
        # over a higher-scoring but org-conflicting candidate (two real people
        # who happen to share a name, e.g. the same name at two employers).
        conf_uri: Optional[str] = None
        conf_score: float = 0.0
        conf_name: str = ""

        for row in self._fuzzy_candidates:
            candidate_name = row.get("name") or ""
            if not candidate_name:
                continue

            # Hard blocker: if BOTH the incoming identity and the candidate
            # have LinkedIn URLs and they are DIFFERENT, this is definitely
            # not the same person. Two different LinkedIn profiles = two
            # different people, regardless of name similarity.
            if exclude_linkedin_url:
                candidate_linkedin = row.get("linkedinUrl")
                if candidate_linkedin and candidate_linkedin != exclude_linkedin_url:
                    continue

            score = _jaro_winkler(name.lower(), candidate_name.lower())
            candidate_org = row.get("org")
            same_org = (
                org is not None
                and candidate_org is not None
                and org.lower() == candidate_org.lower()
            )
            diff_org = (
                org is not None
                and candidate_org is not None
                and org.lower() != candidate_org.lower()
            )

            if same_org and score > conf_score:
                conf_score = score
                conf_uri = row["person"]
                conf_name = candidate_name

            if score > best_score:
                best_score = score
                best_uri = row["person"]
                best_name = candidate_name
                best_org_conflict = diff_org

        # Threshold tiers (org-conflict-guarded):
        # 1. >0.85 + same org -> high-confidence match (strongest signal).
        # 2. >=0.93 + no org CONFLICT -> reliable (typos, stylised variants,
        #    or one side simply has no org recorded). Merges "Jay Livens".
        # 3. >=0.93 but the best candidate's org CONFLICTS -> two different
        #    people who share a name (e.g. two real "Stuart Bailey"s at
        #    different employers). Do NOT merge; log for review.
        # 4. 0.85-0.93 no org -> NOT a match. Jaro-Winkler's 4-char prefix
        #    bonus pushes first-name collisions ("Sandra Andersson" ~
        #    "Sandra Stewart" scored 0.867) above 0.85 on shared-prefix
        #    alone, which blew up our People Graph on 2026-04-11.
        if conf_score > 0.85:
            return MatchResult(
                person_uri=conf_uri,
                match_type="fuzzy_name",
                confidence=conf_score,
                details=f"Fuzzy match: '{name}' ~ '{conf_name}' (score={conf_score:.3f}, org confirmed)",
            )

        if best_score >= 0.93 and not best_org_conflict:
            return MatchResult(
                person_uri=best_uri,
                match_type="fuzzy_name",
                confidence=best_score * 0.8,
                details=f"Fuzzy match: '{name}' ~ '{best_name}' (score={best_score:.3f}, high similarity, no org conflict)",
            )

        if best_score >= 0.93 and best_org_conflict:
            # Same name, conflicting organisation: almost always two distinct
            # people. Hold for review rather than wrongly fusing them.
            logger.info(
                "Same-name candidate BLOCKED by org conflict (likely distinct people): '%s' ~ '%s' (score=%.3f)",
                name,
                best_name,
                best_score,
            )
            return None

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
        O(n^2) (CX-126 #660): now run a single time. Every subsequent fuzzy
        match iterates this list in memory, and register_person() keeps it
        current for persons created during the run.

        Two FLAT queries instead of one with a nested OPTIONAL chain. The
        single-query form joined ``?person hasIdentifier ?lid . ?lid
        identifierType "linkedin_url" ; identifierValue ?linkedinUrl`` as an
        OPTIONAL across every Person -- a join Oxigraph evaluates poorly at
        scale: on the live Studio install (~4,700 persons / ~4,300
        identifiers) it measured 53s, OVER the resolver's own 30s HTTP
        timeout, so even this once-per-run load pegged Oxigraph for minutes
        and stalled the LinkedIn-messages import. Splitting it into (1) a flat
        person+name+org SELECT and (2) a flat person->linkedin_url SELECT,
        joined in Python by person URI, drops the cost to two cheap scans with
        identical results.
        """
        # Query 1: every person with their display name and (optional) org.
        sparql_people = (
            f"SELECT ?person ?name ?org WHERE {{ "
            f"  ?person a <{PWG}Person> ; "
            f"          <{PWG}displayName> ?name . "
            f"  OPTIONAL {{ ?person <{PWG}organization> ?org }} "
            f"}}"
        )
        # Query 2: person -> linkedin_url, flat (no per-person OPTIONAL join).
        sparql_linkedin = (
            f"SELECT ?person ?linkedinUrl WHERE {{ "
            f"  ?person <{PWG}hasIdentifier> ?lid . "
            f'  ?lid <{PWG}identifierType> "linkedin_url" ; '
            f"       <{PWG}identifierValue> ?linkedinUrl . "
            f"}}"
        )

        linkedin_by_person: Dict[str, str] = {}
        for row in (
            self._sparql_query(sparql_linkedin)
            .get("results", {})
            .get("bindings", [])
        ):
            person = row.get("person", {}).get("value")
            url = row.get("linkedinUrl", {}).get("value")
            if person and url and person not in linkedin_by_person:
                linkedin_by_person[person] = url

        candidates: List[Dict[str, Optional[str]]] = []
        for row in (
            self._sparql_query(sparql_people)
            .get("results", {})
            .get("bindings", [])
        ):
            person = row.get("person", {}).get("value")
            candidates.append(
                {
                    "person": person,
                    "name": row.get("name", {}).get("value"),
                    "org": row.get("org", {}).get("value"),
                    "linkedinUrl": linkedin_by_person.get(person),
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

    # -- Union-default-graph guard (AUDIT_4 HIGH-1) ---------------------------

    def _ensure_compartment_isolation(self) -> None:
        """Refuse SECONDARY-compartment I/O until the store is proven
        non-union. Primary: immediate return, zero wire traffic.

        The compartment wall's read isolation assumes an unqualified
        default-graph query cannot see named graphs -- true only while
        Oxigraph runs WITHOUT ``--union-default-graph`` (a flag set in
        other repos' launch files; see compartment.py module docstring).
        Before the first secondary read/write against a store, probe its
        actual semantics via ``assert_default_graph_isolated`` and cache
        the success per store URL for the life of the process. Union mode
        (or any probe transport failure) raises, fail-closed, BEFORE the
        real operation reaches the wire.
        """
        if self.compartment.is_primary:
            return
        if self.oxigraph_url in _NON_UNION_VERIFIED_STORES:
            return
        assert_default_graph_isolated(
            self._probe_update, self._probe_default_graph_query
        )
        _NON_UNION_VERIFIED_STORES.add(self.oxigraph_url)

    def _probe_update(self, sparql: str) -> None:
        """Raw update for the probe ONLY: bypasses ``scope_update`` because
        the probe payload is already GRAPH-scoped to the probe graph (and
        must never be re-wrapped into a user compartment)."""
        resp = self._client.post(
            f"{self.oxigraph_url}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()

    def _probe_default_graph_query(self, sparql: str) -> dict:
        """Raw query for the probe ONLY, against the BARE default endpoint
        (no ``default-graph-uri`` pin): the probe must see exactly what an
        unqualified primary/operator read would see."""
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

    def _sparql_query(self, sparql: str) -> dict:
        # Compartment read isolation happens at the HTTP boundary: for the
        # primary (default) compartment this is the plain /query endpoint,
        # byte-identical to the pre-compartment behaviour; for a secondary
        # compartment the endpoint pins the dataset to that user's named
        # graph, so other users' data is never on the read path.
        #
        # AUDIT_4 HIGH-1: for a secondary compartment, additionally prove
        # (once per store) that the store is not in union-default-graph
        # mode before trusting that pin. No-op for primary.
        self._ensure_compartment_isolation()
        resp = self._client.post(
            self.compartment.query_endpoint(self.oxigraph_url),
            content=sparql,
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
        )
        resp.raise_for_status()
        return resp.json()

    def _sparql_update(self, sparql: str) -> None:
        # For the primary compartment scope_update() returns the payload
        # unchanged (the identical object). For a secondary compartment it
        # wraps INSERT DATA in the user's GRAPH block and REJECTS any other
        # update shape (fail-closed) so an unscoped write can never land in
        # the primary user's default graph.
        scoped = self.compartment.scope_update(sparql)
        # AUDIT_4 HIGH-1: scope first (an unscopable payload raises with
        # ZERO wire traffic, as before), then -- for a secondary
        # compartment only -- prove the store is non-union before letting
        # the scoped write create named-graph data an operator's
        # unqualified read could leak. No-op for primary.
        self._ensure_compartment_isolation()
        resp = self._client.post(
            f"{self.oxigraph_url}/update",
            content=scoped,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()


class _BulkContext:
    """``with resolver.bulk(): ...`` -- enter/exit bulk fuzzy-resolve mode.

    Loads the fuzzy-candidate snapshot once on entry and drops it on exit,
    so the speed-up never leaks into a later single-shot caller that would
    otherwise read a stale snapshot.
    """

    def __init__(self, resolver: "IdentityResolver") -> None:
        self._resolver = resolver

    def __enter__(self) -> "IdentityResolver":
        self._resolver.begin_bulk()
        return self._resolver

    def __exit__(self, *exc) -> None:
        self._resolver.end_bulk()


def _escape(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
    )


def _extract_short_id(person_uri: str) -> str:
    # person_uri is like "https://pwg.dev/ontology#person_abc123def456"
    prefix = f"{PWG}person_"
    if person_uri.startswith(prefix):
        return person_uri[len(prefix):]
    # Fallback: use last segment
    return person_uri.rsplit("_", 1)[-1]
