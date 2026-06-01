"""Facebook Events Importer — reads event_invitations.json and
your_events.json from a Facebook GDPR export and stores life
timeline events in the PWG knowledge graph.

Stores event name, date, location (when available), and description
as PersonFacts about the user — these become timeline entries in the
wiki and are searchable via the assistant.

Usage:
    python -m contact_syncer.facebook_events \
        --dir /path/to/facebook/events/ \
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


def _fix_mojibake(text: str) -> str:
    """Fix Facebook's double-encoded UTF-8 (Latin-1 mojibake)."""
    try:
        return text.encode("latin-1").decode("utf-8")
    except (UnicodeDecodeError, UnicodeEncodeError):
        return text


def parse_events(events_dir: str) -> List[Dict[str, Any]]:
    """Parse Facebook event files and return unified event list."""
    events = []

    # Event invitations (largest set)
    inv_path = os.path.join(events_dir, "event_invitations.json")
    if os.path.exists(inv_path):
        data = json.load(open(inv_path, "r", encoding="utf-8"))
        inv_list = data.get("events_invited_v2", data if isinstance(data, list) else [])
        for inv in inv_list:
            name = _fix_mojibake(inv.get("name", ""))
            if not name:
                continue
            events.append({
                "name": name,
                "start_timestamp": inv.get("start_timestamp", 0),
                "end_timestamp": inv.get("end_timestamp", 0),
                "place": None,
                "description": "",
                "source": "facebook_invitation",
            })

    # User's own events (richer data)
    own_path = os.path.join(events_dir, "your_events.json")
    if os.path.exists(own_path):
        data = json.load(open(own_path, "r", encoding="utf-8"))
        own_list = data.get("your_events_v2", data if isinstance(data, list) else [])
        for ev in own_list:
            name = _fix_mojibake(ev.get("name", ""))
            if not name:
                continue
            place = ev.get("place", {})
            place_name = _fix_mojibake(place.get("name", "")) if place else ""
            description = _fix_mojibake(ev.get("description", ""))
            events.append({
                "name": name,
                "start_timestamp": ev.get("start_timestamp", 0),
                "end_timestamp": ev.get("end_timestamp", 0),
                "place": place_name,
                "description": description[:500],  # Truncate long descriptions
                "source": "facebook_event",
            })

    return events


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


def write_event_fact(
    oxigraph_url: str,
    event: Dict[str, Any],
    user_id: str,
) -> None:
    """Write an event as a PersonFact about the user."""
    ts = event["start_timestamp"]
    if ts:
        dt = datetime.fromtimestamp(ts, tz=timezone.utc)
        date_str = dt.strftime("%Y-%m-%dT%H:%M:%S+00:00")
        human_date = dt.strftime("%d %B %Y")
    else:
        date_str = datetime.now(timezone.utc).isoformat()
        human_date = "unknown date"

    name = _escape(event["name"])
    place = _escape(event.get("place") or "")
    source = event.get("source", "facebook_event")

    # Build fact text
    fact_text = f"Invited to '{event['name']}'"
    if source == "facebook_event":
        fact_text = f"Hosted/attended '{event['name']}'"
    if place:
        fact_text += f" at {event.get('place', '')}"
    fact_text += f" on {human_date}"
    fact_text = _escape(fact_text)

    fact_id = str(uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"pwg://facebook_event/{user_id}/{event['name']}/{ts}"
    ))
    fact_uri = f"https://pwg.dev/ontology#fact_{fact_id}"
    user_uri = f"https://pwg.dev/ontology#user_{user_id}"

    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        f"INSERT DATA {{\n"
        f'  <{fact_uri}> a pwg:PersonFact .\n'
        f'  <{fact_uri}> pwg:aboutPerson <{user_uri}> .\n'
        f'  <{fact_uri}> pwg:factText "{fact_text}" .\n'
        f'  <{fact_uri}> pwg:factSource "{source}" .\n'
        f'  <{fact_uri}> pwg:factDomain "social" .\n'
        f'  <{fact_uri}> pwg:validFrom "{date_str}"^^xsd:dateTime .\n'
        f'  <{fact_uri}> pwg:privacyLevel "L1" .\n'
        f'  <{fact_uri}> pwg:belongsToUser <{user_uri}> .\n'
        f"}}"
    )
    _sparql_update(oxigraph_url, sparql)


# ── Main ─────────────────────────────────────────────────────────────


def import_events(
    events_dir: str,
    *,
    dry_run: bool = False,
    verbose: bool = False,
) -> Dict[str, int]:
    """Import Facebook events as timeline facts."""
    events = parse_events(events_dir)
    print(f"Parsed {len(events)} events")

    counts = {"total": len(events), "written": 0, "errors": 0}

    for i, event in enumerate(events, 1):
        ts = event["start_timestamp"]
        dt = datetime.fromtimestamp(ts, tz=timezone.utc) if ts else None
        date_str = dt.strftime("%Y-%m-%d") if dt else "?"

        if verbose:
            place = event.get("place") or ""
            print(f"  [{i}/{len(events)}] {date_str} — {event['name'][:60]}"
                  + (f" @ {place[:30]}" if place else ""))

        try:
            if not dry_run:
                write_event_fact(config.OXIGRAPH_URL, event, config.USER_ID)
            counts["written"] += 1
        except Exception as e:
            if verbose:
                print(f"    ERROR: {e}")
            counts["errors"] += 1

    print(f"\nDone: {counts['written']} events written, {counts['errors']} errors "
          f"(of {counts['total']} total)")
    return counts


def main():
    # Audit ref /tmp/silent_fail_audit_2026-05-04.md HIGH-4.
    config.validate_required(require_oxigraph=True)
    parser = argparse.ArgumentParser(
        description="Import Facebook events as PWG timeline facts"
    )
    parser.add_argument("--dir", type=str, required=True,
                        help="Path to Facebook events/ directory")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    if not os.path.isdir(args.dir):
        print(f"Directory not found: {args.dir}", file=sys.stderr)
        return 1

    if not config.OXIGRAPH_URL:
        print("OXIGRAPH_URL not configured.", file=sys.stderr)
        return 1

    counts = import_events(args.dir, dry_run=args.dry_run, verbose=args.verbose)
    return 0 if counts["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
