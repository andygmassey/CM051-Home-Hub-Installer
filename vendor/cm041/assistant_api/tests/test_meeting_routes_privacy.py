"""person_enrichment and /person/{slug}/timeline withhold L3 meetings (S23, 118 MUST).

Same rule as /people/context (#239), same helper (_effective_privacy_level):
the stricter of the meeting's and the person's level wins, a meeting with no
parseable level is withheld, and every served meeting carries privacy_level.
The SPARQL runs on a real rdflib engine, so a query that stops selecting the
level fails here. Synthetic data only.
"""
from __future__ import annotations

import unittest

from tests.test_person_context_meetings_privacy import _Store, _graph, server

SLUG = "jane-doe"


class _Base(unittest.TestCase):
    def _patch(self, person_level, meetings):
        store = _Store(_graph(person_level, meetings))
        real = server._sparql_select
        server._sparql_select = store
        self.addCleanup(setattr, server, "_sparql_select", real)
        self.store = store

    def _check(self, events_of):
        """events_of(person_level, meetings) -> list of served meeting dicts."""
        served = events_of("L2", [
            ("Synthetic budget review", "2026-05-21", "L2"),
            ("Synthetic private consultation", "2026-05-20", "L3"),
            ("Synthetic roadmap check-in", "2026-05-19", None),
        ])
        self.assertEqual([], self.store.refusals)
        by = {m["summary"]: m.get("privacy_level") for m in served}
        self.assertEqual("L2", by.get("Synthetic budget review"), "control: L2 served")
        self.assertNotIn("Synthetic private consultation", by, "L3 meeting served")
        self.assertEqual("L2", by.get("Synthetic roadmap check-in"))  # inherits person L2
        self.assertEqual(2, len(by))

    def _check_missing(self, events_of):
        served = events_of(None, [
            ("Synthetic untagged sync", "2026-05-21", None),
            ("Synthetic junk-tagged sync", "2026-05-20", "secret"),
        ])
        self.assertEqual([], served)

    def _check_l3_person(self, events_of):
        self.assertEqual([], events_of("L3", [("Synthetic budget review", "2026-05-21", "L2")]))

    def _check_stricter(self, events_of):
        served = events_of("L1", [("Synthetic budget review", "2026-05-21", "L2")])
        self.assertEqual(["L2"], [m["privacy_level"] for m in served])


class PersonEnrichmentMeetings(_Base):
    def _events(self, person_level, meetings):
        self._patch(person_level, meetings)
        body, status = server.person_enrichment(SLUG)
        self.assertEqual(200, status, body)
        return body["person"].get("meetings", [])

    def test_l3_withheld_l2_served_labelled(self):
        self._check(self._events)

    def test_missing_level_withheld(self):
        self._check_missing(self._events)

    def test_l3_person_withholds_l2_meeting(self):
        self._check_l3_person(self._events)

    def test_stricter_level_served(self):
        self._check_stricter(self._events)


class PersonTimelineMeetings(_Base):
    def _events(self, person_level, meetings):
        self._patch(person_level, meetings)
        body, status = server.person_timeline(SLUG)
        self.assertEqual(200, status, body)
        self.assertNotIn("meetings", " ".join(body.get("degraded_sources") or []), body)
        return [dict(e, summary=e["summary"]) for e in body.get("events", [])
                if e.get("type") == "meeting"]

    def test_l3_withheld_l2_served_labelled(self):
        self._check(self._events)

    def test_missing_level_withheld(self):
        self._check_missing(self._events)

    def test_l3_person_withholds_l2_meeting(self):
        self._check_l3_person(self._events)

    def test_stricter_level_served(self):
        self._check_stricter(self._events)


if __name__ == "__main__":
    unittest.main()
