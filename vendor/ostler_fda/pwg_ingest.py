"""Ingest FDA extraction results into the PWG knowledge graph.

Reads the JSON output from extract_all.py and feeds it into
Qdrant (vector search) and Oxigraph (RDF knowledge graph).

This bridges the FDA extraction (macOS-native data) with the
PWG import pipeline (which handles GDPR exports). Both end up
in the same knowledge graph.

Usage:
    python -m ostler_fda.pwg_ingest [--fda-dir ~/.ostler/imports/fda]

Requires:
    - Qdrant running at localhost:6333
    - Oxigraph running at localhost:7878
    - Ollama running at localhost:11434 (for embeddings)
"""
from __future__ import annotations

import json
import logging
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import httpx

logger = logging.getLogger(__name__)

# ── Config from environment (same as GDPR import pipeline) ────────

QDRANT_URL = os.getenv("QDRANT_URL", "http://localhost:6333")
OXIGRAPH_URL = os.getenv("OXIGRAPH_URL", "http://localhost:7878")
OLLAMA_URL = os.getenv("EMBED_OLLAMA_URL", "http://localhost:11434")
EMBED_MODEL = os.getenv("EMBED_MODEL", "nomic-embed-text")
QDRANT_COLLECTION = os.getenv("QDRANT_COLLECTION", "people")
DEFAULT_PRIVACY = os.getenv("DEFAULT_PRIVACY_LEVEL", "L2")


# ── Shared utilities (same patterns as contact_syncer) ────────────


def _is_provisional_display_name(value: str) -> bool:
    """True when ``value`` is a raw phone/handle placeholder, not a name.

    WhatsApp/iMessage chat-only contacts get a ``+<e164>`` (or bare
    handle) placeholder because the extractor reads JIDs/handles only --
    no pushName, no Contacts match. Those placeholders must be marked
    PROVISIONAL so (a) the identity resolver may freely overwrite them
    when a real name later arrives from contact_syncer / CM046, and (b)
    surfaces can suppress the "+44 7700 900123 as a name" leak (#576).

    Mirrors cm041.identity_resolver.canonical_name._looks_like_phone
    (>= 5 digits, phone-shaped) but is kept local: ostler_fda ships
    independently of cm041 and must not take a hard import on it.
    """
    if not value:
        return True
    v = value.strip()
    if not v:
        return True
    if "@" in v and "." in v.split("@", 1)[1]:
        # A bare email used as a name is also a placeholder, not a name.
        return True
    digits = sum(c.isdigit() for c in v)
    phoneish = all(c in "+()-. \t0123456789" for c in v)
    return phoneish and digits >= 5

def _sparql_update(sparql: str) -> None:
    """Execute a SPARQL UPDATE against Oxigraph."""
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=30.0, transport=transport) as client:
        resp = client.post(
            f"{OXIGRAPH_URL}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()


def _sparql_query(sparql: str) -> list:
    """Execute a SPARQL SELECT and return bindings."""
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=30.0, transport=transport) as client:
        resp = client.post(
            f"{OXIGRAPH_URL}/query",
            content=sparql,
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
        )
        resp.raise_for_status()
        return resp.json().get("results", {}).get("bindings", [])


def _escape(s: str) -> str:
    """Escape a string for safe inclusion in a SPARQL string literal.

    Per SPARQL 1.1 section 19.7 (STRING_LITERAL2), the quoted form
    forbids raw ``\\``, ``"``, LF, and CR. The previous implementation
    handled three of those four; an attacker-controlled string
    containing CR could terminate the literal prematurely and inject
    additional SPARQL.

    This version escapes:
    - the four spec-forbidden chars via ECHAR: ``\\\\``, ``\\"``, ``\\n``,
      ``\\r``;
    - three additional whitespace controls (tab, backspace, form feed)
      via ECHAR for robustness — some parsers trip on raw controls
      even when the spec tolerates them;
    - every other C0/C1 control character (0x00–0x1F, 0x7F) via UCHAR
      (``\\uXXXX``), which SPARQL 1.1 accepts anywhere in a literal.

    ``$``, ``@``, ``{``, ``}`` are deliberately NOT escaped: they are
    valid inside a SPARQL string literal and have no ECHAR form.
    Backslash-escaping them would produce invalid ECHAR sequences
    (``\\$`` isn't in SPARQL 1.1's ECHAR set) and break parsing.
    """
    out: list[str] = []
    for ch in s:
        code = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\b":
            out.append("\\b")
        elif ch == "\f":
            out.append("\\f")
        elif code < 0x20 or code == 0x7F:
            # Other C0 controls + DEL — no ECHAR form, use UCHAR.
            out.append(f"\\u{code:04X}")
        else:
            out.append(ch)
    return "".join(out)


def _embed_text(text: str) -> list[float]:
    """Get embedding vector from Ollama."""
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=60.0, transport=transport) as client:
        resp = client.post(
            f"{OLLAMA_URL}/api/embed",
            json={"model": EMBED_MODEL, "input": text},
        )
        resp.raise_for_status()
        data = resp.json()
    embs = data.get("embeddings") or [data.get("embedding")]
    return embs[0]


def _person_id_from_identifier(identifier: str) -> str:
    """Generate a stable person ID from a phone number or email."""
    clean = identifier.strip().lower()
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://pwg.dev/person/{clean}"))


def _person_uri(person_id: str) -> str:
    return f"https://pwg.dev/ontology#person_{person_id}"


def _whatsapp_display_name(jid: str) -> str:
    """Placeholder display name for an un-named WhatsApp phone contact.

    The local-part of an `@s.whatsapp.net` JID is an E.164 number. Show it as
    a `+`-prefixed phone so the placeholder reads as a phone contact rather
    than a bare "random number" (BW-4). Non-numeric local-parts (defensive)
    are returned unchanged. A real name replaces this once contact_syncer or
    CM046 email enrichment supplies one.
    """
    local = jid.split("@", 1)[0] if "@" in jid else jid
    if local.isdigit():
        return "+" + local
    return local


def _whatsapp_phone_e164(jid: str) -> str:
    """E.164 phone string for an ``@s.whatsapp.net`` JID, used as the phone
    ``identifierValue`` so a WhatsApp contact shares ONE key with the same
    number from Contacts / iMessage and RULE 1 (``dedupe_merge``) folds
    them. Without this the raw JID (``<number>@s.whatsapp.net``) never
    matched the E.164 (``+<number>``) and the same human stayed split as
    a "duplicate +number". Non-numeric / non-JID inputs pass through."""
    local = jid.split("@", 1)[0] if "@" in jid else jid
    return "+" + local if local.isdigit() else jid


# ── iMessage ingestion ────────────────────────────────────────────

def ingest_imessage(fda_dir: Path) -> dict:
    """Ingest iMessage conversations into the people graph.

    Creates Person nodes for each unique contact found in iMessage,
    with phone/email identifiers for cross-referencing with GDPR data.
    """
    conversations_file = fda_dir / "imessage_conversations.json"
    if not conversations_file.exists():
        logger.info("No iMessage data to ingest")
        return {"status": "skipped", "reason": "no data"}

    conversations = json.loads(conversations_file.read_text())
    people_created = 0
    people_enriched = 0

    for convo in conversations:
        participants = convo.get("participants", [])
        msg_count = convo.get("message_count", 0)
        last_msg = convo.get("last_message")

        for participant in participants:
            if not participant:
                continue

            person_id = _person_id_from_identifier(participant)
            uri = _person_uri(person_id)

            # Check if person already exists in Oxigraph
            exists = _person_exists(uri)

            if not exists:
                # Create a minimal person node
                is_phone = participant.startswith("+") or participant.replace("-", "").replace(" ", "").isdigit()
                id_type = "phone" if is_phone else "email"

                triples = [
                    f"<{uri}> a pwg:Person",
                    f'<{uri}> pwg:displayName "{_escape(participant)}"',
                    f'<{uri}> pwg:contactType "person"',
                    f'<{uri}> pwg:privacyLevel "{DEFAULT_PRIVACY}"',
                    f'<{uri}> pwg:createdAt "{datetime.now(timezone.utc).isoformat()}"^^xsd:dateTime',
                    f'<{uri}> pwg:source "imessage_fda"',
                ]

                # #576: the iMessage participant is a raw handle (phone or
                # email) used as the displayName. Flag the phone/email-only
                # case as provisional so the resolver may overwrite it with a
                # Contacts name and surfaces can suppress the bare-number leak.
                if _is_provisional_display_name(participant):
                    triples.append(
                        f'<{uri}> pwg:displayNameProvisional "true"^^xsd:boolean'
                    )

                # Add identifier
                id_uri = f"https://pwg.dev/ontology#id_{person_id}_imessage"
                triples.extend([
                    f"<{uri}> pwg:hasIdentifier <{id_uri}>",
                    f"<{id_uri}> a pwg:PersonIdentifier",
                    f'<{id_uri}> pwg:identifierType "{id_type}"',
                    f'<{id_uri}> pwg:identifierValue "{_escape(participant)}"',
                    f'<{id_uri}> pwg:identifierLabel "IMESSAGE"',
                ])

                sparql = (
                    "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                    "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
                    "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
                )
                _sparql_update(sparql)
                people_created += 1
            else:
                # Enrich: add iMessage identifier if not already present
                id_uri = f"https://pwg.dev/ontology#id_{person_id}_imessage"
                if not _identifier_exists(id_uri):
                    is_phone = participant.startswith("+") or participant.replace("-", "").replace(" ", "").isdigit()
                    id_type = "phone" if is_phone else "email"
                    sparql = (
                        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                        f"INSERT DATA {{\n"
                        f"  <{uri}> pwg:hasIdentifier <{id_uri}> .\n"
                        f"  <{id_uri}> a pwg:PersonIdentifier .\n"
                        f'  <{id_uri}> pwg:identifierType "{id_type}" .\n'
                        f'  <{id_uri}> pwg:identifierValue "{_escape(participant)}" .\n'
                        f'  <{id_uri}> pwg:identifierLabel "IMESSAGE" .\n'
                        f"}}"
                    )
                    _sparql_update(sparql)
                    people_enriched += 1

            # Update last_contact if this conversation is more recent
            if last_msg and msg_count > 0:
                _update_last_contact(uri, last_msg, "imessage")

    logger.info(
        "iMessage: %d people created, %d enriched",
        people_created, people_enriched,
    )
    return {
        "status": "ok",
        "people_created": people_created,
        "people_enriched": people_enriched,
    }


