"""Extract calendar events from macOS Calendar database.

macOS Calendar stores data in one of two places depending on OS version:

  macOS 14 (Sonoma) and earlier:
    ~/Library/Calendars/Calendar Cache       (single sqlite file)

  macOS 15 (Sequoia) and later:
    ~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb

The CalendarItem table schema is compatible across both paths (summary,
start_date, end_date, all_day, calendar_id, location_id) so the main
query works in both worlds. The attendee surface differs: macOS 14 uses
an `Attendee` table; macOS 15 uses `Participant` joined to `Identity`.

This module probes the macOS 15 path FIRST, falls back to macOS 14.
Covers both iCloud Calendar and Google Calendar events synced to the
Mac's Calendar app.

Requires Full Disk Access (FDA) on macOS Sequoia+.
"""
from __future__ import annotations

import logging
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

MAC_EPOCH_OFFSET = 978307200

# macOS 15+ path (Sequoia and later). Probed FIRST.
DEFAULT_CALENDAR_DB_SEQUOIA = (
    Path.home() / "Library" / "Group Containers"
    / "group.com.apple.calendar" / "Calendar.sqlitedb"
)

# macOS 14 path (Sonoma and earlier). Fallback.
DEFAULT_CALENDAR_CACHE = (
    Path.home() / "Library" / "Calendars" / "Calendar Cache"
)


@dataclass
class CalendarEvent:
    """A single calendar event."""
    title: str
    start_date: datetime
    end_date: Optional[datetime]
    location: Optional[str]
    attendees: list[str]
    calendar_name: Optional[str]
    is_all_day: bool
    notes: Optional[str]
    recurrence: Optional[str]


def _resolve_db_path(db_path: Optional[Path]) -> Optional[Path]:
    """Pick the first existing Calendar database. New path wins."""
    if db_path is not None:
        return db_path if db_path.exists() else None
    for candidate in (DEFAULT_CALENDAR_DB_SEQUOIA, DEFAULT_CALENDAR_CACHE):
        if candidate.exists():
            return candidate
    return None


def _load_attendees(conn: sqlite3.Connection) -> dict[int, list[str]]:
    """Build {calendar_item_rowid: [attendee_name, ...]}.

    Tries macOS 15 (Participant + Identity) first, then macOS 14 (Attendee).
    Returns empty dict if neither schema is present.
    """
    attendee_map: dict[int, list[str]] = {}

    # macOS 15+: Participant table. Identity is keyed by Participant.identity_id
    # but Identity has no ROWID exposed; join by Participant.email -> Identity.address.
    try:
        rows = conn.execute("""
            SELECT
                p.owner_id as item_id,
                p.email as email,
                i.display_name as name,
                i.first_name as first_name,
                i.last_name as last_name
            FROM Participant p
            LEFT JOIN Identity i ON i.address = p.email
        """).fetchall()
        for r in rows:
            item_id = r["item_id"]
            if item_id is None:
                continue
            display = r["name"]
            if not display:
                first = r["first_name"] or ""
                last = r["last_name"] or ""
                joined = f"{first} {last}".strip()
                display = joined or r["email"] or ""
            if display:
                attendee_map.setdefault(item_id, []).append(display)
        if attendee_map:
            return attendee_map
    except sqlite3.OperationalError:
        pass

    # macOS 14: Attendee table.
    try:
        rows = conn.execute("""
            SELECT
                a.item_id,
                a.address as email,
                a.common_name as name
            FROM Attendee a
        """).fetchall()
        for r in rows:
            item_id = r["item_id"]
            if item_id is None:
                continue
            display = r["name"] or r["email"] or ""
            if display:
                attendee_map.setdefault(item_id, []).append(display)
    except sqlite3.OperationalError:
        pass

    return attendee_map


