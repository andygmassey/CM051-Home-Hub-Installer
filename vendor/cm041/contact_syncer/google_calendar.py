"""Google Calendar ICS Importer - reads .ics files from Google Takeout
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

SHIP-GATE (divergent-twin graft path): ``contact_syncer`` does NOT ship
from this CM041 repo directly. A customer build takes it from CM051
``vendor/cm041/`` plus the HR015 release tarball. A fix committed here does
NOT reach a customer Hub until CM051 ``vendor/cm041/`` is re-vendored and
the HR015 tarball is re-cut. The companion read-side fix (per-owner brief
labelling) ships from CM051 ``context-refresh/``. Treat "landed on this
branch" as necessary-but-not-sufficient; the cut must re-vendor + re-cut
both twins for this privacy fix to be live.
"""
from __future__ import annotations

import argparse
import hashlib
import json
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


def _extract_calendar_name(content: str) -> str:
    """Extract the calendar's display name from the VCALENDAR header.

    Google Takeout and Apple Calendar both write the owning calendar's
    display name as an ``X-WR-CALNAME`` property at the VCALENDAR level
    (outside any VEVENT). This is the whose-diary signal - e.g. "Family",
    "Robin Carter", "andy@example.com". It sits before the first VEVENT
    and was previously discarded (``parse_ics`` only scanned VEVENT
    blocks), which is exactly how calendar-owner provenance was lost.
    Returns "" when the header is absent.
    """
    m = re.search(r"^X-WR-CALNAME:(.+)$", content, re.MULTILINE)
    if m:
        return m.group(1).strip()
    return ""


def parse_ics(
    ics_path: str,
    *,
    user_name: str = "",
    source_calendar: str = "",
) -> List[Dict[str, Any]]:
    """Parse an ICS file and extract VEVENT entries.

    If user_name is provided, the user is filtered out of attendee lists.

    Every returned event carries a ``source_calendar`` label recording
    whose calendar it came from (whose-diary provenance). It is resolved,
    in priority order, from: an explicit ``source_calendar`` argument
    (passed by the importer, e.g. derived from the export filename), then
    the ICS ``X-WR-CALNAME`` header. When neither is present the field is
    left empty and ``write_calendar_event`` falls back to the event
    ORGANIZER. This is the field that keeps a partner's flight from being
    flattened into the operator's own diary.
    """
    content = open(ics_path, "r", encoding="utf-8").read()

    calname = source_calendar or _extract_calendar_name(content)

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
            if calname:
                event["source_calendar"] = calname
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


def _derive_source_calendar(event: Dict[str, Any]) -> str:
    """Resolve the owning-calendar label for a calendar event.

    Whose-diary provenance, in priority order:
      1. ``source_calendar`` - the calendar display name captured by
         ``parse_ics`` (explicit importer arg or ICS X-WR-CALNAME).
      2. the event ORGANIZER display name - the per-event owner signal,
         the fallback when several people's events share one merged
         calendar with no X-WR-CALNAME.
      3. the ORGANIZER email - last-resort machine identity.

    Returns "" when none is available (unknown owner).
    """
    return (
        (event.get("source_calendar") or "").strip()
        or (event.get("organizer") or "").strip()
        or (event.get("organizer_email") or "").strip()
    )


# ── Operator-confirmed calendar provenance (owner + type) ────────────────────
#
# Owner + type are CONFIRMED BY THE OPERATOR at end-of-installation (and
# re-surfaceable by the assistant / Front Page when a new calendar appears).
# That confirmation is the AUTHORITATIVE source; the ingest-side
# auto-detection below (X-WR-CALNAME / ORGANIZER / filename) is only the
# pre-fill / fallback.
#
# The confirmation is persisted as a small JSON map that the onboarding step
# writes and this ingest reads. Contract:
#
#   ~/.ostler/calendars.json  (override with OSTLER_CALENDAR_PROVENANCE)
#   {
#     "calendars": [
#       {"match": "Partner's Calendar", "owner": "Robin",
#        "type": "family", "privacy_level": "L1"},
#       {"match": "work@example.com",   "owner": "You",
#        "type": "work"},                       # privacy derived from type
#       {"match": "operator@example.com","owner": "You", "type": "personal"}
#     ]
#   }
#
# ``match`` is compared case-insensitively against the event's candidate
# identities (source_calendar / organizer / organizer_email). A missing file
# means "nothing confirmed yet" -> auto-detection alone.
CALENDAR_PROVENANCE_PATH = os.environ.get(
    "OSTLER_CALENDAR_PROVENANCE",
    os.path.expanduser("~/.ostler/calendars.json"),
)

# Recognised privacy levels. Anything OUTSIDE this set -- a missing,
# unknown, or unparseable level -- FAILS CLOSED to L3 (most restrictive),
# matching the estate-wide fail-closed L3 contract the ical-server privacy
# filter standardises on (missing/unknown/unparseable -> L3; only an
# explicit L0/L1/L2/L3 passes through).
_VALID_PRIVACY = {"L0", "L1", "L2", "L3"}

