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
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import httpx

logger = logging.getLogger(__name__)

# ── Config from environment (same as GDPR import pipeline) ────────

QDRANT_URL = os.getenv("QDRANT_URL", "http://localhost:6333")
OXIGRAPH_URL = os.getenv("OXIGRAPH_URL", "http://localhost:7878")
# OLLAMA_HOST is the canonical env var (matches the ollama CLI default).
# EMBED_OLLAMA_URL is kept as a fallback for legacy callers.
OLLAMA_URL = (
    os.getenv("OLLAMA_HOST")
    or os.getenv("EMBED_OLLAMA_URL", "http://localhost:11434")
)
EMBED_MODEL = os.getenv("EMBED_MODEL", "nomic-embed-text")
QDRANT_COLLECTION = os.getenv("QDRANT_COLLECTION", "people")
DEFAULT_PRIVACY = os.getenv("DEFAULT_PRIVACY_LEVEL", "L2")

# Batch sizes for vector pipeline. 64 keeps Ollama happy on a 16GB
# machine; 200 is the Qdrant default tested batch size.
EMBED_BATCH_SIZE = int(os.getenv("EMBED_BATCH_SIZE", "64"))
QDRANT_UPSERT_BATCH_SIZE = int(os.getenv("QDRANT_UPSERT_BATCH_SIZE", "200"))


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


def _warn(msg: str) -> None:
    """Log a non-fatal warning. Goes to stderr with a [warn] prefix so the
    install.sh log surfaces it but the install does not abort.
    """
    print(f"[warn] {msg}", file=sys.stderr)
    logger.warning(msg)


def _ollama_embed_batch(texts: list[str]) -> list[list[float]]:
    """Batch-embed texts via Ollama ``/api/embed``.

    Ollama supports prompt batching: pass a list under ``input`` and
    receive a list of vectors back under ``embeddings``. Falls back to
    a per-text loop if the server rejects the batched payload (older
    Ollama builds).
    """
    if not texts:
        return []
    transport = httpx.HTTPTransport(proxy=None)
    vectors: list[list[float]] = []
    with httpx.Client(timeout=120.0, transport=transport) as client:
        for start in range(0, len(texts), EMBED_BATCH_SIZE):
            chunk = texts[start : start + EMBED_BATCH_SIZE]
            try:
                resp = client.post(
                    f"{OLLAMA_URL}/api/embed",
                    json={"model": EMBED_MODEL, "input": chunk},
                )
                resp.raise_for_status()
                data = resp.json()
                embs = data.get("embeddings")
                if embs is None:
                    # Older Ollama returned a single vector under "embedding".
                    single = data.get("embedding")
                    embs = [single] if single is not None else []
                if len(embs) != len(chunk):
                    # Length mismatch: degrade to one-at-a-time so we still
                    # produce vectors for the rest of the batch.
                    _warn(
                        f"Ollama returned {len(embs)} vectors for "
                        f"{len(chunk)} inputs; falling back to per-text"
                    )
                    embs = []
                    for t in chunk:
                        try:
                            r2 = client.post(
                                f"{OLLAMA_URL}/api/embed",
                                json={"model": EMBED_MODEL, "input": t},
                            )
                            r2.raise_for_status()
                            d2 = r2.json()
                            v = (
                                (d2.get("embeddings") or [None])[0]
                                if d2.get("embeddings")
                                else d2.get("embedding")
                            )
                            embs.append(v or [])
                        except Exception as inner:
                            _warn(f"Ollama embed failed for one item: {inner}")
                            embs.append([])
                vectors.extend(embs)
            except Exception as exc:
                _warn(
                    f"Ollama embed batch failed (chunk start={start}, "
                    f"size={len(chunk)}): {exc}"
                )
                # Pad with empty vectors so caller can keep index alignment.
                vectors.extend([[] for _ in chunk])
    return vectors


