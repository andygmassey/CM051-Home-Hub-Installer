"""Pre-meeting brief — gather known facts about upcoming meeting attendees."""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from typing import Any, Dict, List, Optional

import httpx

_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from meeting_syncer import config
from meeting_syncer.calendar_client import fetch_events

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(message)s")

PWG = "https://pwg.dev/ontology#"


def _sparql_query(oxigraph_url, sparql):
    resp = httpx.post(
        oxigraph_url.rstrip("/") + "/query",
        content=sparql,
        headers={
            "Content-Type": "application/sparql-query",
            "Accept": "application/sparql-results+json",
        },
        timeout=30.0,
    )
    resp.raise_for_status()
    return resp.json()


def _find_person_by_email(oxigraph_url, email):
    """Find a person URI by email identifier."""
    sparql = """
    PREFIX pwg: <{}>
    SELECT ?person ?name ?org ?rel WHERE {{
      ?person a pwg:Person ;
              pwg:displayName ?name ;
              pwg:hasIdentifier ?id .
      ?id pwg:identifierType "email" ;
          pwg:identifierValue "{}" .
      OPTIONAL {{ ?person pwg:organization ?org }}
      OPTIONAL {{ ?person pwg:relationship ?rel }}
    }}
    LIMIT 1
    """.format(PWG, email.lower())
    result = _sparql_query(oxigraph_url, sparql)
    bindings = result.get("results", {}).get("bindings", [])
    if bindings:
        b = bindings[0]
        return {
            "uri": b["person"]["value"],
            "name": b["name"]["value"],
            "organization": b.get("org", {}).get("value", ""),
            "relationship": b.get("rel", {}).get("value", ""),
        }
    return None


def _get_person_facts(oxigraph_url, person_uri):
    """Get all current facts about a person."""
    sparql = """
    PREFIX pwg: <{}>
    SELECT ?text ?domain WHERE {{
      ?fact a pwg:PersonFact ;
            pwg:aboutPerson <{}> ;
            pwg:factText ?text .
      OPTIONAL {{ ?fact pwg:factDomain ?domain }}
      FILTER NOT EXISTS {{ ?fact pwg:validTo ?end }}
    }}
    """.format(PWG, person_uri)
    result = _sparql_query(oxigraph_url, sparql)
    facts = []
    for b in result.get("results", {}).get("bindings", []):
        facts.append(b["text"]["value"])
    return facts


def _get_meeting_history(oxigraph_url, person_uri):
    """Get past meetings with this person."""
    sparql = """
    PREFIX pwg: <{}>
    SELECT ?summary ?date WHERE {{
      ?meeting a pwg:Meeting ;
               pwg:meetingAttendee <{}> ;
               pwg:meetingSummary ?summary .
      OPTIONAL {{ ?meeting pwg:meetingDate ?date }}
    }}
    ORDER BY DESC(?date)
    """.format(PWG, person_uri)
    result = _sparql_query(oxigraph_url, sparql)
    meetings = []
    for b in result.get("results", {}).get("bindings", []):
        meetings.append({
            "summary": b["summary"]["value"],
            "date": b.get("date", {}).get("value", ""),
        })
    return meetings


def pre_meeting_brief(days=1):
    """Generate pre-meeting briefs for upcoming meetings with attendees."""
    owner_emails = set(config.OWNER_EMAILS)
    oxigraph_url = config.OXIGRAPH_URL

    events = fetch_events(config.CALENDAR_API_URL, days)
    if not events:
        return []

    briefs = []
    for event in events:
        attendees = event.get("attendees", [])
        other_attendees = [
            a for a in attendees
            if a.get("email", "").lower() not in owner_emails
        ]
        if not other_attendees:
            continue

        meeting_brief = {
            "meeting": event.get("summary", "(no title)"),
            "start": event.get("start_formatted", ""),
            "location": event.get("location", ""),
            "attendees": [],
        }

        for att in other_attendees:
            email = att.get("email", "")
            name = att.get("name", "")

            attendee_info = {"name": name, "email": email}

            if email:
                person = _find_person_by_email(oxigraph_url, email)
                if person:
                    attendee_info["name"] = person["name"] or name
                    attendee_info["organization"] = person["organization"]
                    attendee_info["relationship"] = person["relationship"]
                    attendee_info["facts"] = _get_person_facts(oxigraph_url, person["uri"])
                    history = _get_meeting_history(oxigraph_url, person["uri"])
                    attendee_info["times_met"] = len(history)
                    if history:
                        attendee_info["last_met"] = history[0].get("date", "")[:10]
                else:
                    attendee_info["known"] = False

            meeting_brief["attendees"].append(attendee_info)

        briefs.append(meeting_brief)

    return briefs


def print_brief(briefs):
    """Print a human-readable pre-meeting brief."""
    if not briefs:
        print("No upcoming meetings with attendees.")
        return

    for brief in briefs:
        print("=" * 60)
        print("MEETING: {}".format(brief["meeting"]))
        print("  When: {}".format(brief["start"]))
        if brief["location"]:
            print("  Where: {}".format(brief["location"]))
        print("")

        for att in brief["attendees"]:
            name = att.get("name") or att.get("email", "Unknown")
            print("  ATTENDEE: {}".format(name))
            if att.get("organization"):
                print("    Org: {}".format(att["organization"]))
            if att.get("relationship"):
                print("    Relationship: {}".format(att["relationship"]))
            if att.get("facts"):
                print("    Facts:")
                for fact in att["facts"]:
                    print("      - {}".format(fact))
            if att.get("times_met"):
                print("    Met {} time(s)".format(att["times_met"]))
                if att.get("last_met"):
                    print("    Last met: {}".format(att["last_met"]))
            if att.get("known") is False:
                print("    (not in People Graph)")
            print("")
    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(description="Pre-meeting brief from the People Graph.")
    parser.add_argument("--days", type=int, default=1, help="Days to look ahead (default: 1)")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    briefs = pre_meeting_brief(days=args.days)
    if args.json:
        print(json.dumps(briefs, indent=2))
    else:
        print_brief(briefs)


if __name__ == "__main__":
    main()
