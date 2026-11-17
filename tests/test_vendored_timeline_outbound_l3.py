"""``/api/v1/timeline?outbound=1`` (read by the 7-day digest) withholds L3.

``_timeline_from_graph(outbound=True)`` applies the fail-closed L3 filter
(``pwg_privacy.is_l3``) to each meeting: its own level and EACH attendee's,
most-restrictive wins, a missing meeting level inherits the attendee's (never
L1), unparseable or nothing-at-all -> hidden. Since the 2026-11-17 review ruling
the Timeline obeys the request's destination (undeclared = unknown) and the
``outbound`` flag changes nothing; owner_local sees every level, labelled.

Runs the shipped SPARQL against a real engine (rdflib). Synthetic data only.
"""
from __future__ import annotations

import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import json
import socket
import sys
import threading
import time
import urllib.request
from http.server import HTTPServer
from pathlib import Path

# VENDORED COPY of CM041 assistant_api/tests/test_timeline_outbound_l3.py,
# loading the shipped ical-server through the repo's own loader.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm041" / "assistant_api" / "tests"))
from test_ical_server_wire_shape import ical_server as server  # noqa: E402


def _no_calendar():
    return patch.object(server, "query_google_calendar", return_value=[])


class _Harness:
    def __init__(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        self.port = s.getsockname()[1]
        s.close()
        self.httpd = HTTPServer(("127.0.0.1", self.port), server.Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def __enter__(self):
        self.thread.start()
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", self.port), 0.1):
                    break
            except OSError:
                time.sleep(0.02)
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)

    def get(self, path):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            headers={"Authorization": "Bearer synthetic-token"})
        with self.opener.open(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())

PWG = "https://schema.ostler.ai/ontology#"
RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
_DAY = (datetime.now(timezone.utc) - timedelta(days=3)).strftime("%Y-%m-%d")

# (summary, meeting level, [(attendee, attendee level), ...])
FIXTURE = [
    ("L1 control lunch", "L1", [("Ana Doe", "L1")]),
    ("L3 secret meeting", "L3", [("Ana Doe", "L1")]),
    ("L1 meeting with an L3 attendee", "L1", [("Ana Doe", "L1"), ("Ben Doe", "L3")]),
    ("untagged meeting, L1 attendee", None, [("Ana Doe", "L1")]),
    ("untagged meeting, untagged attendee", None, [("Carl Doe", None)]),
    ("untagged meeting, L3 attendee", None, [("Ben Doe", "L3")]),
    ("unparseable level, no owner level", "banana", [("Carl Doe", None)]),
    ("L1 meeting, one untagged attendee", "L1", [("Ana Doe", "L1"), ("Carl Doe", None)]),
]
# The outbound reads declare owner_own_brief (the 7-day digest is the owner's own
# brief). Canonical rule: a missing tag beside a present one is L3, so an
# untagged meeting with an L1 attendee is no longer served (it inherited L1).
OUTBOUND_DESTINATION = "owner_own_brief"
VISIBLE = {
    "L1 control lunch",
    "L1 meeting, one untagged attendee",   # item level parses; an unknown owner never raises it
}


def _engine():
    from rdflib import Dataset, Literal, URIRef

    ds = Dataset(default_union=False)
    g = getattr(ds, "default_graph", None) or ds.default_context
    # attendee identity includes its level so one name can be both tagged and not
    for i, (summary, mlvl, atts) in enumerate(FIXTURE):
        m = URIRef("urn:synth:meeting:%d" % i)
        g.add((m, URIRef(RDF_TYPE), URIRef(PWG + "Meeting")))
        g.add((m, URIRef(PWG + "meetingDate"), Literal(_DAY + "T09:00:00")))
        g.add((m, URIRef(PWG + "meetingSummary"), Literal(summary)))
        if mlvl is not None:
            g.add((m, URIRef(PWG + "privacyLevel"), Literal(mlvl)))
        for name, lvl in atts:
            p = URIRef("urn:synth:person:%s:%s" % (name.split()[0].lower(), lvl))
            g.add((p, URIRef(PWG + "displayName"), Literal(name)))
            if lvl is not None:
                g.add((p, URIRef(PWG + "privacyLevel"), Literal(lvl)))
            g.add((m, URIRef(PWG + "meetingAttendee"), p))

    def select(sparql):
        rows = ds.query(sparql)
        return [{str(v): str(r[v]) for v in rows.vars if r[v] is not None} for r in rows]

    return select


def _summaries(outbound, destination=None):
    # ``outbound`` no longer changes anything (Archie 2026-11-17: the Timeline
    # obeys the destination). True keeps the old call sites reading as the
    # owner's own brief; pass ``destination`` for any other view.
    if destination is None and outbound:
        destination = OUTBOUND_DESTINATION
    with patch.object(server, "_sparql_select", side_effect=_engine()):
        rows, err = server._timeline_from_graph(outbound=outbound, destination=destination)
    assert err is None, err
    return {r["summary"] for r in rows}