def _person_exists(uri: str) -> bool:
    """Check if a person URI exists in Oxigraph."""
    try:
        result = _sparql_query(
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            f"SELECT ?t WHERE {{ <{uri}> a ?t }} LIMIT 1"
        )
        return len(result) > 0
    except Exception:
        return False


def _identifier_exists(id_uri: str) -> bool:
    """Check if an identifier URI exists in Oxigraph."""
    try:
        result = _sparql_query(
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            f"SELECT ?t WHERE {{ <{id_uri}> a ?t }} LIMIT 1"
        )
        return len(result) > 0
    except Exception:
        return False


# Per-source last-contact predicates (CM041 schema/people.ttl). FDA
# only ingests calendar and iMessage signal; the legacy aggregate
# pwg:lastContact was retired in CM041 PR-D1a.
_SOURCE_PREDICATE = {
    "calendar": "pwg:lastContactCalendar",
    "imessage": "pwg:lastContactIMessage",
    # WhatsApp T1 (DM) + T2 (group) both write to the same predicate.
    # The pwg:contactSourceTier triple on the identifier carries the
    # tier-context tag so the wiki renderer + future Marvin retrieval
    # can distinguish DM-level signals from group-membership signals
    # without splitting the freshness signal across two predicates.
    "whatsapp": "pwg:lastContactWhatsApp",
}


def _update_last_contact(person_uri: str, timestamp: str, source: str) -> None:
    """Update a person's per-source last-contact if this timestamp is
    more recent than what's stored.

    Oxigraph upsert uses the atomic DELETE-INSERT-WHERE-FILTER
    pattern: equal or older dates are no-ops, idempotent on re-runs.

    Sources that are not contact events (e.g. photos face labels are
    proximity, not interaction) are intentionally absent from
    _SOURCE_PREDICATE and produce a debug-log no-op rather than
    poisoning the freshness signal. Same discipline as the PR-A fix
    that stopped contact_syncer using vCard REV as a contact event.

    Future-dated events are NEVER a "last contact". A calendar export
    routinely carries upcoming meetings, so this writer must reject any
    timestamp after today, otherwise an upcoming meeting (e.g. a fixture
    a week away) wins the read-side max() and the assistant reports a
    future date as "last contact". A scheduled future meeting is a
    "next meeting" signal, not a last-contact one; it is surfaced by the
    Meeting nodes the calendar ingest also emits, never here.
    """
    predicate = _SOURCE_PREDICATE.get(source)
    if predicate is None:
        logger.debug(
            "No last-contact predicate for source %r; skipping", source
        )
        return

    # Known follow-up: harden timestamp parsing against the same edge
    # cases the GDPR import pipeline handles (timezone-naive inputs,
    # empty strings, malformed ISO-8601). Out of scope for PR-D1b.
    try:
        dt = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        date_str = dt.strftime("%Y-%m-%d")

        # A last-contact must be in the past (or today). Comparing the
        # derived YYYY-MM-DD strings sidesteps tz-aware/naive subtraction
        # errors: both sides are plain ISO date strings, lexicographically
        # ordered the same as chronologically. Future-dated events (an
        # upcoming meeting in a calendar export) are dropped here.
        today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if date_str > today_str:
            logger.debug(
                "Skipping future last-contact %s for %s (source=%s); "
                "future events are not last-contact signals",
                date_str, person_uri, source,
            )
            return

        sparql = (
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
            f"DELETE {{ <{person_uri}> {predicate} ?old }}\n"
            f'INSERT {{ <{person_uri}> {predicate} "{date_str}"^^xsd:date }}\n'
            "WHERE {\n"
            f"  OPTIONAL {{ <{person_uri}> {predicate} ?old }}\n"
            f'  FILTER (!BOUND(?old) || ?old < "{date_str}"^^xsd:date)\n'
            "}"
        )
        _sparql_update(sparql)
    except Exception as e:
        logger.debug("Could not update last_contact: %s", e)


# ── WhatsApp historical ingestion (CX-85) ─────────────────────────
#
# Three-tier model (Andy 2026-05-26 -- see whatsapp_history.py for
# the full classifier docstring):
#
#   T1 -- DM:               Person + lastContactWhatsApp +
#                           contactSourceTier "whatsapp_dm".
#                           confidence 1.0 implicit (no triple).
#   T2 -- intimate/active:  Per-member Person + lastContactWhatsApp +
#                           contactSourceTier "whatsapp_group_intimate" or
#                           "whatsapp_group_active" + pwg:confidence 0.7.
#   T3 -- large + passive:  SKIP. No triples emitted. No Person nodes
#                           created. Group is invisible to the graph.
#
# Schema additions introduced here (set a precedent for future
# non-DM sources):
#
#   pwg:confidence            xsd:float, 0.0-1.0. Absence -> 1.0 implicit.
#   pwg:contactSourceTier     xsd:string, one of the three literals above.
#                             Attached to the PersonIdentifier so a single
#                             contact may legitimately accumulate
#                             multiple tier tags across re-runs (DM + group
#                             membership). The wiki renderer picks the
#                             highest-confidence tag when surfacing.

def ingest_whatsapp(fda_dir: Path) -> dict:
    """Ingest WhatsApp chats (T1 DMs + T2 groups) into the people graph.

    Reads whatsapp_history's JSON output, filters out T3 (already
    dropped at extract time by ``conversation_stats`` but we
    double-check at ingest time so a re-run on a stale file does
    not poison the graph), and emits per-tier triples for each
    participant.

    The DELETE-INSERT-WHERE-FILTER pattern in ``_update_last_contact``
    makes the lastContactWhatsApp upsert atomic + idempotent. The
    Person + Identifier inserts use the same "if not exists" pattern
    as ingest_imessage; re-running this ingest is safe.
    """
    chats_file = fda_dir / "whatsapp_conversations.json"
    if not chats_file.exists():
        logger.info("No WhatsApp data to ingest")
        return {"status": "skipped", "reason": "no data"}

    chats = json.loads(chats_file.read_text())
    people_created = 0
    people_enriched = 0
    tier_t1 = 0
    tier_t2_intimate = 0
    tier_t2_active = 0
    tier_t3_skipped = 0

    for chat in chats:
        tier = chat.get("tier", "")
        if tier == "whatsapp_skipped":
            tier_t3_skipped += 1
            continue

        last_msg = chat.get("last_message")

        # Tier-specific participant list. T1 puts the DM partner in
        # `participants`; T2 puts the active group members.
        participants = chat.get("participants") or []
        confidence = chat.get("confidence", 1.0)

        if tier == "whatsapp_dm":
            tier_t1 += 1
        elif tier == "whatsapp_group_intimate":
            tier_t2_intimate += 1
        elif tier == "whatsapp_group_active":
            tier_t2_active += 1
        else:
            # Unknown tier -- skip + warn rather than emit triples
            # with a tier literal the wiki renderer cannot interpret.
            logger.warning("WhatsApp chat with unknown tier %r; skipping", tier)
            continue

        for participant in participants:
            if not participant:
                continue

            # Defensive belt-and-braces (whatsapp_history already rejects
            # these at source): `@lid` is WhatsApp's opaque linked-id, not a
            # phone and not a name. As a contact's sole identity it is pure
            # noise, so it must not become a number-named Person (BW-4).
            if participant.endswith("@lid"):
                continue

            person_id = _person_id_from_identifier(participant)
            uri = _person_uri(person_id)
            exists = _person_exists(uri)

            if not exists:
                # `@s.whatsapp.net` JIDs are phone-rooted: the local-part is
                # an E.164 number. Present it as a `+`-prefixed phone so the
                # placeholder reads as a phone contact rather than a bare
                # "random number" (BW-4); real names arrive later from
                # contact_syncer / CM046 email signatures.
                display = _whatsapp_display_name(participant)
                triples = [
                    f"<{uri}> a pwg:Person",
                    f'<{uri}> pwg:displayName "{_escape(display)}"',
                    f'<{uri}> pwg:contactType "person"',
                    f'<{uri}> pwg:privacyLevel "{DEFAULT_PRIVACY}"',
                    f'<{uri}> pwg:createdAt "{datetime.now(timezone.utc).isoformat()}"^^xsd:dateTime',
                    f'<{uri}> pwg:source "whatsapp_fda"',
                ]

                # #576: flag the bare-number placeholder so the resolver
                # may overwrite it and surfaces can suppress it as a name.
                if _is_provisional_display_name(display):
                    triples.append(
                        f'<{uri}> pwg:displayNameProvisional "true"^^xsd:boolean'
                    )
                id_uri = f"https://pwg.dev/ontology#id_{person_id}_whatsapp"
                triples.extend([
                    f"<{uri}> pwg:hasIdentifier <{id_uri}>",
                    f"<{id_uri}> a pwg:PersonIdentifier",
                    f'<{id_uri}> pwg:identifierType "phone"',
                    f'<{id_uri}> pwg:identifierValue "{_escape(_whatsapp_phone_e164(participant))}"',
                    f'<{id_uri}> pwg:identifierLabel "WHATSAPP"',
                    f'<{id_uri}> pwg:contactSourceTier "{tier}"',
                ])
                # T2 carries an explicit confidence; T1's 1.0 is
                # implicit (no triple emitted, matching the dispatch's
                # "absence == 1.0 implicitly" contract).
                if tier != "whatsapp_dm":
                    triples.append(
                        f'<{id_uri}> pwg:confidence "{confidence}"^^xsd:float'
                    )

                sparql = (
                    "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                    "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
                    "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
                )
                _sparql_update(sparql)
                people_created += 1
            else:
                # Person already exists (probably from contact_syncer,
                # iMessage, or a prior tier of this same WhatsApp run).
                # Add the WhatsApp identifier + tier tag if not already
                # present. We deliberately do NOT downgrade an existing
                # higher-confidence tier -- the SPARQL layer tolerates
                # multiple contactSourceTier values, and the wiki
                # renderer picks the highest one.
                id_uri = f"https://pwg.dev/ontology#id_{person_id}_whatsapp"
                if not _identifier_exists(id_uri):
                    triples = [
                        f"<{uri}> pwg:hasIdentifier <{id_uri}>",
                        f"<{id_uri}> a pwg:PersonIdentifier",
                        f'<{id_uri}> pwg:identifierType "phone"',
                        f'<{id_uri}> pwg:identifierValue "{_escape(participant)}"',
                        f'<{id_uri}> pwg:identifierLabel "WHATSAPP"',
                        f'<{id_uri}> pwg:contactSourceTier "{tier}"',
                    ]
                    if tier != "whatsapp_dm":
                        triples.append(
                            f'<{id_uri}> pwg:confidence "{confidence}"^^xsd:float'
                        )
                    sparql = (
                        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
                        "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
                    )
                    _sparql_update(sparql)
                    people_enriched += 1

            # Always upsert lastContactWhatsApp regardless of person
            # existing or not. The DELETE-INSERT-WHERE-FILTER pattern
            # in _update_last_contact ensures older timestamps never
            # overwrite newer ones, so this is safe to call from any
            # tier's loop.
            if last_msg:
                _update_last_contact(uri, last_msg, "whatsapp")

    logger.info(
        "WhatsApp: %d people created, %d enriched (t1=%d, t2_intimate=%d, t2_active=%d, t3_skipped=%d)",
        people_created, people_enriched,
        tier_t1, tier_t2_intimate, tier_t2_active, tier_t3_skipped,
    )
    return {
        "status": "ok",
        "people_created": people_created,
        "people_enriched": people_enriched,
        "tier_t1_dm_chats": tier_t1,
        "tier_t2_intimate_chats": tier_t2_intimate,
        "tier_t2_active_chats": tier_t2_active,
        "tier_t3_skipped_chats": tier_t3_skipped,
    }


