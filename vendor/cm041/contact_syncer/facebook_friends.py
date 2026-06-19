"""Facebook Friends Importer — reads your_friends.json from a Facebook
GDPR export and imports contacts into the PWG people graph.

For each friend:
1. Parse JSON entry → PersonIdentity
2. Resolve via IdentityResolver (fuzzy name matching)
3. Match → enrich existing person with a "facebook_friend" relationship signal
4. No match → create new person node in PWG (Oxigraph + Qdrant)
5. Upsert Qdrant point with embedding

Facebook friends only have names and timestamps — no company, position,
email, or profile URL. The source field is "facebook_friends".

Usage:
    python -m contact_syncer.facebook_friends \
        --json /path/to/your_friends.json \
        [--dry-run] [--limit N] [--verbose]

Idempotent: re-running upserts by deterministic ID (from name hash).
"""
from __future__ import annotations

import argparse
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
from contact_syncer import privacy_model as _pm
from identity_resolver.models import PersonIdentity
from identity_resolver.resolver import IdentityResolver

try:
    from qdrant_client import QdrantClient
    from qdrant_client.models import PointStruct
    HAS_QDRANT = True
except ImportError:
    HAS_QDRANT = False


# ── JSON parsing ────────────────────────────────────────────────────


def parse_friends_json(json_path: str) -> List[Dict[str, Any]]:
    """Parse Facebook your_friends.json export.

    The file is a dict with a "friends_v2" key containing a list of
    {name: str, timestamp: int} entries.
    """
    with open(json_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    # Handle both the wrapper dict and a raw list
    if isinstance(data, dict):
        friends = data.get("friends_v2", [])
    elif isinstance(data, list):
        friends = data
    else:
        friends = []

    return friends


def _split_name(full_name: str) -> Tuple[Optional[str], Optional[str]]:
    """Split a display name into (given_name, family_name).

    Simple heuristic: first token is given name, rest is family name.
    Returns (None, None) for empty names.
    """
    parts = full_name.strip().split()
    if not parts:
        return None, None
    if len(parts) == 1:
        return parts[0], None
    return parts[0], " ".join(parts[1:])


def _fix_mojibake(text: str) -> str:
    """Fix Facebook's double-encoded UTF-8 (Latin-1 mojibake).

    Facebook GDPR exports encode non-ASCII as escaped UTF-8 bytes
    interpreted as Latin-1 (e.g. "José" becomes "Jos\\u00c3\\u00a9").
    """
    try:
        return text.encode("latin-1").decode("utf-8")
    except (UnicodeDecodeError, UnicodeEncodeError):
        return text


def friend_to_identity(entry: Dict[str, Any]) -> Tuple[PersonIdentity, Dict[str, Any]]:
    """Convert a friend JSON entry to a PersonIdentity + extra metadata."""
    raw_name = (entry.get("name") or "").strip()
    display_name = _fix_mojibake(raw_name)
    given, family = _split_name(display_name)
    timestamp = entry.get("timestamp", 0)

    # Convert Unix timestamp to readable date
    if timestamp:
        try:
            dt = datetime.fromtimestamp(timestamp, tz=timezone.utc)
            friended_on = dt.strftime("%Y-%m-%d")
        except (OSError, ValueError):
            friended_on = ""
    else:
        friended_on = ""

    identity = PersonIdentity(
        display_name=display_name,
        given_name=given,
        family_name=family,
    )

    extra = {
        "friended_on": friended_on,
        "timestamp": timestamp,
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
    extra: Dict[str, Any],
    user_id: str,
    privacy_level: str,
) -> None:
    """Create a new Person node in Oxigraph from a Facebook friend."""
    now = datetime.now(timezone.utc).isoformat()
    # Use Facebook friend date as createdAt, not import time.
    # This gives accurate "First recorded" dates in the wiki.
    friended_on = extra.get("friended_on", "")
    if friended_on:
        created_at = f"{friended_on}T00:00:00+00:00"
    else:
        created_at = now

    fn = _escape(identity.display_name)
    given = _escape(identity.given_name or "")
    family = _escape(identity.family_name or "")

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
    if user_id:
        triples.append(
            f"<{person_uri}> pwg:belongsToUser <https://pwg.dev/ontology#user_{user_id}>"
        )

    # Facebook friend signal (records the relationship + when it was established)
    signal_uri = f"https://pwg.dev/ontology#signal_{person_id}_facebook_friend"
    triples.append(f"<{person_uri}> pwg:hasSignal <{signal_uri}>")
    triples.append(f"<{signal_uri}> a pwg:RelationshipSignal")
    triples.append(f'<{signal_uri}> pwg:signalType "facebook_friend"')
    triples.append(
        f'<{signal_uri}> pwg:privacyLevel '
        f'"{_pm.level_for(rdf_type="RelationshipSignal", source="facebook_friend")}"'
    )
    if extra.get("friended_on"):
        triples.append(
            f'<{signal_uri}> pwg:signalDate "{_escape(extra["friended_on"])}"'
        )

    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
    )
    _sparql_update(oxigraph_url, sparql)