# Calendar type -> default privacy level when the operator has not set one
# explicitly. A shared work calendar is more sensitive to surface than a
# personal / family one. An UNKNOWN or unclassified type is NOT assumed
# benign: it fails closed to L3 (see _DEFAULT_PRIVACY), so an un-confirmed
# calendar's events stay private until the operator classifies them at
# onboarding. Defaulting these to L1 was a fail-OPEN leak (BATCH1 #2).
_TYPE_DEFAULT_PRIVACY = {
    "personal": "L1",
    "family": "L1",
    "work": "L2",
    "shared": "L2",
}
# Fail-closed default: missing / unknown / unclassified / unparseable -> L3.
_DEFAULT_PRIVACY = "L3"


def load_calendar_provenance(
    path: Optional[str] = None,
) -> List[Dict[str, str]]:
    """Load the operator-confirmed calendar owner/type map (authoritative).

    Returns the list of ``{match, owner, type, privacy_level}`` entries, or
    an empty list when the file is absent/unreadable/malformed (auto-detection
    is then the sole source). Never raises - a missing confirmation must not
    break ingest.
    """
    p = path or CALENDAR_PROVENANCE_PATH
    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    entries = data.get("calendars") if isinstance(data, dict) else None
    if not isinstance(entries, list):
        return []
    return [e for e in entries if isinstance(e, dict) and e.get("match")]


def _match_confirmed(
    provenance: List[Dict[str, str]], event: Dict[str, Any]
) -> Optional[Dict[str, str]]:
    """Return the confirmed provenance entry whose ``match`` equals one of
    this event's candidate calendar identities (case-insensitive), or None."""
    if not provenance:
        return None
    candidates = {
        c.strip().lower()
        for c in (
            event.get("source_calendar", ""),
            event.get("organizer", ""),
            event.get("organizer_email", ""),
        )
        if c and c.strip()
    }
    if not candidates:
        return None
    for entry in provenance:
        if str(entry.get("match", "")).strip().lower() in candidates:
            return entry
    return None


def resolve_calendar_provenance(
    event: Dict[str, Any],
    provenance: Optional[List[Dict[str, str]]] = None,
) -> Tuple[str, str, str]:
    """Resolve ``(owner, calendar_type, privacy_level)`` for a calendar event.

    Operator-confirmed config is authoritative for owner and type; the
    auto-detected owner (``_derive_source_calendar``) is the fallback.
    Privacy level fails CLOSED: an explicit, recognised confirmed
    ``privacy_level`` wins; otherwise the confirmed type derives it
    (personal/family -> L1, work/shared -> L2); an unknown/unclassified
    type or an entirely unconfirmed calendar defaults to L3, not L1.
    """
    auto_owner = _derive_source_calendar(event)
    confirmed = _match_confirmed(provenance or [], event)

    if confirmed:
        owner = str(confirmed.get("owner") or "").strip() or auto_owner
        cal_type = str(confirmed.get("type") or "").strip().lower()
        explicit = str(confirmed.get("privacy_level") or "").strip().upper()
        if explicit in _VALID_PRIVACY:
            # Operator set an explicit, recognised level -- authoritative.
            privacy = explicit
        else:
            # No / unparseable explicit level: derive from the confirmed
            # type, failing closed to L3 for an unknown/unclassified type.
            privacy = _TYPE_DEFAULT_PRIVACY.get(cal_type, _DEFAULT_PRIVACY)
    else:
        # Unconfirmed calendar: onboarding has not classified it yet, so it
        # fails closed to L3 (most restrictive) rather than defaulting open.
        owner = auto_owner
        cal_type = ""  # unclassified: onboarding assigns type, not ingest
        privacy = _DEFAULT_PRIVACY
    return owner, cal_type, privacy


# Owner labels that denote the OPERATOR'S OWN calendar rather than a
# distinct third party. The onboarding confirmation writes owner "You" for
# the operator's own calendars (see the calendars.json contract above); we
# also honour the operator's configured display name. Matching is
# case-insensitive on the trimmed label. An EMPTY / unknown owner is
# deliberately NOT in this set: an unattributed event must never be stamped
# as the operator's (fail closed), or a partner-diary event whose owner
# label was lost would leak straight back into operator-scoped reads.
_OPERATOR_OWNER_TOKENS = frozenset(
    {"you", "me", "self", "myself", "my calendar", "operator"}
)


def _owner_denotes_operator(owner: str) -> bool:
    """True when the resolved calendar owner is the operator themselves.

    Recognises the onboarding self-tokens (owner "You") and the operator's
    configured ``USER_DISPLAY_NAME``. An empty/unknown owner returns False
    so it is never attributed to the operator (see ``write_calendar_event``).
    """
    label = (owner or "").strip().lower()
    if not label:
        return False
    if label in _OPERATOR_OWNER_TOKENS:
        return True
    display = (getattr(config, "USER_DISPLAY_NAME", "") or "").strip().lower()
    return bool(display) and label == display


