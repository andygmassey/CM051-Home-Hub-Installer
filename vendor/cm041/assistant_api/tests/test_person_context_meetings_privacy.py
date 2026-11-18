"""/people/context withholds L3 meetings at source and labels every meeting.

118 MUST (A14 review). A meeting summary served here reaches the assistant's
model, and from there can leave by iMessage, WhatsApp or email. The reader
applies the facts doctrine (pwg_privacy): the meeting's own pwg:privacyLevel
and the person's, most-restrictive wins, no parseable level on either axis
means withheld. Every served meeting carries ``privacy_level``, because the
oa consumer renders a meeting only when that field is an explicit L0-L2.

The SPARQL runs on a real engine (rdflib), not a canned row list, so a query
that stopped selecting the level would fail here. Synthetic data only.
"""
from __future__ import annotations

import importlib.util
import sys
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"


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
    database.get_db_connection = lambda path, _key, *_a, **_k: _sqlite.connect(path)
    sys.modules["ostler_security.database"] = database
    posture = types.ModuleType("ostler_security.posture")
    posture.record_posture = lambda *_a, **_k: None
    sys.modules["ostler_security.posture"] = posture


_install_ostler_security_stub()


def _load_server_module():
    spec = importlib.util.spec_from_file_location("ical_server_meetings_priv", SERVER_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server_module()


class _Store:
    """Stands in for _sparql_select over a real rdflib dataset."""

    def __init__(self, graph):
        self.graph = graph
        self.refusals = []

    def __call__(self, sparql):
        try:
            rows = self.graph.query(sparql)
        except Exception as exc:  # pragma: no cover - asserted against
            self.refusals.append((sparql, repr(exc)))
            raise
        out = []
        for row in rows:
            binding = {}
            for var in rows.vars or []:
                value = row[var]
                if value is not None:
                    binding[str(var)] = str(value)
            out.append(binding)
        return out


def _graph(person_level, meetings):
    """One person ``Jane Doe`` and their meetings.

    ``meetings``: list of (summary, date, own_level or None).
    """
    from rdflib import Dataset, Literal, URIRef

    ds = Dataset(default_union=False)
    g = getattr(ds, "default_graph", None) or ds.default_context
    pwg = server.PWG_NS
    rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    person = URIRef("urn:ostler:person/testsubject-synthetic")
    g.add((person, rdf_type, URIRef(pwg + "Person")))
    g.add((person, URIRef(pwg + "displayName"), Literal("Jane Doe")))
    if person_level is not None:
        g.add((person, URIRef(pwg + "privacyLevel"), Literal(person_level)))
    for i, (summary, date, level) in enumerate(meetings):
        m = URIRef("urn:ostler:meeting/synthetic-{}".format(i))
        g.add((m, rdf_type, URIRef(pwg + "Meeting")))
        g.add((m, URIRef(pwg + "meetingAttendee"), person))
        g.add((m, URIRef(pwg + "meetingSummary"), Literal(summary)))
        g.add((m, URIRef(pwg + "meetingDate"), Literal(date)))
        if level is not None:
            g.add((m, URIRef(pwg + "privacyLevel"), Literal(level)))
    return ds


class PersonContextMeetingsPrivacy(unittest.TestCase):
    def _context(self, person_level, meetings, destination="owner_own_brief"):
        # Default view: the owner's own channel (owner_own_brief), where L1/L2
        # are served in full. Tests of other destinations say so.
        store = _Store(_graph(person_level, meetings))
        real = server._sparql_select
        server._sparql_select = store
        self.addCleanup(setattr, server, "_sparql_select", real)
        body = server.person_context("Jane Doe", destination=destination)
        self.assertEqual([], store.refusals)
        self.assertTrue(body.get("found"), body)
        return body["person"]

    def test_an_l3_meeting_is_withheld_and_every_served_meeting_is_labelled(self):
        person = self._context("L2", [
            ("Synthetic budget review", "2026-05-21", "L2"),
            ("Synthetic private consultation", "2026-05-20", "L3"),
            ("Synthetic roadmap check-in", "2026-05-19", None),
        ])
        summaries = [m["summary"] for m in person.get("meetings", [])]
        self.assertIn("Synthetic budget review", summaries, "control: L2 served")
        self.assertNotIn("Synthetic private consultation", summaries,
                         "an L3 meeting was served")
        # Canonical: an untagged meeting beside the person's L2 tag is L3
        # (a missing tag beside a present one), so owner_own_brief withholds it.
        self.assertNotIn("Synthetic roadmap check-in", summaries)
        for m in person["meetings"]:
            self.assertIn(m.get("privacy_level"), ("L0", "L1", "L2"), m)
            self.assertNotIn("privacy_label", m)
        self.assertEqual(
            {"Synthetic budget review": "L2"},
            {m["summary"]: m["privacy_level"] for m in person["meetings"]},
        )

    def test_owner_local_serves_l3_and_untagged_labelled_private(self):
        person = self._context("L2", [
            ("Synthetic budget review", "2026-05-21", "L2"),
            ("Synthetic private consultation", "2026-05-20", "L3"),
            ("Synthetic roadmap check-in", "2026-05-19", None),
        ], destination="owner_local")
        got = {m["summary"]: m.get("privacy_label") for m in person["meetings"]}
        self.assertEqual(got, {
            "Synthetic budget review": None,
            "Synthetic private consultation": "private",
            "Synthetic roadmap check-in": "private",
        })

    def test_undeclared_is_unknown_and_withholds_l2(self):
        person = self._context("L2", [("Synthetic budget review", "2026-05-21", "L2")],
                               destination=None)
        self.assertNotIn("meetings", person, person)

    def test_a_meeting_with_no_parseable_level_anywhere_is_withheld(self):
        person = self._context(None, [
            ("Synthetic untagged sync", "2026-05-21", None),
            ("Synthetic junk-tagged sync", "2026-05-20", "secret"),
        ])
        self.assertNotIn("meetings", person, person)

    def test_an_l3_person_withholds_even_an_l2_meeting(self):
        person = self._context("L3", [("Synthetic budget review", "2026-05-21", "L2")])
        self.assertNotIn("meetings", person, person)

    def test_the_stricter_level_is_the_one_served(self):
        person = self._context("L1", [("Synthetic budget review", "2026-05-21", "L2")])
        self.assertEqual("L2", person["meetings"][0]["privacy_level"])
        # The meeting's OWN level is a legacy (unmigrated) L0, so
        # legacy_l0_guard withholds it outside owner_local, even though the
        # canonical effective class with the person's L2 is L2.
        person = self._context("L2", [("Synthetic budget review", "2026-05-21", "l0 ")])
        self.assertEqual([], person.get("meetings", []))

    def test_134_l0_meeting_withheld_and_l1_twin_served(self):
        # person_context is a Hub route: a legacy L0 meeting is withheld at
        # owner_own_brief (legacy_l0_guard), its L1 twin is served.
        l0 = self._context("L1", [("Synthetic l0 review", "2026-05-21", "L0")])
        self.assertEqual([], l0.get("meetings", []))
        l1 = self._context("L1", [("Synthetic l1 review", "2026-05-21", "L1")])
        self.assertEqual("L1", l1["meetings"][0]["privacy_level"])
        # owner_local is exempt from the guard and labels the legacy L0 private.
        own = self._context("L1", [("Synthetic l0 review", "2026-05-21", "L0")],
                            destination="owner_local")
        self.assertEqual("private", own["meetings"][0]["privacy_label"])



if __name__ == "__main__":
    unittest.main()
