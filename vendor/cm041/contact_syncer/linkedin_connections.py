"""LinkedIn Connections Importer — reads Connections.csv from a LinkedIn
GDPR export and imports contacts into the PWG people graph.

For each connection:
1. Parse CSV row → PersonIdentity
2. Resolve via IdentityResolver (fuzzy name matching + LinkedIn URL)
3. Match → enrich existing person with LinkedIn URL + company + position
4. No match → create new person node in PWG (not in address book)
5. Upsert Qdrant point with embedding

Optional --enrich-contacts mode: for matched connections, also writes
LinkedIn URL (and optionally title/company) back to the user's iCloud
Address Book via CardDAV. Does NOT create new address book contacts
for unmatched connections.

Usage:
    python -m contact_syncer.linkedin_connections \
        --csv /path/to/Connections.csv \
        [--enrich-contacts] [--enrich-fields url,title,org] \
        [--dry-run] [--limit N]

Idempotent: re-running upserts by deterministic ID (from LinkedIn URL).
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import httpx

# Add parent directory so identity_resolver is importable
_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from contact_syncer import config
from identity_resolver.models import PersonIdentity
from identity_resolver.normalise import normalise_email
from identity_resolver.resolver import IdentityResolver

try:
    from qdrant_client import QdrantClient
    from qdrant_client.models import PointStruct
    HAS_QDRANT = True
except ImportError:
    HAS_QDRANT = False


# ── CSV parsing ──────────────────────────────────────────────────────


def parse_connections_csv(csv_path: str) -> List[Dict[str, str]]:
    """Parse LinkedIn Connections.csv, skipping the notes header.

    LinkedIn exports start with 2-3 lines of notes before the actual
    CSV header. We detect the header by looking for 'First Name'.
    """
    rows = []
    header_found = False
    fieldnames = None

    with open(csv_path, "r", encoding="utf-8") as fh:
        for line in fh:
            if not header_found:
                if "First Name" in line:
                    header_found = True
                    # Re-read from this line as CSV
                    fieldnames = [f.strip() for f in line.strip().split(",")]
                continue
            if not line.strip():
                continue
            # Parse the data line using the detected fieldnames
            reader = csv.DictReader([line], fieldnames=fieldnames)
            for row in reader:
                # Skip empty rows
                if not row.get("First Name") and not row.get("Last Name"):
                    continue
                rows.append(row)

    return rows


def row_to_identity(row: Dict[str, str]) -> Tuple[PersonIdentity, Dict[str, str]]:
    """Convert a CSV row to a PersonIdentity + extra metadata dict."""
    first = (row.get("First Name") or "").strip()
    last = (row.get("Last Name") or "").strip()
    display = f"{first} {last}".strip()
    url = (row.get("URL") or "").strip()
    email = (row.get("Email Address") or "").strip()
    company = (row.get("Company") or "").strip()
    position = (row.get("Position") or "").strip()
    connected_on = (row.get("Connected On") or "").strip()

    identity = PersonIdentity(
        display_name=display,
        given_name=first or None,
        family_name=last or None,
        organization=company or None,
        emails=[email] if email else [],
        linkedin_url=url or None,
    )

    extra = {
        "company": company,
        "position": position,
        "connected_on": connected_on,
        "linkedin_url": url,
        "email": email,
    }

    return identity, extra


# ── Oxigraph writes ──────────────────────────────────────────────────


def _sparql_update(oxigraph_url: str, sparql: str) -> None:
    """Execute a SPARQL UPDATE against Oxigraph."""
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=30.0, transport=transport) as client:
        resp = client.post(
            f"{oxigraph_url}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()


def _escape(s: str) -> str:
    """Escape a string for SPARQL literal."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def create_person_oxigraph(
    oxigraph_url: str,
    person_uri: str,
    person_id: str,
    identity: PersonIdentity,
    extra: Dict[str, str],
    user_id: str,
    privacy_level: str,
) -> None:
    """Create a new Person node in Oxigraph from a LinkedIn connection."""
    now = datetime.now(timezone.utc).isoformat()
    # Use LinkedIn connection date as createdAt, not import time.
    # This gives accurate "First recorded" dates in the wiki.
    connected_on = extra.get("connected_on", "")
    if connected_on:
        try:
            dt = datetime.strptime(connected_on, "%d %b %Y")
            created_at = dt.strftime("%Y-%m-%dT00:00:00+00:00")
        except (ValueError, TypeError):
            created_at = now
    else:
        created_at = now

    fn = _escape(identity.display_name)
    given = _escape(identity.given_name or "")
    family = _escape(identity.family_name or "")
    org = _escape(identity.organization or "")
    position = _escape(extra.get("position") or "")

    triples = [
        f"<{person_uri}> a pwg:Person",
        f'<{person_uri}> pwg:displayName "{fn}"',
        f'<{person_uri}> pwg:contactType "person"',
        f'<{person_uri}> pwg:privacyLevel "{privacy_level}"',
        f'<{person_uri}> pwg:createdAt "{created_at}"^^xsd:dateTime',
    ]
    if given:
        triples.append(f'<{person_uri}> pwg:givenName "{given}"')
    if family:
        triples.append(f'<{person_uri}> pwg:familyName "{family}"')
    if org:
        triples.append(f'<{person_uri}> pwg:organization "{org}"')
    if position:
        triples.append(f'<{person_uri}> pwg:jobTitle "{position}"')
    if user_id:
        triples.append(
            f"<{person_uri}> pwg:belongsToUser <https://pwg.dev/ontology#user_{user_id}>"
        )

    # LinkedIn URL identifier
    if extra.get("linkedin_url"):
        id_uri = f"https://pwg.dev/ontology#id_{person_id}_linkedin"
        triples.append(f"<{person_uri}> pwg:hasIdentifier <{id_uri}>")
        triples.append(f"<{id_uri}> a pwg:PersonIdentifier")
        triples.append(f'<{id_uri}> pwg:identifierType "linkedin_url"')
        triples.append(f'<{id_uri}> pwg:identifierValue "{_escape(extra["linkedin_url"])}"')

    # Email identifier. Store the NORMALISED value (lower-cased, trimmed) so it
    # matches what the resolver's find_by_identifier queries for. The resolver
    # normalises emails on read (_iter_identifiers -> normalise_email); writing
    # the raw value here would silently defeat Tier-1 exact-identifier dedup, so
    # a LinkedIn-sourced person with the same email in different case would not
    # merge against the (normalised) contact-card node. Same class as the BW-1
    # contact_syncer fix.
    if extra.get("email"):
        email_value = normalise_email(extra["email"])
        id_uri = f"https://pwg.dev/ontology#id_{person_id}_email_linkedin"
        triples.append(f"<{person_uri}> pwg:hasIdentifier <{id_uri}>")
        triples.append(f"<{id_uri}> a pwg:PersonIdentifier")
        triples.append(f'<{id_uri}> pwg:identifierType "email"')
        triples.append(f'<{id_uri}> pwg:identifierValue "{_escape(email_value)}"')
        triples.append(f'<{id_uri}> pwg:identifierLabel "LINKEDIN"')

    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
    )
    _sparql_update(oxigraph_url, sparql)


