"""Backfill vCard PHOTO data onto existing Person records.

The original ``contact_syncer`` run never extracted PHOTO — PLAN.md used to
exclude it as "binary data, not useful for knowledge graph". That decision
predates the CM031 iOS Companion, which needs faces. This one-shot script
revisits every vCard in the CardDAV source and, for contacts whose Person
node is already in the graph, adds the photo without rebuilding anything
else.

Side effects per contact (only with ``--apply``):
  - write raw bytes to ``PHOTO_DIR/<person_uri_hash>.<ext>``
  - DELETE+INSERT a ``foaf:img <file://...>`` triple on the Person node
  - Qdrant ``set_payload`` adds ``profile_photo_path`` (no re-embedding)

Dry run is the default so this can be run against production to size the
change before committing any writes.

Usage::

    python -m contact_syncer.backfill_photos              # dry run
    python -m contact_syncer.backfill_photos --apply      # write
    python -m contact_syncer.backfill_photos --apply -v
"""
from __future__ import annotations

import argparse
import os
import sys
import uuid
from typing import Any, Dict, Optional

import httpx

_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from qdrant_client import QdrantClient

from contact_syncer import config
from contact_syncer.carddav import CardDAVClient
from contact_syncer.photo_storage import write_photo
from contact_syncer.vcard_parser import parse_vcard


def find_person_uri_by_icloud_uid(oxigraph_url: str, uid: str) -> Optional[str]:
    """Look up the Person URI already in Oxigraph for a given iCloud UID."""
    safe_uid = uid.replace("\\", "\\\\").replace('"', '\\"')
    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "SELECT ?person WHERE {\n"
        "  ?person a pwg:Person ;\n"
        "          pwg:hasIdentifier ?id .\n"
        '  ?id pwg:identifierType "icloud_contact_uid" ;\n'
        f'      pwg:identifierValue "{safe_uid}" .\n'
        "} LIMIT 1"
    )
    resp = httpx.post(
        f"{oxigraph_url}/query",
        content=sparql,
        headers={
            "Content-Type": "application/sparql-query",
            "Accept": "application/sparql-results+json",
        },
        timeout=30.0,
    )
    resp.raise_for_status()
    bindings = resp.json().get("results", {}).get("bindings", [])
    return bindings[0]["person"]["value"] if bindings else None


def write_foaf_img(oxigraph_url: str, person_uri: str, path: str) -> None:
    """Idempotently set foaf:img on a Person — DELETE any existing, then INSERT."""
    for sparql in (
        (
            "PREFIX foaf: <http://xmlns.com/foaf/0.1/>\n"
            f"DELETE WHERE {{ <{person_uri}> foaf:img ?o . }}"
        ),
        (
            "PREFIX foaf: <http://xmlns.com/foaf/0.1/>\n"
            "INSERT DATA {\n"
            f"  <{person_uri}> foaf:img <file://{path}> .\n"
            "}"
        ),
    ):
        resp = httpx.post(
            f"{oxigraph_url}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
            timeout=30.0,
        )
        resp.raise_for_status()


def set_qdrant_photo_path(
    qdrant: QdrantClient, collection: str, person_uri: str, path: str
) -> None:
    """Patch profile_photo_path onto the existing Qdrant point (no re-embed)."""
    point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, person_uri))
    qdrant.set_payload(
        collection_name=collection,
        payload={"profile_photo_path": path},
        points=[point_id],
    )


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument(
        "--apply",
        action="store_true",
        help="Actually write. Default is dry run — reports counts only.",
    )
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()

    dry = not args.apply
    if dry:
        print("DRY RUN — no writes. Pass --apply to commit.")

    if not config.CARDDAV_URL or not config.OXIGRAPH_URL or not config.QDRANT_URL:
        print(
            "ERROR: CARDDAV_URL / OXIGRAPH_URL / QDRANT_URL must all be set "
            "(via environment or contact_syncer/.env)."
        )
        return 2

    carddav = CardDAVClient(
        url=config.CARDDAV_URL,
        username=config.CARDDAV_USERNAME,
        password=config.CARDDAV_PASSWORD,
    )

    print("Fetching all vCards from CardDAV...")
    vcards = carddav.get_all_vcards()
    total = len(vcards)
    print(f"  {total} cards")

    qdrant = QdrantClient(url=config.QDRANT_URL)

    stats: Dict[str, int] = {
        "total": total,
        "no_photo": 0,
        "no_uid": 0,
        "no_matching_person": 0,
        "parse_error": 0,
        "write_error": 0,
        "would_write": 0,
        "wrote": 0,
    }

    for i, vcard_text in enumerate(vcards, 1):
        if i % 200 == 0 or i == total:
            print(
                f"  [{i}/{total}] wrote={stats['wrote']} "
                f"would={stats['would_write']} "
                f"no_photo={stats['no_photo']} "
                f"no_match={stats['no_matching_person']}"
            )

        try:
            parsed: Dict[str, Any] = parse_vcard(vcard_text)
        except Exception as exc:
            stats["parse_error"] += 1
            if args.verbose:
                print(f"    parse failed: {exc}")
            continue

        if not parsed.get("photo"):
            stats["no_photo"] += 1
            continue

        uid = parsed.get("uid")
        if not uid:
            stats["no_uid"] += 1
            continue

        try:
            person_uri = find_person_uri_by_icloud_uid(config.OXIGRAPH_URL, uid)
        except Exception as exc:
            if args.verbose:
                print(f"    lookup failed for uid={uid}: {exc}")
            person_uri = None

        if not person_uri:
            stats["no_matching_person"] += 1
            if args.verbose:
                print(f"    no Person for uid={uid} fn={parsed.get('fn')!r}")
            continue

        if dry:
            stats["would_write"] += 1
            if args.verbose:
                photo = parsed["photo"]
                print(
                    f"    WOULD write {person_uri} "
                    f"(mime={photo['mime']}, {len(photo['data'])} bytes)"
                )
            continue

        try:
            path = write_photo(
                person_uri=person_uri,
                data=parsed["photo"]["data"],
                ext=parsed["photo"]["ext"],
                base_dir=config.PHOTO_DIR,
            )
            write_foaf_img(config.OXIGRAPH_URL, person_uri, path)
            set_qdrant_photo_path(
                qdrant, config.QDRANT_COLLECTION, person_uri, path
            )
            stats["wrote"] += 1
            if args.verbose:
                print(f"    wrote {path} for {person_uri}")
        except Exception as exc:
            stats["write_error"] += 1
            print(f"    ERROR writing for {person_uri}: {exc}")

    print()
    print("=" * 60)
    print(f"Total vCards:          {stats['total']}")
    print(f"  Parse errors:        {stats['parse_error']}")
    print(f"  No PHOTO:            {stats['no_photo']}")
    print(f"  No UID:              {stats['no_uid']}")
    print(f"  No matching Person:  {stats['no_matching_person']}")
    if dry:
        print(f"  Would write:         {stats['would_write']}")
        print("\nThis was a dry run. Pass --apply to commit.")
    else:
        print(f"  Wrote:               {stats['wrote']}")
        print(f"  Write errors:        {stats['write_error']}")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
