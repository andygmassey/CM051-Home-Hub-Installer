"""The Apple Calendar extractor carries each event's calendar id (its UUID).

An owner rule ("ignore calendar Work") is bound to the calendar's stable id,
so the extractor must say which id each event came from. Synthetic database
only: two calendars, one event each, built in a temp directory.

Controls:
- a schema WITHOUT a Calendar.UUID column still extracts every event with its
  calendar name and location (only the id is lost, never the row);
- an event whose calendar row has no UUID carries no id.

CANNOT-RUN here: a real macOS Calendar database (the UUID column is taken from
the macOS 14/15 schema, not verified on a box).
"""
from __future__ import annotations

import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from ostler_fda import calendar as cal

MAC_EPOCH = 978307200  # seconds from 1970-01-01 to 2001-01-01


def _mac(dt: datetime) -> float:
    return dt.timestamp() - MAC_EPOCH


def _build(path: Path, with_uuid: bool) -> None:
    conn = sqlite3.connect(path)
    uuid_col = ", UUID TEXT" if with_uuid else ""
    conn.execute(f"CREATE TABLE Calendar (ROWID INTEGER PRIMARY KEY, title TEXT{uuid_col})")
    conn.execute("CREATE TABLE Location (ROWID INTEGER PRIMARY KEY, title TEXT)")
    conn.execute(
        "CREATE TABLE CalendarItem (ROWID INTEGER PRIMARY KEY, summary TEXT, "
        "start_date REAL, end_date REAL, all_day INTEGER, description TEXT, "
        "location_id INTEGER, calendar_id INTEGER, has_recurrences INTEGER)")
    conn.execute("CREATE TABLE Attendee (ROWID INTEGER PRIMARY KEY, owner_id INTEGER, "
                 "email TEXT, display_name TEXT)")
    if with_uuid:
        conn.execute("INSERT INTO Calendar VALUES (1, 'Work', 'UUID-WORK-0001')")
        conn.execute("INSERT INTO Calendar VALUES (2, 'Home', 'UUID-HOME-0002')")
    else:
        conn.execute("INSERT INTO Calendar VALUES (1, 'Work')")
        conn.execute("INSERT INTO Calendar VALUES (2, 'Home')")
    conn.execute("INSERT INTO Location VALUES (1, 'Room 1')")
    start = datetime.now(timezone.utc) + timedelta(days=1)
    for rowid, title, cal_row in ((1, "Work standup", 1), (2, "Dentist", 2)):
        conn.execute(
            "INSERT INTO CalendarItem VALUES (?, ?, ?, ?, 0, NULL, 1, ?, 0)",
            (rowid, title, _mac(start), _mac(start + timedelta(minutes=30)), cal_row))
    conn.commit()
    conn.close()


class CalendarIdFromStore(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _extract(self, with_uuid: bool):
        db = self.dir / ("with_uuid.db" if with_uuid else "no_uuid.db")
        _build(db, with_uuid)
        return {e.title: e for e in cal.extract_events(db_path=db, since_days=7, future_days=7)}

    def test_each_event_carries_its_calendar_uuid(self):
        events = self._extract(with_uuid=True)
        self.assertEqual(events["Work standup"].calendar_name, "Work")
        self.assertEqual(events["Work standup"].calendar_id, "UUID-WORK-0001")
        self.assertEqual(events["Dentist"].calendar_name, "Home")
        self.assertEqual(events["Dentist"].calendar_id, "UUID-HOME-0002")

    def test_a_store_without_a_uuid_column_keeps_every_event_without_an_id(self):
        events = self._extract(with_uuid=False)
        self.assertEqual(sorted(events), ["Dentist", "Work standup"])
        self.assertEqual(events["Work standup"].calendar_name, "Work")
        self.assertEqual(events["Work standup"].location, "Room 1")
        self.assertIsNone(events["Work standup"].calendar_id)


if __name__ == "__main__":
    unittest.main()
