"""The brief's calendar and mail endpoints read the LOCAL ingested stores.

Customer installs have no iCloud CalDAV pairing and no gws Gmail credential,
so the old paths answered 200 with nothing and the brief told the customer
"No events today" with events on the calendar. All data here is synthetic.
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ical_server_wire_shape import ical_server  # noqa: E402


def _now():
    return datetime.now().astimezone().replace(microsecond=0)


class BriefLocalStores(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="brief-local-")
        p = mock.patch.object(ical_server, "FDA_IMPORT_DIR", self.dir)
        p.start()
        self.addCleanup(p.stop)
        # No optional extras configured, as on a customer install.
        for target in ("ICAL_SCRIPT",):
            q = mock.patch.object(ical_server, target, "/nonexistent/ical-query.sh")
            q.start()
            self.addCleanup(q.stop)
        g = mock.patch.object(ical_server, "query_google_calendar",
                              side_effect=RuntimeError("401"))
        g.start()
        self.addCleanup(g.stop)

    def _write(self, name, rows):
        Path(self.dir, name).write_text(json.dumps(rows, default=str))

    def test_todays_events_are_returned(self):
        n = _now().replace(hour=12, minute=0, second=0)
        rows = [
            {"title": "Standup", "start_date": n, "end_date": n + timedelta(hours=1),
             "attendees": ["alice@example.com"], "is_all_day": False},
            {"title": "Lunch", "start_date": n + timedelta(hours=1),
             "end_date": n + timedelta(hours=2), "attendees": [], "is_all_day": False},
            {"title": "Tomorrow thing", "start_date": n + timedelta(days=1),
             "end_date": n + timedelta(days=1, hours=1), "attendees": [], "is_all_day": False},
        ]
        self._write("calendar_events.json", rows)
        status, body = ical_server.build_calendar_response(1)
        self.assertEqual(status, 200)
        self.assertEqual([e["title"] for e in body["events"]], ["Standup", "Lunch"])
        self.assertEqual(body["count"], 2)

    def test_genuinely_empty_day_is_a_200_zero(self):
        self._write("calendar_events.json", [])
        status, body = ical_server.build_calendar_response(1)
        self.assertEqual((status, body["count"]), (200, 0))

    def test_calendar_store_missing_is_not_an_empty_200(self):
        status, body = ical_server.build_calendar_response(1)
        self.assertEqual(status, 503)
        self.assertTrue(body["degraded"])
        self.assertIn("error", body)

    def test_calendar_store_corrupt_is_not_an_empty_200(self):
        Path(self.dir, "calendar_events.json").write_text("{not json")
        status, _ = ical_server.build_calendar_response(1)
        self.assertEqual(status, 503)

    def _script(self, rc):
        sh = Path(self.dir, "ical-query.sh")
        sh.write_text(f"#!/bin/sh\nexit {rc}\n")
        sh.chmod(0o755)
        q = mock.patch.object(ical_server, "ICAL_SCRIPT", str(sh))
        q.start()
        self.addCleanup(q.stop)

    def test_unpaired_icloud_is_not_connected_not_empty(self):
        self._write("calendar_events.json", [])
        self._script(3)
        status, body = ical_server.build_calendar_response(1)
        self.assertEqual(status, 200)
        self.assertEqual(body["not_connected"], ["iCloud"])
        self.assertNotIn("degraded", body)

    def test_unpaired_icloud_and_no_local_store_is_503(self):
        self._script(3)
        status, _ = ical_server.build_calendar_response(1)
        self.assertEqual(status, 503)

    def test_icloud_script_failure_degrades(self):
        self._write("calendar_events.json", [])
        self._script(1)
        status, body = ical_server.build_calendar_response(1)
        self.assertEqual(status, 200)
        self.assertTrue(body["degraded"])

    def test_install_wrapper_exits_3_when_unpaired(self):
        root = Path(__file__).resolve().parents[4]
        text = (root / "install.sh").read_text()
        i = text.index("iCloud not paired")
        self.assertIn("exit 3", text[i:i + 600])
        self.assertNotIn("exit 0", text[i:i + 600])

    def test_birthdays_one_row_per_uri_even_when_names_match(self):
        """Characterisation, not a fix. Two LIVE person URIs with the same
        name and birthday are two rows: dedupe is by person URI on purpose
        (a name dedupe collapsed distinct people). A same-name pair is an
        unmerged duplicate, i.e. an identity-resolution miss, fixed by merging
        the people, not by hiding one at the birthday query."""
        bday = (datetime.now() + timedelta(days=2)).strftime("%Y-%m-%d")
        rows = [
            {"p": "urn:test:p1", "name": "Test Person", "bday": bday, "bnode": "urn:test:p1"},
            {"p": "urn:test:p2", "name": "Test Person", "bday": bday, "bnode": "urn:test:p2"},
        ]
        with mock.patch.object(ical_server, "_sparql_select", return_value=rows), \
             mock.patch.object(ical_server, "_load_people_list_self_uris", return_value=set()), \
             mock.patch.object(ical_server, "_load_carded_uris", return_value={"urn:test:p1", "urn:test:p2"}):
            out = ical_server.people_birthdays(days=14)
        self.assertEqual([r["name"] for r in out["people"]], ["Test Person", "Test Person"])

    def test_mail_fixture_is_counted(self):
        n = _now()
        rows = [
            {"subject": "Fresh A", "sender": "a@example.com",
             "date_received": n - timedelta(hours=2), "is_read": False},
            {"subject": "Fresh B", "sender": "b@example.com",
             "date_received": n - timedelta(hours=5), "is_read": True},
            {"subject": "Old", "sender": "c@example.com",
             "date_received": n - timedelta(days=3), "is_read": False},
        ]
        self._write("apple_mail.json", rows)
        status, body = ical_server.fetch_recent_emails(hours=24)
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 2)          # received in 24 h
        self.assertEqual(body["unread_total"], 2)   # measured unread, all time
        self.assertEqual(body["emails"][0]["subject"], "Fresh A")
        self.assertEqual(body["source"], "apple_mail")

    def test_mail_source_failure_is_not_an_empty_200(self):
        with mock.patch.object(ical_server, "_fetch_recent_emails_gws",
                               return_value={"emails": [], "count": 0,
                                             "error": "401 No credentials"}):
            status, body = ical_server.fetch_recent_emails(hours=24)
        self.assertEqual(status, 503)
        self.assertTrue(body["degraded"])
        self.assertNotIn("count", body)


if __name__ == "__main__":
    unittest.main()