def enrich_person_oxigraph(
    oxigraph_url: str,
    person_uri: str,
    person_id: str,
    extra: Dict[str, Any],
) -> None:
    """Enrich an existing Person node with a Facebook friend signal.

    Adds a RelationshipSignal triple to record the Facebook friendship.
    Also updates createdAt if the Facebook friend date is earlier.
    """
    signal_uri = f"https://pwg.dev/ontology#signal_{person_id}_facebook_friend"
    triples = [
        f"<{person_uri}> pwg:hasSignal <{signal_uri}>",
        f"<{signal_uri}> a pwg:RelationshipSignal",
        f'<{signal_uri}> pwg:signalType "facebook_friend"',
        f'<{signal_uri}> pwg:privacyLevel '
        f'"{_pm.level_for(rdf_type="RelationshipSignal", source="facebook_friend")}"',
    ]
    if extra.get("friended_on"):
        triples.append(
            f'<{signal_uri}> pwg:signalDate "{_escape(extra["friended_on"])}"'
        )

    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
    )
    _sparql_update(oxigraph_url, sparql)

    # Update createdAt if Facebook friend date is earlier than current value
    friended_on = extra.get("friended_on", "")
    if friended_on:
        fb_date = f"{friended_on}T00:00:00+00:00"
        update_sparql = (
            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
            "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
            f"DELETE {{ <{person_uri}> pwg:createdAt ?old }}\n"
            f"INSERT {{ <{person_uri}> pwg:createdAt \"{fb_date}\"^^xsd:dateTime }}\n"
            f"WHERE {{\n"
            f"  <{person_uri}> pwg:createdAt ?old .\n"
            f"  FILTER (?old > \"{fb_date}\"^^xsd:dateTime)\n"
            f"}}"
        )
        _sparql_update(oxigraph_url, update_sparql)


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
    extra: Dict[str, Any],
    vector: List[float],
    privacy_level: str,
) -> None:
    """Upsert a person point into Qdrant's people collection."""
    now_iso = datetime.now(timezone.utc).isoformat()
    friended_on = extra.get("friended_on") or ""
    timestamp = extra.get("timestamp") or 0

    # Use friended_on date for last_contact
    last_contact = friended_on or now_iso[:10]
    last_contact_ts = timestamp or int(time.time())

    # observed_at records the REAL source date (the Facebook friendship
    # date) so the wiki's time-ordered views show when the relationship
    # was actually established, not the install/import date. Only set it
    # when friended_on is present -- never fabricate a date.
    observed_at = ""
    if friended_on:
        observed_at = f"{friended_on}T00:00:00+00:00"

    payload = {
        "person_id": person_id,
        "person_uri": person_uri,
        "display_name": identity.display_name,
        "given_name": identity.given_name or "",
        "family_name": identity.family_name or "",
        "organization": "",
        "job_title": "",
        "phones": [],
        "emails": [],
        "linkedin_url": "",
        "contact_type": "person",
        "privacy_level": privacy_level,
        "source": "facebook_friends",
        "last_contact": last_contact,
        "last_contact_ts": last_contact_ts,
        "created_at": now_iso,
        "updated_at": now_iso,
    }
    if observed_at:
        payload["observed_at"] = observed_at

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
            if ex_source and ex_source != "facebook_friends":
                payload["source"] = ex_source
    except Exception:
        pass

    qdrant.upsert(collection_name=collection, points=[point])


