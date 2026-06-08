"""Instagram Social Graph Importer — reads close_friends.json,
followers_1.json, and following.json from an Instagram GDPR export
and imports contacts into the PWG people graph.

For each connection:
1. Parse JSON entry → PersonIdentity (display_name = username)
2. Resolve via IdentityResolver (fuzzy matching — some usernames
   contain real names like "belindaburwell" or "alisonmassey")
3. Match → enrich existing person with Instagram username identifier
4. No match → create new person node in PWG
5. Upsert Qdrant point with embedding

Close friends get a special "relationship_hint": "close_friend" tag
in the Qdrant payload. Followers and following are tagged differently
via "instagram_relationship" field.

Usage:
    python -m contact_syncer.instagram_social \
        --dir /path/to/instagram/connections/followers_and_following/ \
        [--dry-run] [--limit N] [--verbose]

Idempotent: re-running upserts by deterministic ID (from Instagram URL).
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
from typing import Any, Dict, List, Optional, Set, Tuple

import httpx

# Add parent directory so identity_resolver is importable
_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from contact_syncer import config
from identity_resolver.models import PersonIdentity
from identity_resolver.resolver import IdentityResolver

try:
    from qdrant_client import QdrantClient
    from qdrant_client.models import PointStruct
    HAS_QDRANT = True
except ImportError:
    HAS_QDRANT = False


# ── JSON parsing ────────────────────────────────────────────────────


def _extract_username_and_timestamp(entry: Dict) -> Optional[Tuple[str, int, str]]:
    """Extract (username, timestamp, profile_url) from an Instagram JSON entry.

    Instagram export formats vary between file types:
    - close_friends.json / followers_1.json: username in string_list_data[0].value
    - following.json: username in title field

    Returns None if the entry cannot be parsed.
    """
    username = None
    timestamp = 0
    profile_url = ""

    sld = entry.get("string_list_data") or []
    if sld:
        first = sld[0]
        username = first.get("value") or None
        timestamp = first.get("timestamp", 0)
        profile_url = first.get("href", "")

    # Fallback: following.json puts username in title
    if not username:
        username = (entry.get("title") or "").strip()

    if not username:
        return None

    # If we got username from title but no profile_url, try href from string_list_data
    if not profile_url and sld:
        profile_url = sld[0].get("href", "")

    # If still no profile URL, construct it
    if not profile_url:
        profile_url = f"https://www.instagram.com/{username}"

    # If no timestamp from string_list_data value, check string_list_data again
    if timestamp == 0 and sld:
        timestamp = sld[0].get("timestamp", 0)

    return username, timestamp, profile_url


def parse_close_friends(filepath: str) -> List[Dict[str, Any]]:
    """Parse close_friends.json. Returns list of {username, timestamp, profile_url}."""
    with open(filepath, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    entries = data.get("relationships_close_friends", [])
    results = []
    for entry in entries:
        parsed = _extract_username_and_timestamp(entry)
        if parsed:
            username, ts, url = parsed
            results.append({
                "username": username,
                "timestamp": ts,
                "profile_url": url,
            })
    return results


def parse_followers(filepath: str) -> List[Dict[str, Any]]:
    """Parse followers_1.json. Returns list of {username, timestamp, profile_url}.

    Followers file is a bare JSON array (no wrapper key).
    """
    with open(filepath, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    # Could be a bare list or wrapped
    if isinstance(data, list):
        entries = data
    else:
        # Try common keys
        entries = (
            data.get("relationships_followers", [])
            or data.get("followers", [])
            or []
        )

    results = []
    for entry in entries:
        parsed = _extract_username_and_timestamp(entry)
        if parsed:
            username, ts, url = parsed
            results.append({
                "username": username,
                "timestamp": ts,
                "profile_url": url,
            })
    return results


def parse_following(filepath: str) -> List[Dict[str, Any]]:
    """Parse following.json. Returns list of {username, timestamp, profile_url}."""
    with open(filepath, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    entries = data.get("relationships_following", [])
    results = []
    for entry in entries:
        parsed = _extract_username_and_timestamp(entry)
        if parsed:
            username, ts, url = parsed
            results.append({
                "username": username,
                "timestamp": ts,
                "profile_url": url,
            })
    return results


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
    instagram_username: str,
    profile_url: str,
    user_id: str,
    privacy_level: str,
    connection_timestamp: int = 0,
) -> None:
    """Create a new Person node in Oxigraph from an Instagram connection."""
    now = datetime.now(timezone.utc).isoformat()
    # Use Instagram connection timestamp as createdAt, not import time.
    # This gives accurate "First recorded" dates in the wiki.
    if connection_timestamp > 0:
        try:
            dt = datetime.fromtimestamp(connection_timestamp, tz=timezone.utc)
            created_at = dt.isoformat()
        except (OSError, ValueError):
            created_at = now
    else:
        created_at = now

    fn = _escape(identity.display_name)

    triples = [
        f"<{person_uri}> a pwg:Person",
        f'<{person_uri}> pwg:displayName "{fn}"',
        f'<{person_uri}> pwg:contactType "person"',
        f'<{person_uri}> pwg:privacyLevel "{privacy_level}"',
        f'<{person_uri}> pwg:createdAt "{created_at}"^^xsd:dateTime',
    ]
    if identity.given_name:
        triples.append(f'<{person_uri}> pwg:givenName "{_escape(identity.given_name)}"')
    if identity.family_name:
        triples.append(f'<{person_uri}> pwg:familyName "{_escape(identity.family_name)}"')
    if user_id:
        triples.append(
            f"<{person_uri}> pwg:belongsToUser <https://pwg.dev/ontology#user_{user_id}>"
        )

    # Instagram username identifier
    id_uri = f"https://pwg.dev/ontology#id_{person_id}_instagram"
    triples.append(f"<{person_uri}> pwg:hasIdentifier <{id_uri}>")
    triples.append(f"<{id_uri}> a pwg:PersonIdentifier")
    triples.append(f'<{id_uri}> pwg:identifierType "instagram_username"')
    triples.append(f'<{id_uri}> pwg:identifierValue "{_escape(instagram_username)}"')
    if profile_url:
        triples.append(f'<{id_uri}> pwg:identifierURL "{_escape(profile_url)}"')

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
    instagram_username: str,
    profile_url: str,
    connection_timestamp: int = 0,
) -> None:
    """Enrich an existing Person node with Instagram username identifier.

    Also updates createdAt if the Instagram connection date is earlier.
    """
    id_uri = f"https://pwg.dev/ontology#id_{person_id}_instagram"
    triples = [
        f"<{person_uri}> pwg:hasIdentifier <{id_uri}>",
        f"<{id_uri}> a pwg:PersonIdentifier",
        f'<{id_uri}> pwg:identifierType "instagram_username"',
        f'<{id_uri}> pwg:identifierValue "{_escape(instagram_username)}"',
    ]
    if profile_url:
        triples.append(f'<{id_uri}> pwg:identifierURL "{_escape(profile_url)}"')

    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
    )
    _sparql_update(oxigraph_url, sparql)

    # Update createdAt if Instagram connection date is earlier than current value
    if connection_timestamp > 0:
        try:
            dt = datetime.fromtimestamp(connection_timestamp, tz=timezone.utc)
            ig_date = dt.isoformat()
            update_sparql = (
                "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
                f"DELETE {{ <{person_uri}> pwg:createdAt ?old }}\n"
                f"INSERT {{ <{person_uri}> pwg:createdAt \"{ig_date}\"^^xsd:dateTime }}\n"
                f"WHERE {{\n"
                f"  <{person_uri}> pwg:createdAt ?old .\n"
                f"  FILTER (?old > \"{ig_date}\"^^xsd:dateTime)\n"
                f"}}"
            )
            _sparql_update(oxigraph_url, update_sparql)
        except (OSError, ValueError):
            pass


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
    instagram_username: str,
    profile_url: str,
    vector: List[float],
    privacy_level: str,
    instagram_relationship: str,
    is_close_friend: bool,
    connection_timestamp: int,
) -> None:
    """Upsert a person point into Qdrant's people collection."""
    now_iso = datetime.now(timezone.utc).isoformat()

    # Use the connection timestamp for last_contact
    if connection_timestamp > 0:
        last_contact = datetime.fromtimestamp(
            connection_timestamp, tz=timezone.utc
        ).strftime("%Y-%m-%d")
        last_contact_ts = connection_timestamp
    else:
        last_contact = now_iso[:10]
        last_contact_ts = int(time.time())

    payload: Dict[str, Any] = {
        "person_id": person_id,
        "person_uri": person_uri,
        "display_name": identity.display_name,
        "given_name": identity.given_name or "",
        "family_name": identity.family_name or "",
        "organization": "",
        "job_title": "",
        "phones": [],
        "emails": [],
        "instagram_username": instagram_username,
        "instagram_url": profile_url,
        "instagram_relationship": instagram_relationship,
        "contact_type": "person",
        "privacy_level": privacy_level,
        "source": "instagram_social",
        "last_contact": last_contact,
        "last_contact_ts": last_contact_ts,
        "created_at": now_iso,
        "updated_at": now_iso,
    }

    if is_close_friend:
        payload["relationship_hint"] = "close_friend"

    point_uuid = str(uuid.uuid5(uuid.NAMESPACE_URL, person_uri))
    point = PointStruct(
        id=point_uuid,
        vector=vector,
        payload=payload,
    )

    # Check if point exists — preserve richer data if present
    try:
        existing = qdrant.retrieve(
            collection_name=collection,
            ids=[point_uuid],
            with_payload=True,
        )
        if existing and existing[0].payload:
            ep = existing[0].payload
            # Preserve newer last_contact
            ex_ts = ep.get("last_contact_ts")
            if ex_ts and ex_ts > last_contact_ts:
                payload["last_contact"] = ep["last_contact"]
                payload["last_contact_ts"] = ex_ts
            # Preserve richer source
            ex_source = ep.get("source", "")
            if ex_source and ex_source != "instagram_social":
                payload["source"] = ex_source
            # Preserve existing relationship_hint if close_friend
            if not is_close_friend and ep.get("relationship_hint") == "close_friend":
                payload["relationship_hint"] = "close_friend"
            # Preserve existing names/org/emails if richer
            for field in ("organization", "job_title", "given_name", "family_name"):
                if ep.get(field) and not payload.get(field):
                    payload[field] = ep[field]
            if ep.get("emails"):
                payload["emails"] = ep["emails"]
            if ep.get("phones"):
                payload["phones"] = ep["phones"]
    except Exception:
        pass

    qdrant.upsert(collection_name=collection, points=[point])


