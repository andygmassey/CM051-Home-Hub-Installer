"""133 gate fixes, run against a REAL Oxigraph engine (pyoxigraph Store).

Fix 3, decisions_list: a meeting's privacyLevel and an attendee's privacyLevel
live in the named user graph (urn:ostler:user/<id>). The decision itself sits
in the default graph. Oxigraph has no union default graph, so the provenance
lookup must name GRAPH explicitly, or every L3 source reads as "no level" and
is served as legacy_untagged.

Fix 4, api_preferences: the CM059 compiler writes the level under ``privacy``.
The gate must read it, and the strictest of ``privacy_level`` and ``privacy``
wins.

No fixture encodes a canned answer for the queries: the store is real, so a
query that misses the named graph returns no rows and the test goes red.

Mutant run: set ICAL_SERVER_FILE to a copy of ical-server.py whose GRAPH
wrappers are removed (or whose gate reads only privacy_level). The same tests
must go red there.

Synthetic placeholders only.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import pyoxigraph


HERE = Path(__file__).resolve().parent
SERVER_FILE = Path(os.environ.get("ICAL_SERVER_FILE")
                   or HERE.parent / "ical-server.py")


def _install_ostler_security_stub() -> None:
    try:
        import ostler_security  # noqa: F401
        return
    except Exception:
        pass
    import sqlite3 as _sqlite

    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    database = types.ModuleType("ostler_security.database")
    database.get_db_connection = lambda path, _key, *a, **k: _sqlite.connect(path)
    sys.modules["ostler_security.database"] = database
    posture = types.ModuleType("ostler_security.posture")
    posture.record_posture = lambda *a, **k: None
    sys.modules["ostler_security.posture"] = posture


_install_ostler_security_stub()


def _load_server_module():
    spec = importlib.util.spec_from_file_location("ical_server_133", SERVER_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server_module()
PWG = server.PWG_NS
USER_GRAPH = "urn:ostler:user/sam"


def _store_select(store):
    """The same contract as server._sparql_select, run on the real store."""
    def run(query):
        result = store.query(query)
        names = [v.value for v in result.variables]
        out = []
        for sol in result:
            row = {}
            for name in names:
                term = sol[name]
                if term is not None:
                    row[name] = term.value
            out.append(row)
        return out
    return run


def _seed(store: pyoxigraph.Store) -> None:
    """Synthetic store. Decisions in the default graph; meetings and people in
    the named user graph, as the shipped writers place them."""
    p = f"PREFIX pwg: <{PWG}>\n"
    store.update(p + f"""
    INSERT DATA {{
      <urn:ostler:decision/l2> a pwg:Decision ; pwg:decisionSummary "Ship the L2 plan" ;
        pwg:decisionDate "2026-06-10T00:00:00" ; pwg:decisionSource <urn:ostler:meeting/l2> ;
        pwg:decisionStatus "active" .
      <urn:ostler:decision/l3> a pwg:Decision ; pwg:decisionSummary "Secret L3 plan" ;
        pwg:decisionDate "2026-06-11T00:00:00" ; pwg:decisionSource <urn:ostler:meeting/l3> ;
        pwg:decisionStatus "active" .
      <urn:ostler:decision/att> a pwg:Decision ; pwg:decisionSummary "L2 meeting, L3 attendee" ;
        pwg:decisionDate "2026-06-12T00:00:00" ; pwg:decisionSource <urn:ostler:meeting/l2> ;
        pwg:decisionAbout <urn:ostler:person/b> ; pwg:decisionStatus "active" .
      <urn:ostler:decision/l3d> a pwg:Decision ; pwg:decisionSummary "Secret default-graph L3 plan" ;
        pwg:decisionDate "2026-06-14T00:00:00" ; pwg:decisionSource <urn:ostler:meeting/l3d> ;
        pwg:decisionStatus "active" .
      <urn:ostler:decision/l2d> a pwg:Decision ; pwg:decisionSummary "Ship the default-graph L2 plan" ;
        pwg:decisionDate "2026-06-15T00:00:00" ; pwg:decisionSource <urn:ostler:meeting/l2d> ;
        pwg:decisionStatus "active" .
      <urn:ostler:decision/attd> a pwg:Decision ; pwg:decisionSummary "L2 meeting, L3 default-graph attendee" ;
        pwg:decisionDate "2026-06-16T00:00:00" ; pwg:decisionSource <urn:ostler:meeting/l2d> ;
        pwg:decisionAbout <urn:ostler:person/cd> ; pwg:decisionStatus "active" .
      <urn:ostler:decision/untagged> a pwg:Decision ; pwg:decisionSummary "Untagged meeting plan" ;
        pwg:decisionDate "2026-06-13T00:00:00" ; pwg:decisionSource <urn:ostler:meeting/none> ;
        pwg:decisionStatus "active" .
    }}
    """)
    # Default-graph levels: the shipped decision writer puts meetings and
    # people in the default graph, so the lookup must see them there too.
    store.update(p + """
    INSERT DATA {
      <urn:ostler:meeting/l3d> pwg:privacyLevel "L3" .
      <urn:ostler:meeting/l2d> pwg:privacyLevel "L2" .
      <urn:ostler:person/cd> a pwg:Person ; pwg:displayName "Synthetic Person C" ;
        pwg:privacyLevel "L3" .
    }
    """)
    store.update(p + f"""
    INSERT DATA {{
      GRAPH <{USER_GRAPH}> {{
        <urn:ostler:meeting/l2> pwg:privacyLevel "L2" .
        <urn:ostler:meeting/l3> pwg:privacyLevel "L3" .
        <urn:ostler:meeting/none> a pwg:Meeting .
        <urn:ostler:person/a> a pwg:Person ; pwg:displayName "Synthetic Person A" ;
          pwg:privacyLevel "L2" .
        <urn:ostler:person/b> a pwg:Person ; pwg:displayName "Synthetic Person B" ;
          pwg:privacyLevel "L3" .
      }}
    }}
    """)


class TestDecisionsNamedGraph(unittest.TestCase):

    def setUp(self) -> None:
        self.store = pyoxigraph.Store()
        _seed(self.store)

    def _call(self):
        with patch.object(server, "_sparql_select", side_effect=_store_select(self.store)):
            return server.decisions_list()

    def test_l3_meeting_withheld_l2_twin_served(self) -> None:
        body, status = self._call()
        self.assertEqual(status, 200)
        summaries = [d["summary"] for d in body["decisions"]]
        # Red on the default-graph pattern: the L3 meeting reads as no level,
        # so this decision is served.
        self.assertNotIn("Secret L3 plan", summaries)
        self.assertIn("Ship the L2 plan", summaries)

    def test_default_graph_l3_meeting_withheld_l2_twin_served(self) -> None:
        # Level in the DEFAULT graph: a GRAPH-only lookup misses it and serves.
        summaries = [d["summary"] for d in self._call()[0]["decisions"]]
        self.assertNotIn("Secret default-graph L3 plan", summaries)
        self.assertIn("Ship the default-graph L2 plan", summaries)

    def test_default_graph_l3_attendee_withholds_decision(self) -> None:
        summaries = [d["summary"] for d in self._call()[0]["decisions"]]
        self.assertNotIn("L2 meeting, L3 default-graph attendee", summaries)

    def test_l3_attendee_withholds_decision(self) -> None:
        body, _ = self._call()
        summaries = [d["summary"] for d in body["decisions"]]
        self.assertNotIn("L2 meeting, L3 attendee", summaries)

    def test_meeting_without_level_still_served_as_untagged(self) -> None:
        # 133 untagged rule: no readable level anywhere -> served and counted.
        body, _ = self._call()
        summaries = [d["summary"] for d in body["decisions"]]
        self.assertIn("Untagged meeting plan", summaries)
        self.assertEqual(body["legacy_untagged"], 1)

    def test_withheld_counts(self) -> None:
        body, _ = self._call()
        self.assertEqual(body["withheld"], {"l3": 4, "unknown": 0})


class TestInterestPrivacyKeys(unittest.TestCase):
    """api_preferences reads both ``privacy`` (CM059) and ``privacy_level``."""

    RECORDS = [
        {"id": "cm059-l3", "domain": "food", "privacy": "L3", "score": 0.9,
         "confidence": 0.9, "polarity": "like"},
        {"id": "cm059-l2", "domain": "food", "privacy": "L2", "score": 0.8,
         "confidence": 0.9, "polarity": "like"},
        {"id": "cm059-bogus", "domain": "food", "privacy": "bogus", "score": 0.7,
         "confidence": 0.9, "polarity": "like"},
        {"id": "both-l3-wins", "domain": "food", "privacy_level": "L3",
         "privacy": "L2", "score": 0.6, "confidence": 0.9, "polarity": "like"},
        {"id": "untagged", "domain": "food", "score": 0.5, "confidence": 0.9,
         "polarity": "like"},
    ]

    def _call(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "interest_profile.json"
            path.write_text(json.dumps({"interests": self.RECORDS,
                                        "schema_version": "test"}), encoding="utf-8")
            with patch.object(server, "INTEREST_PROFILE_PATH", str(path)):
                return server.api_preferences()

    def test_cm059_privacy_key_l3_withheld(self) -> None:
        body = self._call()
        ids = [it["id"] for it in body["interests"]]
        # Red on a gate that reads only privacy_level: cm059-l3 is served.
        self.assertNotIn("cm059-l3", ids)

    def test_cm059_privacy_key_l2_served(self) -> None:
        ids = [it["id"] for it in self._call()["interests"]]
        self.assertIn("cm059-l2", ids)

    def test_strictest_key_wins(self) -> None:
        # privacy_level L3 with privacy L2: withheld. Reading privacy alone
        # would serve it.
        ids = [it["id"] for it in self._call()["interests"]]
        self.assertNotIn("both-l3-wins", ids)

    def test_unparseable_value_withheld_and_counted(self) -> None:
        body = self._call()
        ids = [it["id"] for it in body["interests"]]
        self.assertNotIn("cm059-bogus", ids)
        self.assertEqual(body["withheld"]["unknown"], 1)

    def test_untagged_still_served_and_counted(self) -> None:
        body = self._call()
        ids = [it["id"] for it in body["interests"]]
        self.assertIn("untagged", ids)
        self.assertEqual(body["legacy_untagged"], 1)


if __name__ == "__main__":
    unittest.main()