class TimelineOutboundL3(unittest.TestCase):

    def test_outbound_returns_exactly_the_visible_set(self):
        self.assertEqual(_summaries(True), VISIBLE)

    def test_l3_meeting_absent_l1_control_present(self):
        got = _summaries(True)
        self.assertNotIn("L3 secret meeting", got)
        self.assertIn("L1 control lunch", got)

    def test_one_l3_attendee_hides_an_l1_meeting(self):
        self.assertNotIn("L1 meeting with an L3 attendee", _summaries(True))

    def test_untagged_beside_a_tagged_attendee_is_hidden(self):
        # Canonical: missing beside present = L3.
        self.assertNotIn("untagged meeting, L1 attendee", _summaries(True))

    def test_undeclared_outbound_is_unknown_and_withholds_l1(self):
        with patch.object(server, "_sparql_select", side_effect=_engine()):
            rows, err = server._timeline_from_graph(outbound=True)
        self.assertIsNone(err)
        self.assertEqual([], [r["summary"] for r in rows])

    def test_untagged_with_no_signal_is_hidden(self):
        got = _summaries(True)
        self.assertNotIn("untagged meeting, untagged attendee", got)
        self.assertNotIn("untagged meeting, no attendees", got)

    def test_meeting_without_attendees_rows(self):
        # rdflib cannot GROUP_CONCAT a group whose ?name is wholly unbound
        # (Oxigraph can), so the attendee-less shape is fed as canned rows,
        # exactly as the shipped query returns it (alevels "none").
        base = {"date": _DAY, "attendees": "", "alevels": "none"}
        rows = [dict(base, summary="L1 no attendees", mlevels="L1"),
                dict(base, summary="untagged no attendees", mlevels=""),
                dict(base, summary="L3 no attendees", mlevels="L3")]
        with patch.object(server, "_sparql_select", return_value=rows):
            got, _ = server._timeline_from_graph(outbound=True,
                                                 destination=OUTBOUND_DESTINATION)
        self.assertEqual([r["summary"] for r in got], ["L1 no attendees"])

    def test_unparseable_level_hidden(self):
        self.assertNotIn("unparseable level, no owner level", _summaries(True))

    def test_owner_local_sees_every_level_labelled(self):
        self.assertEqual(_summaries(False, "owner_local"), {f[0] for f in FIXTURE})
        with patch.object(server, "_sparql_select", side_effect=_engine()):
            rows, _ = server._timeline_from_graph(destination="owner_local")
        labelled = {r["summary"] for r in rows if r.get("privacy_label") == "private"}
        self.assertIn("L3 secret meeting", labelled)
        self.assertNotIn("L1 control lunch", labelled)

    def test_the_outbound_flag_no_longer_opens_anything(self):
        # Undeclared = unknown (strictest): with or without outbound=1 the same
        # set leaves, and it holds no L1 meeting.
        self.assertEqual(_summaries(False), set())
        with patch.object(server, "_sparql_select", side_effect=_engine()):
            rows, _ = server._timeline_from_graph(outbound=True)
        self.assertEqual(rows, [])

    def test_route_obeys_the_destination_and_default_is_unknown(self):
        with _no_calendar(), \
                patch.object(server, "_expected_service_token",
                             return_value="synthetic-token"), \
                patch.object(server, "_sparql_select", side_effect=_engine()), \
                patch.object(server, "_timeline_conversations",
                             side_effect=lambda **k: ([], None)), \
                _Harness() as h:
            _, out = h.get("/api/v1/timeline?outbound=1&destination=owner_own_brief")
            _, plain = h.get("/api/v1/timeline?destination=owner_own_brief")
            _, undeclared = h.get("/api/v1/timeline")
            _, own = h.get("/api/v1/timeline?destination=owner_local")
        self.assertEqual({i["summary"] for i in out["items"]}, VISIBLE)
        self.assertEqual({i["summary"] for i in plain["items"]}, VISIBLE)
        self.assertEqual(undeclared["items"], [])
        self.assertEqual(len(own["items"]), len(FIXTURE))

    def test_outbound_omits_the_unlevelled_calendar_strip(self):
        cal = [{"start": _DAY, "summary": "Synthetic flight", "location": "", "attendees": []}]
        with patch.object(server, "query_google_calendar", return_value=cal), \
                patch.object(server, "_sparql_select", return_value=[]), \
                patch.object(server, "_timeline_conversations",
                             side_effect=lambda **k: ([], None)):
            out = server.api_timeline(outbound=True, destination=OUTBOUND_DESTINATION)
            undeclared = server.api_timeline()
            own = server.api_timeline(destination="owner_local")
        # The calendar strip carries no level (canonical L3): owner_local only.
        self.assertEqual(out["items"], [])
        self.assertEqual(undeclared["items"], [])
        self.assertEqual([i["summary"] for i in own["items"]], ["Synthetic flight"])
        self.assertEqual("private", own["items"][0].get("privacy_label"))

    def test_conversations_outbound_fail_closed(self):
        import io
        pts = {"result": {"points": [
            {"payload": {"occurred_at": _DAY, "contact_name": "Ana Doe", "channel": "L1chat", "privacy_level": "L1"}},
            {"payload": {"occurred_at": _DAY, "contact_name": "Ben Doe", "channel": "L3chat", "privacy_level": "L3"}},
            {"payload": {"occurred_at": _DAY, "contact_name": "Carl Doe", "channel": "untagged"}},
        ]}}

        class _R(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self, *a): return False
        with patch.object(server.urllib.request, "urlopen",
                          side_effect=lambda *a, **k: _R(json.dumps(pts).encode())):
            out, _ = server._timeline_conversations(outbound=True,
                                                    destination=OUTBOUND_DESTINATION)
            undeclared, _ = server._timeline_conversations()
            own, _ = server._timeline_conversations(destination="owner_local")
        # CM051 composes the title with the participants ("L1chat with ...") and
        # capitalises it: compare the seeded stem.
        self.assertEqual([r["summary"].split(" with ")[0] for r in out], ["L1chat"])
        self.assertEqual(undeclared, [])
        self.assertEqual(len(own), 3)
        self.assertEqual({r["summary"].split(" with ")[0].lower() for r in own if r.get("privacy_label")},
                         {"l3chat", "untagged"})


if __name__ == "__main__":
    unittest.main()