# ── Calendar attendee ingestion ───────────────────────────────────

def ingest_calendar(fda_dir: Path) -> dict:
    """Ingest calendar event attendees into the people graph.

    Creates Person nodes for attendees and links them to events.
    Meeting frequency is a strong relationship signal.
    """
    events_file = fda_dir / "calendar_events.json"
    if not events_file.exists():
        logger.info("No calendar data to ingest")
        return {"status": "skipped", "reason": "no data"}

    events = json.loads(events_file.read_text())
    people_seen: set[str] = set()
    events_processed = 0
    meetings_created = 0

    for event in events:
        attendees = event.get("attendees", [])
        start_date = event.get("start_date", "")
        title = event.get("title", "")
        location = event.get("location", "")

        attendee_uris: list[str] = []
        for attendee in attendees:
            if not attendee:
                continue

            person_id = _person_id_from_identifier(attendee)
            uri = _person_uri(person_id)
            attendee_uris.append(uri)

            if person_id not in people_seen:
                people_seen.add(person_id)

                if not _person_exists(uri):
                    triples = [
                        f"<{uri}> a pwg:Person",
                        f'<{uri}> pwg:displayName "{_escape(attendee)}"',
                        f'<{uri}> pwg:contactType "person"',
                        f'<{uri}> pwg:privacyLevel "{DEFAULT_PRIVACY}"',
                        f'<{uri}> pwg:createdAt "{datetime.now(timezone.utc).isoformat()}"^^xsd:dateTime',
                        f'<{uri}> pwg:source "calendar_fda"',
                    ]
                    sparql = (
                        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
                        "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
                    )
                    _sparql_update(sparql)

            # Update last contact from meeting date
            if start_date:
                _update_last_contact(uri, start_date, "calendar")

        # Emit a Meeting node so the wiki Meetings page renders this event.
        # The CM044 reader (pwg_data.load_meetings) queries `pwg:Meeting`
        # with pwg:meetingSummary / pwg:meetingDate / pwg:meetingLocation /
        # pwg:meetingAttendee, so we write exactly those predicates. Without
        # this the calendar events only ever became contact-date signals and
        # the Meetings wiki page rendered empty even though events existed.
        # Meeting URI is a stable uuid5 of title+date so re-ingest is
        # idempotent (Oxigraph INSERT DATA on identical triples is a no-op).
        if title or attendee_uris:
            meeting_id = uuid.uuid5(
                uuid.NAMESPACE_URL,
                f"https://pwg.dev/meeting/{title}|{start_date}",
            )
            meeting_uri = f"https://pwg.dev/ontology#meeting_{meeting_id}"
            m_triples = [
                f"<{meeting_uri}> a pwg:Meeting",
                f'<{meeting_uri}> pwg:source "calendar_fda"',
                f'<{meeting_uri}> pwg:privacyLevel "{DEFAULT_PRIVACY}"',
            ]
            if title:
                m_triples.append(
                    f'<{meeting_uri}> pwg:meetingSummary "{_escape(title)}"'
                )
            if start_date:
                m_triples.append(
                    f'<{meeting_uri}> pwg:meetingDate "{_escape(start_date)}"'
                )
            if location:
                m_triples.append(
                    f'<{meeting_uri}> pwg:meetingLocation "{_escape(location)}"'
                )
            for a_uri in attendee_uris:
                m_triples.append(
                    f"<{meeting_uri}> pwg:meetingAttendee <{a_uri}>"
                )
            m_sparql = (
                "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
                "INSERT DATA {\n  " + " .\n  ".join(m_triples) + " .\n}"
            )
            _sparql_update(m_sparql)
            meetings_created += 1

        events_processed += 1

    logger.info(
        "Calendar: %d events processed, %d unique attendees, %d meetings",
        events_processed, len(people_seen), meetings_created,
    )
    return {
        "status": "ok",
        "events_processed": events_processed,
        "unique_attendees": len(people_seen),
        "meetings_created": meetings_created,
    }


# ── Photos face ingestion ────────────────────────────────────────

def ingest_photos_people(fda_dir: Path) -> dict:
    """Ingest Photos face labels into the people graph.

    Creates Person nodes for recognised faces and links them
    to photo events (dates + locations = "you were with X at Y on Z").
    """
    people_file = fda_dir / "photos_people.json"
    if not people_file.exists():
        logger.info("No Photos data to ingest")
        return {"status": "skipped", "reason": "no data"}

    people = json.loads(people_file.read_text())
    people_created = 0

    for person in people:
        name = person.get("name", "")
        if not name:
            continue

        person_id = _person_id_from_identifier(f"photos_face_{name}")
        uri = _person_uri(person_id)

        if not _person_exists(uri):
            photo_count = person.get("photo_count", 0)
            first_seen = person.get("first_seen", "")
            last_seen = person.get("last_seen", "")

            triples = [
                f"<{uri}> a pwg:Person",
                f'<{uri}> pwg:displayName "{_escape(name)}"',
                f'<{uri}> pwg:contactType "person"',
                f'<{uri}> pwg:privacyLevel "{DEFAULT_PRIVACY}"',
                f'<{uri}> pwg:source "photos_fda"',
                f'<{uri}> pwg:photoCount "{photo_count}"^^xsd:integer',
            ]

            if first_seen:
                triples.append(
                    f'<{uri}> pwg:createdAt "{first_seen}"^^xsd:dateTime'
                )
            # Photos face-label last_seen is proximity, not a contact
            # event. Person nodes are still created for face discovery,
            # but freshness signal stays clean. Same discipline as the
            # PR-A vCard REV fix.

            sparql = (
                "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
                "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
            )
            _sparql_update(sparql)
            people_created += 1

    logger.info("Photos: %d people created from face labels", people_created)
    return {"status": "ok", "people_created": people_created}


# ── Apple Mail contact ingestion ──────────────────────────────────

def ingest_mail_contacts(fda_dir: Path) -> dict:
    """Ingest frequent email contacts into the people graph.

    Uses the sender frequency data to create/enrich Person nodes
    with email identifiers.
    """
    contacts_file = fda_dir / "apple_mail_contacts.json"
    if not contacts_file.exists():
        logger.info("No Apple Mail contacts to ingest")
        return {"status": "skipped", "reason": "no data"}

    contacts = json.loads(contacts_file.read_text())
    people_created = 0

    for email, count in contacts.items():
        if not email or count < 3:
            # Skip very infrequent senders
            continue

        person_id = _person_id_from_identifier(email)
        uri = _person_uri(person_id)

        if not _person_exists(uri):
            triples = [
                f"<{uri}> a pwg:Person",
                f'<{uri}> pwg:displayName "{_escape(email)}"',
                f'<{uri}> pwg:contactType "person"',
                f'<{uri}> pwg:privacyLevel "{DEFAULT_PRIVACY}"',
                f'<{uri}> pwg:source "apple_mail_fda"',
            ]

            id_uri = f"https://pwg.dev/ontology#id_{person_id}_mail"
            triples.extend([
                f"<{uri}> pwg:hasIdentifier <{id_uri}>",
                f"<{id_uri}> a pwg:PersonIdentifier",
                f'<{id_uri}> pwg:identifierType "email"',
                f'<{id_uri}> pwg:identifierValue "{_escape(email)}"',
                f'<{id_uri}> pwg:identifierLabel "APPLE_MAIL"',
            ])

            sparql = (
                "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
                "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
            )
            _sparql_update(sparql)
            people_created += 1

    logger.info("Apple Mail: %d contacts created", people_created)
    return {"status": "ok", "people_created": people_created}


