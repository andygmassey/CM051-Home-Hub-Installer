"""Meeting Syncer — creates Meeting nodes from calendar events and links attendees to Person nodes."""
from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import httpx

_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from identity_resolver.models import PersonIdentity
from identity_resolver.normalise import clean_display_name
from identity_resolver.resolver import IdentityResolver

from meeting_syncer import config
from meeting_syncer.calendar_client import fetch_events

from qdrant_client import QdrantClient

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(message)s")

PWG = "https://pwg.dev/ontology#"


def _escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _meeting_uri(event_uid):
    h = hashlib.md5(event_uid.encode()).hexdigest()[:12]
    return "{}meeting_{}".format(PWG, h)


def _parse_event_datetime(start_str):
    """Parse iCal datetime string to ISO date (YYYY-MM-DD)."""
    if not start_str:
        return None
    try:
        if len(start_str) == 15:
            dt = datetime.strptime(start_str, "%Y%m%dT%H%M%S")
            return dt.strftime("%Y-%m-%d")
        elif len(start_str) == 8:
            dt = datetime.strptime(start_str, "%Y%m%d")
            return dt.strftime("%Y-%m-%d")
    except ValueError:
        pass
    return None


def _parse_event_datetime_iso(start_str):
    """Parse iCal datetime to full ISO datetime string."""
    if not start_str:
        return None
    try:
        if len(start_str) == 15:
            dt = datetime.strptime(start_str, "%Y%m%dT%H%M%S")
            return dt.isoformat()
        elif len(start_str) == 8:
            dt = datetime.strptime(start_str, "%Y%m%d")
            return dt.isoformat()
    except ValueError:
        pass
    return None


