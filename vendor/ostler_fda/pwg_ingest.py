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
                id_uri = f"https://pwg.dev/ontology#id_{person_id}_whatsapp"
                triples.extend([
                    f"<{uri}> pwg:hasIdentifier <{id_uri}>",
                    f"<{id_uri}> a pwg:PersonIdentifier",
                    f'<{id_uri}> pwg:identifierType "phone"',
                    f'<{id_uri}> pwg:identifierValue "{_escape(participant)}"',
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
# Batch sizes: 64 keeps Ollama responsive on a 16GB Mac across
# thousands of visits; 200 is Qdrant's tested upsert chunk.
_BROWSING_EMBED_BATCH_SIZE = int(os.getenv("EMBED_BATCH_SIZE", "64"))
_BROWSING_QDRANT_BATCH_SIZE = int(os.getenv("QDRANT_UPSERT_BATCH_SIZE", "200"))
# nomic-embed-text emits 768-dim vectors. The collection MUST be created
# at this size before the first upsert: a PUT of points into a missing
# collection 404s and silently lands zero rows.
_BROWSING_VECTOR_DIM = int(os.getenv("BROWSING_VECTOR_DIM", "768"))

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


def _qdrant_ensure_collection(collection: str, dim: int) -> None:
    """Create the Qdrant ``collection`` at ``dim`` (Cosine) if absent.

    Single-Mac product: there is no gateway to lazily create the
    collection, and nothing else on a fresh install creates
    safari_history. Qdrant rejects a PUT of points into a missing
    collection (404), which would silently land zero rows. So the
    direct writer ensures its own collection first.

    Idempotent and non-destructive: an existing collection is left
    untouched (a dim mismatch is logged, never auto-recreated, so a
    customer's data is never dropped). Failures are swallowed: a
    subsequent upsert failure already degrades the count rather than
    crashing the installer.
    """
    transport = httpx.HTTPTransport(proxy=None)
    base = f"{QDRANT_URL}/collections/{collection}"
    with httpx.Client(timeout=30.0, transport=transport) as client:
        try:
            resp = client.get(base)
            if resp.status_code == 200:
                vectors = (
                    resp.json().get("result", {})
                    .get("config", {}).get("params", {})
                    .get("vectors", {})
                )
                size = vectors.get("size") if isinstance(vectors, dict) else None
                if size is not None and size != dim:
                    logger.warning(
                        "Qdrant collection %s exists at dim=%s, expected %d; "
                        "leaving as-is (upserts may be rejected).",
                        collection, size, dim,
                    )
                return
        except Exception as exc:
            logger.warning(
                "Qdrant collection probe for %s failed: %s",
                collection, type(exc).__name__,
            )
        try:
            resp = client.put(
                base, json={"vectors": {"size": dim, "distance": "Cosine"}},
            )
            resp.raise_for_status()
            logger.info("Created Qdrant collection %s (dim=%d).", collection, dim)
        except Exception as exc:
            logger.warning(
                "Qdrant collection create for %s failed: %s",
                collection, type(exc).__name__,
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
        # Ensure the collection exists at 768-dim before the first upsert.
        # On a fresh single-Mac install nothing else creates it, and a PUT
        # of points into a missing collection 404s into zero rows.
        _qdrant_ensure_collection(BROWSING_QDRANT_COLLECTION, _BROWSING_VECTOR_DIM)
        vectors = _ollama_embed_batch([item["doc"] for item in queue])
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


# ── People -> Qdrant populate (Oxigraph sweep, direct, v1.0) ───────
#
# Single-Mac product: nothing creates or populates the Qdrant `people`
# collection on a fresh install. contact_syncer is not bundled or run,
# graph_db_start creates no collections, and the iMessage path writes
# Oxigraph RDF only. The wiki People pages are fine (the CM044 compiler
# reads people from Oxigraph via SPARQL), but the iOS People tab + Hub
# People-card + semantic search read the Qdrant `people` collection
# (ical-server.py people_search / scroll, BOTH filtered on
# payload.contact_type == "person") and so see zero rows.
#
# This sweeps EVERY pwg:Person from Oxigraph -- all sources, matching
# the wiki's completeness rather than just iMessage -- embeds the
# display name with the local Ollama instance, and upserts one point
# per person into `people`, self-creating the collection at 768-dim
# (same no-gateway / no-precreate gap the browsing writer closes).

PEOPLE_QDRANT_COLLECTION = QDRANT_COLLECTION  # "people"; override via QDRANT_COLLECTION
# nomic-embed-text emits 768-dim vectors (same model + dim as browsing).
_PEOPLE_VECTOR_DIM = int(os.getenv("PEOPLE_VECTOR_DIM", "768"))


def ingest_people_to_qdrant() -> dict:
    """Populate the Qdrant ``people`` collection from Oxigraph.

    Reads every ``pwg:Person`` + ``pwg:displayName``, embeds the name,
    and upserts a point per person carrying the payload contract the iOS
    People tab + Hub People-card read: ``display_name``, ``person_uri``,
    and ``contact_type == "person"`` (the filter BOTH the search and
    scroll endpoints require -- a point without it is invisible to the
    tab). Self-creates the collection at 768-dim. Counts only in the
    return dict; never raises -- an Oxigraph/Ollama/Qdrant hiccup
    degrades the count rather than aborting the installer.
    """
    try:
        rows = _sparql_query(
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            "SELECT ?person ?name WHERE {\n"
            "  ?person a pwg:Person ; pwg:displayName ?name .\n"
            "}"
        )
    except Exception as exc:
        logger.warning(
            "People sweep: Oxigraph query failed: %s", type(exc).__name__,
        )
        return {"status": "error", "sent": 0, "points_created": 0, "total": 0}

    # Dedup by person URI; keep the first display name seen.
    persons: dict[str, str] = {}
    for r in rows:
        uri = (r.get("person", {}).get("value") or "").strip()
        name = (r.get("name", {}).get("value") or "").strip()
        if uri and name and uri not in persons:
            persons[uri] = name

    if not persons:
        logger.info("People sweep: no pwg:Person in Oxigraph to populate.")
        return {"status": "no_data", "sent": 0, "points_created": 0, "total": 0}

    items = list(persons.items())  # [(uri, name), ...] -- stable order
    sent = 0
    try:
        _qdrant_ensure_collection(PEOPLE_QDRANT_COLLECTION, _PEOPLE_VECTOR_DIM)
        vectors = _ollama_embed_batch([name for _, name in items])
        points = [
            {
                # Stable id: same person URI re-upserts in place across
                # re-installs rather than duplicating the row.
                "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"person|{uri}")),
                "vector": vec,
                "payload": {
                    "display_name": name,
                    "person_uri": uri,
                    # Both ical-server read paths filter on this exact
                    # value; without it the iOS People tab sees nothing.
                    "contact_type": "person",
                },
            }
            for (uri, name), vec in zip(items, vectors)
        ]
        sent = _qdrant_upsert_points(PEOPLE_QDRANT_COLLECTION, points)
    except Exception as exc:
        logger.warning(
            "People sweep: vector-store write failed: %s", type(exc).__name__,
        )
        return {
            "status": "error",
            "sent": sent,
            "points_created": sent,
            "total": len(items),
        }

    if sent == 0:
        # Persons existed but none landed (every chunk failed). Report
        # error, not ok-with-zero, so the installer does not claim
        # success while the People tab stays empty.
        logger.warning(
            "People sweep: embedded %d persons but 0 landed in Qdrant '%s'.",
            len(items), PEOPLE_QDRANT_COLLECTION,
        )
        return {
            "status": "error",
            "sent": 0,
            "points_created": 0,
            "total": len(items),
        }

    logger.info(
        "People sweep: %d persons upserted to Qdrant '%s'.",
        sent, PEOPLE_QDRANT_COLLECTION,
    )
    return {
        "status": "ok",
        "sent": sent,
        "points_created": sent,
        "total": len(items),
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
    ]:
        try:
            results[name] = func(fda_dir)
        except Exception as e:
            logger.warning("[warn] %s ingestion failed: %s", name, e)
            results[name] = {"status": "error", "error": str(e)}

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
