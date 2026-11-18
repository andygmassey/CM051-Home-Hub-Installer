"""person_enrichment and /person/{slug}/timeline withhold L3 meetings (S23, 118 MUST).

Same rule as /people/context (#239), same helper (_effective_privacy_level):
the stricter of the meeting's and the person's level wins, a meeting with no
parseable level is withheld, and every served meeting carries privacy_level.
Per route and per destination (Archie 2026-11-17): owner_own_brief serves L2,
cloud_model (and undeclared, unknown) withholds it, owner_local serves L3 and untagged
with privacy_label "private", and a legacy L0 is withheld except for owner_local.
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

    _MIXED = [
        ("Synthetic budget review", "2026-05-21", "L2"),
        ("Synthetic private consultation", "2026-05-20", "L3"),
        ("Synthetic roadmap check-in", "2026-05-19", None),
    ]

    def _check(self, events_of):
        """events_of(person_level, meetings, destination) -> served meetings.

        owner_own_brief (the default view here): L2 served, L3 withheld, and an
        untagged meeting beside the person's L2 is L3 (canonical), withheld."""
        served = events_of("L2", self._MIXED)
        self.assertEqual([], self.store.refusals)
        by = {m["summary"]: m.get("privacy_level") for m in served}
        self.assertEqual("L2", by.get("Synthetic budget review"), "control: L2 served")
        self.assertNotIn("Synthetic private consultation", by, "L3 meeting served")
        self.assertNotIn("Synthetic roadmap check-in", by, "untagged (L3) served")
        self.assertEqual(1, len(by))
        self.assertFalse(any("privacy_label" in m for m in served), served)

    def _check_cloud(self, events_of):
        # Undeclared = unknown (strictest row): L2 never leaves for a cloud model.
        self.assertEqual([], events_of("L2", self._MIXED, destination=None))
        self.assertEqual([], events_of("L2", self._MIXED, destination="cloud_model"))

    def _check_owner_local(self, events_of):
        served = events_of("L2", self._MIXED, destination="owner_local")
        self.assertEqual({
            "Synthetic budget review": None,
            "Synthetic private consultation": "private",
            "Synthetic roadmap check-in": "private",
        }, {m["summary"]: m.get("privacy_label") for m in served})

    def _check_legacy_l0(self, events_of):
        meetings = [("Synthetic l0 review", "2026-05-21", "L0"),
                    ("Synthetic l1 review", "2026-05-20", "L1")]
        served = events_of("L1", meetings)
        self.assertEqual(["Synthetic l1 review"], [m["summary"] for m in served])
        own = events_of("L1", meetings, destination="owner_local")
        self.assertEqual({"Synthetic l0 review": "private", "Synthetic l1 review": None},
                         {m["summary"]: m.get("privacy_label") for m in own})

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
    def _events(self, person_level, meetings, destination="owner_own_brief"):
        self._patch(person_level, meetings)
        body, status = server.person_enrichment(SLUG, destination=destination)
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

    def test_undeclared_and_cloud_model_withhold_l2(self):
        self._check_cloud(self._events)

    def test_owner_local_serves_l3_and_untagged_labelled(self):
        self._check_owner_local(self._events)

    def test_legacy_l0_withheld_except_owner_local(self):
        self._check_legacy_l0(self._events)


class PersonTimelineMeetings(_Base):
    def _events(self, person_level, meetings, destination="owner_own_brief"):
        self._patch(person_level, meetings)
        body, status = server.person_timeline(SLUG, destination=destination)
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

    def test_undeclared_and_cloud_model_withhold_l2(self):
        self._check_cloud(self._events)

    def test_owner_local_serves_l3_and_untagged_labelled(self):
        self._check_owner_local(self._events)

    def test_legacy_l0_withheld_except_owner_local(self):
        self._check_legacy_l0(self._events)


if __name__ == "__main__":
    unittest.main()