class MeetingSyncer:

    def __init__(self):
        self.resolver = IdentityResolver(
            oxigraph_url=config.OXIGRAPH_URL,
            default_country_code=config.DEFAULT_COUNTRY_CODE,
        )
        self.qdrant = QdrantClient(url=config.QDRANT_URL) if config.QDRANT_URL else None
        self.oxigraph_url = config.OXIGRAPH_URL.rstrip("/")
        self.owner_emails = set(config.OWNER_EMAILS)
        self.state_file = config.STATE_FILE

    def _load_state(self):
        if os.path.isfile(self.state_file):
            with open(self.state_file, "r") as fh:
                return json.load(fh)
        return {"processed_uids": [], "last_run": None}

    def _save_state(self, state):
        with open(self.state_file, "w") as fh:
            json.dump(state, fh, indent=2)

    def _sparql_query(self, sparql):
        resp = httpx.post(
            self.oxigraph_url + "/query",
            content=sparql,
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
            timeout=30.0,
        )
        resp.raise_for_status()
        return resp.json()

    def _sparql_update(self, sparql):
        resp = httpx.post(
            self.oxigraph_url + "/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
            timeout=30.0,
        )
        resp.raise_for_status()

    def _create_meeting(self, event):
        """Create a Meeting node in Oxigraph. Returns the meeting URI."""
        meeting_uri = _meeting_uri(event["uid"])
        summary = _escape(event.get("summary", ""))
        location = _escape(event.get("location", ""))
        event_uid = _escape(event["uid"])
        meeting_date = _parse_event_datetime_iso(event.get("start"))
        now = datetime.now(timezone.utc).isoformat()

        triples = [
            "<{}> a pwg:Meeting".format(meeting_uri),
            '<{}> pwg:calendarEventId "{}"'.format(meeting_uri, event_uid),
            '<{}> pwg:meetingSummary "{}"'.format(meeting_uri, summary),
            '<{}> pwg:createdAt "{}"^^xsd:dateTime'.format(meeting_uri, now),
        ]
        if meeting_date:
            triples.append(
                '<{}> pwg:meetingDate "{}"^^xsd:dateTime'.format(meeting_uri, meeting_date)
            )
        if location:
            triples.append('<{}> pwg:meetingLocation "{}"'.format(meeting_uri, location))

        sparql = (
            "PREFIX pwg: <{}>\n".format(PWG)
            + "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
            + "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
        )
        self._sparql_update(sparql)
        return meeting_uri

    def _link_attendee(self, meeting_uri, person_uri):
        """Link a person to a meeting via pwg:meetingAttendee."""
        sparql = (
            "PREFIX pwg: <{}>\n".format(PWG)
            + "INSERT DATA {{ <{}> pwg:meetingAttendee <{}> . }}".format(
                meeting_uri, person_uri
            )
        )
        self._sparql_update(sparql)

    def _get_last_calendar_contact(self, person_uri):
        """Query the current pwg:lastContactCalendar date for a person.

        Returns ISO date string or None.
        """
        sparql = (
            "PREFIX pwg: <{}>\n".format(PWG)
            + "SELECT ?lc WHERE {{ <{}> pwg:lastContactCalendar ?lc }}".format(
                person_uri
            )
        )
        result = self._sparql_query(sparql)
        bindings = result.get("results", {}).get("bindings", [])
        if bindings:
            return bindings[0]["lc"]["value"]
        return None

    def _update_last_calendar_contact(self, person_uri, meeting_date):
        """Update pwg:lastContactCalendar if meeting_date is more recent.

        Updates both Oxigraph and Qdrant. Oxigraph upsert uses the
        atomic DELETE-INSERT-WHERE-FILTER pattern: equal or older
        dates are no-ops, so the call is idempotent on re-runs.
        """
        current = self._get_last_calendar_contact(person_uri)
        if current and current >= meeting_date:
            return  # Stored value is already at or beyond this meeting

        sparql = (
            "PREFIX pwg: <{}>\n".format(PWG)
            + "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
            + "DELETE {{ <{}> pwg:lastContactCalendar ?old }}\n".format(person_uri)
            + 'INSERT {{ <{}> pwg:lastContactCalendar "{}"^^xsd:date }}\n'.format(
                person_uri, meeting_date
            )
            + "WHERE {{\n"
            + "  OPTIONAL {{ <{}> pwg:lastContactCalendar ?old }}\n".format(person_uri)
            + '  FILTER (!BOUND(?old) || ?old < "{}"^^xsd:date)\n'.format(meeting_date)
            + "}}"
        )
        self._sparql_update(sparql)

        # Update Qdrant payload
        if self.qdrant:
            try:
                results, _ = self.qdrant.scroll(
                    collection_name=config.QDRANT_COLLECTION,
                    scroll_filter={
                        "must": [
                            {"key": "person_uri", "match": {"value": person_uri}},
                        ]
                    },
                    limit=1,
                    with_payload=True,
                    with_vectors=False,
                )
                if results:
                    point = results[0]
                    ts = int(datetime.strptime(meeting_date, "%Y-%m-%d").timestamp())
                    self.qdrant.set_payload(
                        collection_name=config.QDRANT_COLLECTION,
                        payload={
                            "last_contact": meeting_date,
                            "last_contact_ts": ts,
                            "updated_at": datetime.now(timezone.utc).isoformat(),
                        },
                        points=[point.id],
                    )
            except Exception as e:
                logger.warning("Failed to update Qdrant lastContact for %s: %s", person_uri, e)

    # Local parts of attendee emails that indicate system/event accounts,
    # not humans. Used to skip creating phantom "person" nodes for event
    # brands (e.g. the HKWD case on 2026-04-11).
    _NON_HUMAN_EMAIL_LOCALS = {
        # Transactional + automated
        "events", "event", "info", "noreply", "no-reply", "donotreply",
        "do-not-reply", "hello", "team", "contact", "admin", "support",
        "help", "hi", "rsvp", "invites", "invite", "meetings", "calendar",
        "office", "hr", "careers", "jobs", "marketing", "press", "media",
        "billing", "accounts", "sales", "notifications", "notification",
        "alert", "alerts", "news", "newsletter", "digest", "digests",
        "updates", "auto", "automated", "mailer", "mailer-daemon",
        "postmaster", "bounce", "bounces", "feedback", "reply", "replies",
        "system", "webmaster", "hostmaster", "abuse", "security",
    }

    # Domain substrings that signal bulk / transactional senders. Matched
    # as endswith on the lowercased host. Be conservative — plain
    # `mail.company.com` is NOT enough; we want clearly transactional
    # subdomains only.
    _NON_HUMAN_DOMAIN_SUFFIXES = (
        ".eventbrite.com",
        ".mailchimp.com",
        ".mailchimp.app",
        ".sendgrid.net",
        ".amazonses.com",
        ".sparkpostmail.com",
        ".constantcontact.com",
        ".hubspotemail.net",
        ".rsgsv.net",
        ".mcsv.net",
        ".list-manage.com",
        ".beehiiv.com",
        ".mail.beehiiv.com",
        ".notifications.github.com",
    )

    # Substrings that indicate a brand-ish display name even when the
    # email looks OK. Matched against the full name, case-insensitive.
    _NON_HUMAN_NAME_SUBSTRINGS = (
        " team", " hq", " support", " events", " bot", " digest",
        " newsletter", " notifications", " notifications",
        " marketing", " sales", " customer success",
    )

    @classmethod
    def _looks_non_human(cls, name: str, email: str) -> bool:
        """Return True if an attendee looks like a brand/system, not a human.

        Layered checks, earliest hit wins. Ordered roughly by precision:

        1. Email local-part in the known-automation set.
        2. Email host matches a known transactional suffix.
        3. Display name contains a brand-ish substring (" Team", " Bot"…).
        4. All-caps short display name (≤6 chars) → nearly always an org
           acronym (HKWD, AWS, PWG…).

        Only one of these has to trip to return True. The checks are
        deliberately redundant with each other so a brand that slipped
        one layer still gets caught by another.
        """
        name_l = (name or "").strip().lower()
        email_l = (email or "").strip().lower()

        # 1) Local part match
        local, _, host = email_l.partition("@")
        if local and local in cls._NON_HUMAN_EMAIL_LOCALS:
            return True

        # 2) Host suffix match — accept both ".foo.com" (strict subdomain)
        #    and the bare "foo.com" form (exact host). Suffixes in the
        #    list are written with a leading dot for readability.
        if host:
            for suffix in cls._NON_HUMAN_DOMAIN_SUFFIXES:
                bare = suffix.lstrip(".")
                if host == bare or host.endswith(suffix):
                    return True

        # 3) Brand-ish display-name substring. Pad with spaces so we
        #    don't catch "Bot" inside "Robert".
        if name_l:
            padded = f" {name_l} "
            for needle in cls._NON_HUMAN_NAME_SUBSTRINGS:
                if needle in padded:
                    return True

        # 4) All-caps short names like "HKWD", "AWS", "PWG" — require at
        #    least 2 chars so single-letter display names (degenerate but
        #    occasionally human, "J", "X") fall through.
        if name:
            stripped = name.strip()
            if stripped == stripped.upper() and 2 <= len(stripped) <= 6:
                return True

        return False

    def _resolve_attendee(self, attendee):
        """Resolve an attendee to a person URI, creating if needed.

        Skips non-human attendees (event brands, noreply accounts) to avoid
        polluting the people graph with phantom person nodes.
        """
        email = attendee.get("email", "")
        name = attendee.get("name", "")

        if not email and not name:
            return None

        if self._looks_non_human(name, email):
            logger.info(
                "  Skipping non-human attendee: %s <%s>",
                name or "(no name)", email or "(no email)",
            )
            return None

        # Clean emoji/symbol decorations + duplicate tokens from the attendee
        # display name before it seeds a person node. Keep the cleaned value
        # only if non-empty (else fall back to the raw name/email).
        cleaned_name = clean_display_name(name) if name else ""
        identity = PersonIdentity(
            display_name=cleaned_name or name or email,
            emails=[email] if email else [],
        )
        # use_fuzzy=False: calendar attendees share the "common first name"
        # collision risk that burned contact sync. Email is a strong enough
        # identifier; if it doesn't match, create a fresh person rather than
        # fuzzy-merging into the wrong existing one.
        match = self.resolver.resolve(identity, use_fuzzy=False)

        if match.person_uri:
            return match.person_uri

        # Create new person
        person_uri = self.resolver.create_person(identity, config.USER_ID)
        logger.info("  Created person: %s (%s)", name or email, person_uri)
        return person_uri

    def sync(self, days=30, dry_run=False):
        """Main sync: fetch calendar events, create meetings, link attendees.

        Returns a result dict with shape::

            {
                "imported": int,          # meetings_created (B1 contract)
                "meetings_created": int,
                "attendees_linked": int,
                "contacts_updated": int,
                "skipped": int,
                "errors": list[dict],
            }
        """
        logger.info("Fetching calendar events for next %d days...", days)
        events = fetch_events(config.CALENDAR_API_URL, days)
        logger.info("Found %d events with attendees and UIDs.", len(events))

        if not events:
            logger.info("No events to process.")
            return {
                "imported": 0,
                "meetings_created": 0,
                "attendees_linked": 0,
                "contacts_updated": 0,
                "skipped": 0,
                "errors": [],
            }

        state = self._load_state()
        processed = set(state.get("processed_uids", []))

        meetings_created = 0
        attendees_linked = 0
        contacts_updated = 0
        skipped = 0

        for event in events:
            uid = event["uid"]
            if uid in processed:
                skipped += 1
                continue

            summary = event.get("summary", "(no title)")
            meeting_date = _parse_event_datetime(event.get("start"))
            attendees = event.get("attendees", [])

            # Filter out owner
            other_attendees = [
                a for a in attendees
                if a.get("email", "").lower() not in self.owner_emails
            ]

            if not other_attendees:
                processed.add(uid)
                continue

            logger.info("  Meeting: %s (%s) — %d attendees", summary, meeting_date or "?", len(other_attendees))

            if dry_run:
                for a in other_attendees:
                    logger.info("    [DRY RUN] %s <%s>", a.get("name", ""), a.get("email", ""))
                processed.add(uid)
                meetings_created += 1
                continue

            # Create meeting node
            meeting_uri = self._create_meeting(event)
            meetings_created += 1

            # Process each attendee
            for attendee in other_attendees:
                person_uri = self._resolve_attendee(attendee)
                if not person_uri:
                    continue

                self._link_attendee(meeting_uri, person_uri)
                attendees_linked += 1

                # Update lastContact only for past/today meetings (not future)
                if meeting_date and meeting_date <= datetime.now().strftime("%Y-%m-%d"):
                    self._update_last_calendar_contact(person_uri, meeting_date)
                    contacts_updated += 1

            processed.add(uid)

        # Save state
        if not dry_run:
            state["processed_uids"] = list(processed)
            state["last_run"] = datetime.now(timezone.utc).isoformat()
            self._save_state(state)

        mode = " (dry run)" if dry_run else ""
        logger.info("")
        logger.info("=" * 50)
        logger.info("Meeting sync complete%s:", mode)
        logger.info("  Meetings created:    %d", meetings_created)
        logger.info("  Attendees linked:    %d", attendees_linked)
        logger.info("  Contacts updated:    %d", contacts_updated)
        logger.info("  Skipped (already):   %d", skipped)
        logger.info("=" * 50)

        return {
            "imported": meetings_created,
            "meetings_created": meetings_created,
            "attendees_linked": attendees_linked,
            "contacts_updated": contacts_updated,
            "skipped": skipped,
            "errors": [],
        }