def _sparql_query(oxigraph_url: str, sparql: str) -> list:
    """Execute a SPARQL SELECT query and return bindings."""
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=30.0, transport=transport) as client:
        resp = client.post(
            f"{oxigraph_url}/query",
            content=sparql,
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
        )
        resp.raise_for_status()
        return resp.json().get("results", {}).get("bindings", [])


def enrich_person_oxigraph(
    oxigraph_url: str,
    person_uri: str,
    person_id: str,
    extra: Dict[str, str],
) -> None:
    """Enrich an existing Person node with LinkedIn data.

    Adds LinkedIn URL identifier (only if the person doesn't already
    have a DIFFERENT LinkedIn URL) and updates company/position if
    the existing values are empty. Also updates createdAt if the
    LinkedIn connection date is earlier than the current value.
    """
    incoming_url = extra.get("linkedin_url", "")

    if incoming_url:
        # Check if the person already has a LinkedIn URL
        check_sparql = (
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            f"SELECT ?url WHERE {{\n"
            f"  <{person_uri}> pwg:hasIdentifier ?id .\n"
            f'  ?id pwg:identifierType "linkedin_url" ;\n'
            f"      pwg:identifierValue ?url .\n"
            f"}}"
        )
        existing = _sparql_query(oxigraph_url, check_sparql)
        existing_urls = [row["url"]["value"] for row in existing]

        if incoming_url not in existing_urls:
            if existing_urls:
                # Person already has a DIFFERENT LinkedIn URL — do NOT add
                # another one. This would create a false merge. Log and skip.
                import logging
                logging.getLogger(__name__).warning(
                    "Skipping LinkedIn URL for %s: already has %s, incoming %s",
                    person_uri, existing_urls[0], incoming_url,
                )
            else:
                # No existing LinkedIn URL — safe to add
                id_uri = f"https://pwg.dev/ontology#id_{person_id}_linkedin"
                sparql = (
                    "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                    f"INSERT DATA {{\n"
                    f"  <{person_uri}> pwg:hasIdentifier <{id_uri}> .\n"
                    f"  <{id_uri}> a pwg:PersonIdentifier .\n"
                    f'  <{id_uri}> pwg:identifierType "linkedin_url" .\n'
                    f'  <{id_uri}> pwg:identifierValue "{_escape(incoming_url)}" .\n'
                    f"}}"
                )
                _sparql_update(oxigraph_url, sparql)

    # Update createdAt if LinkedIn connection date is earlier
    connected_on = extra.get("connected_on", "")
    if connected_on:
        try:
            dt = datetime.strptime(connected_on, "%d %b %Y")
            linkedin_date = dt.strftime("%Y-%m-%dT00:00:00+00:00")
            # Only update if earlier than current createdAt
            update_sparql = (
                "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
                f"DELETE {{ <{person_uri}> pwg:createdAt ?old }}\n"
                f"INSERT {{ <{person_uri}> pwg:createdAt \"{linkedin_date}\"^^xsd:dateTime }}\n"
                f"WHERE {{\n"
                f"  <{person_uri}> pwg:createdAt ?old .\n"
                f"  FILTER (?old > \"{linkedin_date}\"^^xsd:dateTime)\n"
                f"}}"
            )
            _sparql_update(oxigraph_url, update_sparql)
        except (ValueError, TypeError):
            pass

    # Update org + position only if currently empty on the node
    org = _escape(extra.get("company") or "")
    position = _escape(extra.get("position") or "")

    if org:
        # Insert if not exists pattern
        sparql = (
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            f"INSERT {{\n"
            f'  <{person_uri}> pwg:organization "{org}" .\n'
            f"}} WHERE {{\n"
            f"  FILTER NOT EXISTS {{ <{person_uri}> pwg:organization ?existing }}\n"
            f"}}"
        )
        _sparql_update(oxigraph_url, sparql)

    if position:
        sparql = (
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            f"INSERT {{\n"
            f'  <{person_uri}> pwg:jobTitle "{position}" .\n'
            f"}} WHERE {{\n"
            f"  FILTER NOT EXISTS {{ <{person_uri}> pwg:jobTitle ?existing }}\n"
            f"}}"
        )
        _sparql_update(oxigraph_url, sparql)


# ── iCloud Address Book enrichment (CardDAV write-back) ──────────────


def enrich_vcard(
    vcard_text: str,
    extra: Dict[str, str],
    fields: set,
) -> Tuple[str, List[str]]:
    """Patch a vCard with LinkedIn data. Returns (modified_vcard, changes_list).

    Only modifies fields specified in `fields` set.
    Supported fields: "url", "title", "org".

    Rules:
    - LinkedIn URL: always adds (as a new URL line with type=LINKEDIN)
      unless the exact URL is already present.
    - TITLE: only sets if the vCard has no existing TITLE line.
      User-edited titles take priority over LinkedIn data.
    - ORG: only sets if the vCard has no existing ORG line.
      User-edited org takes priority over LinkedIn data.

    Idempotent: re-running won't duplicate URLs or overwrite edits.
    """
    import re

    lines = vcard_text.rstrip().split("\n")
    changes: List[str] = []
    linkedin_url = extra.get("linkedin_url", "")
    position = extra.get("position", "")
    company = extra.get("company", "")

    # Check existing state
    has_linkedin_url = any(
        linkedin_url.lower() in line.lower()
        for line in lines
        if line.upper().startswith("URL")
    ) if linkedin_url else True

    has_title = any(
        line.upper().startswith("TITLE")
        for line in lines
    )

    has_org = any(
        line.upper().startswith("ORG")
        for line in lines
    )

    # Find the END:VCARD line to insert before it
    end_idx = None
    for i, line in enumerate(lines):
        if line.strip().upper() == "END:VCARD":
            end_idx = i
            break

    if end_idx is None:
        return vcard_text, []

    insertions = []

    if "url" in fields and linkedin_url and not has_linkedin_url:
        insertions.append(f"URL;type=LINKEDIN:{linkedin_url}")
        changes.append(f"+ LinkedIn URL: {linkedin_url}")

    if "title" in fields and position and not has_title:
        # Escape commas and semicolons per vCard spec
        safe_position = position.replace(",", "\\,").replace(";", "\\;")
        insertions.append(f"TITLE:{safe_position}")
        changes.append(f"+ Title: {position}")

    if "org" in fields and company and not has_org:
        safe_company = company.replace(",", "\\,").replace(";", "\\;")
        insertions.append(f"ORG:{safe_company};")
        changes.append(f"+ Org: {company}")

    if not insertions:
        return vcard_text, []

    # Insert before END:VCARD
    new_lines = lines[:end_idx] + insertions + lines[end_idx:]
    return "\n".join(new_lines) + "\n", changes


def find_vcard_href_for_person(
    carddav_client: Any,
    etags: Dict[str, str],
    person_display_name: str,
    icloud_uid: Optional[str] = None,
) -> Optional[Tuple[str, str, str]]:
    """Find the CardDAV href + ETag + vCard text for a person.

    Matches by iCloud UID (from the person's identifiers in Oxigraph)
    or falls back to display name matching against fetched vCards.

    Returns (href, etag, vcard_text) or None.
    """
    # If we have an iCloud UID, the href typically contains it
    if icloud_uid:
        for href, etag in etags.items():
            if icloud_uid in href:
                try:
                    vcard_text = carddav_client.get_vcard(href)
                    return href, etag, vcard_text
                except Exception:
                    pass

    # Fallback: we can't efficiently search by name without fetching
    # all vCards, which is expensive. Return None — the caller should
    # use a pre-built name→href index if doing bulk enrichment.
    return None


class VCardIndex:
    """Pre-built index of iCloud contacts for efficient name lookups.

    Fetches all vCards once, builds a name → (href, etag, vcard_text)
    mapping. Used during bulk LinkedIn enrichment.
    """

    def __init__(self, carddav_client: Any) -> None:
        self._by_name: Dict[str, Tuple[str, str, str]] = {}
        self._build(carddav_client)

    def _build(self, client: Any) -> None:
        """Fetch all vCards and index by display name (lowercased)."""
        import re
        etags = client.get_etags()
        print(f"  Building vCard index ({len(etags)} contacts)...")

        for href, etag in etags.items():
            try:
                vcard_text = client.get_vcard(href)
            except Exception:
                continue
            # Extract FN (display name) from vCard
            for line in vcard_text.split("\n"):
                if line.upper().startswith("FN"):
                    name = line.split(":", 1)[-1].strip()
                    if name:
                        self._by_name[name.lower()] = (href, etag, vcard_text)
                    break

        print(f"  Indexed {len(self._by_name)} contacts by name")

    def lookup(self, display_name: str) -> Optional[Tuple[str, str, str]]:
        """Look up by exact display name (case-insensitive).

        Returns (href, etag, vcard_text) or None.
        """
        return self._by_name.get(display_name.lower())


# ── Qdrant writes ────────────────────────────────────────────────────


def embed_text(ollama_url: str, text: str, model: str = "nomic-embed-text") -> List[float]:
    """Get embedding vector from Ollama."""
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=60.0, transport=transport) as client:
        resp = client.post(
            f"{ollama_url}/api/embed",
            json={"model": model, "input": text},
        )
        resp.raise_for_status()
        data = resp.json()
    embs = data.get("embeddings") or [data.get("embedding")]
    return embs[0]


def upsert_qdrant(
    qdrant: Any,
    collection: str,
    person_id: str,
    person_uri: str,
    identity: PersonIdentity,
    extra: Dict[str, str],
    vector: List[float],
    privacy_level: str,
) -> None:
    """Upsert a person point into Qdrant's people collection."""
    now_iso = datetime.now(timezone.utc).isoformat()
    connected_on = extra.get("connected_on") or ""

    # Parse connected_on date for last_contact
    last_contact = connected_on or now_iso[:10]
    try:
        # LinkedIn format: "31 Dec 2025"
        dt = datetime.strptime(connected_on, "%d %b %Y")
        last_contact = dt.strftime("%Y-%m-%d")
        last_contact_ts = int(dt.timestamp())
    except (ValueError, TypeError):
        last_contact_ts = int(time.time())

    payload = {
        "person_id": person_id,
        "person_uri": person_uri,
        "display_name": identity.display_name,
        "given_name": identity.given_name or "",
        "family_name": identity.family_name or "",
        "organization": identity.organization or "",
        "job_title": extra.get("position") or "",
        "phones": [],
        "emails": identity.emails,
        "linkedin_url": extra.get("linkedin_url") or "",
        "contact_type": "person",
        "privacy_level": privacy_level,
        "source": "linkedin_connections",
        "last_contact": last_contact,
        "last_contact_ts": last_contact_ts,
        "created_at": now_iso,
        "updated_at": now_iso,
    }

    point_uuid = str(uuid.uuid5(uuid.NAMESPACE_URL, person_uri))
    point = PointStruct(
        id=point_uuid,
        vector=vector,
        payload=payload,
    )

    # Check if point exists — if so, preserve existing last_contact
    # (which may have been set by actual meetings/conversations)
    try:
        existing = qdrant.retrieve(
            collection_name=collection,
            ids=[point_uuid],
            with_payload=True,
        )
        if existing and existing[0].payload:
            ex_ts = existing[0].payload.get("last_contact_ts")
            if ex_ts and ex_ts > last_contact_ts:
                payload["last_contact"] = existing[0].payload["last_contact"]
                payload["last_contact_ts"] = ex_ts
            # Preserve source if already richer
            ex_source = existing[0].payload.get("source", "")
            if ex_source and ex_source != "linkedin_connections":
                payload["source"] = ex_source
    except Exception:
        pass

    qdrant.upsert(collection_name=collection, points=[point])


# ── Main orchestrator ────────────────────────────────────────────────


def import_connections(
    csv_path: str,
    *,
    dry_run: bool = False,
    enrich_contacts: bool = False,
    enrich_fields: Optional[set] = None,
    limit: Optional[int] = None,
    verbose: bool = False,
) -> Dict[str, int]:
    """Import LinkedIn connections into the people graph.

    All connections go into PWG (Oxigraph + Qdrant). When
    --enrich-contacts is set, matched connections ALSO get their
    LinkedIn data written back to the user's iCloud Address Book
    via CardDAV. New connections are NOT added to the address book.

    Args:
        enrich_contacts: if True, write LinkedIn URL/title/org back
            to matching iCloud vCards via CardDAV.
        enrich_fields: which fields to write back. Default: {"url"}.
            Options: "url", "title", "org".

    Returns counts: {total, matched, created, skipped, errors, contacts_enriched}
    """
    rows = parse_connections_csv(csv_path)
    if limit:
        rows = rows[:limit]

    resolver = IdentityResolver(
        oxigraph_url=config.OXIGRAPH_URL,
        default_country_code=config.DEFAULT_COUNTRY_CODE,
    )

    qdrant = None
    if HAS_QDRANT and not dry_run:
        qdrant = QdrantClient(url=config.QDRANT_URL)

    if enrich_fields is None:
        enrich_fields = {"url"}

    # Build vCard index if enriching contacts
    vcard_index = None
    carddav = None
    if enrich_contacts:
        from contact_syncer.carddav import CardDAVClient
        if not config.CARDDAV_URL or not config.CARDDAV_USERNAME:
            print("WARNING: --enrich-contacts requires CardDAV config. Skipping contact enrichment.",
                  file=sys.stderr)
            enrich_contacts = False
        else:
            carddav = CardDAVClient(
                url=config.CARDDAV_URL,
                username=config.CARDDAV_USERNAME,
                password=config.CARDDAV_PASSWORD,
            )
            vcard_index = VCardIndex(carddav)

    counts = {"total": len(rows), "matched": 0, "created": 0, "skipped": 0,
              "errors": 0, "contacts_enriched": 0}
    print(f"Importing {len(rows)} LinkedIn connections...")

    for i, row in enumerate(rows, 1):
        identity, extra = row_to_identity(row)

        # Skip rows with no usable name. LinkedIn exports a literal
        # "LinkedIn Member" placeholder for connections whose profile is
        # private/withheld; these carry no real identity and must not become
        # individual people (94 collapsed into one junk node on a real
        # import). Matched case-insensitively.
        _display = identity.display_name.strip()
        if not _display or _display.casefold() == "linkedin member":
            counts["skipped"] += 1
            continue

        if verbose or i % 100 == 0:
            print(f"  [{i}/{len(rows)}] {identity.display_name}", end="")

        try:
            # Resolve — use fuzzy matching since LinkedIn connections
            # won't have iCloud UIDs or phone numbers to match on.
            # LinkedIn URL is the strong identifier when available.
            match = resolver.resolve(identity, use_fuzzy=True)

            if match and match.person_uri and match.match_type != "new":
                # Existing person — enrich with LinkedIn data
                person_uri = match.person_uri
                person_id = (
                    person_uri.split("person_")[-1]
                    if "person_" in person_uri
                    else str(uuid.uuid4()).replace("-", "")[:12]
                )

                if verbose:
                    print(f" → MATCH ({match.match_type}, {match.confidence:.2f})")

                if not dry_run:
                    enrich_person_oxigraph(
                        config.OXIGRAPH_URL, person_uri, person_id, extra
                    )

                # CardDAV write-back for matched contacts
                if enrich_contacts and vcard_index:
                    vcard_result = vcard_index.lookup(identity.display_name)
                    if vcard_result:
                        href, etag, vcard_text = vcard_result
                        modified, changes = enrich_vcard(vcard_text, extra, enrich_fields)
                        if changes:
                            if dry_run:
                                for c in changes:
                                    print(f"    [dry-run] {c}")
                            else:
                                try:
                                    carddav.put_vcard(href, modified, etag)
                                    counts["contacts_enriched"] += 1
                                    if verbose:
                                        for c in changes:
                                            print(f"    {c}")
                                except Exception as e:
                                    if verbose:
                                        print(f"    CardDAV write failed: {e}")

                counts["matched"] += 1
            else:
                # New person — create in PWG (not in address book)
                person_id = str(uuid.uuid4()).replace("-", "")[:12]
                person_uri = f"https://pwg.dev/ontology#person_{person_id}"

                if verbose:
                    print(f" → NEW")

                if not dry_run:
                    create_person_oxigraph(
                        config.OXIGRAPH_URL,
                        person_uri,
                        person_id,
                        identity,
                        extra,
                        config.USER_ID,
                        config.DEFAULT_PRIVACY_LEVEL,
                    )
                counts["created"] += 1

                # Register the new person in the resolver's in-memory fuzzy
                # index so LATER rows in this SAME run dedupe against it. The
                # candidate snapshot is loaded once and frozen; without this a
                # one-shot bulk import (e.g. 3,810 LinkedIn connections) mints a
                # fresh node for every repeat of a name -- the root cause of
                # "Jay Livens x6" on a fresh install, which the incrementally
                # synced graph never hit (each daily run re-snapshots). Fires in
                # dry-run too so the reported dedup reflects real behaviour.
                resolver.register_person(
                    person_uri,
                    identity.display_name,
                    org=identity.organization,
                    linkedin_url=identity.linkedin_url,
                )

            # Qdrant upsert (embed + write)
            if qdrant and not dry_run:
                embed_text_str = (
                    f"{identity.display_name} "
                    f"{identity.organization or ''} "
                    f"{extra.get('position') or ''}"
                ).strip()
                try:
                    vector = embed_text(config.EMBED_OLLAMA_URL, embed_text_str, config.EMBED_MODEL)
                    upsert_qdrant(
                        qdrant,
                        config.QDRANT_COLLECTION,
                        person_id,
                        person_uri,
                        identity,
                        extra,
                        vector,
                        config.DEFAULT_PRIVACY_LEVEL,
                    )
                except Exception as e:
                    if verbose:
                        print(f"    Qdrant/embed error: {e}")

        except Exception as e:
            if verbose or i % 100 == 0:
                print(f" → ERROR: {e}")
            counts["errors"] += 1
            continue

        if not verbose and i % 100 != 0:
            pass  # suppress output for non-verbose non-milestone rows

    enriched_msg = f", {counts['contacts_enriched']} contacts enriched" if enrich_contacts else ""
    print(f"\nDone: {counts['matched']} matched, {counts['created']} created, "
          f"{counts['skipped']} skipped, {counts['errors']} errors"
          f"{enriched_msg} (of {counts['total']} total)")

    return counts


# ── CLI ──────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        description="Import LinkedIn Connections.csv into PWG people graph"
    )
    parser.add_argument(
        "--csv",
        type=str,
        required=True,
        help="Path to Connections.csv from LinkedIn GDPR export",
    )
    parser.add_argument("--dry-run", action="store_true", help="Parse and resolve but don't write")
    parser.add_argument("--enrich-contacts", action="store_true",
                        help="Write LinkedIn URL/title/org back to matching iCloud contacts via CardDAV")
    parser.add_argument("--enrich-fields", type=str, default="url",
                        help="Comma-separated fields to write back: url,title,org (default: url)")
    parser.add_argument("--limit", type=int, default=None, help="Process only first N connections")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print each connection")
    args = parser.parse_args()

    if not os.path.isfile(args.csv):
        print(f"File not found: {args.csv}", file=sys.stderr)
        return 1

    # Validate config
    if not config.OXIGRAPH_URL:
        print("OXIGRAPH_URL not configured. Set in .env or environment.", file=sys.stderr)
        return 1
    if not config.QDRANT_URL:
        print("QDRANT_URL not configured (Qdrant writes will be skipped).", file=sys.stderr)

    enrich_fields = set(args.enrich_fields.split(",")) if args.enrich_fields else {"url"}

    counts = import_connections(
        args.csv,
        dry_run=args.dry_run,
        enrich_contacts=args.enrich_contacts,
        enrich_fields=enrich_fields,
        limit=args.limit,
        verbose=args.verbose,
    )

    return 0 if counts["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
