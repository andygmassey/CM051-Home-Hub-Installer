"""Extract calendar events from macOS Calendar database.

macOS Calendar stores data in:
    ~/Library/Calendars/

The structure is a set of .calendar directories, each containing
.ics files for individual events. We can also read the Calendar
cache database for faster bulk extraction:
    ~/Library/Calendars/Calendar Cache

This covers both iCloud Calendar and Google Calendar events that
are synced to the Mac's Calendar app.

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


def extract_events(
    db_path: Optional[Path] = None,
    since_days: int = 365,
    future_days: int = 30,
) -> list[CalendarEvent]:
    """Extract calendar events from the Calendar cache.

    Args:
        db_path: Path to Calendar Cache database.
        since_days: Include events from last N days.
        future_days: Include events up to N days in the future.

    Returns:
        List of CalendarEvent objects, chronological order.
    """
    db_path = db_path or DEFAULT_CALENDAR_CACHE

    if not db_path.exists():
        raise FileNotFoundError(f"Calendar cache not found at {db_path}")

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            raise PermissionError(
                "Cannot read Calendar data. Grant Full Disk Access."
            ) from e
        raise

    conn.row_factory = sqlite3.Row

    now_mac = datetime.now(timezone.utc).timestamp() - MAC_EPOCH_OFFSET
    start_mac = now_mac - (since_days * 86400)
    end_mac = now_mac + (future_days * 86400)

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
        logger.error("Failed to query Calendar: %s", e)
        # Try alternative schema (varies by macOS version)
        try:
            rows = conn.execute("""
                SELECT
                    ROWID,
                    summary as title,
                    start_date,
                    end_date,
                    all_day as is_all_day,
                    description as notes,
                    location,
                    NULL as calendar_name,
                    0 as has_recurrences
                FROM CalendarItem
                WHERE start_date > ?
                  AND start_date < ?
                ORDER BY start_date ASC
            """, (start_mac, end_mac)).fetchall()
        except sqlite3.OperationalError:
            logger.error("Calendar schema not recognised on this macOS version")
            conn.close()
            return []

    # Get attendees separately (many-to-many)
    attendee_map = {}
    try:
        att_rows = conn.execute("""
            SELECT
                a.item_id,
                a.address as email,
                a.common_name as name
            FROM Attendee a
        """).fetchall()
        for att in att_rows:
            item_id = att["item_id"]
            if item_id not in attendee_map:
                attendee_map[item_id] = []
            name = att["name"] or att["email"] or ""
            if name:
                attendee_map[item_id].append(name)
    except sqlite3.OperationalError:
        pass  # Attendee table may not exist in all versions

    conn.close()

    events = []
    for row in rows:
        start = datetime.fromtimestamp(
            (row["start_date"] or 0) + MAC_EPOCH_OFFSET, tz=timezone.utc
        )
        end = None
        if row["end_date"]:
            end = datetime.fromtimestamp(
                row["end_date"] + MAC_EPOCH_OFFSET, tz=timezone.utc
            )

        location = row["location"] if row["location"] else None
        # Clean up location if it's from the Location table
        if isinstance(location, int):
            location = None

        # sqlite3.Row doesn't support .get() — use try/except for ROWID
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

    logger.info("Extracted %d calendar events", len(events))
    return events


def meeting_contacts(events: list[CalendarEvent]) -> dict[str, int]:
    """Count how often each person appears as a meeting attendee.

    Returns dict of name → meeting count, for cross-referencing
    with the contact graph.
    """
    counts: dict[str, int] = {}
    for event in events:
        for attendee in event.attendees:
            counts[attendee] = counts.get(attendee, 0) + 1

    return dict(sorted(counts.items(), key=lambda x: x[1], reverse=True))
