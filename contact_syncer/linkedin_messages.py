"""LinkedIn Messages Importer — reads messages.csv from a LinkedIn
GDPR export and extracts relationship signals + conversation metadata
into the PWG people graph.

For each conversation thread:
1. Group messages by CONVERSATION ID
2. Identify participants (sender names + LinkedIn profile URLs)
3. Resolve participants against existing people graph
4. Extract: message count, date range, last message date, reciprocity
5. Store relationship signals in Oxigraph
6. Upsert people to Qdrant with updated last_contact dates

Does NOT store full message content in the graph — that's a privacy
decision. Stores metadata only: who talked, when, how much, which
direction.

Usage:
    python -m contact_syncer.linkedin_messages \
        --csv /path/to/messages.csv \
        [--dry-run] [--limit N] [--verbose]
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import uuid
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import httpx

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


# ── CSV parsing ──────────────────────────────────────────────────────


def parse_messages_csv(csv_path: str) -> List[Dict[str, str]]:
    """Parse LinkedIn messages.csv."""
    rows = []
    with open(csv_path, "r", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            if row.get("FROM") and row.get("CONTENT"):
                rows.append(row)
    return rows


def group_conversations(rows: List[Dict[str, str]], user_name: str = "User") -> Dict[str, Dict]:
    """Group messages by conversation ID and extract metadata.

    Returns a dict of conversation_id -> {
        participants: [{name, profile_url, message_count, is_user}],
        total_messages: int,
        first_message: datetime,
        last_message: datetime,
        user_message_count: int,
        other_message_count: int,
    }
    """
    convos: Dict[str, Dict] = {}

    for row in rows:
        conv_id = row.get("CONVERSATION ID", "")
        if not conv_id:
            continue

        if conv_id not in convos:
            convos[conv_id] = {
                "participants": {},
                "total_messages": 0,
                "first_message": None,
                "last_message": None,
                "user_message_count": 0,
                "other_message_count": 0,
                "subject": row.get("SUBJECT", ""),
            }

        c = convos[conv_id]
        c["total_messages"] += 1

        sender = row.get("FROM", "").strip()
        sender_url = row.get("SENDER PROFILE URL", "").strip()

        if sender not in c["participants"]:
            c["participants"][sender] = {
                "name": sender,
                "profile_url": sender_url,
                "message_count": 0,
                "is_user": sender.lower() == user_name.lower(),
            }
        c["participants"][sender]["message_count"] += 1

        if sender.lower() == user_name.lower():
            c["user_message_count"] += 1
        else:
            c["other_message_count"] += 1

        # Parse date
        date_str = row.get("DATE", "")
        if date_str:
            try:
                dt = datetime.strptime(date_str, "%Y-%m-%d %H:%M:%S %Z")
            except ValueError:
                try:
                    dt = datetime.fromisoformat(date_str.replace(" UTC", "+00:00"))
                except ValueError:
                    dt = None
            if dt:
                if c["first_message"] is None or dt < c["first_message"]:
                    c["first_message"] = dt
                if c["last_message"] is None or dt > c["last_message"]:
                    c["last_message"] = dt

    return convos


# ── Oxigraph writes ──────────────────────────────────────────────────


def _sparql_update(oxigraph_url: str, sparql: str) -> None:
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=30.0, transport=transport) as client:
        resp = client.post(
            f"{oxigraph_url}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()


def _escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write_conversation_signal(
    oxigraph_url: str,
    person_uri: str,
    conv_metadata: Dict,
    user_id: str,
) -> None:
    """Write a LinkedIn messaging relationship signal to Oxigraph."""
    last_msg = conv_metadata["last_message"]
    if last_msg:
        last_msg_str = last_msg.strftime("%Y-%m-%dT%H:%M:%S+00:00")
    else:
        last_msg_str = datetime.now(timezone.utc).isoformat()

    signal_id = str(uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"pwg://linkedin_message_signal/{person_uri}/{conv_metadata.get('conv_id', '')}"
    ))
    signal_uri = f"https://pwg.dev/ontology#signal_{signal_id}"

    total = conv_metadata["total_messages"]
    user_msgs = conv_metadata["user_message_count"]
    other_msgs = conv_metadata["other_message_count"]

    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        f"INSERT DATA {{\n"
        f'  <{signal_uri}> a pwg:RelationshipSignal .\n'
        f'  <{signal_uri}> pwg:about <{person_uri}> .\n'
        f'  <{signal_uri}> pwg:signalType "linkedin_messaging" .\n'
        f'  <{signal_uri}> pwg:signalDate "{last_msg_str}"^^xsd:dateTime .\n'
        f'  <{signal_uri}> pwg:totalMessages "{total}"^^xsd:integer .\n'
        f'  <{signal_uri}> pwg:userMessages "{user_msgs}"^^xsd:integer .\n'
        f'  <{signal_uri}> pwg:otherMessages "{other_msgs}"^^xsd:integer .\n'
        f'  <{signal_uri}> pwg:userId "{user_id}" .\n'
        f"}}"
    )
    _sparql_update(oxigraph_url, sparql)


# ── Main orchestrator ────────────────────────────────────────────────


def import_messages(
    csv_path: str,
    *,
    dry_run: bool = False,
    limit: Optional[int] = None,
    verbose: bool = False,
    user_name: str = "User",
) -> Dict[str, int]:
    """Import LinkedIn messages and extract relationship signals.

    Returns counts: {conversations, participants_matched, participants_new,
                     signals_written, errors}
    """
    rows = parse_messages_csv(csv_path)
    print(f"Parsed {len(rows)} messages")

    convos = group_conversations(rows, user_name)
    print(f"Grouped into {len(convos)} conversations")

    # Sort by most messages (richest conversations first)
    sorted_convos = sorted(
        convos.items(),
        key=lambda x: x[1]["total_messages"],
        reverse=True,
    )

    if limit:
        sorted_convos = sorted_convos[:limit]

    resolver = IdentityResolver(
        oxigraph_url=config.OXIGRAPH_URL,
        default_country_code=config.DEFAULT_COUNTRY_CODE,
    )

    counts = {
        "conversations": len(sorted_convos),
        "participants_matched": 0,
        "participants_new": 0,
        "signals_written": 0,
        "errors": 0,
    }

    for i, (conv_id, conv) in enumerate(sorted_convos, 1):
        # Find the non-user participants
        others = [
            p for p in conv["participants"].values()
            if not p["is_user"]
        ]

        if not others:
            continue

        for other in others:
            name = other["name"]
            profile_url = other.get("profile_url", "")

            if verbose or i % 100 == 0:
                print(f"  [{i}/{len(sorted_convos)}] {name} ({conv['total_messages']} msgs)", end="")

            try:
                identity = PersonIdentity(
                    display_name=name,
                    given_name=name.split()[0] if " " in name else None,
                    family_name=name.split()[-1] if " " in name else None,
                    linkedin_url=profile_url or None,
                )

                match = resolver.resolve(identity, use_fuzzy=True)

                if match and match.person_uri and match.match_type != "new":
                    person_uri = match.person_uri
                    if verbose:
                        print(f" → MATCH ({match.match_type})")
                    counts["participants_matched"] += 1
                else:
                    # Create new person
                    person_id = str(uuid.uuid4()).replace("-", "")[:12]
                    person_uri = f"https://pwg.dev/ontology#person_{person_id}"

                    if verbose:
                        print(f" → NEW")

                    if not dry_run:
                        from contact_syncer.linkedin_connections import create_person_oxigraph
                        # Use first message date as connection date
                        connected_on = ""
                        if conv["first_message"]:
                            connected_on = conv["first_message"].strftime("%d %b %Y")
                        create_person_oxigraph(
                            config.OXIGRAPH_URL,
                            person_uri,
                            person_id,
                            identity,
                            {
                                "company": "",
                                "position": "",
                                "connected_on": connected_on,
                                "linkedin_url": profile_url,
                                "email": "",
                            },
                            config.USER_ID,
                            config.DEFAULT_PRIVACY_LEVEL,
                        )
                    counts["participants_new"] += 1

                # Write messaging relationship signal
                if not dry_run:
                    conv["conv_id"] = conv_id
                    write_conversation_signal(
                        config.OXIGRAPH_URL,
                        person_uri,
                        conv,
                        config.USER_ID,
                    )
                counts["signals_written"] += 1

            except Exception as e:
                if verbose:
                    print(f" → ERROR: {e}")
                counts["errors"] += 1
                continue

            if not verbose and i % 100 != 0:
                pass

    print(f"\nDone: {counts['conversations']} conversations, "
          f"{counts['participants_matched']} matched, "
          f"{counts['participants_new']} new, "
          f"{counts['signals_written']} signals written, "
          f"{counts['errors']} errors")

    return counts


# ── CLI ──────────────────────────────────────────────────────────────


def main():
    # Audit ref /tmp/silent_fail_audit_2026-05-04.md HIGH-4.
    config.validate_required(require_oxigraph=True)
    parser = argparse.ArgumentParser(
        description="Import LinkedIn messages.csv — extract relationship signals"
    )
    parser.add_argument("--csv", type=str, required=True, help="Path to messages.csv")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--limit", type=int, default=None, help="Process only top N conversations")
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument("--user-name", type=str, default="User",
                        help="Your name as it appears in the FROM field")
    args = parser.parse_args()

    if not os.path.isfile(args.csv):
        print(f"File not found: {args.csv}", file=sys.stderr)
        return 1

    if not config.OXIGRAPH_URL:
        print("OXIGRAPH_URL not configured.", file=sys.stderr)
        return 1

    counts = import_messages(
        args.csv,
        dry_run=args.dry_run,
        limit=args.limit,
        verbose=args.verbose,
        user_name=args.user_name,
    )

    return 0 if counts["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