def extract_events(
    db_path: Optional[Path] = None,
    since_days: int = 365,
    future_days: int = 30,
) -> list[CalendarEvent]:
    """Extract calendar events from the Calendar database.

    Args:
        db_path: Path to Calendar database. If None, probes macOS 15 path
            then macOS 14 path. Pass an explicit path to override.
        since_days: Include events from last N days.
        future_days: Include events up to N days in the future.

    Returns:
        List of CalendarEvent objects, chronological order. Returns []
        on any failure (graceful degradation, errors logged).
    """
    try:
        resolved = _resolve_db_path(db_path)
    except Exception as e:
        logger.error("Failed to resolve Calendar db path: %s", e)
        return []

    if resolved is None:
        logger.warning(
            "Calendar database not found at either macOS 15 path (%s) "
            "or macOS 14 path (%s)",
            DEFAULT_CALENDAR_DB_SEQUOIA, DEFAULT_CALENDAR_CACHE,
        )
        return []

    try:
        conn = sqlite3.connect(f"file:{resolved}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            logger.error(
                "Cannot read Calendar data at %s. Grant Full Disk Access.",
                resolved,
            )
        else:
            logger.error("Failed to open Calendar db %s: %s", resolved, e)
        return []
    except Exception as e:
        logger.error("Unexpected error opening Calendar db %s: %s", resolved, e)
        return []

    conn.row_factory = sqlite3.Row

    now_mac = datetime.now(timezone.utc).timestamp() - MAC_EPOCH_OFFSET
    start_mac = now_mac - (since_days * 86400)
    end_mac = now_mac + (future_days * 86400)

    rows: list[sqlite3.Row] = []
    try:
        rows = conn.execute("""
            SELECT
                ci.ROWID,
                ci.summary as title,
                ci.start_date,
                ci.end_date,
                ci.all_day as is_all_day,
                ci.description as notes,
                l.title as location,
                c.title as calendar_name,
                ci.has_recurrences
            FROM CalendarItem ci
            LEFT JOIN Location l ON l.ROWID = ci.location_id
            LEFT JOIN Calendar c ON c.ROWID = ci.calendar_id
            WHERE ci.start_date > ?
              AND ci.start_date < ?
            ORDER BY ci.start_date ASC
        """, (start_mac, end_mac)).fetchall()
    except sqlite3.OperationalError as e:
        logger.error("Failed to query Calendar (primary schema): %s", e)
        # Last-resort fallback: bare CalendarItem with no joins.
        try:
            rows = conn.execute("""
                SELECT
                    ROWID,
                    summary as title,
                    start_date,
                    end_date,
                    all_day as is_all_day,
                    description as notes,
                    NULL as location,
                    NULL as calendar_name,
                    0 as has_recurrences
                FROM CalendarItem
                WHERE start_date > ?
                  AND start_date < ?
                ORDER BY start_date ASC
            """, (start_mac, end_mac)).fetchall()
        except sqlite3.OperationalError as e2:
            logger.error("Calendar schema not recognised: %s", e2)
            conn.close()
            return []
    except Exception as e:
        logger.error("Unexpected error querying Calendar: %s", e)
        conn.close()
        return []

    try:
        attendee_map = _load_attendees(conn)
    except Exception as e:
        logger.warning("Attendee load failed (continuing without): %s", e)
        attendee_map = {}

    conn.close()

    events: list[CalendarEvent] = []
    for row in rows:
        try:
            start = datetime.fromtimestamp(
                (row["start_date"] or 0) + MAC_EPOCH_OFFSET, tz=timezone.utc
            )
            end = None
            if row["end_date"]:
                end = datetime.fromtimestamp(
                    row["end_date"] + MAC_EPOCH_OFFSET, tz=timezone.utc
                )

            location = row["location"] if row["location"] else None
            if isinstance(location, int):
                location = None

            try:
                rowid = row["ROWID"]
            except (IndexError, KeyError):
                rowid = 0

            events.append(CalendarEvent(
                title=row["title"] or "Untitled Event",
                start_date=start,
                end_date=end,
                location=str(location) if location else None,
                attendees=attendee_map.get(rowid, []),
                calendar_name=row["calendar_name"],
                is_all_day=bool(row["is_all_day"]),
                notes=row["notes"],
                recurrence="recurring" if row["has_recurrences"] else None,
            ))
        except Exception as e:
            logger.warning("Skipping malformed Calendar row: %s", e)
            continue

    logger.info(
        "Extracted %d calendar events from %s", len(events), resolved,
    )
    return events


def meeting_contacts(events: list[CalendarEvent]) -> dict[str, int]:
    """Count how often each person appears as a meeting attendee.

    Returns dict of name to meeting count, for cross-referencing
    with the contact graph.
    """
    counts: dict[str, int] = {}
    for event in events:
        for attendee in event.attendees:
            counts[attendee] = counts.get(attendee, 0) + 1

    return dict(sorted(counts.items(), key=lambda x: x[1], reverse=True))
