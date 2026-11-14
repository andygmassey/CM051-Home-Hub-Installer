"""Photos on the Timeline: pwg:PhotoEvent aggregated per (day, place).

Runs the shipped SPARQL in ``_timeline_photos`` against a real engine (rdflib),
the same way ``test_timeline_outbound_l3`` does. Synthetic data only: place
names are invented and there are no people.

Contract (the producer side is ``vendor/ostler_fda/pwg_ingest.py``
``ingest_photo_events``; the consumer side is CM031 ``TimelineDataService``):
  - one aggregated row per (day, place): "Photos: N photos at <place>"
  - no place: "Photos: N photos on <date>"
  - fail closed on privacy: L3, unparseable or missing levels are not counted
  - outside the past window: not counted
  - the entries type is "photos" (the iOS app maps it to the Photos chip)
"""
from __future__ import annotations

import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import sys as _sys
from pathlib import Path as _P
_sys.path.insert(0, str(_P(__file__).resolve().parent))
from test_people_list_endpoint import server  # noqa: E402  (vendored server with the ostler_security stub)


def _no_calendar():
    """Patch the forward-calendar sources to empty (no OAuth on a fresh box)."""
    from unittest.mock import patch as _patch
    return _patch.object(server, "query_google_calendar", return_value=[])

PWG = "https://schema.ostler.ai/ontology#"
RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
_NOW = datetime.now(timezone.utc)
_DAY = (_NOW - timedelta(days=3)).strftime("%Y-%m-%d")
_OLD = (_NOW - timedelta(days=900)).strftime("%Y-%m-%d")

# (photo id, date, place or None, privacy level or None)
PHOTOS = [
    ("p1", _DAY + "T09:00:00+00:00", "Synthville, Testland", "L2"),
    ("p2", _DAY + "T09:05:00+00:00", "Synthville, Testland", "L2"),
    ("p3", _DAY + "T10:00:00+00:00", "Synthville, Testland", "L2"),
    ("p4", _DAY + "T10:30:00+00:00", "Synthville, Testland", "L3"),   # hidden
    ("p5", _DAY + "T11:00:00+00:00", None, "L2"),
    ("p6", _DAY + "T11:05:00+00:00", None, "L2"),
    ("p7", _DAY + "T12:00:00+00:00", None, None),                     # hidden
    ("p8", _DAY + "T12:30:00+00:00", None, "banana"),                 # hidden
    ("p9", _OLD + "T08:00:00+00:00", "Oldtown, Testland", "L2"),      # outside window
]


def _engine(photos=PHOTOS):
    from rdflib import Dataset, Literal, URIRef

    ds = Dataset(default_union=False)
    g = getattr(ds, "default_graph", None) or ds.default_context
    for pid, date, place, lvl in photos:
        n = URIRef("urn:synth:photo:" + pid)
        g.add((n, URIRef(RDF_TYPE), URIRef(PWG + "PhotoEvent")))
        g.add((n, URIRef(PWG + "photoDate"), Literal(date)))
        if place:
            g.add((n, URIRef(PWG + "photoPlace"), Literal(place)))
        if lvl is not None:
            g.add((n, URIRef(PWG + "privacyLevel"), Literal(lvl)))

    def select(sparql):
        rows = ds.query(sparql)
        return [{str(v): str(r[v]) for v in rows.vars if r[v] is not None} for r in rows]

    return select


def _photo_rows(photos=PHOTOS, past_days=730):
    with patch.object(server, "_sparql_select", side_effect=_engine(photos)):
        rows, err = server._timeline_photos(past_days=past_days)
    assert err is None, err
    return rows


class TimelinePhotosAggregation(unittest.TestCase):

    def test_place_group_counts_only_visible_photos(self):
        rows = {r["summary"]: r for r in _photo_rows()}
        place = rows["Photos: 3 photos at Synthville, Testland"]
        self.assertEqual(place["count"], 3)          # p4 (L3) not counted
        self.assertEqual(place["date"], _DAY)
        self.assertEqual(place["location"], "Synthville, Testland")
        self.assertEqual(place["kind"], "photos")

    def test_no_place_group_is_per_day(self):
        rows = {r["summary"]: r for r in _photo_rows()}
        day = rows["Photos: 2 photos on " + _DAY]
        self.assertEqual(day["count"], 2)            # p7 (missing) and p8 (unparseable) hidden
        self.assertEqual(day["location"], "")

    def test_l3_missing_and_unparseable_are_hidden(self):
        summaries = " ".join(r["summary"] for r in _photo_rows())
        self.assertNotIn("Oldtown", summaries)
        self.assertEqual(sum(r["count"] for r in _photo_rows()), 5)

    def test_outside_the_past_window_is_not_counted(self):
        self.assertNotIn("Oldtown", " ".join(r["summary"] for r in _photo_rows(past_days=730)))

    def test_singular_noun_for_one_photo(self):
        one = [("q1", _DAY + "T09:00:00+00:00", "Riverside Town", "L2")]
        self.assertEqual(_photo_rows(one)[0]["summary"], "Photos: 1 photo at Riverside Town")

    def test_no_photos_is_an_empty_list_not_an_error(self):
        rows, err = None, None
        with patch.object(server, "_sparql_select", side_effect=_engine([])):
            rows, err = server._timeline_photos(past_days=730)
        self.assertIsNone(err)
        self.assertEqual(rows, [])

    def test_graph_failure_is_reported_not_swallowed(self):
        with patch.object(server, "_sparql_select", side_effect=RuntimeError("oxigraph down")):
            rows, err = server._timeline_photos(past_days=730)
        self.assertEqual(rows, [])
        self.assertIn("oxigraph down", err)


