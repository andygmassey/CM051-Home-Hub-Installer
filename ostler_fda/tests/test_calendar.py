"""Tests for Calendar extractor."""
from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

from ostler_fda.calendar import (
    MAC_EPOCH_OFFSET,
    CalendarEvent,
    extract_events,
    meeting_contacts,
)


def _create_calendar_db(path: Path) -> sqlite3.Connection:
    """Create a Calendar Cache database with the expected schema."""
    conn = sqlite3.connect(str(path))
    conn.executescript("""
        CREATE TABLE Calendar (
            ROWID INTEGER PRIMARY KEY,
            title TEXT
        );
        CREATE TABLE Location (
            ROWID INTEGER PRIMARY KEY,
            title TEXT
        );
        CREATE TABLE CalendarItem (
            ROWID INTEGER PRIMARY KEY,
            summary TEXT,
            start_date REAL,
            end_date REAL,
            all_day INTEGER DEFAULT 0,
            description TEXT,
            location_id INTEGER,
            calendar_id INTEGER,
            has_recurrences INTEGER DEFAULT 0
        );
        CREATE TABLE Attendee (
            ROWID INTEGER PRIMARY KEY,
            item_id INTEGER,
            address TEXT,
            common_name TEXT
        );
    """)
    return conn


def _mac_time(year: int, month: int, day: int, hour: int = 12) -> float:
    return datetime(year, month, day, hour, tzinfo=timezone.utc).timestamp() - MAC_EPOCH_OFFSET


def _recent_mac_time(hours_ago: int = 1) -> float:
    return datetime.now(timezone.utc).timestamp() - MAC_EPOCH_OFFSET - (hours_ago * 3600)


