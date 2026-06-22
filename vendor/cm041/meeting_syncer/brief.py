"""Pre-meeting brief -- gather known facts about upcoming meeting attendees.

# What the brief contains

For each upcoming meeting with at least one non-operator attendee, the
brief includes:

1. Meeting metadata (title, start time, location).
2. A Google Maps deep link when the calendar has a non-empty location.
3. Per-attendee context:
   - Name, organisation, relationship.
   - Wiki page URL (links into the operator's local wiki
     instance) so the brief reader can pivot into the full profile.
   - Existing facts from the People Graph.
   - Meeting history count + last-met date.
   - Last-discussion wiki link (deep link to the conversation page
     CM044 produced for the most recent meeting / chat with this
     attendee).
   - Outstanding TODOs cross-linked to this attendee (sourced from
     CM048 ``pwg:OutstandingTodo`` triples emitted by the conversation
     processing pipeline).

# Schema

See ``meeting_syncer/SCHEMA.md`` for the canonical wire shape this
module emits. Downstream consumers (the Hub HTTP endpoint, the iOS
Companion's MeetingBriefService) are pinned to that schema.

# Why no Reminders push?

The pre-meeting brief is a READ surface. Apple Reminders push is a
write surface owned by ostler-assistant's reminders_push gate (CM048
sidecar -> EventKit). The brief reads ``pwg:OutstandingTodo`` triples
that the writer already produced; it does not create new ones.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from typing import Any, Dict, List, Optional
from urllib.parse import quote_plus

import httpx

_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from meeting_syncer import config
from meeting_syncer.calendar_client import fetch_events

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(message)s")

PWG = "https://pwg.dev/ontology#"

# Maximum number of outstanding todos surfaced per attendee. Keeps
# WhatsApp deliveries within the ~300-char budget even when one
# attendee has a long open-loop history. The full list remains in
# Oxigraph; the brief just trims for display.
_MAX_TODOS_PER_ATTENDEE = 5


def _wiki_slug(name: str) -> str:
    """Compute a wiki page slug from a display name.

    Mirrors ``ical-server.py``'s ``_wiki_slug`` byte-for-byte so URLs
    resolve to the same page from either surface (ical-server pre-
    computes slugs for the iOS Companion; this module builds the
    same slugs for the brief).
    """
    if not name:
        return "unknown"
    import re
    s = name.strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = re.sub(r"-+", "-", s).strip("-")
    return s[:80] if s else "unknown"


def _wiki_base_url() -> str:
    """Read the wiki base URL from config or env, with a sensible default.

    The wiki recompiler (CM044) defaults to localhost:8044 in the
    customer install. Operators serving the wiki on a different
    host/port override via the ``WIKI_BASE_URL`` env var.
    """
    return os.environ.get("WIKI_BASE_URL", "http://localhost:8044").rstrip("/")


def _build_person_wiki_url(name: str) -> str:
    """Wiki page URL for a person, derived from the display name slug."""
    return f"{_wiki_base_url()}/People/{_wiki_slug(name)}/"


def _build_conversation_wiki_url(conversation_id: str) -> str:
    """Wiki page URL for a conversation. CM044's wiki compiler emits
    a Conversations/<id>/ page for every ingested conversation."""
    if not conversation_id:
        return ""
    return f"{_wiki_base_url()}/Conversations/{conversation_id}/"


def _build_google_maps_url(location: str) -> str:
    """Build a Google Maps deep link for a calendar event location.

    Returns an empty string when the location is empty or whitespace.
    The brief view collapses the maps row when this returns "" so
    online meetings (no physical location) do not render a useless
    "open in maps" affordance.
    """
    if not location or not location.strip():
        return ""
    return (
        "https://www.google.com/maps/search/?api=1&query="
        + quote_plus(location.strip())
    )


def _days_overdue(deadline: str, *, today: Optional[Any] = None) -> Optional[int]:
    """Whole days a todo is past its deadline, or ``None`` when not overdue.

    ``deadline`` is the ISO date string (``YYYY-MM-DD``) the enrichment
    table writes. Returns:

    - a positive int when the deadline is strictly in the past (e.g. a
      deadline of yesterday on a todo read today returns ``1``);
    - ``None`` when the deadline is today, in the future, empty, or
      unparseable.

    The CM058 Notch consumer treats a present, positive ``days_overdue``
    as the trigger for the overdue cue card. We deliberately emit the
    field ONLY when there is something to show, so older clients (and
    the WhatsApp / iOS surfaces that ignore it) are unaffected by an
    extra key, and the Notch never lights up for a not-yet-due item.

    ``today`` is injectable for deterministic tests; production reads
    the current UTC date.
    """
    if not deadline or not str(deadline).strip():
        return None
    from datetime import date, datetime, timezone

    raw = str(deadline).strip()
    parsed: Optional[Any] = None
    # ISO date (YYYY-MM-DD) is the canonical enrichment shape, but be
    # tolerant of an ISO datetime (YYYY-MM-DDTHH:MM:SS[...]) too.
    try:
        if "T" in raw:
            parsed = datetime.fromisoformat(
                raw.replace("Z", "+00:00")
            ).date()
        else:
            parsed = date.fromisoformat(raw[:10])
    except (ValueError, TypeError):
        return None

    if today is None:
        today = datetime.now(timezone.utc).date()

    delta = (today - parsed).days
    return delta if delta > 0 else None


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
    """Get past meetings with this person, most recent first."""
    sparql = """
    PREFIX pwg: <{}>
    SELECT ?summary ?date ?id WHERE {{
      ?meeting a pwg:Meeting ;
               pwg:meetingAttendee <{}> ;
               pwg:meetingSummary ?summary .
      OPTIONAL {{ ?meeting pwg:meetingDate ?date }}
      OPTIONAL {{ ?meeting pwg:meetingId ?id }}
    }}
    ORDER BY DESC(?date)
    """.format(PWG, person_uri)
    result = _sparql_query(oxigraph_url, sparql)
    meetings = []
    for b in result.get("results", {}).get("bindings", []):
        meetings.append({
            "summary": b["summary"]["value"],
            "date": b.get("date", {}).get("value", ""),
            "id": b.get("id", {}).get("value", ""),
        })
    return meetings


def _get_last_conversation_id(oxigraph_url, person_uri):
    """Find the most recent conversation that mentioned this person.

    CM048's ingest writes ``<urn:pwg:fact/...> pwg:about <person_uri>``
    + ``pwg:fromConversation <conv_uri>`` triples for every extracted
    fact. We walk the conversation graph back to find the most recent
    conversation URI, then strip the ``urn:pwg:conversation/`` prefix
    to recover the conversation_id the wiki page is keyed by.

    Returns ``""`` when no conversation matches (the person may exist
    in the graph from a contact-sync without any conversation having
    been ingested yet).
    """
    sparql = """
    PREFIX pwg: <urn:pwg:>
    SELECT ?conv ?date WHERE {{
      ?fact <urn:pwg:about> <{person}> ;
            <urn:pwg:fromConversation> ?conv .
      OPTIONAL {{ ?conv <urn:pwg:date> ?date }}
    }}
    ORDER BY DESC(?date)
    LIMIT 1
    """.format(person=person_uri)
    try:
        result = _sparql_query(oxigraph_url, sparql)
    except Exception as exc:
        logger.warning("last-conversation query failed for %s: %s", person_uri, exc)
        return ""
    bindings = result.get("results", {}).get("bindings", [])
    if not bindings:
        return ""
    conv_uri = bindings[0].get("conv", {}).get("value", "")
    # Strip the urn:pwg:conversation/ prefix to recover the bare id.
    prefix = "urn:pwg:conversation/"
    if conv_uri.startswith(prefix):
        return conv_uri[len(prefix):]
    return ""


def _get_outstanding_todos(oxigraph_url, person_uri):
    """Outstanding todos that mention this attendee, most recent first.

    Queries the ``pwg:OutstandingTodo`` triples CM048's ingest writes.
    Each todo block carries one ``pwg:aboutPerson`` per non-user
    participant of the source conversation so a 3-person meeting's
    "Andy sends Alice the deck" todo surfaces on EITHER a meeting
    with Alice or a meeting with Bob, whichever comes first.

    Returns a list of dicts shaped for direct inclusion in the brief
    payload. Status filter is ``open`` so closed-out todos do not
    clutter the brief once v1.0.1 wires the closure pass.
    """
    sparql = """
    PREFIX pwg: <urn:pwg:>
    SELECT ?todo ?text ?owner ?ownerDisplay ?deadline ?priority
           ?status ?sourceDate ?createdAt WHERE {{
      ?todo a <urn:pwg:OutstandingTodo> ;
            <urn:pwg:aboutPerson> <{person}> ;
            <urn:pwg:todoText> ?text ;
            <urn:pwg:owner> ?owner ;
            <urn:pwg:status> ?status .
      OPTIONAL {{ ?todo <urn:pwg:ownerDisplay> ?ownerDisplay }}
      OPTIONAL {{ ?todo <urn:pwg:deadline> ?deadline }}
      OPTIONAL {{ ?todo <urn:pwg:priority> ?priority }}
      OPTIONAL {{ ?todo <urn:pwg:sourceConversationDate> ?sourceDate }}
      OPTIONAL {{ ?todo <urn:pwg:todoCreatedAt> ?createdAt }}
      FILTER (?status = "open")
    }}
    ORDER BY DESC(?createdAt)
    LIMIT {limit}
    """.format(person=person_uri, limit=_MAX_TODOS_PER_ATTENDEE)
    try:
        result = _sparql_query(oxigraph_url, sparql)
    except Exception as exc:
        logger.warning("outstanding-todos query failed for %s: %s", person_uri, exc)
        return []
    todos = []
    for b in result.get("results", {}).get("bindings", []):
        deadline = b.get("deadline", {}).get("value", "")
        todo = {
            "text": b.get("text", {}).get("value", ""),
            "owner": b.get("owner", {}).get("value", ""),
            "owner_display": b.get("ownerDisplay", {}).get("value", ""),
            "deadline": deadline,
            "priority": b.get("priority", {}).get("value", ""),
            "source_conversation_date": b.get("sourceDate", {}).get("value", ""),
        }
        # Optional overdue cue for the CM058 Notch consumer. Present
        # only when the deadline is strictly in the past, so the field
        # is absent (not 0 / null) for on-time and not-yet-due todos.
        overdue = _days_overdue(deadline)
        if overdue is not None:
            todo["days_overdue"] = overdue
        todos.append(todo)
    return todos


def pre_meeting_brief(days=1):
    """Generate pre-meeting briefs for upcoming meetings with attendees.

    See ``SCHEMA.md`` for the wire shape this function returns. The
    short version: a list of meeting-brief dicts, each with a
    ``meeting`` / ``start`` / ``location`` / ``maps_url`` /
    ``attendees`` top-level shape, where each attendee has
    ``name`` / ``wiki_url`` / ``facts`` / ``times_met`` /
    ``last_met`` / ``last_discussion_url`` / ``outstanding_todos``.
    """
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

        location = event.get("location", "")
        meeting_brief = {
            "meeting": event.get("summary", "(no title)"),
            "start": event.get("start_formatted", ""),
            "start_iso": event.get("start", ""),
            "uid": event.get("uid", ""),
            "location": location,
            "maps_url": _build_google_maps_url(location),
            "attendees": [],
        }

        # Optional meeting end time (DTEND) for the CM058 Notch consumer,
        # which uses it to render an in-progress countdown / "ends in N
        # min" cue. Mirrors ``start_iso`` (the raw calendar end value the
        # unified calendar API carries on each event). Emitted only when
        # the event has a non-empty end, so all-day / open-ended events
        # and older clients are unaffected by an extra key.
        end_iso = event.get("end", "")
        if end_iso:
            meeting_brief["end_iso"] = end_iso

        for att in other_attendees:
            email = att.get("email", "")
            name = att.get("name", "")

            # Pre-compute the wiki URL from the display name so even
            # unknown attendees (not in the People Graph yet) get a
            # link the operator can click into the wiki and create.
            attendee_info: Dict[str, Any] = {
                "name": name,
                "email": email,
                "wiki_url": _build_person_wiki_url(name) if name else "",
                "outstanding_todos": [],
                "last_discussion_url": "",
            }

            if email:
                person = _find_person_by_email(oxigraph_url, email)
                if person:
                    resolved_name = person["name"] or name
                    attendee_info["name"] = resolved_name
                    attendee_info["wiki_url"] = _build_person_wiki_url(resolved_name)
                    attendee_info["organization"] = person["organization"]
                    attendee_info["relationship"] = person["relationship"]
                    attendee_info["facts"] = _get_person_facts(
                        oxigraph_url, person["uri"]
                    )
                    history = _get_meeting_history(oxigraph_url, person["uri"])
                    attendee_info["times_met"] = len(history)
                    if history:
                        attendee_info["last_met"] = history[0].get("date", "")[:10]
                    # Last-discussion link. Falls back to "" when no
                    # conversation has been ingested for this person
                    # yet (e.g. contact pulled from iCloud but never
                    # spoken to via a captured channel).
                    last_conv_id = _get_last_conversation_id(
                        oxigraph_url, person["uri"]
                    )
                    if last_conv_id:
                        attendee_info["last_discussion_url"] = (
                            _build_conversation_wiki_url(last_conv_id)
                        )
                        attendee_info["last_discussion_id"] = last_conv_id
                    # Outstanding todos cross-linked to this attendee.
                    attendee_info["outstanding_todos"] = _get_outstanding_todos(
                        oxigraph_url, person["uri"]
                    )
                else:
                    attendee_info["known"] = False

            meeting_brief["attendees"].append(attendee_info)

        briefs.append(meeting_brief)

    return briefs


def render_whatsapp_message(brief: dict) -> str:
    """Render a pre-meeting brief into a concise WhatsApp message.

    Budget target: ~300 chars + 1-3 links. The cron sender (CM051
    LaunchAgent) calls this; the iOS surface uses the richer JSON
    directly. Customer-facing copy lives here so the strings can be
    extracted into a catalogue in a future v1.x i18n pass (Rule 0.9).

    The message format is deliberately plain text -- WhatsApp Web's
    URL preview unfurls the wiki / maps link, and richer markdown
    causes the channel adapter to escape characters that would
    otherwise read fine.
    """
    parts = []
    title = brief.get("meeting") or "(no title)"
    start = brief.get("start") or ""

    if start:
        parts.append(f"Meeting: {title} at {start}.")
    else:
        parts.append(f"Meeting: {title}.")

    if brief.get("maps_url"):
        parts.append(f"Location: {brief.get('location', '')} {brief['maps_url']}")

    attendees = brief.get("attendees") or []
    if attendees:
        names = ", ".join(
            a.get("name") or a.get("email") or "Unknown"
            for a in attendees[:3]
        )
        parts.append(f"With: {names}.")
        # Surface up to one wiki link for the first attendee.
        first = attendees[0]
        if first.get("wiki_url"):
            parts.append(f"Wiki: {first['wiki_url']}")
        if first.get("last_discussion_url"):
            parts.append(f"Last chat: {first['last_discussion_url']}")
        # Surface up to 3 outstanding todos across all attendees,
        # newest first (already ordered by SPARQL).
        all_todos = []
        for a in attendees:
            for t in (a.get("outstanding_todos") or [])[:3]:
                all_todos.append((a.get("name", ""), t))
        if all_todos:
            todo_lines = []
            for name, t in all_todos[:3]:
                owner = t.get("owner_display") or t.get("owner") or ""
                owner_label = f"{owner}: " if owner else ""
                deadline = f" (by {t['deadline']})" if t.get("deadline") else ""
                todo_lines.append(f"{owner_label}{t.get('text', '')}{deadline}")
            parts.append("Open: " + " | ".join(todo_lines))

    return "\n".join(parts)


def print_brief(briefs):
    """Print a human-readable pre-meeting brief."""
    if not briefs:
        print("No upcoming meetings with attendees.")
        return

    for brief in briefs:
        print("=" * 60)
        print("MEETING: {}".format(brief["meeting"]))
        print("  When: {}".format(brief["start"]))
        if brief.get("location"):
            print("  Where: {}".format(brief["location"]))
            if brief.get("maps_url"):
                print("  Map: {}".format(brief["maps_url"]))
        print("")

        for att in brief["attendees"]:
            name = att.get("name") or att.get("email", "Unknown")
            print("  ATTENDEE: {}".format(name))
            if att.get("wiki_url"):
                print("    Wiki: {}".format(att["wiki_url"]))
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
            if att.get("last_discussion_url"):
                print("    Last discussion: {}".format(att["last_discussion_url"]))
            if att.get("outstanding_todos"):
                print("    Outstanding TODOs:")
                for t in att["outstanding_todos"]:
                    owner = t.get("owner_display") or t.get("owner", "")
                    owner_label = f"[{owner}] " if owner else ""
                    deadline = f" (by {t['deadline']})" if t.get("deadline") else ""
                    print("      - {}{}{}".format(
                        owner_label, t.get("text", ""), deadline
                    ))
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