def _qdrant_upsert_people(persons: list[dict]) -> int:
    """Batch-upsert person points into the Qdrant people collection.

    Each entry in ``persons`` should be a dict with keys:
    ``id`` (UUID string), ``vector`` (list[float], 768 floats), and
    ``payload`` (dict). Points are flushed in chunks of
    ``QDRANT_UPSERT_BATCH_SIZE`` (default 200) to keep individual
    requests under Qdrant's body limit.

    Returns the number of points the server acknowledged. Errors are
    logged via :func:`_warn` and the function continues to the next
    chunk: a half-failed batch is still partial progress.
    """
    if not persons:
        return 0
    # Skip entries whose embedding produced an empty vector (Ollama
    # failure upstream). Qdrant rejects zero-length vectors with a
    # cryptic 400; better to drop and warn.
    valid = [p for p in persons if p.get("vector")]
    dropped = len(persons) - len(valid)
    if dropped:
        _warn(
            f"Skipping {dropped} person points with empty vectors "
            "(Ollama embed failure upstream)"
        )
    if not valid:
        return 0

    upserted = 0
    transport = httpx.HTTPTransport(proxy=None)
    url = f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points/upsert"
    with httpx.Client(timeout=60.0, transport=transport) as client:
        for start in range(0, len(valid), QDRANT_UPSERT_BATCH_SIZE):
            chunk = valid[start : start + QDRANT_UPSERT_BATCH_SIZE]
            body = {
                "points": [
                    {
                        "id": p["id"],
                        "vector": p["vector"],
                        "payload": p["payload"],
                    }
                    for p in chunk
                ]
            }
            try:
                resp = client.put(url, json=body, params={"wait": "true"})
                resp.raise_for_status()
                upserted += len(chunk)
            except Exception as exc:
                _warn(
                    f"Qdrant upsert failed (chunk start={start}, "
                    f"size={len(chunk)}): {exc}"
                )
    return upserted


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

    # Vector queue: each entry is the data needed to embed + upsert one
    # person into Qdrant after the Oxigraph writes succeed. Keyed by
    # person_uri so we de-dupe participants that appear in multiple
    # conversations.
    qdrant_queue: dict[str, dict] = {}

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

            # Queue this person for Qdrant. Keep the freshest last_msg
            # seen across conversations so the vector payload matches
            # the freshness signal we wrote to Oxigraph.
            slot = qdrant_queue.get(uri)
            existing_last = slot.get("last_contact_date") if slot else None
            best_last = last_msg if last_msg else existing_last
            if slot:
                slot["last_contact_date"] = best_last or slot.get("last_contact_date")
            else:
                qdrant_queue[uri] = {
                    "person_id": person_id,
                    "person_uri": uri,
                    "display_name": participant,
                    "slug": person_id,
                    "last_contact_date": best_last,
                }

    # Vector-search side of the write. Non-fatal: any failure here is
    # logged via _warn and swallowed so the install does not abort and
    # the RDF path remains the source of truth for the wiki.
    qdrant_people_upserted = 0
    if qdrant_queue:
        try:
            queue_list = list(qdrant_queue.values())
            texts = [item["display_name"] for item in queue_list]
            vectors = _ollama_embed_batch(texts)
            now_iso = datetime.now(timezone.utc).isoformat()
            points: list[dict] = []
            for item, vec in zip(queue_list, vectors):
                point_id = str(
                    uuid.uuid5(uuid.NAMESPACE_URL, item["person_uri"])
                )
                payload = {
                    "slug": item["slug"],
                    "displayName": item["display_name"],
                    "display_name": item["display_name"],
                    "person_id": item["person_id"],
                    "person_uri": item["person_uri"],
                    "oxigraph_uri": item["person_uri"],
                    "source": "imessage",
                    "contact_type": "person",
                    "privacy_level": DEFAULT_PRIVACY,
                    "last_contact_date": item.get("last_contact_date"),
                    "created_at": now_iso,
                    "updated_at": now_iso,
                }
                points.append({"id": point_id, "vector": vec, "payload": payload})
            qdrant_people_upserted = _qdrant_upsert_people(points)
        except Exception as exc:
            _warn(f"iMessage vector-search write failed: {exc}")

    logger.info(
        "iMessage: %d people created, %d enriched, %d upserted to Qdrant",
        people_created, people_enriched, qdrant_people_upserted,
    )
    return {
        "status": "ok",
        "people_created": people_created,
        "people_enriched": people_enriched,
        "qdrant_people_upserted": qdrant_people_upserted,
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
        ("calendar", ingest_calendar),
        ("photos", ingest_photos_people),
        ("apple_mail", ingest_mail_contacts),
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