# ── Browser history ingestion (direct path, v1.0) ─────────────────
#
# Single-Mac product: there is NO PWG gateway on a customer install.
# The zeroclaw-gateway daemon on :8000 does not implement
# /api/safari/ingest, and nothing listens on :8765. So this writer
# embeds visits with the local Ollama instance and upserts directly
# into the Qdrant `safari_history` collection -- the exact collection
# the CM044 wiki Browsing page and the person-matching reader scroll.
#
# Blocklist: because there is no server-side gateway to enforce it,
# the sensitive-domain blocklist (banking / medical / auth / adult)
# is enforced HERE, client-side, before anything is embedded or
# stored. A blocked visit never reaches Ollama or Qdrant. Dropped
# visits are counted as "skipped_sensitive".
#
# Privacy: the return dict is counts only. No URLs, titles, or
# domains cross the install.sh process boundary (install.sh reads
# `sent` and `skipped_sensitive`).

# The CM044 Browsing page + person-matching reader BOTH scroll the
# Qdrant collection named exactly "safari_history". Chrome visits land
# in the SAME collection (readers key off url/title/domain, not the
# source). Overridable for tests only.
BROWSING_QDRANT_COLLECTION = os.getenv(
    "BROWSING_QDRANT_COLLECTION", "safari_history"
)
# nomic-embed-text emits 768-dim vectors; this fallback is used only to
# size a fresh `safari_history` collection when nothing embedded (every
# other collection in this repo embeds at 768). We prefer the FIRST real
# embedding length and fall back to this only if no live embedder is
# reachable -- same pattern as the people/preferences ingestors.
BROWSING_EMBED_DIM = int(os.getenv("BROWSING_EMBED_DIM", "768"))
# Batch sizes: 64 keeps Ollama responsive on a 16GB Mac across
# thousands of visits; 200 is Qdrant's tested upsert chunk.
_BROWSING_EMBED_BATCH_SIZE = int(os.getenv("EMBED_BATCH_SIZE", "64"))
_BROWSING_QDRANT_BATCH_SIZE = int(os.getenv("QDRANT_UPSERT_BATCH_SIZE", "200"))

# Sensitive-domain blocklist. Substring match on the lowercased domain
# so subdomains (e.g. secure.bank.example.com) are caught too.
_SENSITIVE_DOMAIN_SUBSTRINGS = (
    # Banking / finance
    "bank", "paypal", "stripe.com", "wise.com", "revolut", "monzo",
    "barclays", "hsbc", "natwest", "lloyds", "santander", "halifax",
    "nationwide", "amex", "americanexpress", "mastercard", "visa.com",
    "coinbase", "binance", "kraken.com",
    # Medical / health
    "nhs.uk", "patient", "healthgrades", "webmd", "mayoclinic",
    "pharmacy", "doctolib", "zocdoc", "medical", "clinic", "hospital",
    "therapy", "psychology", "mentalhealth",
    # Adult
    "pornhub", "xvideos", "xnxx", "onlyfans", "xhamster", "redtube",
    # Auth / account-recovery surfaces
    "accounts.google.com", "appleid.apple.com", "login.microsoftonline",
)


def _is_sensitive_domain(domain: str) -> bool:
    """True if ``domain`` matches the sensitive blocklist (substring,
    case-insensitive). A blank domain is never sensitive (it is dropped
    upstream as unusable)."""
    if not domain:
        return False
    d = domain.lower()
    return any(token in d for token in _SENSITIVE_DOMAIN_SUBSTRINGS)


def _ollama_embed_batch(texts: list[str]) -> list[list[float]]:
    """Batch-embed texts via Ollama /api/embed.

    Returns one vector per input, in order. On any failure a given
    slot is padded with an empty list so the caller keeps index
    alignment; empty vectors are dropped at upsert time. Falls back to
    the per-text :func:`_embed_text` if a batch response is malformed.
    """
    if not texts:
        return []
    transport = httpx.HTTPTransport(proxy=None)
    vectors: list[list[float]] = []
    with httpx.Client(timeout=120.0, transport=transport) as client:
        for start in range(0, len(texts), _BROWSING_EMBED_BATCH_SIZE):
            chunk = texts[start : start + _BROWSING_EMBED_BATCH_SIZE]
            try:
                resp = client.post(
                    f"{OLLAMA_URL}/api/embed",
                    json={"model": EMBED_MODEL, "input": chunk},
                )
                resp.raise_for_status()
                embs = resp.json().get("embeddings")
                if embs is None or len(embs) != len(chunk):
                    # Malformed/short batch: degrade to one-at-a-time.
                    embs = []
                    for t in chunk:
                        try:
                            embs.append(_embed_text(t))
                        except Exception as inner:
                            logger.warning(
                                "Ollama embed failed for one visit: %s",
                                type(inner).__name__,
                            )
                            embs.append([])
                vectors.extend(embs)
            except Exception as exc:
                logger.warning(
                    "Ollama embed batch failed (start=%d, size=%d): %s",
                    start, len(chunk), type(exc).__name__,
                )
                vectors.extend([[] for _ in chunk])
    return vectors


def _qdrant_ensure_collection(
    collection: str, vector_size: int, distance: str = "Cosine"
) -> None:
    """Create a Qdrant collection if it does not already exist.

    On a fresh single-Mac install nothing pre-creates the Qdrant
    collections (``install.sh graph_db_start`` brings the container up
    empty). A bare PUT of points into a missing collection lands 0 rows
    and Qdrant does NOT auto-create it, so the writer must self-create
    -- otherwise the iOS People tab / Hub People card / semantic search
    stay blank by design. See HR015 #600 + the
    feedback_qdrant_collections_no_self_create_fresh_install memory.

    Idempotent: a GET on an existing collection short-circuits, so a
    re-install does not clobber existing vectors. A genuinely missing
    collection (404 on GET) is created with the given vector size +
    distance. Any other error is logged and re-raised so the caller can
    decide whether to fail loud.
    """
    transport = httpx.HTTPTransport(proxy=None)
    url = f"{QDRANT_URL}/collections/{collection}"
    with httpx.Client(timeout=30.0, transport=transport) as client:
        try:
            resp = client.get(url)
            if resp.status_code == 200:
                return
        except Exception as exc:
            logger.warning(
                "Qdrant collection probe for %s failed: %s",
                collection, type(exc).__name__,
            )
        # Not present (or probe failed): create it. Qdrant treats a PUT
        # to an existing collection as an error, but we only reach here
        # when the GET did not return 200, so this is the create path.
        body = {"vectors": {"size": vector_size, "distance": distance}}
        resp = client.put(url, json=body)
        resp.raise_for_status()
        logger.info(
            "Created Qdrant collection '%s' (size=%d, distance=%s).",
            collection, vector_size, distance,
        )


def _qdrant_upsert_points(collection: str, points: list[dict]) -> int:
    """Batch-upsert points into a named Qdrant collection.

    Each point is ``{"id", "vector", "payload"}``. Points with an empty
    vector are dropped (Qdrant rejects zero-length vectors). Flushes in
    chunks; logs and continues on a chunk failure. Returns the count
    the server acknowledged.
    """
    valid = [p for p in points if p.get("vector")]
    dropped = len(points) - len(valid)
    if dropped:
        logger.warning(
            "Dropping %d browsing points with empty vectors "
            "(Ollama embed failure upstream).", dropped,
        )
    if not valid:
        return 0
    upserted = 0
    transport = httpx.HTTPTransport(proxy=None)
    # Qdrant REST upsert is PUT /collections/{name}/points (NOT
    # /points/upsert, which 404s). Verified live on Studio 2026-05-30.
    url = f"{QDRANT_URL}/collections/{collection}/points"
    with httpx.Client(timeout=60.0, transport=transport) as client:
        for start in range(0, len(valid), _BROWSING_QDRANT_BATCH_SIZE):
            chunk = valid[start : start + _BROWSING_QDRANT_BATCH_SIZE]
            body = {"points": [
                {"id": p["id"], "vector": p["vector"], "payload": p["payload"]}
                for p in chunk
            ]}
            try:
                resp = client.put(url, json=body, params={"wait": "true"})
                resp.raise_for_status()
                upserted += len(chunk)
            except Exception as exc:
                logger.warning(
                    "Qdrant upsert into %s failed (start=%d, size=%d): %s",
                    collection, start, len(chunk), type(exc).__name__,
                )
    return upserted


def _load_browsing_visits(fda_dir: Path) -> list[dict]:
    """Read safari_history.json + chrome_history.json from ``fda_dir``.

    Both are lists of timeline dicts emitted by the FDA extractor with
    keys: type, timestamp, url, domain, title, visit_count, source.
    Only safari_history.json is produced by extract_all.py today;
    chrome_history.json is read forward-compatibly (skipped if absent)
    so a future Chrome extractor needs no change here. A missing file
    is skipped silently; a malformed file logs and contributes nothing.
    """
    visits: list[dict] = []
    for filename in ("safari_history.json", "chrome_history.json"):
        path = fda_dir / filename
        if not path.exists():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            logger.warning(
                "Could not parse %s: %s; skipping.",
                filename, type(exc).__name__,
            )
            continue
        if isinstance(data, list):
            visits.extend(v for v in data if isinstance(v, dict))
        else:
            logger.warning("%s root is not a list; skipping.", filename)
    return visits