def main():
    parser = argparse.ArgumentParser(description="Sync calendar meetings into the People Graph.")
    parser.add_argument("--days", type=int, default=30, help="Number of days to look ahead (default: 30)")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be done without writing")
    parser.add_argument(
        "--api-url",
        type=str,
        default=None,
        help=(
            "Override the calendar API URL (ical-server endpoint). Defaults to "
            "config.CALENDAR_API_URL. Used by CM051 install.sh's hydrate_graph "
            "sub-phase (CX-81 B1) to point at the local ical-server."
        ),
    )
    parser.add_argument(
        "--graph-endpoint",
        type=str,
        default=None,
        help=(
            "Override the Oxigraph URL the syncer writes to. Equivalent to "
            "setting the OXIGRAPH_URL environment variable but explicit on "
            "the command line."
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help=(
            "Emit a single-line JSON status dict on stdout when the run "
            "completes ({\"imported\": N, \"meetings_created\": N, ...}). "
            "install.sh's hydrate_graph parses this with jq."
        ),
    )
    args = parser.parse_args()

    # Apply overrides before constructing the syncer so __init__ picks them up.
    if args.graph_endpoint:
        config.OXIGRAPH_URL = args.graph_endpoint
    if args.api_url:
        config.CALENDAR_API_URL = args.api_url

    syncer = MeetingSyncer()
    result = syncer.sync(days=args.days, dry_run=args.dry_run)

    if args.json:
        print(json.dumps(result or {"imported": 0, "skipped": 0, "errors": []}))


if __name__ == "__main__":
    main()