def write_calendar_event(
    oxigraph_url: str,
    event: Dict[str, Any],
    user_id: str,
    provenance: Optional[List[Dict[str, str]]] = None,
) -> None:
    """Write a calendar event as a PersonFact.

    Carries whose-diary provenance via ``pwg:sourceCalendar`` (owner) and
    ``pwg:calendarType`` (personal/work/family/...) when known, so
    downstream readers - the daily brief in particular - can label each
    event by its owner and never merge one person's trip into another's.
    ``provenance`` is the operator-confirmed owner/type map (authoritative);
    when None it is loaded from the default path. Calendar type also informs
    the fact's ``pwg:privacyLevel``.

    ``pwg:aboutPerson`` (the SUBJECT of the fact) is stamped to the operator
    ONLY for the operator's own calendar. A distinct-owner (partner/family)
    or unknown-owner event is NOT attributed to the operator: otherwise every
    reader querying ``pwg:aboutPerson=<operator>`` - including the legacy /
    out-of-repo readers this repo cannot filter - would surface the partner's
    diary as the operator's own (BATCH1 #3 F1, the real root cause). Whose
    diary it is still travels on ``pwg:sourceCalendar`` for the by-owner
    readers, and ``pwg:belongsToUser`` (graph custody) stays on the operator
    regardless.
    """
    if provenance is None:
        provenance = load_calendar_provenance()
    summary = _escape(event["summary"])
    location = _escape(event.get("location", ""))
    dtstart = event.get("dtstart", "")
    source_calendar, calendar_type, privacy_level = resolve_calendar_provenance(
        event, provenance
    )

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

    # Owner + type provenance: emit each only when resolved, so an
    # ownerless/unclassified event stays valid. An ownerless event is NOT
    # assumed to be the operator's own (that was the fail-open); it is left
    # unattributed.
    provenance_triples = ""
    if source_calendar:
        provenance_triples += (
            f'  <{fact_uri}> pwg:sourceCalendar "{_escape(source_calendar)}" .\n'
        )
    if calendar_type:
        provenance_triples += (
            f'  <{fact_uri}> pwg:calendarType "{_escape(calendar_type)}" .\n'
        )

    # Subject attribution: only the operator's OWN calendar is stamped
    # about the operator. A distinct or unknown owner is withheld so it can
    # never surface in an operator-scoped `aboutPerson=<operator>` read.
    about_triple = (
        f'  <{fact_uri}> pwg:aboutPerson <{user_uri}> .\n'
        if _owner_denotes_operator(source_calendar)
        else ""
    )

    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        f"INSERT DATA {{\n"
        f'  <{fact_uri}> a pwg:PersonFact .\n'
        f"{about_triple}"
        f'  <{fact_uri}> pwg:factText "{fact_text}" .\n'
        f'  <{fact_uri}> pwg:factSource "google_calendar" .\n'
        f'  <{fact_uri}> pwg:factDomain "calendar" .\n'
        f"{provenance_triples}"
        f'  <{fact_uri}> pwg:validFrom "{dtstart}"^^xsd:dateTime .\n'
        f'  <{fact_uri}> pwg:privacyLevel "{_escape(privacy_level)}" .\n'
        f'  <{fact_uri}> pwg:belongsToUser <{user_uri}> .\n'
        f"}}"
    )
    _sparql_update(oxigraph_url, sparql)


# ── Main ─────────────────────────────────────────────────────────────


# Generic ICS filenames that carry no useful owner signal - do not use
# these as a fallback owner label (they would mislabel every event).
_GENERIC_ICS_STEMS = frozenset({"calendar", "basic", "events", "export", "ical"})


def import_calendar(
    ics_path: str,
    *,
    dry_run: bool = False,
    verbose: bool = False,
    user_name: str = "",
    source_calendar: str = "",
    provenance: Optional[List[Dict[str, str]]] = None,
) -> Dict[str, int]:
    """Import Google Calendar events.

    ``source_calendar`` is the owning-calendar label for this file (whose
    diary it is). When the caller does not supply one and the ICS has no
    X-WR-CALNAME header, we fall back to the export filename stem (Google
    Takeout names each calendar export ``<calendar-name>.ics``), skipping
    generic stems like ``calendar.ics`` that carry no owner signal. This
    is the provenance that keeps a partner's flights distinct from the
    operator's in every downstream reader.

    ``provenance`` is the operator-confirmed owner/type map (authoritative,
    written by the end-of-install onboarding confirmation). Loaded once from
    the default path when None so every event in the file resolves against
    the same map.
    """
    if provenance is None:
        provenance = load_calendar_provenance()
    events = parse_ics(
        ics_path, user_name=user_name, source_calendar=source_calendar
    )

    # Filename-stem fallback when neither an explicit owner nor an
    # X-WR-CALNAME header was available.
    if events and not any(e.get("source_calendar") for e in events):
        stem = os.path.splitext(os.path.basename(ics_path))[0].strip()
        if stem and stem.lower() not in _GENERIC_ICS_STEMS:
            for e in events:
                e.setdefault("source_calendar", stem)

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
            print(f"  [{i}/{len(events)}] {dtstart} - {summary}"
                  + (f" ({n_attendees} attendees)" if n_attendees else ""))

        try:
            if not dry_run:
                write_calendar_event(
                    config.OXIGRAPH_URL, event, config.USER_ID,
                    provenance=provenance,
                )
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
