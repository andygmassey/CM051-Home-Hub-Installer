"""Filter and group BEFORE the cap, never after it (walk #27, shape S5).

1. Browsing search scanned at most 5 pages of 1000 points, in point-id order,
   and only then filtered by keyword. On the walk box safari_history holds
   8714 points, so about 43% of browsing history could never be found. The
   fixture here is 8714 points with the only match at id 7000.

2. people_recent took `ORDER BY DESC(?date) LIMIT limit*3` over meeting x
   attendee ROWS and only then dropped the owner and repeat people. With the
   owner and one busy contact in the 20 most recent meetings, the 15-row
   window held nobody else, so "who did I meet recently" returned one person.

Real stores where the defect is in the query: a loopback fake Qdrant that
pages exactly like the real scroll API, and a real pyoxigraph engine
(tests/_fake_oxigraph.py). Cast names only.
"""
from __future__ import annotations

import json
import sys
import threading
import unittest
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
sys.path.insert(0, str(REPO / "tests"))
sys.path.insert(0, str(HERE))

from _fake_oxigraph import FakeOxigraph  # noqa: E402
from test_people_list_endpoint import server  # noqa: E402  (loads ical-server.py with its stubs)

N_POINTS = 8714      # safari_history on Mini16, walk #27
MATCH_ID = 7000      # beyond the old 5000-point scan


class _FakeQdrant:
    """Pages /collections/<c>/points/scroll by id, 1000 (or `limit`) at a
    time, like Qdrant. `collections` maps a name to a list of payloads; the
    point id is the list index. Filters are not applied: every fixture point
    is one the real filter would admit."""

    def __init__(self, collections):
        self.collections = collections
        self.scroll_calls = 0
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):  # noqa: N802
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}")
                parts = self.path.split("/")
                coll = parts[2] if len(parts) > 2 else ""
                if self.path.endswith("/points/scroll"):
                    outer.scroll_calls += 1
                    data = outer.collections.get(coll, [])
                    start = int(body.get("offset") or 0)
                    lim = int(body.get("limit") or 10)
                    pts = [{"id": i, "payload": data[i]}
                           for i in range(start, min(start + lim, len(data)))]
                    nxt = start + lim if start + lim < len(data) else None
                    out = {"result": {"points": pts, "next_page_offset": nxt}}
                else:
                    out = {"result": []}
                raw = json.dumps(out).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(raw)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def _browsing_points():
    return [{
        "url": f"https://example.com/{i}",
        "title": "Sourdough starter guide" if i == MATCH_ID else f"Page {i}",
        "domain": "example.com", "timestamp": "2026-10-01T10:00:00Z",
    } for i in range(N_POINTS)]


def _no_embed(*_a, **_k):
    raise RuntimeError("embedding not under test")


class BrowsingSearchScansEverything(unittest.TestCase):
    def setUp(self):
        self.q = _FakeQdrant({"safari_history": _browsing_points()})
        self._saved = (server.QDRANT_URL, server._embed_text)
        server.QDRANT_URL = self.q.url
        server._embed_text = _no_embed

    def tearDown(self):
        server.QDRANT_URL, server._embed_text = self._saved
        self.q.close()

    def test_a_visit_past_the_old_5000_point_scan_is_found(self):
        out, code = server.api_browsing_search(q="sourdough", limit=10)
        self.assertEqual(code, 200, out)
        urls = [r["url"] for r in out["results"]]
        self.assertEqual(urls, [f"https://example.com/{MATCH_ID}"], out)
        self.assertNotIn("truncated", out)

    def test_control_a_word_on_no_page_finds_nothing(self):
        out, _ = server.api_browsing_search(q="zebrafish", limit=10)
        self.assertEqual(out["results"], [])
        self.assertGreaterEqual(self.q.scroll_calls, 9, "the whole collection was not read")

    def test_hitting_the_runaway_guard_is_reported_not_silent(self):
        saved = getattr(server, "_BROWSING_SCAN_MAX_PAGES", None)
        if saved is None:
            self.fail("no _BROWSING_SCAN_MAX_PAGES: the scan has no reported ceiling")
        server._BROWSING_SCAN_MAX_PAGES = 2
        try:
            out, _ = server.api_browsing_search(q="sourdough", limit=10)
        finally:
            server._BROWSING_SCAN_MAX_PAGES = saved
        self.assertTrue(out.get("truncated"), out)
        self.assertEqual(out.get("scanned"), 2000)


def _day(n):
    return (datetime.now(timezone.utc) - timedelta(days=n)).strftime("%Y-%m-%d")