def ingest_browser_history(fda_dir: Path) -> dict:
    """Ingest Safari (and Chrome, if present) browsing history into the
    Qdrant ``safari_history`` collection via the local Ollama embedder.

    Direct, single-machine path: no gateway. Sensitive domains are
    dropped client-side before embed/store. Defensive: missing, empty,
    or all-sensitive input returns ``{"status": "no_data", ...}`` with
    zero counts and never raises; an Ollama/Qdrant hiccup degrades the
    count rather than crashing the installer.

    Returns counts only (HR015 #134 privacy contract):
      ``status``           : "ok" | "no_data" | "error"
      ``sent``             : points upserted into Qdrant (install.sh reads this)
      ``points_created``   : alias of ``sent`` (parity with other ingestors)
      ``skipped_sensitive``: visits dropped by the blocklist (install.sh reads this)
      ``total``            : ingestible visits considered (after url filter)
    """
    visits = _load_browsing_visits(fda_dir)
    if not visits:
        logger.info("No browsing history to ingest.")
        return {
            "status": "no_data",
            "sent": 0,
            "points_created": 0,
            "skipped_sensitive": 0,
            "total": 0,
        }

    skipped_sensitive = 0
    queue: list[dict] = []
    for v in visits:
        url = (v.get("url") or "").strip()
        if not url:
            continue
        domain = (v.get("domain") or "").strip()
        if _is_sensitive_domain(domain):
            skipped_sensitive += 1
            continue
        title = (v.get("title") or "").strip()
        timestamp = (v.get("timestamp") or "").strip()
        source = v.get("source") or "safari_history"
        visit_count = v.get("visit_count") or 0

        # Embedding document: title carries the human-readable signal
        # the person-matcher scans; domain + url anchor it.
        doc = " ".join(part for part in (title, domain, url) if part)
        # Stable point id: same url+timestamp re-runs upsert in place
        # (idempotent re-install) rather than duplicating rows.
        point_id = str(uuid.uuid5(
            uuid.NAMESPACE_URL, f"browsing|{source}|{url}|{timestamp}"
        ))
        queue.append({
            "point_id": point_id,
            "doc": doc,
            "payload": {
                "url": url,
                "domain": domain,
                "title": title,
                # Readers look for visit_date / created_at / date; the
                # extractor names it `timestamp`. Provide all aliases so
                # the Browsing timeline buckets visits regardless of key.
                "timestamp": timestamp,
                "visit_date": timestamp,
                "created_at": timestamp,
                "date": timestamp,
                "visit_count": visit_count,
                "source": source,
                "type": "web_visit",
                "privacy_level": DEFAULT_PRIVACY,
            },
        })

    if not queue:
        logger.info(
            "Browsing: 0 ingestible visits (%d skipped sensitive).",
            skipped_sensitive,
        )
        return {
            "status": "no_data",
            "sent": 0,
            "points_created": 0,
            "skipped_sensitive": skipped_sensitive,
            "total": 0,
        }

    sent = 0
    try:
        vectors = _ollama_embed_batch([item["doc"] for item in queue])

        # Self-create the `safari_history` collection before upserting.
        # On a fresh single-Mac install nothing pre-creates it
        # (install.sh graph_db_start brings Qdrant up empty), and a bare
        # PUT of points into a missing collection lands 0 rows -- Qdrant
        # does NOT auto-create it. Without this the hydrator embedded
        # 11,447 visits but reported sent=0 and the CM044 Browsing wing
        # stayed blank. Mirrors the people/preferences/social ingestors.
        # See feedback_qdrant_collections_no_self_create_fresh_install.
        vector_size = BROWSING_EMBED_DIM
        for vec in vectors:
            if vec:
                vector_size = len(vec)
                break
        _qdrant_ensure_collection(BROWSING_QDRANT_COLLECTION, vector_size)

        points = [
            {"id": item["point_id"], "vector": vec, "payload": item["payload"]}
            for item, vec in zip(queue, vectors)
        ]
        sent = _qdrant_upsert_points(BROWSING_QDRANT_COLLECTION, points)
    except Exception as exc:
        # Non-fatal: the installer must not abort on a vector-store hiccup.
        logger.warning(
            "Browsing vector-store write failed: %s", type(exc).__name__,
        )
        return {
            "status": "error",
            "sent": sent,
            "points_created": sent,
            "skipped_sensitive": skipped_sensitive,
            "total": len(queue),
        }

    if sent == 0:
        # We had visits to store but none landed (every chunk failed).
        # Report error, not "ok" -- a silent ok-with-zero would let the
        # installer claim success while the Browsing page stays blank.
        logger.warning(
            "Browsing: embedded %d visits but 0 landed in Qdrant '%s'.",
            len(queue), BROWSING_QDRANT_COLLECTION,
        )
        return {
            "status": "error",
            "sent": 0,
            "points_created": 0,
            "skipped_sensitive": skipped_sensitive,
            "total": len(queue),
        }

    logger.info(
        "Browsing: %d visits upserted to Qdrant '%s' (%d skipped sensitive).",
        sent, BROWSING_QDRANT_COLLECTION, skipped_sensitive,
    )
    return {
        "status": "ok",
        "sent": sent,
        "points_created": sent,
        "skipped_sensitive": skipped_sensitive,
        "total": len(queue),
    }


# ── Safari bookmarks ingestion (Reading wiki page) ────────────────
#
# extract_all.py writes safari_bookmarks.json (the installer offers
# `safari_bookmarks` as a Recommended FDA source), but nothing ever
# ingested it -- so the data died on disk after extraction and the
# CM044 Reading wiki page rendered an empty bookmarks section for every
# customer (the silent-fail caught in the 2026-06-04 resweep).
#
# Reader contract (confirmed against the live reader, file:line):
#   - collection NAME : "preferences"
#       CM044 compiler/pages/reading_pages.py:46 (scroll_all),
#       compiler/incremental.py:44 ("reading" -> ["qdrant:preferences"]),
#       compiler/compile.py:69 ("reading" page registered).
#   - reader FILTER   : payload `category == "bookmark"`
#       reading_pages.py:43 ({"key": "category", "match": {"value": cat}})
#       for cat in ("bookmark", "website").
#   - payload FIELDS the reader consumes:
#       subject       (reading_pages.py:124 -- the bookmark title)
#       strength      (reading_pages.py:98/132 -- sort + bar)
#       source        (reading_pages.py:93/133)
#       observed_at / created_at (reading_pages.py:94 -- timeline buckets)
#       extra.url     (reading_pages.py:127 -- makes the title clickable)
#   The full payload mirrors CM019 ParsedPreference.to_payload
#   (parsers/base.py:118) so FDA-extracted bookmarks render identically
#   to GDPR-imported ones.
#
# Counts-only return (install.sh reads `sent`); no bookmark titles or
# URLs cross the process boundary. Fails LOUD (status "error") if there
# were bookmarks to ingest but nothing landed in Qdrant -- a silent
# ok-with-zero would let the installer claim success while the Reading
# page stays blank, the exact silent-fail this function exists to kill.

# The reader scrolls exactly this collection name. Overridable for
# tests only. Defaults to "preferences" to match CM019 + reading_pages.
PREFERENCES_QDRANT_COLLECTION = os.getenv(
    "PREFERENCES_QDRANT_COLLECTION", "preferences"
)
# nomic-embed-text emits 768-dim vectors; fallback used only when no
# live embedding length is available to size a fresh collection.
PREFERENCES_EMBED_DIM = int(os.getenv("PREFERENCES_EMBED_DIM", "768"))

# Folder -> strength. Reading List items were explicitly saved to read
# later; Favourites (BookmarksBar) are pinned. Both are stronger signals
# than an ordinary filed bookmark. Mirrors CM019 apple.py's favourite
# vs ordinary split (0.75 / 0.70).
_BOOKMARK_STRENGTH_BY_FOLDER = {
    "Reading List": 0.75,
    "Favourites": 0.72,
}
_BOOKMARK_DEFAULT_STRENGTH = 0.70


def _load_safari_bookmarks(fda_dir: Path) -> list[dict]:
    """Read safari_bookmarks.json from ``fda_dir``.

    The file is a list of dicts emitted by extract_all.py
    (``[asdict(b) for b in bookmarks]``) with keys: title, url, domain,
    folder. A missing file is skipped silently (the source was not
    enabled); a malformed file logs and contributes nothing.
    """
    path = fda_dir / "safari_bookmarks.json"
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        logger.warning(
            "Could not parse safari_bookmarks.json: %s; skipping.",
            type(exc).__name__,
        )
        return []
    if not isinstance(data, list):
        logger.warning("safari_bookmarks.json root is not a list; skipping.")
        return []
    return [b for b in data if isinstance(b, dict)]