# ── Main orchestrator ────────────────────────────────────────────────


def import_friends(
    json_path: str,
    *,
    dry_run: bool = False,
    limit: Optional[int] = None,
    verbose: bool = False,
) -> Dict[str, int]:
    """Import Facebook friends into the people graph.

    Returns counts: {total, matched, created, skipped, errors}
    """
    friends = parse_friends_json(json_path)
    if limit:
        friends = friends[:limit]

    resolver = IdentityResolver(
        oxigraph_url=config.OXIGRAPH_URL,
        default_country_code=config.DEFAULT_COUNTRY_CODE,
    )

    qdrant = None
    if HAS_QDRANT and not dry_run:
        qdrant = QdrantClient(url=config.QDRANT_URL)

    counts = {"total": len(friends), "matched": 0, "created": 0, "skipped": 0,
              "errors": 0}
    print(f"Importing {len(friends)} Facebook friends...")

    for i, entry in enumerate(friends, 1):
        identity, extra = friend_to_identity(entry)

        if not identity.display_name.strip():
            counts["skipped"] += 1
            continue

        if verbose or i % 100 == 0:
            print(f"  [{i}/{len(friends)}] {identity.display_name}", end="")

        try:
            # Resolve — use fuzzy matching since Facebook friends
            # only have names (no email, phone, or URL to match on).
            match = resolver.resolve(identity, use_fuzzy=True)

            if match and match.person_uri and match.match_type != "new":
                # Existing person — enrich with Facebook friend signal
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

                counts["matched"] += 1
            else:
                # New person — create in PWG
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
                # one-shot bulk import mints a fresh node for every repeat of a
                # name -- the root cause of one-shot-import duplicates on a
                # fresh install, which the incrementally synced graph never hit
                # (each daily run re-snapshots).
                resolver.register_person(
                    person_uri,
                    identity.display_name,
                    org=identity.organization,
                    linkedin_url=identity.linkedin_url,
                )

            # Qdrant upsert (embed + write)
            if qdrant and not dry_run:
                embed_text_str = identity.display_name
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

    print(f"\nDone: {counts['matched']} matched, {counts['created']} created, "
          f"{counts['skipped']} skipped, {counts['errors']} errors"
          f" (of {counts['total']} total)")

    return counts


# ── CLI ──────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        description="Import Facebook your_friends.json into PWG people graph"
    )
    parser.add_argument(
        "--json",
        type=str,
        required=True,
        help="Path to your_friends.json from Facebook GDPR export",
    )
    parser.add_argument("--dry-run", action="store_true", help="Parse and resolve but don't write")
    parser.add_argument("--limit", type=int, default=None, help="Process only first N friends")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print each friend")
    args = parser.parse_args()

    if not os.path.isfile(args.json):
        print(f"File not found: {args.json}", file=sys.stderr)
        return 1

    # Validate config
    if not config.OXIGRAPH_URL:
        print("OXIGRAPH_URL not configured. Set in .env or environment.", file=sys.stderr)
        return 1
    if not config.QDRANT_URL:
        print("QDRANT_URL not configured (Qdrant writes will be skipped).", file=sys.stderr)

    counts = import_friends(
        args.json,
        dry_run=args.dry_run,
        limit=args.limit,
        verbose=args.verbose,
    )

    return 0 if counts["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
