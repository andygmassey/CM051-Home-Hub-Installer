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

    def test_a_free_day_in_a_populated_store_is_a_200_zero(self):
        # Events on other days, none today: a genuinely free day.
        n = _now().replace(hour=12, minute=0, second=0)
        self._write("calendar_events.json", [
            {"title": "Tomorrow thing", "start_date": n + timedelta(days=1),
             "end_date": n + timedelta(days=1, hours=1), "attendees": [], "is_all_day": False}])
        status, body = ical_server.build_calendar_response(1)
        self.assertEqual((status, body["count"]), (200, 0))
        self.assertNotIn("degraded", body)

    def test_an_empty_but_present_store_is_no_data_not_a_free_day(self):
        # The extractor wrote [] (no Full Disk Access, an empty database):
        # that is "could not look", and the brief must say so, not "free day".
        self._write("calendar_events.json", [])
        status, body = ical_server.build_calendar_response(1)
        self.assertEqual(status, 503)
        self.assertTrue(body["degraded"])
        self.assertTrue(any("holds no events at all" in d for d in body["detail"]), body)

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

    def _populated_other_day(self):
        # A store with events, none today: the local read succeeds and
        # contributes nothing, so the iCloud arm is what the test sees.
        n = _now().replace(hour=12, minute=0, second=0)
        self._write("calendar_events.json", [
            {"title": "Tomorrow thing", "start_date": n + timedelta(days=1),
             "end_date": n + timedelta(days=1, hours=1), "attendees": [], "is_all_day": False}])

    def test_unpaired_icloud_is_not_connected_not_empty(self):
        self._populated_other_day()
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
        self._populated_other_day()
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

    # ── Staleness (Mini16, 2026-10-19: a 45-hour-old store served as today's) ──

    def _age_store(self, name, hours):
        import os, time
        t = time.time() - hours * 3600
        os.utime(Path(self.dir, name), (t, t))

    def test_a_fresh_calendar_store_is_not_degraded(self):
        n = _now().replace(hour=12, minute=0, second=0)
        self._write("calendar_events.json", [
            {"title": "Standup", "start_date": n, "end_date": n + timedelta(hours=1),
             "attendees": ["a@example.com"], "is_all_day": False}])
        status, body = ical_server.build_calendar_response(1)
        self.assertEqual(status, 200)
        self.assertNotIn("degraded", body)
        self.assertNotIn("stale", body)
        self.assertLess(body["local_store_age_seconds"], 60)

    def test_a_calendar_store_three_writer_intervals_old_is_degraded_and_stale(self):
        n = _now().replace(hour=12, minute=0, second=0)
        self._write("calendar_events.json", [
            {"title": "Standup", "start_date": n, "end_date": n + timedelta(hours=1),
             "attendees": ["a@example.com"], "is_all_day": False}])
        self._age_store("calendar_events.json", 45)
        status, body = ical_server.build_calendar_response(1)
        self.assertEqual(status, 200)
        # The events are still served (the reader decides what to do with
        # them), but the answer says it is old, in a field every reader reads.
        self.assertEqual([e["title"] for e in body["events"]], ["Standup"])
        self.assertTrue(body.get("degraded"), body)
        self.assertTrue(body.get("stale"), body)
        self.assertGreaterEqual(body["local_store_age_seconds"], 45 * 3600 - 5)
        self.assertTrue(any("calendar_events.json is 45 hours old" in e for e in body["errors"]), body)

    def test_the_stale_threshold_follows_the_writer_interval(self):
        # Three intervals, inclusive: 2h59m at the default hourly writer is
        # fresh, 3h is stale; a 10-minute writer makes 31 minutes stale.
        self.assertIsNone(ical_server._stale_detail("x.json", 3 * 3600 - 1))
        self.assertIsNotNone(ical_server._stale_detail("x.json", 3 * 3600))
        with mock.patch.dict("os.environ", {"OSTLER_FDA_RERUN_INTERVAL_S": "600"}):
            self.assertIsNotNone(ical_server._stale_detail("x.json", 31 * 60))
            self.assertIsNone(ical_server._stale_detail("x.json", 29 * 60))

    def test_a_stale_mail_store_is_degraded_and_stale(self):
        n = _now()
        self._write("apple_mail.json", [
            {"subject": "Hello", "sender": "a@example.com", "date_received": n, "is_read": False}])
        self._age_store("apple_mail.json", 50)
        status, body = ical_server.fetch_recent_emails(24)
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 1)
        self.assertTrue(body.get("degraded") and body.get("stale"), body)
        self.assertTrue(any("apple_mail.json is 50 hours old" in e for e in body["errors"]), body)

    # ── Duplicates (Mini16, 2026-10-19: one flight, two rows, "a related event") ──

    def test_two_spellings_of_one_flight_are_one_event(self):
        n = _now().replace(hour=13, minute=25, second=0)
        rows = [
            {"title": "Pat. XY 123", "start_date": n, "end_date": n + timedelta(hours=6),
             "attendees": [], "is_all_day": False, "calendar_name": "Family"},
            {"title": "Pat's flight to London Heathrow Airport XY 123", "start_date": n,
             "end_date": n + timedelta(hours=6), "attendees": [], "is_all_day": False,
             "calendar_name": "Family"},
            # Same slot, different event: both kept.
            {"title": "Sam's piano lesson", "start_date": n, "end_date": n + timedelta(hours=6),
             "attendees": [], "is_all_day": False, "calendar_name": "Family"},
        ]
        self._write("calendar_events.json", rows)
        status, body = ical_server.build_calendar_response(1)
        self.assertEqual(status, 200)
        self.assertEqual(sorted(e["title"] for e in body["events"]),
                         ["Pat's flight to London Heathrow Airport XY 123", "Sam's piano lesson"])
        self.assertEqual(body["count"], 2)

    def test_a_shared_bare_number_is_not_a_shared_event(self):
        # Archie, #3021: "2026" in two titles is a year, not a booking code.
        # Two different events in one slot keep both rows; a mixed code
        # ("XY123") still folds.
        n = _now().replace(hour=10, minute=0, second=0)
        rows = [
            {"title": "Review 2026 budget", "start_date": n, "end_date": n + timedelta(hours=1),
             "attendees": [], "is_all_day": False, "calendar_name": "Work"},
            {"title": "Plan 2026 offsite", "start_date": n, "end_date": n + timedelta(hours=1),
             "attendees": [], "is_all_day": False, "calendar_name": "Work"},
            {"title": "XY123 to the coast", "start_date": n, "end_date": n + timedelta(hours=1),
             "attendees": [], "is_all_day": False, "calendar_name": "Work"},
            {"title": "Sam XY123", "start_date": n, "end_date": n + timedelta(hours=1),
             "attendees": [], "is_all_day": False, "calendar_name": "Work"},
        ]
        self._write("calendar_events.json", rows)
        status, body = ical_server.build_calendar_response(1)
        self.assertEqual(status, 200)
        self.assertEqual(sorted(e["title"] for e in body["events"]),
                         ["Plan 2026 offsite", "Review 2026 budget", "XY123 to the coast"])

    def test_a_one_word_subset_title_is_not_the_same_event(self):
        # Red team, #3021: the containment rule must not merge distinct
        # events. One shared word is not a match; two are ("Budget review"
        # inside "Budget review with finance" is the same meeting).
        n = _now().replace(hour=11, minute=0, second=0)
        slot = {"start_date": n, "end_date": n + timedelta(hours=1), "attendees": [],
                "is_all_day": False, "calendar_name": "Work"}
        rows = [dict(slot, title=t) for t in (
            "Lunch", "Lunch with Sam",            # kept apart
            "Call", "Call the supplier",          # kept apart
            "Budget review", "Budget review with finance",  # folded
        )]
        self._write("calendar_events.json", rows)
        status, body = ical_server.build_calendar_response(1)
        self.assertEqual(status, 200)
        self.assertEqual(sorted(e["title"] for e in body["events"]),
                         ["Budget review with finance", "Call", "Call the supplier", "Lunch", "Lunch with Sam"])