def ingest_bookmarks(fda_dir: Path) -> dict:
    """Ingest Safari bookmarks into the Qdrant ``preferences`` collection
    so the CM044 Reading wiki page can render them.

    Direct, single-machine path: no gateway. Sensitive domains are
    dropped client-side before embed/store (same blocklist as browsing).
    Defensive: missing, empty, or all-sensitive input returns
    ``{"status": "no_data", ...}`` with zero counts and never raises; an
    Ollama/Qdrant hiccup degrades the count rather than crashing the
    installer.

    Each bookmark becomes one ``preferences`` point with
    ``category == "bookmark"`` and the payload field set the Reading page
    reads. The point id is derived stably from the bookmark URL so a
    re-install upserts in place rather than duplicating rows.

    Returns counts only (parity with the other ingesters; install.sh
    reads ``sent``):
      ``status``           : "ok" | "no_data" | "error"
      ``sent``             : points upserted into Qdrant
      ``points_created``   : alias of ``sent``
      ``skipped_sensitive``: bookmarks dropped by the blocklist
      ``total``            : ingestible bookmarks considered
    """
    bookmarks = _load_safari_bookmarks(fda_dir)
    if not bookmarks:
        logger.info("No bookmarks to ingest.")
        return {
            "status": "no_data",
            "sent": 0,
            "points_created": 0,
            "skipped_sensitive": 0,
            "total": 0,
        }

    now_iso = datetime.now(timezone.utc).isoformat()
    skipped_sensitive = 0
    queue: list[dict] = []
    seen_urls: set[str] = set()
    for b in bookmarks:
        url = (b.get("url") or "").strip()
        if not url or url in seen_urls:
            continue
        domain = (b.get("domain") or "").strip()
        if _is_sensitive_domain(domain):
            skipped_sensitive += 1
            continue
        seen_urls.add(url)
        title = (b.get("title") or "").strip() or domain or url
        folder = (b.get("folder") or "").strip()
        strength = _BOOKMARK_STRENGTH_BY_FOLDER.get(
            folder, _BOOKMARK_DEFAULT_STRENGTH
        )

        # Embedding document: title carries the human-readable signal;
        # domain anchors it. Mirrors the browsing path's doc construction
        # and CM019's "Like <subject> category:bookmark" embedding text.
        doc = " ".join(
            part for part in ("Like", title, "category:bookmark", domain) if part
        )
        # Stable point id: same URL re-runs upsert in place (idempotent
        # re-install) rather than duplicating rows.
        point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"bookmark|{url}"))
        queue.append({
            "point_id": point_id,
            "doc": doc,
            "payload": {
                # Reader contract (CM044 reading_pages.py) + CM019
                # ParsedPreference.to_payload parity so FDA bookmarks
                # render identically to GDPR-imported ones.
                "preference_id": point_id,
                "subject": title,
                "preference_type": "Like",
                "category": "bookmark",
                "strength": strength,
                "source": "safari_bookmarks",
                "context": folder or None,
                "size": "Medium",
                "compartment_level": DEFAULT_PRIVACY,
                "privacy_level": DEFAULT_PRIVACY,
                "created_at": now_iso,
                "observed_at": now_iso,
                "extra": {
                    "url": url,
                    "domain": domain,
                    "folder": folder,
                    "source_type": "safari_bookmarks",
                },
            },
        })

    if not queue:
        logger.info(
            "Bookmarks: 0 ingestible (%d skipped sensitive).",
            skipped_sensitive,
        )
        return {
            "status": "no_data",
            "sent": 0,
            "points_created": 0,
            "skipped_sensitive": skipped_sensitive,
            "total": 0,
        }

    vectors = _ollama_embed_batch([item["doc"] for item in queue])

    # Size the collection from the first real embedding; fall back to
    # the nomic-embed-text default only if nothing embedded.
    vector_size = PREFERENCES_EMBED_DIM
    for vec in vectors:
        if vec:
            vector_size = len(vec)
            break

    try:
        _qdrant_ensure_collection(PREFERENCES_QDRANT_COLLECTION, vector_size)
    except Exception as exc:
        logger.warning(
            "Bookmarks: could not ensure Qdrant collection '%s': %s",
            PREFERENCES_QDRANT_COLLECTION, type(exc).__name__,
        )
        return {
            "status": "error",
            "sent": 0,
            "points_created": 0,
            "skipped_sensitive": skipped_sensitive,
            "total": len(queue),
        }

    points = [
        {"id": item["point_id"], "vector": vec, "payload": item["payload"]}
        for item, vec in zip(queue, vectors)
    ]

    sent = 0
    try:
        sent = _qdrant_upsert_points(PREFERENCES_QDRANT_COLLECTION, points)
    except Exception as exc:
        logger.warning(
            "Bookmarks vector-store write failed: %s", type(exc).__name__,
        )
        return {
            "status": "error",
            "sent": sent,
            "points_created": sent,
            "skipped_sensitive": skipped_sensitive,
            "total": len(queue),
        }

    if sent == 0:
        # We had bookmarks to store but none landed (every chunk failed).
        # Report error, not "ok" -- a silent ok-with-zero would let the
        # installer claim success while the Reading page stays blank.
        logger.warning(
            "Bookmarks: had %d to ingest but 0 landed in Qdrant '%s'.",
            len(queue), PREFERENCES_QDRANT_COLLECTION,
        )
        return {
            "status": "error",
            "sent": 0,
            "points_created": 0,
            "skipped_sensitive": skipped_sensitive,
            "total": len(queue),
        }

    logger.info(
        "Bookmarks: %d upserted to Qdrant '%s' (%d skipped sensitive).",
        sent, PREFERENCES_QDRANT_COLLECTION, skipped_sensitive,
    )
    return {
        "status": "ok",
        "sent": sent,
        "points_created": sent,
        "skipped_sensitive": skipped_sensitive,
        "total": len(queue),
    }


# ── iMessage social-graph signal (Social wiki page) ───────────────
#
# extract_all.py writes imessage_conversations.json (iMessage is a
# Recommended FDA source) and ingest_imessage() above turns each
# participant into a pwg:Person node in Oxigraph. But the CM044 Social
# wiki page does NOT read Oxigraph -- it reads the Qdrant `preferences`
# collection filtered to the social categories. Nothing ever wrote
# those points, so the Social page rendered empty on every fresh
# install even when the customer had years of iMessage history. This is
# the same silent-fail class the bookmarks ingest above was built to
# kill (2026-06-04 resweep), now closed for the Social section.
#
# The day-one social signal is "who you talk to most": each frequent
# 1:1 iMessage contact becomes one `category == "social"` preference
# point whose strength is derived from how much you message them. Group
# chats are skipped (a group's "participants" are not a who-I-talk-to
# signal and the handles would be noisy in the Social table).
#
# Reader contract (confirmed against the live reader, file:line):
#   - collection NAME : "preferences"
#       CM044 compiler/pages/social_pages.py:31 (scroll_all).
#   - reader FILTER   : payload `category == "social"`
#       social_pages.py:23 SOCIAL_CATEGORIES + :30 match filter.
#   - payload FIELDS the reader consumes:
#       subject          (social_pages.py:64 -- the contact label, the
#                         "account/content" row key + top-accounts table)
#       strength         (social_pages.py:65/89 -- sort + the table value)
#       source           (social_pages.py:61 -- "Platform" column +
#                         the by-platform breakdown)
#       preference_type  (social_pages.py:63 -- by-interaction breakdown)
#   The full payload mirrors CM019 ParsedPreference.to_payload parity so
#   FDA-derived social signals render identically to GDPR-imported ones.
#
# Privacy posture (conservative, matches the bookmarks blocklist intent):
# the contact handle is a phone number or email. Phone numbers are
# partially masked for the rendered `subject` so the Social page never
# shows a full personal number; the unmasked value is NOT stored in the
# payload at all. Group chats are excluded entirely. The point id is
# derived stably from the handle so a re-install upserts in place.
#
# Counts-only return (install.sh reads `sent`); no full handles cross
# the process boundary in the return value. Fails LOUD (status "error")
# if there were contacts to ingest but nothing landed -- a silent
# ok-with-zero would let the installer claim success while the Social
# page stays blank, the exact failure this function exists to kill.

# Message-count -> strength. More messages = stronger social tie. We
# bucket rather than use a raw ratio so a single heavy thread cannot
# dominate the 0..1 range. Mirrors the bookmarks folder-strength split.
_SOCIAL_STRENGTH_BANDS = (
    (200, 0.90),   # very frequent contact
    (50, 0.80),    # regular contact
    (10, 0.70),    # occasional contact
)
_SOCIAL_MIN_MESSAGES = 5      # below this, too thin to be a "social tie"
_SOCIAL_DEFAULT_STRENGTH = 0.60


def _social_strength_for(message_count: int) -> float:
    """Map an iMessage message count onto a 0..1 social-tie strength."""
    for threshold, strength in _SOCIAL_STRENGTH_BANDS:
        if message_count >= threshold:
            return strength
    return _SOCIAL_DEFAULT_STRENGTH


def _is_phone_handle(handle: str) -> bool:
    """True if the handle looks like a phone number (vs an email)."""
    stripped = handle.replace("-", "").replace(" ", "").replace("(", "").replace(")", "")
    return handle.startswith("+") or stripped.isdigit()


def _mask_social_subject(handle: str) -> str:
    """Privacy-mask a contact handle for the rendered Social table.

    Phone numbers are reduced to a country/area prefix plus the last two
    digits (``+44 … 56``) so the page conveys "a UK contact" without
    publishing a full personal number. Emails keep the local part's first
    character plus the domain (``j…@example.com``). The unmasked value
    is never stored in the payload.
    """
    handle = (handle or "").strip()
    if not handle:
        return "Unknown contact"
    if _is_phone_handle(handle):
        digits = "".join(c for c in handle if c.isdigit())
        if len(digits) < 4:
            return "Phone contact"
        prefix = ("+" + digits[:2]) if handle.startswith("+") else digits[:2]
        return f"{prefix} … {digits[-2:]}"
    # Email handle.
    local, _, domain = handle.partition("@")
    if not domain:
        return handle[:1] + "…"
    return f"{local[:1]}…@{domain}"


def _load_imessage_conversations(fda_dir: Path) -> list[dict]:
    """Read imessage_conversations.json from ``fda_dir``.

    The file is a list of dicts emitted by extract_all.py
    (``[asdict(c) for c in conversations]``) with keys: chat_id,
    display_name, participants, message_count, is_group, last_message.
    A missing file is skipped silently (the source was not enabled); a
    malformed file logs and contributes nothing.
    """
    path = fda_dir / "imessage_conversations.json"
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        logger.warning(
            "Could not parse imessage_conversations.json: %s; skipping.",
            type(exc).__name__,
        )
        return []
    if not isinstance(data, list):
        logger.warning(
            "imessage_conversations.json root is not a list; skipping."
        )
        return []
    return [c for c in data if isinstance(c, dict)]