class TestExtractEvents:
    """Test calendar event extraction."""

    def test_basic_extraction(self, tmp_path):
        db = tmp_path / "Calendar Cache"
        conn = _create_calendar_db(db)

        conn.execute("INSERT INTO Calendar (ROWID, title) VALUES (1, 'Work')")
        conn.execute("""
            INSERT INTO CalendarItem
            (ROWID, summary, start_date, end_date, all_day, description,
             location_id, calendar_id, has_recurrences)
            VALUES (1, 'Team Standup', ?, ?, 0, 'Daily sync', NULL, 1, 0)
        """, (_recent_mac_time(2), _recent_mac_time(1)))
        conn.commit()
        conn.close()

        events = extract_events(db_path=db)
        assert len(events) == 1
        assert events[0].title == "Team Standup"
        assert events[0].calendar_name == "Work"
        assert events[0].notes == "Daily sync"
        assert events[0].is_all_day is False

    def test_all_day_event(self, tmp_path):
        db = tmp_path / "Calendar Cache"
        conn = _create_calendar_db(db)

        conn.execute("INSERT INTO Calendar (ROWID, title) VALUES (1, 'Personal')")
        conn.execute("""
            INSERT INTO CalendarItem
            (ROWID, summary, start_date, end_date, all_day, description,
             location_id, calendar_id, has_recurrences)
            VALUES (1, 'Birthday', ?, ?, 1, NULL, NULL, 1, 0)
        """, (_recent_mac_time(24), _recent_mac_time(0)))
        conn.commit()
        conn.close()

        events = extract_events(db_path=db)
        assert len(events) == 1
        assert events[0].is_all_day is True

    def test_with_location(self, tmp_path):
        db = tmp_path / "Calendar Cache"
        conn = _create_calendar_db(db)

        conn.execute("INSERT INTO Calendar (ROWID, title) VALUES (1, 'Work')")
        conn.execute("INSERT INTO Location (ROWID, title) VALUES (1, 'Pacific Coffee, Wan Chai')")
        conn.execute("""
            INSERT INTO CalendarItem
            (ROWID, summary, start_date, end_date, all_day, description,
             location_id, calendar_id, has_recurrences)
            VALUES (1, 'Coffee with Test Advisor', ?, ?, 0, NULL, 1, 1, 0)
        """, (_recent_mac_time(2), _recent_mac_time(1)))
        conn.commit()
        conn.close()

        events = extract_events(db_path=db)
        assert len(events) == 1
        assert events[0].location == "Pacific Coffee, Wan Chai"

    def test_with_attendees(self, tmp_path):
        db = tmp_path / "Calendar Cache"
        conn = _create_calendar_db(db)

        conn.execute("INSERT INTO Calendar (ROWID, title) VALUES (1, 'Work')")
        conn.execute("""
            INSERT INTO CalendarItem
            (ROWID, summary, start_date, end_date, all_day, description,
             location_id, calendar_id, has_recurrences)
            VALUES (1, 'Sprint Review', ?, ?, 0, NULL, NULL, 1, 0)
        """, (_recent_mac_time(2), _recent_mac_time(1)))
        conn.execute("INSERT INTO Attendee (ROWID, item_id, address, common_name) VALUES (1, 1, 'alice@co.com', 'Alice Chen')")
        conn.execute("INSERT INTO Attendee (ROWID, item_id, address, common_name) VALUES (2, 1, 'bob@co.com', 'Bob Smith')")
        conn.commit()
        conn.close()

        events = extract_events(db_path=db)
        assert len(events) == 1
        assert "Alice Chen" in events[0].attendees
        assert "Bob Smith" in events[0].attendees

    def test_date_range_filter(self, tmp_path):
        db = tmp_path / "Calendar Cache"
        conn = _create_calendar_db(db)

        conn.execute("INSERT INTO Calendar (ROWID, title) VALUES (1, 'Work')")
        # Event 1 hour ago (in range)
        conn.execute("""
            INSERT INTO CalendarItem (ROWID, summary, start_date, end_date, all_day, calendar_id, has_recurrences)
            VALUES (1, 'Recent', ?, ?, 0, 1, 0)
        """, (_recent_mac_time(1), _recent_mac_time(0)))
        # Event 400 days ago (out of range)
        conn.execute("""
            INSERT INTO CalendarItem (ROWID, summary, start_date, end_date, all_day, calendar_id, has_recurrences)
            VALUES (2, 'Ancient', ?, ?, 0, 1, 0)
        """, (_recent_mac_time(400 * 24), _recent_mac_time(399 * 24)))
        conn.commit()
        conn.close()

        events = extract_events(db_path=db, since_days=365)
        assert len(events) == 1
        assert events[0].title == "Recent"

    def test_recurring_event(self, tmp_path):
        db = tmp_path / "Calendar Cache"
        conn = _create_calendar_db(db)

        conn.execute("INSERT INTO Calendar (ROWID, title) VALUES (1, 'Work')")
        conn.execute("""
            INSERT INTO CalendarItem (ROWID, summary, start_date, end_date, all_day, calendar_id, has_recurrences)
            VALUES (1, 'Weekly 1:1', ?, ?, 0, 1, 1)
        """, (_recent_mac_time(2), _recent_mac_time(1)))
        conn.commit()
        conn.close()

        events = extract_events(db_path=db)
        assert events[0].recurrence == "recurring"

    def test_file_not_found(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            extract_events(db_path=tmp_path / "nonexistent")

    def test_empty_database(self, tmp_path):
        db = tmp_path / "Calendar Cache"
        conn = _create_calendar_db(db)
        conn.close()

        events = extract_events(db_path=db)
        assert events == []


class TestMeetingContacts:
    """Test attendee frequency counting."""

    def test_counts_attendees(self):
        now = datetime.now(timezone.utc)
        events = [
            CalendarEvent("Meeting 1", now, now, None, ["Alice", "Bob"], "Work", False, None, None),
            CalendarEvent("Meeting 2", now, now, None, ["Alice", "Charlie"], "Work", False, None, None),
            CalendarEvent("Meeting 3", now, now, None, ["Alice"], "Work", False, None, None),
        ]
        contacts = meeting_contacts(events)
        assert contacts["Alice"] == 3
        assert contacts["Bob"] == 1
        assert contacts["Charlie"] == 1

    def test_sorted_by_frequency(self):
        now = datetime.now(timezone.utc)
        events = [
            CalendarEvent("M1", now, now, None, ["Rare", "Common", "Common"], "W", False, None, None),
            CalendarEvent("M2", now, now, None, ["Common"], "W", False, None, None),
        ]
        contacts = meeting_contacts(events)
        keys = list(contacts.keys())
        assert keys[0] == "Common"

    def test_empty(self):
        assert meeting_contacts([]) == {}
