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
import time
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

            person_id = _person_id_from_identifier(participant)
            uri = _person_uri(person_id)
            exists = _person_exists(uri)

            if not exists:
                # JIDs from WhatsApp are always phone-rooted
                # (e.g. "<phone_e164>@s.whatsapp.net"). Stripping the
                # suffix gives the E.164-shaped local-part the wiki
                # uses as the displayName until enriched by other
                # sources (contact_syncer, CM046 email signatures, etc.).
                display = participant.split("@", 1)[0] if "@" in participant else participant
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

    for event in events:
        attendees = event.get("attendees", [])
        start_date = event.get("start_date", "")
        title = event.get("title", "")

        for attendee in attendees:
            if not attendee:
                continue

            person_id = _person_id_from_identifier(attendee)
            uri = _person_uri(person_id)

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

        events_processed += 1

    logger.info(
        "Calendar: %d events processed, %d unique attendees",
        events_processed, len(people_seen),
    )
    return {
        "status": "ok",
        "events_processed": events_processed,
        "unique_attendees": len(people_seen),
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


# ── Browser history ingestion (CX-86 Gap A) ───────────────────────
#
# Streams safari_history.json + chrome_history.json (written by
# extract_all.py) through the CM019 gateway's POST /api/safari/ingest
# endpoint. The gateway writes to the `safari_history` Qdrant
# collection (renamed from `safari_browsing` in Gap B), where the
# CM044 wiki Browsing page reads from.
#
# Auth: Bearer token from ~/.ostler/secrets/service_token. Blocklist
# (Q3 sign-off): banking / medical / etc. URLs are rejected by the
# gateway with HTTP 422 and counted as "skipped_sensitive".
# needs_reprocessing=true (Q2 sign-off): backfilled rows land in
# Qdrant with empty topics/category; gateway background tick enriches.
#
# Privacy AC mirror B2 + CX-85: stdout payload contains counts only.
# No URLs, titles, or domain names cross the install.sh boundary.

# #48g historical backfill (CX-86): the customer-install gateway binds
# 127.0.0.1:8000 (locked at CX-59 / DMG #34, 2026-05-24). The previous
# default of :8765 was the dev-only port the gateway used pre-launch;
# leaving it as a fallback meant every install where OSTLER_GATEWAY_URL
# was not explicitly set would silently fail to ingest browsing history
# (connection refused -> errored++, sent=0). install.sh's hydrate_browsing
# step does NOT set OSTLER_GATEWAY_URL today, so the :8765 default was
# the runtime path on every customer Mac.
_GATEWAY_ENDPOINT_DEFAULT = "http://localhost:8000/api/safari/ingest"
_SERVICE_TOKEN_PATH = Path.home() / ".ostler" / "secrets" / "service_token"

# Defensive runtime bounds (browser-ingest hang fix). The gateway embeds
# each entry via Ollama on ingest; on a fresh install Ollama may be cold
# or the gateway not yet ready, so a POST can block for the full
# per-request timeout. With thousands of history rows that previously
# meant an effectively-infinite loop -- the "importing browsing history
# hangs" symptom. install.sh wraps this call in `timeout 90` ONLY when
# GNU timeout / gtimeout is on PATH, which a stock macOS does NOT have,
# so the shell cap cannot be relied on. We therefore bound the work here
# too, with no external dependency:
#   * overall wall-clock budget (< install.sh's 90s cap so we return a
#     clean counts JSON before the shell would SIGKILL us)
#   * a short per-request timeout (a single short-doc embed is fast once
#     the model is warm; if it is not, we would rather move on)
#   * a circuit breaker: after N consecutive transport failures the
#     gateway is presumed down/hung and we stop
# Whatever is not sent inline is left for the gateway's background
# enrichment tick / Doctor rescan to backfill. This function never hangs
# and never raises; it always returns the counts-only dict.
_BROWSER_INGEST_BUDGET_S = float(
    os.environ.get("OSTLER_BROWSER_INGEST_BUDGET_S", "75")
)
_BROWSER_INGEST_REQ_TIMEOUT_S = float(
    os.environ.get("OSTLER_BROWSER_INGEST_REQ_TIMEOUT_S", "8")
)
_BROWSER_INGEST_BREAKER_MAX = 5


def _read_service_token() -> Optional[str]:
    """Read the Bearer token install.sh's auth_tokens phase wrote."""
    try:
        return _SERVICE_TOKEN_PATH.read_text(encoding="utf-8").strip() or None
    except (OSError, FileNotFoundError):
        return None


def ingest_browser_history(fda_dir: Path, gateway_url: Optional[str] = None) -> dict:
    """Stream browser history JSON to the gateway.

    Reads safari_history.json + chrome_history.json from ``fda_dir``,
    POSTs each entry to ``POST /api/safari/ingest`` with Bearer auth
    and ``needs_reprocessing: true``. Counts ok / skipped (HTTP 422
    blocklist) / errored. Returns a counts-only dict.
    """
    endpoint = gateway_url or os.environ.get(
        "OSTLER_GATEWAY_URL", _GATEWAY_ENDPOINT_DEFAULT,
    )

    payload_entries: list[dict] = []
    safari_count = 0
    chrome_count = 0
    for filename, label in [
        ("safari_history.json", "safari_history"),
        ("chrome_history.json", "chrome_history"),
    ]:
        path = fda_dir / filename
        if not path.exists():
            continue
        try:
            entries = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            logger.warning(
                "Could not read %s: %s; skipping that source.",
                filename, type(exc).__name__,
            )
            continue
        if not isinstance(entries, list):
            logger.warning("%s root is not a list; skipping.", filename)
            continue
        payload_entries.extend(entries)
        if label == "safari_history":
            safari_count = len(entries)
        else:
            chrome_count = len(entries)

    if not payload_entries:
        logger.info("No browser history to ingest.")
        return {
            "status": "no_data",
            "total": 0,
            "sent": 0,
            "skipped_sensitive": 0,
            "errored": 0,
            "safari_entries": 0,
            "chrome_entries": 0,
        }

    token = _read_service_token()
    if not token:
        logger.warning(
            "No service token at %s; the gateway requires Bearer auth.",
            _SERVICE_TOKEN_PATH,
        )
        return {
            "status": "no_token",
            "total": len(payload_entries),
            "sent": 0,
            "skipped_sensitive": 0,
            "errored": 0,
            "safari_entries": safari_count,
            "chrome_entries": chrome_count,
        }

    sent = 0
    skipped_sensitive = 0
    errored = 0
    consecutive_failures = 0
    bounded_out = False  # True if budget or breaker cut the batch short

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    deadline = time.monotonic() + _BROWSER_INGEST_BUDGET_S
    # proxy=None: the gateway is on loopback; never route localhost POSTs
    # through a customer's HTTP proxy (matches _sparql_* / _embed clients
    # above). Also makes connection-refused surface as a fast ConnectError
    # so the circuit breaker can trip instead of the proxy masking it.
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(
        timeout=_BROWSER_INGEST_REQ_TIMEOUT_S, transport=transport,
    ) as client:
        for entry in payload_entries:
            # Wall-clock budget: stop cleanly and let the gateway's
            # background tick backfill whatever is left. Never hang.
            if time.monotonic() >= deadline:
                bounded_out = True
                logger.info(
                    "Browser ingest budget (%.0fs) reached; deferring the "
                    "remaining entries to the gateway background tick.",
                    _BROWSER_INGEST_BUDGET_S,
                )
                break

            payload = {
                "url": entry.get("url"),
                "title": entry.get("title"),
                "timestamp": entry.get("timestamp"),
                "device": entry.get("source", "unknown"),
                "needs_reprocessing": True,
            }
            if not payload["url"]:
                errored += 1
                continue
            try:
                resp = client.post(endpoint, json=payload, headers=headers)
            except (httpx.RequestError, httpx.HTTPError) as exc:
                consecutive_failures += 1
                errored += 1
                if consecutive_failures <= 5:
                    logger.warning(
                        "gateway POST failed (%s); continuing batch.",
                        type(exc).__name__,
                    )
                # Circuit breaker: the gateway is presumed down or hung.
                # Stop now rather than grind every remaining row through
                # the full per-request timeout.
                if consecutive_failures >= _BROWSER_INGEST_BREAKER_MAX:
                    bounded_out = True
                    logger.warning(
                        "gateway unreachable after %d consecutive failures; "
                        "deferring the remaining entries to the background "
                        "tick.",
                        consecutive_failures,
                    )
                    break
                continue

            if resp.status_code in (200, 201, 202):
                consecutive_failures = 0
                sent += 1
            elif resp.status_code == 422:
                # 422 = the gateway is alive and applied its sensitive-URL
                # blocklist, so this counts as the backend working.
                consecutive_failures = 0
                skipped_sensitive += 1
            else:
                # Any other status (404/405/501/502/503) means the ingest
                # route is not actually being served -- e.g. the daemon
                # squats :8000 with a proxy stub but no live gateway behind
                # it, returning 405/503. These come back fast, so without
                # counting them the breaker never trips and we grind every
                # row against the wall-clock budget. Treat repeated non-2xx
                # as backend-unavailable and bail, same as transport errors.
                consecutive_failures += 1
                errored += 1
                if consecutive_failures <= 5:
                    logger.warning(
                        "gateway returned HTTP %d for ingest; continuing.",
                        resp.status_code,
                    )
                if consecutive_failures >= _BROWSER_INGEST_BREAKER_MAX:
                    bounded_out = True
                    logger.warning(
                        "browsing-ingest backend not available (repeated "
                        "HTTP %d); deferring the remaining entries to the "
                        "background backfill.",
                        resp.status_code,
                    )
                    break

    logger.info(
        "Browser history ingest: %d sent, %d skipped (sensitive), "
        "%d errored across %d Safari + %d Chrome entries.%s",
        sent, skipped_sensitive, errored,
        safari_count, chrome_count,
        " (bounded; remainder deferred)" if bounded_out else "",
    )
    return {
        "status": "partial" if bounded_out else "ok",
        "total": len(payload_entries),
        "sent": sent,
        "skipped_sensitive": skipped_sensitive,
        "errored": errored,
        "safari_entries": safari_count,
        "chrome_entries": chrome_count,
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