def ingest_social(fda_dir: Path) -> dict:
    """Ingest iMessage social-tie signal into the Qdrant ``preferences``
    collection so the CM044 Social wiki page renders on a fresh install.

    Direct, single-machine path: no gateway. Group chats are skipped;
    contacts below ``_SOCIAL_MIN_MESSAGES`` are skipped as too thin.
    Defensive: missing, empty, or all-skipped input returns
    ``{"status": "no_data", ...}`` with zero counts and never raises; an
    Ollama/Qdrant hiccup degrades the count rather than crashing the
    installer.

    Each frequent 1:1 contact becomes one ``preferences`` point with
    ``category == "social"`` and the payload fields the Social page reads
    (subject, strength, source, preference_type). The displayed subject
    is privacy-masked; the unmasked handle is never stored. The point id
    is derived stably from the handle so a re-install upserts in place.

    Returns counts only (parity with the other ingesters; install.sh
    reads ``sent``):
      ``status``         : "ok" | "no_data" | "error"
      ``sent``           : points upserted into Qdrant
      ``points_created`` : alias of ``sent``
      ``skipped_group``  : group-chat threads excluded
      ``skipped_thin``   : contacts below the message floor
      ``total``          : ingestible contacts considered
    """
    conversations = _load_imessage_conversations(fda_dir)
    if not conversations:
        logger.info("No iMessage conversations to ingest for social signal.")
        return {
            "status": "no_data",
            "sent": 0,
            "points_created": 0,
            "skipped_group": 0,
            "skipped_thin": 0,
            "total": 0,
        }

    # Aggregate per handle: a contact may appear across several 1:1
    # threads (e.g. phone + email handle); sum their messages.
    handle_messages: dict[str, int] = {}
    skipped_group = 0
    for convo in conversations:
        if convo.get("is_group"):
            skipped_group += 1
            continue
        msg_count = int(convo.get("message_count") or 0)
        for participant in convo.get("participants") or []:
            handle = (participant or "").strip()
            if not handle:
                continue
            handle_messages[handle] = handle_messages.get(handle, 0) + msg_count

    skipped_thin = 0
    queue: list[dict] = []
    for handle, total_messages in handle_messages.items():
        if total_messages < _SOCIAL_MIN_MESSAGES:
            skipped_thin += 1
            continue
        subject = _mask_social_subject(handle)
        strength = _social_strength_for(total_messages)
        # Embedding document: the masked subject keeps personal numbers
        # out of the vector store too. Mirrors CM019's "Like <subject>
        # category:social" embedding text.
        doc = " ".join(("Like", subject, "category:social", "imessage"))
        # Stable point id keyed on the raw handle so re-installs upsert
        # in place; the raw handle never reaches the payload.
        point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"social|imessage|{handle}"))
        queue.append({
            "point_id": point_id,
            "doc": doc,
            "payload": {
                "preference_id": point_id,
                "subject": subject,
                "preference_type": "Like",
                "category": "social",
                "strength": strength,
                "source": "imessage",
                "size": "Medium",
                "compartment_level": DEFAULT_PRIVACY,
                "privacy_level": DEFAULT_PRIVACY,
                "created_at": datetime.now(timezone.utc).isoformat(),
                "observed_at": datetime.now(timezone.utc).isoformat(),
                "extra": {
                    "message_count": total_messages,
                    "source_type": "imessage_social",
                    "handle_kind": "phone" if _is_phone_handle(handle) else "email",
                },
            },
        })

    if not queue:
        logger.info(
            "Social: 0 ingestible (%d group threads, %d thin contacts).",
            skipped_group, skipped_thin,
        )
        return {
            "status": "no_data",
            "sent": 0,
            "points_created": 0,
            "skipped_group": skipped_group,
            "skipped_thin": skipped_thin,
            "total": 0,
        }

    vectors = _ollama_embed_batch([item["doc"] for item in queue])

    vector_size = PREFERENCES_EMBED_DIM
    for vec in vectors:
        if vec:
            vector_size = len(vec)
            break

    try:
        _qdrant_ensure_collection(PREFERENCES_QDRANT_COLLECTION, vector_size)
    except Exception as exc:
        logger.warning(
            "Social: could not ensure Qdrant collection '%s': %s",
            PREFERENCES_QDRANT_COLLECTION, type(exc).__name__,
        )
        return {
            "status": "error",
            "sent": 0,
            "points_created": 0,
            "skipped_group": skipped_group,
            "skipped_thin": skipped_thin,
            "total": len(queue),
        }

    points = [
        {"id": item["point_id"], "vector": vec, "payload": item["payload"]}
        for item, vec in zip(queue, vectors)
    ]

    sent = 0
    try:
        sent = _qdrant_upsert_points(PREFERENCES_QDRANT_COLLECTION, points)
    except Exception as exc:
        logger.warning(
            "Social vector-store write failed: %s", type(exc).__name__,
        )
        return {
            "status": "error",
            "sent": sent,
            "points_created": sent,
            "skipped_group": skipped_group,
            "skipped_thin": skipped_thin,
            "total": len(queue),
        }

    if sent == 0:
        logger.warning(
            "Social: had %d to ingest but 0 landed in Qdrant '%s'.",
            len(queue), PREFERENCES_QDRANT_COLLECTION,
        )
        return {
            "status": "error",
            "sent": 0,
            "points_created": 0,
            "skipped_group": skipped_group,
            "skipped_thin": skipped_thin,
            "total": len(queue),
        }

    logger.info(
        "Social: %d upserted to Qdrant '%s' (%d group, %d thin skipped).",
        sent, PREFERENCES_QDRANT_COLLECTION, skipped_group, skipped_thin,
    )
    return {
        "status": "ok",
        "sent": sent,
        "points_created": sent,
        "skipped_group": skipped_group,
        "skipped_thin": skipped_thin,
        "total": len(queue),
    }


# ── People search index (#600) ────────────────────────────────────
#
# Populate the Qdrant `people` collection from Oxigraph so the iOS
# People tab, the Hub People card, and semantic people-search have
# something to read. Those three readers scroll/search the collection
# named exactly "people" and key off `contact_type == "person"`; the
# wiki People page also scrolls "people" (compiler/pages/people.py).
#
# Reader contract (confirmed against live readers, file:line in the
# #600 PR description):
#   - collection NAME : "people"
#       CM044 compiler/pages/people.py:46, enrich_from_qdrant.py:89,
#       demo_mode.py:344 ("people")
#   - vector DIMENSION: 768 (nomic-embed-text); every other collection
#       in this repo embeds at 768 (see the safari path tests using
#       [0.1] * 768) and install.sh self-creates `people` at 768-dim.
#       We size the collection from the FIRST real embedding length and
#       fall back to 768 only if no live embedder is reachable.
#   - payload FIELDS the readers consume:
#       display_name   (people.py:74, enrich_from_qdrant.py:119,
#                       person_pages.py:761)
#       organization   (people.py / person_pages.py:763)
#       job_title      (people.py / person_pages.py:764)
#       given_name / family_name (person_pages.py:762)
#       contact_type   ("person"; the readers' filter, person_pages.py:768)
#       phones / emails (lists; people.py:160-161, enrich_from_qdrant.py
#                       :154-164)
#       person_id / person_uri (demo_mode.py:336-337)
#       privacy_level / source / last_contact (demo_mode.py:344-348)
#
# Counts-only return (install.sh reads `sent`); no display names cross
# the process boundary. Fails LOUD (status "error") if Oxigraph holds
# Person nodes but nothing landed in Qdrant -- a silent ok-with-zero
# would let the installer claim success while the People surfaces stay
# blank, the exact #600 silent-fail this function exists to kill.

# The readers scroll/search exactly this collection name. Overridable
# for tests only.
PEOPLE_QDRANT_COLLECTION = os.getenv("PEOPLE_QDRANT_COLLECTION", "people")
# nomic-embed-text emits 768-dim vectors; this is the fallback used
# only when no live embedding length is available to size the
# collection (e.g. the embedder is down and every embed returns []).
PEOPLE_EMBED_DIM = int(os.getenv("PEOPLE_EMBED_DIM", "768"))


