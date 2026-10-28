"""I22: a past meeting keeps its time on the Timeline; an all-day event stays all-day.

F&F walk (TestFlight, 2026-10-24): every past meeting on the iOS Timeline read
"All day". The app (CM031 TimelineDataService.serverEntries) takes the Hub's
``all_day`` flag when sent, else treats a date-only ``timestamp`` as all-day.
The Hub's ``_timeline_from_graph`` cut each meeting's ``pwg:meetingDate`` to
its first ten characters, so every past row reached the app date-only.

The graph holds the full start (the calendar ingest writes
``2026-05-01 09:30:00+00:00``) and, from this change, the calendar's own
all-day flag as ``pwg:meetingAllDay``. These tests drive the REAL
``api_timeline`` with the graph read patched to rows in exactly that shape.

The same file runs against CM041 upstream and the copy vendored into CM051, so
it asserts the instant and the flag, never one tree's string format.
Synthetic data only.
"""
from __future__ import annotations

import importlib.util
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"


def _load():
    spec = importlib.util.spec_from_file_location("ical_server_i22", SERVER_FILE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


server = _load()

# Graph rows as the GROUP_CONCAT query returns them, newest first.
ROWS = [
    # timed, flagged by the ingest
    {"m": "urn:m1", "date": "2026-05-04 09:30:00+00:00", "allDay": "false",
     "summary": "Design review", "location": "Room 2", "attendees": "Sam Doe"},
    # all-day, flagged by the ingest (Apple stores the floating date at 00:00 UTC)
    {"m": "urn:m2", "date": "2026-05-03 00:00:00+00:00", "allDay": "true",
     "summary": "Company offsite", "location": "", "attendees": "Sam Doe"},
    # an older graph row with no flag, timed
    {"m": "urn:m3", "date": "2026-05-02T14:15:00", "summary": "Call",
     "location": "", "attendees": "Sam Doe"},
    # an older graph row with no flag, a bare date
    {"m": "urn:m4", "date": "2026-05-01", "summary": "Holiday",
     "location": "", "attendees": ""},
]


def _entries(rows=ROWS):
    captured = {}

    def _select(q, *a, **k):
        captured.setdefault("q", q)
        return rows

    with patch.object(server, "query_google_calendar", return_value=[]), \
         patch.object(server, "_sparql_select", side_effect=_select), \
         patch.object(server, "_timeline_conversations", return_value=([], None)):
        result = server.api_timeline(days=7, past_days=3650, limit=200)
    by_title = {e["title"]: e for e in result["entries"]}
    return by_title, captured.get("q", "")


def _instant(ts):
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return dt if dt.tzinfo else None


class TestTimelineKeepsMeetingTime(unittest.TestCase):

    def test_timed_past_meeting_keeps_its_time_and_is_not_all_day(self):
        e, _ = _entries()
        row = e["Design review"]
        self.assertIs(row["all_day"], False)
        self.assertEqual(_instant(row["timestamp"]),
                         datetime(2026, 5, 4, 9, 30, tzinfo=timezone.utc))

    def test_all_day_event_stays_all_day_on_its_own_date(self):
        e, _ = _entries()
        row = e["Company offsite"]
        self.assertIs(row["all_day"], True)
        self.assertTrue(row["timestamp"].startswith("2026-05-03"), row["timestamp"])

    def test_older_unflagged_timed_row_keeps_its_time(self):
        e, _ = _entries()
        row = e["Call"]
        self.assertIs(row["all_day"], False)
        self.assertIn("14:15", row["timestamp"])

    def test_older_unflagged_bare_date_is_all_day(self):
        e, _ = _entries()
        row = e["Holiday"]
        self.assertIs(row["all_day"], True)
        self.assertTrue(row["timestamp"].startswith("2026-05-01"), row["timestamp"])

    def test_every_entry_carries_the_flag(self):
        e, _ = _entries()
        for title, row in e.items():
            self.assertIn("all_day", row, title)
            self.assertIsInstance(row["all_day"], bool, title)

    def test_the_graph_query_reads_the_all_day_flag(self):
        _, q = _entries()
        self.assertIn("pwg:meetingAllDay", q)

    def test_legacy_items_keep_their_date_shape(self):
        # The legacy `items` field (wiki, brief) still carries the date alone.
        with patch.object(server, "query_google_calendar", return_value=[]), \
             patch.object(server, "_sparql_select", return_value=ROWS), \
             patch.object(server, "_timeline_conversations", return_value=([], None)):
            result = server.api_timeline(days=7, past_days=3650, limit=200)
        dates = sorted(i["date"] for i in result["items"] if i.get("kind") in ("meeting", "event"))
        self.assertEqual(dates, ["2026-05-01", "2026-05-02", "2026-05-03", "2026-05-04"])


if __name__ == "__main__":
    unittest.main()