# ── Main orchestrator ────────────────────────────────────────────────


def _username_to_display_name(username: str) -> str:
    """Best-effort conversion of Instagram username to a display name.

    Strips trailing digits, replaces separators with spaces, title-cases.
    E.g. "belindaburwell" stays as "belindaburwell" (no separators to split on),
    "isla.whittet" → "Isla Whittet", "guy.williams.779" → "Guy Williams".
    """
    # Remove common suffixes like trailing numbers after dots/underscores
    import re
    clean = re.sub(r'[._]\d+$', '', username)
    # Replace dots, underscores with spaces
    clean = clean.replace(".", " ").replace("_", " ")
    # Remove leading/trailing whitespace
    clean = clean.strip()
    # Title case if contains spaces (looks like a real name)
    if " " in clean:
        clean = clean.title()
    return clean


def import_instagram(
    dir_path: str,
    *,
    dry_run: bool = False,
    limit: Optional[int] = None,
    verbose: bool = False,
) -> Dict[str, int]:
    """Import Instagram social graph into the people graph.

    Parses close_friends.json, followers_1.json, and following.json.
    Close friends are tagged with relationship_hint=close_friend.
    Followers and following are distinguished by instagram_relationship field.

    Returns counts: {total, matched, created, skipped, errors,
                     close_friends, followers, following}
    """
    # Locate files
    close_friends_path = os.path.join(dir_path, "close_friends.json")
    followers_path = os.path.join(dir_path, "followers_1.json")
    following_path = os.path.join(dir_path, "following.json")

    # Parse all three files
    close_friends_data = []
    followers_data = []
    following_data = []

    if os.path.isfile(close_friends_path):
        close_friends_data = parse_close_friends(close_friends_path)
        print(f"  Parsed {len(close_friends_data)} close friends")
    else:
        print(f"  WARNING: {close_friends_path} not found, skipping close friends")

    if os.path.isfile(followers_path):
        followers_data = parse_followers(followers_path)
        print(f"  Parsed {len(followers_data)} followers")
    else:
        print(f"  WARNING: {followers_path} not found, skipping followers")

    if os.path.isfile(following_path):
        following_data = parse_following(following_path)
        print(f"  Parsed {len(following_data)} following")
    else:
        print(f"  WARNING: {following_path} not found, skipping following")

    # Build a combined list with tags
    # Priority: close_friends first (highest signal), then following, then followers
    close_friend_usernames: Set[str] = {
        e["username"].lower() for e in close_friends_data
    }
    following_usernames: Set[str] = {
        e["username"].lower() for e in following_data
    }

    all_entries: List[Tuple[Dict[str, Any], str, bool]] = []

    for entry in close_friends_data:
        all_entries.append((entry, "close_friend", True))

    for entry in following_data:
        is_cf = entry["username"].lower() in close_friend_usernames
        if not is_cf:
            all_entries.append((entry, "following", False))
        # If already added as close_friend, skip the duplicate

    for entry in followers_data:
        uname_lower = entry["username"].lower()
        is_cf = uname_lower in close_friend_usernames
        is_following = uname_lower in following_usernames
        if is_cf:
            continue  # Already added as close_friend
        if is_following:
            # Already added as following — could upgrade to "mutual"
            # but keep it simple: the following entry stays, we tag this one
            # Actually, let's find and update the relationship tag
            for i, (e, rel, cf) in enumerate(all_entries):
                if e["username"].lower() == uname_lower and rel == "following":
                    all_entries[i] = (e, "mutual", cf)
                    break
            continue
        all_entries.append((entry, "follower", False))

    if limit:
        all_entries = all_entries[:limit]

    # Initialise resolver and clients
    resolver = IdentityResolver(
        oxigraph_url=config.OXIGRAPH_URL,
        default_country_code=config.DEFAULT_COUNTRY_CODE,
    )

    qdrant = None
    if HAS_QDRANT and not dry_run:
        qdrant = QdrantClient(url=config.QDRANT_URL)

    counts = {
        "total": len(all_entries),
        "matched": 0,
        "created": 0,
        "skipped": 0,
        "errors": 0,
        "close_friends": len(close_friends_data),
        "followers": len(followers_data),
        "following": len(following_data),
    }

    print(f"\nImporting {len(all_entries)} unique Instagram connections...")

    for i, (entry, relationship, is_close_friend) in enumerate(all_entries, 1):
        username = entry["username"]
        timestamp = entry["timestamp"]
        profile_url = entry["profile_url"]

        display_name = _username_to_display_name(username)

        identity = PersonIdentity(
            display_name=display_name,
        )

        tag = "[CF] " if is_close_friend else ""
        if verbose or i % 100 == 0:
            print(f"  [{i}/{len(all_entries)}] {tag}@{username} ({relationship})", end="")

        try:
            # Resolve — fuzzy matching may pick up usernames that look like
            # real names (e.g. "belindaburwell" matches "Belinda Burwell")
            match = resolver.resolve(identity, use_fuzzy=True)

            if match and match.person_uri and match.match_type != "new":
                # Existing person — enrich with Instagram data
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
                        config.OXIGRAPH_URL,
                        person_uri,
                        person_id,
                        username,
                        profile_url,
                        connection_timestamp=timestamp,
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
                        username,
                        profile_url,
                        config.USER_ID,
                        config.DEFAULT_PRIVACY_LEVEL,
                        connection_timestamp=timestamp,
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
                embed_text_str = f"{display_name} instagram @{username}"
                try:
                    vector = embed_text(
                        config.EMBED_OLLAMA_URL, embed_text_str, config.EMBED_MODEL
                    )
                    upsert_qdrant(
                        qdrant,
                        config.QDRANT_COLLECTION,
                        person_id,
                        person_uri,
                        identity,
                        username,
                        profile_url,
                        vector,
                        config.DEFAULT_PRIVACY_LEVEL,
                        instagram_relationship=relationship,
                        is_close_friend=is_close_friend,
                        connection_timestamp=timestamp,
                    )
                except Exception as e:
                    if verbose:
                        print(f"    Qdrant/embed error: {e}")

        except Exception as e:
            if verbose or i % 100 == 0:
                print(f" → ERROR: {e}")
            counts["errors"] += 1
            continue

    print(
        f"\nDone: {counts['matched']} matched, {counts['created']} created, "
        f"{counts['skipped']} skipped, {counts['errors']} errors "
        f"(of {counts['total']} unique entries)"
    )
    print(
        f"  Sources: {counts['close_friends']} close friends, "
        f"{counts['followers']} followers, {counts['following']} following"
    )

    return counts


# ── CLI ──────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        description="Import Instagram social graph into PWG people graph"
    )
    parser.add_argument(
        "--dir",
        type=str,
        required=True,
        help="Path to Instagram connections/followers_and_following/ directory",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Parse and resolve but don't write"
    )
    parser.add_argument(
        "--limit", type=int, default=None, help="Process only first N entries"
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Print each connection"
    )
    args = parser.parse_args()

    if not os.path.isdir(args.dir):
        print(f"Directory not found: {args.dir}", file=sys.stderr)
        return 1

    # Validate config
    if not config.OXIGRAPH_URL:
        print(
            "OXIGRAPH_URL not configured. Set in .env or environment.",
            file=sys.stderr,
        )
        return 1
    if not config.QDRANT_URL:
        print(
            "QDRANT_URL not configured (Qdrant writes will be skipped).",
            file=sys.stderr,
        )

    counts = import_instagram(
        args.dir,
        dry_run=args.dry_run,
        limit=args.limit,
        verbose=args.verbose,
    )

    return 0 if counts["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
