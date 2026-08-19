"""WhatsApp Contacts Cross-Reference — matches phone numbers from
WhatsApp's GDPR export against the PWG people graph.

The WhatsApp GDPR account info export includes contacts.json with
phone numbers in E.164 format (+852..., +44...). These are cross-
referenced against existing people graph nodes that have phone
identifiers from iCloud contacts.

Usage:
    python -m contact_syncer.whatsapp_contacts \
        --json /path/to/contacts.json \
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


# ── Parsing ──────────────────────────────────────────────────────────


def parse_whatsapp_contacts(json_path: str) -> List[str]:
    """Parse WhatsApp contacts.json and extract phone numbers."""
    data = json.load(open(json_path, "r", encoding="utf-8"))
    phones = data.get("wa_contacts", [])
    # Filter out empty strings and deduplicate
    return sorted(set(p.strip() for p in phones if p and p.strip()))


# ── Oxigraph phone lookup ────────────────────────────────────────────


def find_person_by_phone(oxigraph_url: str, phone: str) -> Optional[str]:
    """Query Oxigraph for a person with this phone number.

    Uses last 8 digits for fuzzy matching since phone formats vary
    across sources (iCloud stores differently than WhatsApp).
    """
    # Normalize: strip everything except digits and +
    normalized = "".join(c for c in phone if c.isdigit() or c == "+")
    if len(normalized) < 8:
        return None

    # Use last 8 digits for matching (avoids country code format issues)
    suffix = normalized[-8:]

    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        f'SELECT ?person WHERE {{\n'
        f'  ?person pwg:hasIdentifier ?id .\n'
        f'  ?id pwg:identifierType "phone" .\n'
        f'  ?id pwg:identifierValue ?val .\n'
        f'  FILTER(CONTAINS(?val, "{suffix}"))\n'
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


def write_whatsapp_signal(oxigraph_url: str, person_uri: str, phone: str, user_id: str) -> None:
    """Write a whatsapp_contact signal + add phone as identifier."""
    signal_id = str(uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"pwg://whatsapp_contact/{person_uri}"
    ))
    signal_uri = f"https://pwg.dev/ontology#signal_{signal_id}"
    now = datetime.now(timezone.utc).isoformat()

    # Add signal
    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        f"INSERT DATA {{\n"
        f'  <{signal_uri}> a pwg:RelationshipSignal .\n'
        f'  <{signal_uri}> pwg:about <{person_uri}> .\n'
        f'  <{signal_uri}> pwg:signalType "whatsapp_contact" .\n'
        f'  <{signal_uri}> pwg:signalDate "{now}"^^xsd:dateTime .\n'
        f'  <{signal_uri}> pwg:userId "{user_id}" .\n'
        f"}}"
    )
    _sparql_update(oxigraph_url, sparql)


# ── Main ─────────────────────────────────────────────────────────────


def cross_reference(
    json_path: str,
    *,
    dry_run: bool = False,
    verbose: bool = False,
) -> Dict[str, int]:
    """Cross-reference WhatsApp contacts against the people graph."""
    phones = parse_whatsapp_contacts(json_path)
    print(f"Parsed {len(phones)} unique WhatsApp phone numbers")

    counts = {"total": len(phones), "matched": 0, "not_matched": 0,
              "signals_written": 0, "errors": 0}

    for i, phone in enumerate(phones, 1):
        if verbose or i % 100 == 0:
            print(f"  [{i}/{len(phones)}] {phone[:7]}***", end="")

        try:
            person_uri = find_person_by_phone(config.OXIGRAPH_URL, phone)

            if person_uri:
                person_name = person_uri.split("person_")[-1] if "person_" in person_uri else "?"
                if verbose:
                    print(f" → MATCH ({person_name[:20]})")
                counts["matched"] += 1

                if not dry_run:
                    write_whatsapp_signal(config.OXIGRAPH_URL, person_uri, phone, config.USER_ID)
                    counts["signals_written"] += 1
            else:
                if verbose:
                    print(f" → no match")
                counts["not_matched"] += 1

        except Exception as e:
            if verbose:
                print(f" → ERROR: {e}")
            counts["errors"] += 1

    print(f"\nDone: {counts['matched']} matched out of {counts['total']} "
          f"({counts['signals_written']} signals written, {counts['errors']} errors)")

    return counts


def main():
    # Audit ref /tmp/silent_fail_audit_2026-05-04.md HIGH-4.
    config.validate_required(require_oxigraph=True)
    parser = argparse.ArgumentParser(
        description="Cross-reference WhatsApp contacts against PWG people graph"
    )
    parser.add_argument("--json", type=str, required=True, help="Path to contacts.json")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    if not os.path.isfile(args.json):
        print(f"File not found: {args.json}", file=sys.stderr)
        return 1

    if not config.OXIGRAPH_URL:
        print("OXIGRAPH_URL not configured.", file=sys.stderr)
        return 1

    counts = cross_reference(args.json, dry_run=args.dry_run, verbose=args.verbose)
    return 0 if counts["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
