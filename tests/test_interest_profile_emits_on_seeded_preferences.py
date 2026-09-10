#!/usr/bin/env python3
"""The interest-profile generator must emit an interest when the graph has one.

WHY THIS EXISTS. MEASURED on the v1.0.81 walk box, 2026-09-09.

    GET /api/v1/preferences  ->  200, count 0, interests[] length 0

The handler reads ~/.ostler/preferences/interest_profile.json, a 245-byte file
written during the install with zero interests, on a box holding 830 preference
points in Qdrant and 1629 people. The daemon tool pwg_preferences therefore
reported finding nothing and the grounded probe scored the turn
tool_found_nothing. The TOOL is correct on an empty origin; the question is why
the origin is empty.

WHAT THIS FILE ESTABLISHES, offline and without a box:

  1. THE PIPELINE WORKS GIVEN DATA. One seeded row in a category that clears
     the confidence floor produces exactly one interest.
  2. THE FETCH PATH PARSES THE REAL RESPONSE. fetch_preferences over a stub
     speaking the format the client actually asks for returns rows.
  3. 🔴 AND THE CATEGORY DECIDES WHETHER ANYTHING SURVIVES AT ALL. A row in
     category "interest" reaches confidence 0.2475 against compile_profile's
     min_confidence floor of 0.28, and NO number of observations lifts it:
     measured at 1, 3, 10, 20 and 50 identical rows, the answer is zero every
     time. "interest" and "inferred_interest" are the two categories that map
     to the Interests domain, so the category most literally named for the
     output is the one that cannot reach it.

     Measured maximum over 180 combinations of category, strength and source:
     0.4275, by category "music". So the floor is clearable and the pipeline is
     not structurally broken. Which categories a box's rows carry decides
     whether it gets a profile at all.

This file PINS that behaviour rather than asserting a fix. Whether 0.28 is
right, whether "interest" should score 0.2475, and whether the ingest should be
classifying into richer categories are product decisions with an owner, and a
test that quietly encoded my preference among them would make the decision by
stealth.

⚠️ NO PROXY. urllib honours HTTP_PROXY for 127.0.0.1, so the stub below is
unreachable on any machine with one set: the first run of this fixture died with
"HTTP Error 503: Forwarding failure" against its own loopback server. Same shape
as ostler-assistant#391. The server is addressed through a proxy-free opener.
"""
from __future__ import annotations

import csv  # noqa: F401  (documents the format the client asks for)
import io
import os
import sys
import threading
import unittest
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "vendor", "cm059_editor"))

from compiler import interest_profile as ip  # noqa: E402

NOW = datetime(2026, 9, 9, tzinfo=timezone.utc)


def _row(**kw):
    d = {
        "subject": "submarine cables",
        "category": "interest",
        "strength": "0.9",
        "source": "seed",
        "observed_at": "2026-09-08T00:00:00Z",
        "created_at": "2026-09-08T00:00:00Z",
        "polarity": "like",
    }
    d.update(kw)
    return d


def _interests(profile):
    return sum(len(b.get("interests", [])) for b in profile.get("domains", []))


class _CsvPrefHandler(BaseHTTPRequestHandler):
    """Answers the SPARQL SELECT in the format _sparql_select asks for."""

    BODY = (
        "subject,category,strength,source,observed,created\r\n"
        "submarine cables,music,0.5,seed,2026-09-08T00:00:00Z,2026-09-08T00:00:00Z\r\n"
    ).encode()

    def do_POST(self):  # noqa: N802
        self.send_response(200)
        self.send_header("Content-Type", "text/csv")
        self.send_header("Content-Length", str(len(self.BODY)))
        self.end_headers()
        self.wfile.write(self.BODY)

    def log_message(self, *_a):  # keep the test output clean
        pass


class InterestProfileEmitsOnSeededPreferences(unittest.TestCase):
    def test_a_seeded_row_that_clears_the_floor_produces_an_interest(self):
        """MUST-HIT. Without this the zero below could be a dead pipeline."""
        profile = ip.compile_profile([_row(category="music", strength="0.5")])
        self.assertEqual(
            _interests(profile),
            1,
            "a seeded preference above the confidence floor produced no interest, "
            "so the generator is broken independently of any box's data",
        )

    def test_an_empty_graph_produces_an_empty_profile(self):
        """MUST-MISS, so the arm above cannot pass vacuously."""
        self.assertEqual(_interests(ip.compile_profile([])), 0)

    def test_the_interest_category_can_never_clear_the_floor(self):
        """THE FINDING, pinned rather than fixed.

        Not an assertion that this is correct. An assertion that this is what
        happens, so a change to either number is visible.
        """
        floor = ip.compile_profile.__defaults__[2]
        self.assertEqual(floor, 0.28, "the floor moved; re-measure the ceiling below")

        built = ip.build_interest(_row(category="interest"), NOW)
        self.assertLess(
            built["confidence"],
            floor,
            "category 'interest' now clears the floor; this file's premise has changed",
        )

        for n in (1, 3, 10, 20, 50):
            with self.subTest(observations=n):
                self.assertEqual(
                    _interests(ip.compile_profile([_row(category="interest")] * n)),
                    0,
                    f"{n} observations lifted an 'interest' row over the floor; "
                    "aggregation now raises confidence and the finding is stale",
                )

    def test_the_fetch_path_parses_what_the_client_asks_for(self):
        """The client sends Accept: text/csv and parses with csv.DictReader.

        A JSON stub returns zero rows and looks exactly like an empty graph,
        which is how the first draft of this fixture fooled its own author.
        """
        srv = HTTPServer(("127.0.0.1", 0), _CsvPrefHandler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            url = "http://127.0.0.1:%d" % srv.server_address[1]
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            original = urllib.request.urlopen
            urllib.request.urlopen = opener.open  # type: ignore[assignment]
            try:
                rows = ip.fetch_preferences(url)
            finally:
                urllib.request.urlopen = original  # type: ignore[assignment]
            self.assertGreaterEqual(
                len(rows),
                1,
                "fetch_preferences returned nothing from a stub that answered with "
                "one row in the format the client asks for",
            )
            self.assertEqual(rows[0]["subject"], "submarine cables")
        finally:
            srv.shutdown()


if __name__ == "__main__":
    unittest.main(verbosity=2)