class TimelinePhotosEndpoint(unittest.TestCase):

    def test_api_timeline_carries_photos_with_entries_type_photos(self):
        with _no_calendar(), \
             patch.object(server, "_sparql_select", side_effect=_engine()), \
             patch.object(server, "_timeline_conversations", return_value=([], None)):
            body = server.api_timeline(days=0, past_days=730, limit=200)
        photo_items = [i for i in body["items"] if i["kind"] == "photos"]
        self.assertEqual(len(photo_items), 2)
        photo_entries = [e for e in body["entries"] if e["type"] == "photos"]
        self.assertEqual(
            sorted(e["title"] for e in photo_entries),
            ["Photos: 2 photos on " + _DAY, "Photos: 3 photos at Synthville, Testland"],
        )
        self.assertTrue(all(e["timestamp"] for e in photo_entries))

    def test_photo_failure_surfaces_as_error_row_and_is_not_an_entry(self):
        def fake(sparql):
            if "PhotoEvent" in sparql:
                raise RuntimeError("photo query down")
            return []
        with _no_calendar(), \
             patch.object(server, "_sparql_select", side_effect=fake), \
             patch.object(server, "_timeline_conversations", return_value=([], None)):
            body = server.api_timeline(days=0, past_days=730, limit=200)
        self.assertIn("photos_error", [i["kind"] for i in body["items"]])
        self.assertNotIn("photos", [e["type"] for e in body["entries"]])


if __name__ == "__main__":
    unittest.main()


# Contract: the Hub entries this suite produces must equal the fixture the
# CM031 iOS decoder is tested against (TimelinePhotosContractTests.swift).
_FIXTURE = __import__("pathlib").Path(__file__).parent / "fixtures" / "timeline_photos_contract.json"


class TimelinePhotosContract(unittest.TestCase):

    def test_entries_match_the_ios_contract_fixture(self):
        import json
        fx = json.loads(_FIXTURE.read_text())
        photos = [(e["photo"], e["date"], e["place"], e["privacy"]) for e in fx["input_photo_events"]]
        with _no_calendar(), \
             patch.object(server, "_sparql_select", side_effect=_engine(photos)), \
             patch.object(server, "_timeline_conversations", return_value=([], None)):
            body = server.api_timeline(days=0, past_days=36500, limit=200)
        got = [e for e in body["entries"] if e["type"] == "photos"]
        # The vendored Timeline also carries CM051's #2565 provenance fields
        # (source, title_verbatim) on every entry. The iOS contract fixture
        # pins the customer-facing fields; compare exactly those.
        contract_keys = ("type", "timestamp", "title", "subtitle", "attendees", "all_day")
        got = [{k: e.get(k) for k in contract_keys} for e in got]
        self.assertEqual(got, fx["expected_entries"])


class TimelinePhotosFixturePin(unittest.TestCase):
    """The fixture is a cross-repo contract. CM031's copy must be byte-identical.

    Canonical copy: this repo, last changed in c209a75. The CM031 copy at
    CM031/Tests/Fixtures/timeline_photos_contract.json is checked against the
    same digest by TimelinePhotosContractTests.testFixtureIsByteIdenticalToCM041Pin.
    Changing this file means re-pinning here AND in CM031, in the same change.
    """

    PINNED_FROM = "c209a75"
    PINNED_SHA256 = "e98b4f002dd47f57a00008af284554ebb8a5fe982f8d220268b57752298849da"

    def test_fixture_bytes_match_the_pinned_digest(self):
        import hashlib
        digest = hashlib.sha256(_FIXTURE.read_bytes()).hexdigest()
        self.assertEqual(
            digest, self.PINNED_SHA256,
            "timeline_photos_contract.json changed (pinned from CM041 %s). Re-pin "
            "here and in CM031 TimelinePhotosContractTests together." % self.PINNED_FROM)