def _meetings():
    B = "urn:test:"
    t = [
        f"<{B}owner> a pwg:Person ; pwg:displayName \"Jane Doe\" .",
        f"<{B}busy> a pwg:Person ; pwg:displayName \"Sam Brown\" .",
    ]
    # 20 meetings in the last two days, each with the owner and one busy contact.
    for i in range(20):
        t.append(f"<{B}m{i}> a pwg:Meeting ; pwg:meetingDate \"{_day(i % 2)}T{10 + i % 8:02d}:00:00\" ;"
                 f" pwg:meetingAttendee <{B}owner> , <{B}busy> ; pwg:meetingSummary \"Standup {i}\" .")
    # Five other people met earlier in the week, once each, with the owner.
    others = ["Tom Jones", "Carl Stewart", "Mary Coe", "Ben Patel", "Liz Andersen"]
    for j, name in enumerate(others):
        t.append(f"<{B}o{j}> a pwg:Person ; pwg:displayName \"{name}\" .")
        t.append(f"<{B}om{j}> a pwg:Meeting ; pwg:meetingDate \"{_day(3 + j % 3)}T09:00:00\" ;"
                 f" pwg:meetingAttendee <{B}owner> , <{B}o{j}> ; pwg:meetingSummary \"Catch-up\" .")
    # A merged-away duplicate of a busy contact must not count as a person.
    t.append(f"<{B}busy-dup> a pwg:Person ; pwg:displayName \"Sam Brown\" ; pwg:mergedInto <{B}busy> .")
    t.append(f"<{B}mdup> a pwg:Meeting ; pwg:meetingDate \"{_day(0)}T08:00:00\" ;"
             f" pwg:meetingAttendee <{B}busy-dup> .")
    return "INSERT DATA {\n" + "\n".join(t) + "\n}", others


class PeopleRecentGroupsBeforeTheCap(unittest.TestCase):
    def setUp(self):
        self.ox = FakeOxigraph()
        data, self.others = _meetings()
        self.ox.update(data)
        self._saved = (server.OXIGRAPH_URL, server.USER_NAME)
        server.OXIGRAPH_URL = self.ox.url
        server.USER_NAME = "Jane Doe"  # the owner, screened by name

    def tearDown(self):
        server.OXIGRAPH_URL, server.USER_NAME = self._saved
        self.ox.close()

    def test_a_busy_week_still_returns_limit_people(self):
        out = server.people_recent(days=7, limit=5)
        names = [c["name"] for c in out["contacts"]]
        self.assertEqual(len(names), 5, out)
        self.assertEqual(len(set(names)), 5, names)
        self.assertEqual(names[0], "Sam Brown", "newest meeting first")
        self.assertNotIn("Jane Doe", names)

    def test_control_a_quiet_week_returns_everyone_once(self):
        out = server.people_recent(days=7, limit=50)
        names = sorted(c["name"] for c in out["contacts"])
        self.assertEqual(names, sorted(["Sam Brown"] + self.others), out)


class StaleAndTimelineReadEverything(unittest.TestCase):
    """The same shape in two siblings: people_stale took 25 stale points in
    id order and sorted those; the Timeline's conversation leg stopped at
    limit*4 points in id order and dated the Timeline from that slice."""

    def setUp(self):
        import time
        now = int(time.time())
        year = 365 * 86400
        people = []
        for i in range(2000):
            people.append({
                "display_name": f"Sam Brown {i}", "contact_type": "person",
                "last_contact_ts": now - year, "last_contact": "2025-10-01",
                "person_uri": f"urn:test:p{i}",
            })
        # The most stale person sits far past the old 25-point window.
        people[1500] = {
            "display_name": "Tom Jones", "contact_type": "person",
            "last_contact_ts": now - 5 * year, "last_contact": "2021-10-01",
            "person_uri": "urn:test:most-stale",
        }
        convs = [{"date": "2025-01-01", "channel": "whatsapp", "contact_name": "Ben Coe"}
                 for _ in range(1000)]
        convs[900] = {"date": _day(1), "channel": "imessage", "contact_name": "Liz Andersen"}
        self.q = _FakeQdrant({"people": people, "conversations": convs})
        self.ox = FakeOxigraph()  # empty graph: the recheck finds no newer contact
        self._saved = (server.QDRANT_URL, server.OXIGRAPH_URL)
        server.QDRANT_URL = self.q.url
        server.OXIGRAPH_URL = self.ox.url

    def tearDown(self):
        server.QDRANT_URL, server.OXIGRAPH_URL = self._saved
        self.q.close()
        self.ox.close()

    def test_the_most_stale_person_is_first_even_past_the_old_window(self):
        out = server.people_stale(months=3, limit=5)
        names = [c["name"] for c in out["contacts"]]
        self.assertTrue(names, out)
        self.assertEqual(names[0], "Tom Jones", names)

    def test_the_newest_conversation_is_on_the_timeline_even_past_the_old_window(self):
        rows, err = server._timeline_conversations(past_days=3650, limit=10)
        self.assertIsNone(err)
        self.assertEqual(rows[0]["date"], _day(1), rows[:2])


if __name__ == "__main__":
    unittest.main()
