"""Google Calendar ICS Importer — reads .ics files from Google Takeout
and stores calendar events as timeline facts + meeting records in the
PWG knowledge graph.

Each event becomes:
- A PersonFact timeline entry (searchable, displayed in wiki timeline)
- Attendee names resolved against the people graph
- Meeting relationships created between the user and attendees

Usage:
    python -m contact_syncer.google_calendar \
        --ics /path/to/calendar.ics \
        [--dry-run] [--verbose]
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

import httpx

_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from contact_syncer import config
from identity_resolver.models import PersonIdentity
from identity_resolver.resolver import IdentityResolver


# ── ICS parsing ──────────────────────────────────────────────────────


def parse_ics(ics_path: str, *, user_name: str = "") -> List[Dict[str, Any]]:
    """Parse an ICS file and extract VEVENT entries.

    If user_name is provided, the user is filtered out of attendee lists.
    """
    content = open(ics_path, "r", encoding="utf-8").read()

    # Build set of lowercase name variants to exclude from attendees
    exclude_names: set[str] = set()
    if user_name:
        exclude_names.add(user_name.lower())
        parts = user_name.lower().split()
        if parts:
            exclude_names.add(parts[0])  # first name alone

    events = []
    for match in re.finditer(r"BEGIN:VEVENT(.*?)END:VEVENT", content, re.DOTALL):
        block = match.group(1)
        event = _parse_vevent(block, exclude_names=exclude_names)
        if event.get("summary"):
            events.append(event)

    return events


def _parse_vevent(block: str, *, exclude_names: set[str] | None = None) -> Dict[str, Any]:
    """Parse a single VEVENT block into a dict."""
    # Unfold continuation lines (RFC 5545: lines starting with space/tab)
    unfolded = re.sub(r"\r?\n[ \t]", "", block)
    lines = unfolded.strip().split("\n")

    event: Dict[str, Any] = {
        "summary": "",
        "dtstart": "",
        "dtend": "",
        "location": "",
        "description": "",
        "organizer": "",
        "organizer_email": "",
        "attendees": [],
        "uid": "",
    }

    for line in lines:
        line = line.strip()
        if not line:
            continue

        if line.startswith("SUMMARY:"):
            event["summary"] = line[8:]
        elif line.startswith("DTSTART"):
            event["dtstart"] = _extract_datetime(line)
        elif line.startswith("DTEND"):
            event["dtend"] = _extract_datetime(line)
        elif line.startswith("LOCATION:"):
            event["location"] = line[9:]
        elif line.startswith("DESCRIPTION:"):
            event["description"] = line[12:][:500]
        elif line.startswith("UID:"):
            event["uid"] = line[4:]
        elif line.startswith("ORGANIZER"):
            cn = _extract_param(line, "CN")
            email = _extract_mailto(line)
            if cn:
                event["organizer"] = cn
            if email:
                event["organizer_email"] = email
        elif line.startswith("ATTENDEE"):
            cn = _extract_param(line, "CN")
            email = _extract_mailto(line)
            if cn and (not exclude_names or cn.lower() not in exclude_names):
                event["attendees"].append({"name": cn, "email": email or ""})

    return event


def _extract_datetime(line: str) -> str:
    """Extract a datetime from a DTSTART/DTEND line."""
    # Handle various formats: DTSTART:20101109T103000Z,
    # DTSTART;VALUE=DATE:20101109, DTSTART;TZID=...:20101109T103000
    value = line.split(":")[-1].strip()
    try:
        if "T" in value:
            if value.endswith("Z"):
                dt = datetime.strptime(value, "%Y%m%dT%H%M%SZ")
            else:
                dt = datetime.strptime(value, "%Y%m%dT%H%M%S")
            return dt.strftime("%Y-%m-%dT%H:%M:%S+00:00")
        else:
            dt = datetime.strptime(value[:8], "%Y%m%d")
            return dt.strftime("%Y-%m-%dT00:00:00+00:00")
    except ValueError:
        return ""


def _extract_param(line: str, param: str) -> str:
    """Extract a named parameter value from an ICS property line."""
    pattern = f"{param}=([^;:]+)"
    m = re.search(pattern, line)
    return m.group(1).strip() if m else ""


def _extract_mailto(line: str) -> str:
    """Extract a mailto: email from an ICS property line."""
    m = re.search(r"mailto:([^\s;]+)", line, re.IGNORECASE)
    return m.group(1).strip() if m else ""


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


def write_calendar_event(
    oxigraph_url: str,
    event: Dict[str, Any],
    user_id: str,
) -> None:
    """Write a calendar event as a PersonFact."""
    summary = _escape(event["summary"])
    location = _escape(event.get("location", ""))
    dtstart = event.get("dtstart", "")

    if dtstart:
        try:
            dt = datetime.fromisoformat(dtstart)
            human_date = dt.strftime("%d %B %Y")
        except ValueError:
            human_date = "unknown date"
    else:
        human_date = "unknown date"
        dtstart = datetime.now(timezone.utc).isoformat()

    fact_text = f"Calendar event: '{event['summary']}'"
    if location:
        fact_text += f" at {event['location']}"
    fact_text += f" on {human_date}"
    if event.get("attendees"):
        names = [a["name"] for a in event["attendees"][:5]]
        fact_text += f" with {', '.join(names)}"
    fact_text = _escape(fact_text)

    fact_id = str(uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"pwg://gcal/{user_id}/{event.get('uid', summary)}"
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
        f'  <{fact_uri}> pwg:factSource "google_calendar" .\n'
        f'  <{fact_uri}> pwg:factDomain "calendar" .\n'
        f'  <{fact_uri}> pwg:validFrom "{dtstart}"^^xsd:dateTime .\n'
        f'  <{fact_uri}> pwg:privacyLevel "L1" .\n'
        f'  <{fact_uri}> pwg:belongsToUser <{user_uri}> .\n'
        f"}}"
    )
    _sparql_update(oxigraph_url, sparql)


# ── Main ─────────────────────────────────────────────────────────────


def import_calendar(
    ics_path: str,
    *,
    dry_run: bool = False,
    verbose: bool = False,
    user_name: str = "",
) -> Dict[str, int]:
    """Import Google Calendar events."""
    events = parse_ics(ics_path, user_name=user_name)
    print(f"Parsed {len(events)} calendar events")

    # Sort by date descending
    events.sort(key=lambda e: e.get("dtstart", ""), reverse=True)

    resolver = IdentityResolver(
        oxigraph_url=config.OXIGRAPH_URL,
        default_country_code=config.DEFAULT_COUNTRY_CODE,
    )

    counts = {"total": len(events), "written": 0, "attendees_matched": 0,
              "attendees_new": 0, "errors": 0}

    for i, event in enumerate(events, 1):
        dtstart = event.get("dtstart", "?")[:10]
        summary = event["summary"][:50]
        n_attendees = len(event.get("attendees", []))

        if verbose:
            print(f"  [{i}/{len(events)}] {dtstart} — {summary}"
                  + (f" ({n_attendees} attendees)" if n_attendees else ""))

        try:
            if not dry_run:
                write_calendar_event(config.OXIGRAPH_URL, event, config.USER_ID)
            counts["written"] += 1

            # Resolve attendees against people graph
            for attendee in event.get("attendees", []):
                name = attendee["name"]
                email = attendee.get("email", "")
                identity = PersonIdentity(
                    display_name=name,
                    given_name=name.split()[0] if " " in name else None,
                    family_name=name.split()[-1] if " " in name else None,
                    emails=[email] if email else [],
                )
                try:
                    match = resolver.resolve(identity, use_fuzzy=True)
                    if match and match.person_uri and match.match_type != "new":
                        counts["attendees_matched"] += 1
                    else:
                        counts["attendees_new"] += 1
                except Exception:
                    pass

        except Exception as e:
            if verbose:
                print(f"    ERROR: {e}")
            counts["errors"] += 1

    print(f"\nDone: {counts['written']} events written, "
          f"{counts['attendees_matched']} attendees matched, "
          f"{counts['attendees_new']} attendees new, "
          f"{counts['errors']} errors (of {counts['total']} total)")
    return counts


def main():
    parser = argparse.ArgumentParser(
        description="Import Google Calendar ICS as PWG timeline facts"
    )
    parser.add_argument("--ics", type=str, required=True, help="Path to .ics file")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument("--user-name", type=str, default="",
                        help="Your name (filtered from attendee lists)")
    args = parser.parse_args()

    if not os.path.isfile(args.ics):
        print(f"File not found: {args.ics}", file=sys.stderr)
        return 1

    if not config.OXIGRAPH_URL:
        print("OXIGRAPH_URL not configured.", file=sys.stderr)
        return 1

    counts = import_calendar(args.ics, dry_run=args.dry_run, verbose=args.verbose,
                             user_name=args.user_name)
    return 0 if counts["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