class CalendarHandlerWritesTheBuilderReply(unittest.TestCase):
    """The /calendar handler writes what build_calendar_response returned.

    Batch 3 caught the handler binding the reply to one name and serialising
    another (NameError on every /calendar and /calendar/today request), which
    the builder-level tests above could not see. Drives do_GET itself."""

    def _get(self, path):
        import io
        h = ical_server.Handler.__new__(ical_server.Handler)
        h.path = path
        h.wfile = io.BytesIO()
        sent = []
        h._guard = lambda *a, **k: True
        h.send_response = lambda code, *a: sent.append(code)
        h.send_header = lambda *a: None
        h.end_headers = lambda: None
        reply = {"events": [], "count": 0, "period_days": 0, "sources": [], "marker": path}
        with mock.patch.object(ical_server, "build_calendar_response",
                               side_effect=lambda days: (207, dict(reply, period_days=days))):
            h.do_GET()
        return sent, json.loads(h.wfile.getvalue().decode())

    def test_calendar_today_writes_the_builder_reply(self):
        sent, body = self._get("/calendar/today")
        self.assertEqual(sent, [207])
        self.assertEqual((body["marker"], body["period_days"]), ("/calendar/today", 1))

    def test_calendar_writes_the_builder_reply(self):
        sent, body = self._get("/calendar?days=3")
        self.assertEqual(sent, [207])
        self.assertEqual((body["marker"], body["period_days"]), ("/calendar?days=3", 3))


if __name__ == "__main__":
    unittest.main()
