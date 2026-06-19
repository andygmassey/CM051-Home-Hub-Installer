"""Twitter/X Contacts Cross-Reference — matches phone numbers from
Twitter's synced contacts against the PWG people graph.

Twitter's GDPR export includes contacts synced from the user's phone
(contact.js). These are phone numbers only — no names. But the
people graph already has phone numbers from iCloud contacts, so we
can cross-reference to discover "which of my contacts are on Twitter."

This adds a "twitter_synced_contact" relationship signal to matched
people — confirming the user has this person's phone number AND
they're on Twitter.

Usage:
    python -m contact_syncer.twitter_contacts \
        --js /path/to/contact.js \
        [--dry-run] [--verbose]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import httpx

_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from contact_syncer import config
from contact_syncer import privacy_model as _pm


# ── Parsing ──────────────────────────────────────────────────────────


def parse_twitter_contacts(js_path: str) -> List[str]:
    """Parse contact.js and extract unique phone numbers.

    Twitter JS files start with 'window.YTD...' prefix before the JSON.
    """
    content = open(js_path, "r", encoding="utf-8").read()
    json_start = content.find("[")
    if json_start < 0:
        return []

    data = json.loads(content[json_start:])
    phones = set()
    for entry in data:
        contact = entry.get("contact", {})
        for phone in contact.get("phoneNumbers", []):
            if phone and phone.strip():
                phones.add(phone.strip())
        for email in contact.get("emails", []):
            if email and email.strip():
                # Could cross-ref emails too, but phone is primary
                pass
    return sorted(phones)


# ── Oxigraph phone lookup ────────────────────────────────────────────


def find_person_by_phone(oxigraph_url: str, phone: str) -> Optional[str]:
    """Query Oxigraph for a person with this phone number as an identifier.

    Returns person_uri or None.
    """
    # Normalize phone: strip all non-digit chars, use last 8 digits for matching.
    # Twitter stores phones in varied formats:
    #   +85255550123, (001)2125551234, (0044)7700900123, 07700900123
    # Parenthetical country codes and leading zeros are common.
    digits_only = "".join(c for c in phone if c.isdigit())
    if len(digits_only) < 8:
        return None
    normalized = digits_only

    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        f'SELECT ?person WHERE {{\n'
        f'  ?person pwg:hasIdentifier ?id .\n'
        f'  ?id pwg:identifierType "phone" .\n'
        f'  ?id pwg:identifierValue ?val .\n'
        f'  FILTER(CONTAINS(?val, "{normalized[-8:]}"))\n'
        f'}} LIMIT 1'
    )

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
        results = resp.json()

    bindings = results.get("results", {}).get("bindings", [])
    if bindings:
        return bindings[0].get("person", {}).get("value")
    return None


def _sparql_update(oxigraph_url: str, sparql: str) -> None:
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=30.0, transport=transport) as client:
        resp = client.post(
            f"{oxigraph_url}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()


def write_twitter_signal(oxigraph_url: str, person_uri: str, user_id: str) -> None:
    """Write a twitter_synced_contact signal to Oxigraph."""
    signal_id = str(uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"pwg://twitter_contact/{person_uri}"
    ))
    signal_uri = f"https://pwg.dev/ontology#signal_{signal_id}"
    now = datetime.now(timezone.utc).isoformat()

    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        f"INSERT DATA {{\n"
        f'  <{signal_uri}> a pwg:RelationshipSignal .\n'
        f'  <{signal_uri}> pwg:about <{person_uri}> .\n'
        f'  <{signal_uri}> pwg:signalType "twitter_synced_contact" .\n'
        f'  <{signal_uri}> pwg:privacyLevel "{_pm.level_for(rdf_type="RelationshipSignal", source="twitter_synced_contact")}" .\n'
        f'  <{signal_uri}> pwg:signalDate "{now}"^^xsd:dateTime .\n'
        f'  <{signal_uri}> pwg:userId "{user_id}" .\n'
        f"}}"
    )
    _sparql_update(oxigraph_url, sparql)


# ── Main ─────────────────────────────────────────────────────────────


def cross_reference(
    js_path: str,
    *,
    dry_run: bool = False,
    verbose: bool = False,
) -> Dict[str, int]:
    """Cross-reference Twitter synced contacts against the people graph.

    Returns counts: {total_phones, matched, not_matched, signals_written, errors}
    """
    phones = parse_twitter_contacts(js_path)
    print(f"Parsed {len(phones)} unique phone numbers from Twitter contacts")

    counts = {"total_phones": len(phones), "matched": 0, "not_matched": 0,
              "signals_written": 0, "errors": 0}

    for i, phone in enumerate(phones, 1):
        if verbose or i % 200 == 0:
            print(f"  [{i}/{len(phones)}] {phone[:6]}***", end="")

        try:
            person_uri = find_person_by_phone(config.OXIGRAPH_URL, phone)

            if person_uri:
                if verbose:
                    print(f" → MATCH ({person_uri.split('#')[-1]})")
                counts["matched"] += 1

                if not dry_run:
                    write_twitter_signal(config.OXIGRAPH_URL, person_uri, config.USER_ID)
                    counts["signals_written"] += 1
            else:
                if verbose:
                    print(f" → no match")
                counts["not_matched"] += 1

        except Exception as e:
            if verbose:
                print(f" → ERROR: {e}")
            counts["errors"] += 1

    print(f"\nDone: {counts['matched']} matched out of {counts['total_phones']} "
          f"({counts['signals_written']} signals written, {counts['errors']} errors)")

    return counts


def main():
    parser = argparse.ArgumentParser(
        description="Cross-reference Twitter synced contacts against PWG people graph"
    )
    parser.add_argument("--js", type=str, required=True, help="Path to contact.js")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    if not os.path.isfile(args.js):
        print(f"File not found: {args.js}", file=sys.stderr)
        return 1

    if not config.OXIGRAPH_URL:
        print("OXIGRAPH_URL not configured.", file=sys.stderr)
        return 1

    counts = cross_reference(args.js, dry_run=args.dry_run, verbose=args.verbose)
    return 0 if counts["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