def _load_people_from_oxigraph() -> list[dict]:
    """SPARQL-query Oxigraph for every pwg:Person with a display name.

    Returns one dict per person with the fields the Qdrant reader
    contract needs. Identifiers (phone/email) are folded into ``phones``
    and ``emails`` lists via a second grouped query so a person with
    several numbers still produces one row.
    """
    people_rows = _sparql_query(
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "SELECT ?uri ?displayName ?contactType ?org ?jobTitle "
        "?givenName ?familyName ?createdAt WHERE {\n"
        "  ?uri a pwg:Person ;\n"
        "       pwg:displayName ?displayName .\n"
        "  OPTIONAL { ?uri pwg:contactType ?contactType }\n"
        "  OPTIONAL { ?uri pwg:organization ?org }\n"
        "  OPTIONAL { ?uri pwg:jobTitle ?jobTitle }\n"
        "  OPTIONAL { ?uri pwg:givenName ?givenName }\n"
        "  OPTIONAL { ?uri pwg:familyName ?familyName }\n"
        # pwg:createdAt holds the REAL historical contact-creation date
        # (e.g. a 2013/2018/2022 LinkedIn/Facebook connection date written
        # by contact_syncer) -- distinct from the install-time stamp. The
        # time-ordered wiki views (year pages, person timeline, "recent")
        # key on observed_at/created_at, so without surfacing this here the
        # FDA-sourced people are ABSENT from those views, not just stamped
        # wrong. OPTIONAL: a person with no real date stays omitted from
        # time views (consistent with the iCloud-contacts decision) -- we
        # never fabricate now().
        "  OPTIONAL { ?uri pwg:createdAt ?createdAt }\n"
        "}"
    )

    # Second query: identifiers grouped per person.
    id_rows = _sparql_query(
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "SELECT ?uri ?idType ?idValue WHERE {\n"
        "  ?uri a pwg:Person ;\n"
        "       pwg:hasIdentifier ?id .\n"
        "  ?id pwg:identifierType ?idType ;\n"
        "      pwg:identifierValue ?idValue .\n"
        "}"
    )
    phones_by_uri: dict[str, list[str]] = {}
    emails_by_uri: dict[str, list[str]] = {}
    for row in id_rows:
        uri = (row.get("uri", {}) or {}).get("value", "")
        id_type = (row.get("idType", {}) or {}).get("value", "")
        id_value = (row.get("idValue", {}) or {}).get("value", "")
        if not uri or not id_value:
            continue
        if id_type == "phone":
            phones_by_uri.setdefault(uri, [])
            if id_value not in phones_by_uri[uri]:
                phones_by_uri[uri].append(id_value)
        elif id_type == "email":
            emails_by_uri.setdefault(uri, [])
            if id_value not in emails_by_uri[uri]:
                emails_by_uri[uri].append(id_value)

    # A person may produce more than one row when they carry several
    # pwg:createdAt values (the contact_syncer "update if earlier" path can
    # leave more than one historic date across re-runs). Keep the first row
    # for the scalar fields, but track the EARLIEST createdAt across all
    # rows for the URI so the time-ordered views anchor on the person's
    # true first-seen date rather than whichever row SPARQL returned first.
    people: list[dict] = []
    seen_uris: set[str] = set()
    index_by_uri: dict[str, int] = {}
    for row in people_rows:
        uri = (row.get("uri", {}) or {}).get("value", "")
        display_name = (row.get("displayName", {}) or {}).get("value", "").strip()
        if not uri or not display_name:
            continue
        created_at = (row.get("createdAt", {}) or {}).get("value", "").strip()
        if uri in seen_uris:
            # Already have this person; only fold in an earlier real date.
            if created_at:
                idx = index_by_uri[uri]
                existing = people[idx]["created_at"]
                if not existing or created_at < existing:
                    people[idx]["created_at"] = created_at
            continue
        seen_uris.add(uri)
        index_by_uri[uri] = len(people)
        people.append({
            "uri": uri,
            "display_name": display_name,
            "contact_type": (row.get("contactType", {}) or {}).get("value", "")
            or "person",
            "organization": (row.get("org", {}) or {}).get("value", ""),
            "job_title": (row.get("jobTitle", {}) or {}).get("value", ""),
            "given_name": (row.get("givenName", {}) or {}).get("value", ""),
            "family_name": (row.get("familyName", {}) or {}).get("value", ""),
            "phones": phones_by_uri.get(uri, []),
            "emails": emails_by_uri.get(uri, []),
            # Real historical first-seen date (may be ""). Surfaced to the
            # Qdrant payload as observed_at/created_at so time-ordered views
            # can place this person. Empty -> omitted from those views (no
            # now() fabrication).
            "created_at": created_at,
        })
    return people


def _person_embed_doc(person: dict) -> str:
    """Build the descriptive text embedded for semantic people-search.

    Name carries the human-readable signal the matcher scans; org +
    job title anchor it. Mirrors the browsing path's title+domain+url
    doc construction.
    """
    parts = [
        person.get("display_name", ""),
        person.get("job_title", ""),
        person.get("organization", ""),
    ]
    return " ".join(p for p in parts if p).strip()


def ingest_people_to_qdrant() -> dict:
    """Populate the Qdrant ``people`` collection from Oxigraph (#600).

    On a fresh single-Mac install the per-source hydrate steps write
    pwg:Person nodes into Oxigraph (the wiki People page reads those
    directly), but nothing ever embeds them into Qdrant -- so the iOS
    People tab, the Hub People card, and semantic people-search (which
    all read the Qdrant ``people`` collection filtered on
    contact_type == "person") render blank.

    This function: (1) reads every pwg:Person with a display name from
    Oxigraph, (2) self-creates the ``people`` collection if absent at
    the embedder's vector size, (3) embeds each person's descriptive
    text via local Ollama, (4) upserts one point per person (id derived
    stably from the person URI so a re-install is idempotent) with a
    payload matching the reader contract, (5) returns a counts-only
    dict, (6) fails LOUD (status "error") if Oxigraph held Person nodes
    but nothing landed in Qdrant.

    Returns counts only (parity with the other ingesters; install.sh
    reads ``sent``):
      ``status``         : "ok" | "no_data" | "error"
      ``sent``           : points upserted into Qdrant
      ``points_created`` : alias of ``sent``
      ``total``          : Person nodes considered (with a display name)
    """
    try:
        people = _load_people_from_oxigraph()
    except Exception as exc:
        logger.warning(
            "People: Oxigraph query failed: %s", type(exc).__name__,
        )
        return {"status": "error", "sent": 0, "points_created": 0, "total": 0}

    if not people:
        logger.info("No people in Oxigraph to index.")
        return {"status": "no_data", "sent": 0, "points_created": 0, "total": 0}

    docs = [_person_embed_doc(p) for p in people]
    vectors = _ollama_embed_batch(docs)

    # Size the collection from the first real embedding; fall back to
    # the nomic-embed-text default only if nothing embedded.
    vector_size = PEOPLE_EMBED_DIM
    for vec in vectors:
        if vec:
            vector_size = len(vec)
            break

    try:
        _qdrant_ensure_collection(PEOPLE_QDRANT_COLLECTION, vector_size)
    except Exception as exc:
        logger.warning(
            "People: could not ensure Qdrant collection '%s': %s",
            PEOPLE_QDRANT_COLLECTION, type(exc).__name__,
        )
        return {
            "status": "error",
            "sent": 0,
            "points_created": 0,
            "total": len(people),
        }

    points: list[dict] = []
    for person, vec in zip(people, vectors):
        uri = person["uri"]
        # Stable point id: same URI re-runs upsert in place rather than
        # duplicating rows on re-install.
        point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, uri))
        payload = {
            "person_uri": uri,
            "person_id": point_id,
            "display_name": person["display_name"],
            "contact_type": person["contact_type"] or "person",
            "organization": person["organization"],
            "job_title": person["job_title"],
            "given_name": person["given_name"],
            "family_name": person["family_name"],
            "phones": person["phones"],
            "emails": person["emails"],
            "privacy_level": DEFAULT_PRIVACY,
            "source": "fda_people_index",
            "last_contact": "",
        }
        # Surface the REAL pwg:createdAt date so the time-ordered wiki
        # views (year pages, person timeline, "recent people") can place
        # this person. The CM044 readers key on observed_at first, then
        # fall back to created_at, so write BOTH from the same real date.
        # Omit entirely when there is no real date: a no-real-date FDA
        # person stays absent from time views rather than being stamped
        # with a fabricated now() (consistent with the iCloud-contacts
        # decision).
        created_at = (person.get("created_at") or "").strip()
        if created_at:
            payload["observed_at"] = created_at
            payload["created_at"] = created_at
        points.append({
            "id": point_id,
            "vector": vec,
            "payload": payload,
        })

    sent = 0
    try:
        sent = _qdrant_upsert_points(PEOPLE_QDRANT_COLLECTION, points)
    except Exception as exc:
        logger.warning(
            "People: Qdrant upsert failed: %s", type(exc).__name__,
        )
        return {
            "status": "error",
            "sent": sent,
            "points_created": sent,
            "total": len(people),
        }

    if sent == 0:
        # We had Person nodes to index but none landed (embed failure
        # for every row, or every chunk failed). Report error, not
        # "ok" -- a silent ok-with-zero is the #600 bug.
        logger.warning(
            "People: %d Person nodes in Oxigraph but 0 landed in Qdrant '%s'.",
            len(people), PEOPLE_QDRANT_COLLECTION,
        )
        return {
            "status": "error",
            "sent": 0,
            "points_created": 0,
            "total": len(people),
        }

    logger.info(
        "People: %d of %d Person nodes indexed into Qdrant '%s'.",
        sent, len(people), PEOPLE_QDRANT_COLLECTION,
    )
    return {
        "status": "ok",
        "sent": sent,
        "points_created": sent,
        "total": len(people),
    }


# ── Master runner ─────────────────────────────────────────────────

def ingest_all(fda_dir: Optional[Path] = None) -> dict:
    """Run all FDA -> PWG ingestion steps.

    Reads the JSON output from extract_all.py and feeds it into
    Qdrant and Oxigraph.
    """
    fda_dir = fda_dir or (Path.home() / ".ostler" / "imports" / "fda")

    if not fda_dir.exists():
        logger.error("FDA output directory not found: %s", fda_dir)
        return {"status": "error", "reason": f"directory not found: {fda_dir}"}

    logging.basicConfig(level=logging.INFO, format="%(message)s")

    results = {}

    # Ingest in order of value for the people graph
    logger.info("Ingesting FDA data into PWG knowledge graph...")
    logger.info("")

    for name, func in [
        ("imessage", ingest_imessage),
        ("whatsapp", ingest_whatsapp),
        ("calendar", ingest_calendar),
        ("photos", ingest_photos_people),
        ("apple_mail", ingest_mail_contacts),
        ("browser_history", ingest_browser_history),
        ("bookmarks", ingest_bookmarks),
        ("social", ingest_social),
    ]:
        try:
            results[name] = func(fda_dir)
        except Exception as e:
            logger.warning("[warn] %s ingestion failed: %s", name, e)
            results[name] = {"status": "error", "error": str(e)}

    # People search index (#600): runs LAST so every per-source step
    # above has finished writing pwg:Person nodes into Oxigraph before
    # we sweep them into the Qdrant `people` collection. Takes no
    # fda_dir -- it reads Oxigraph, not the FDA JSON.
    try:
        results["people_index"] = ingest_people_to_qdrant()
    except Exception as e:
        logger.warning("[warn] people_index ingestion failed: %s", e)
        results["people_index"] = {"status": "error", "error": str(e)}

    logger.info("")
    logger.info("FDA -> PWG ingestion complete.")
    return results


def main():
    """CLI entry point."""
    import argparse
    parser = argparse.ArgumentParser(description="Ingest FDA data into PWG")
    parser.add_argument("--fda-dir", type=str, default=None)
    args = parser.parse_args()

    fda_dir = Path(args.fda_dir) if args.fda_dir else None
    results = ingest_all(fda_dir)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
