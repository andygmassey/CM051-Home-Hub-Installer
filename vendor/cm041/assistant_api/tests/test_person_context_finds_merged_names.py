"""/people/context finds a person by a name that a contact merge retired.

v1.0.107, measured on the Mini16 #27 box: a contact merge types the
human-named nodes pwg:RetiredPerson with pwg:mergedInto <survivor>, and the
live survivor can be left with only a phone number or an email as its
displayName. person_context matched ``?person a pwg:Person ; pwg:displayName``
only, so asking the assistant about that person by name returned
found=False and the chat answered "could not find any information".

The store here is a REAL pyoxigraph engine behind a real socket
(tests/_fake_oxigraph.py), not a stubbed _sparql_select: the defect lives in
the SPARQL text, so the SPARQL has to run.

Cast names only. Phone numbers are in the Ofcom drama range, emails are on
example.com.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
sys.path.insert(0, str(REPO / "tests"))
sys.path.insert(0, str(HERE))

from _fake_oxigraph import FakeOxigraph  # noqa: E402
from test_people_list_endpoint import server  # noqa: E402  (loads ical-server.py with its stubs)

P = "https://schema.ostler.ai/ontology#"
B = "urn:test:person:"

TRIPLES = f"""
INSERT DATA {{
  # One hop: survivor named only by an email, two human-named retired nodes.
  <{B}survivor-email> a pwg:Person ; pwg:displayName "jane.doe@example.com" .
  <{B}retired-a> a pwg:RetiredPerson ; pwg:displayName "Jane Doe" ;
      pwg:mergedInto <{B}survivor-email> .
  <{B}retired-b> a pwg:RetiredPerson ; pwg:displayName "Jane Smith" ;
      pwg:mergedInto <{B}survivor-email> .

  # Two hops: a merge of a merge. Survivor named only by a phone number.
  <{B}survivor-phone> a pwg:Person ; pwg:displayName "+447700900123" .
  <{B}retired-mid> a pwg:RetiredPerson ; pwg:displayName "raj.patel@example.com" ;
      pwg:mergedInto <{B}survivor-phone> .
  <{B}retired-far> a pwg:RetiredPerson ; pwg:displayName "Raj Patel" ;
      pwg:mergedInto <{B}retired-mid> .

  # Crowding (Archie review): one survivor with FOUR retired names that all
  # match "brown", two other matching people, and a target reachable only by
  # its retired name. Row ORDER is the engine's: on pyoxigraph this layout
  # puts the target's row after the crowder's four, so a 5-ROW cap drops it.
  <{B}target> a pwg:Person ; pwg:displayName "+447700900789" .
  <{B}target-old> a pwg:RetiredPerson ; pwg:displayName "Sam Brown" ;
      pwg:mergedInto <{B}target> .
  <{B}crowder> a pwg:Person ; pwg:displayName "+447700900456" .
  <{B}crowd-1> a pwg:RetiredPerson ; pwg:displayName "Alex Brown" ; pwg:mergedInto <{B}crowder> .
  <{B}crowd-2> a pwg:RetiredPerson ; pwg:displayName "Alexander Brown" ; pwg:mergedInto <{B}crowder> .
  <{B}crowd-3> a pwg:RetiredPerson ; pwg:displayName "Alexandra Brown" ; pwg:mergedInto <{B}crowder> .
  <{B}crowd-4> a pwg:RetiredPerson ; pwg:displayName "Ali Brown" ; pwg:mergedInto <{B}crowder> .
  <{B}other-1> a pwg:Person ; pwg:displayName "Ben Brown" .
  <{B}other-2> a pwg:Person ; pwg:displayName "Carl Brown" .

  # Control: an ordinary human-named live person.
  <{B}control> a pwg:Person ; pwg:displayName "Tom Jones" .
}}
"""


class PersonContextFindsMergedNames(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ox = FakeOxigraph()
        cls.ox.update(TRIPLES)
        cls._saved_url = server.OXIGRAPH_URL
        server.OXIGRAPH_URL = cls.ox.url

    @classmethod
    def tearDownClass(cls):
        server.OXIGRAPH_URL = cls._saved_url
        cls.ox.close()

    def _one(self, name):
        out = server.person_context(name)
        self.assertTrue(out.get("found"), f"not found: {name!r} -> {out}")
        self.assertIn("person", out, f"expected exactly one person: {out}")
        return out["person"]

    def test_retired_human_name_finds_email_named_survivor(self):
        p = self._one("Jane Doe")
        self.assertEqual(p["person_uri"], B + "survivor-email")
        self.assertIn(p["name"], ("Jane Doe", "Jane Smith"))

    def test_both_retired_names_collapse_to_one_survivor(self):
        # "jane" matches both retired nodes AND the survivor's own email:
        # one live person, reported once, under a human name.
        p = self._one("jane")
        self.assertEqual(p["person_uri"], B + "survivor-email")
        self.assertNotIn("@", p["name"])

    def test_two_hop_chain_resolves_to_live_terminus(self):
        p = self._one("Raj Patel")
        self.assertEqual(p["person_uri"], B + "survivor-phone")
        self.assertEqual(p["name"], "Raj Patel")

    def test_retired_node_is_never_returned_itself(self):
        for q in ("Jane", "Raj"):
            out = server.person_context(q)
            uris = [m["person_uri"] for m in out.get("matches", [])] or \
                [out.get("person", {}).get("person_uri")]
            self.assertFalse(any("retired" in (u or "") for u in uris), (q, uris))

    def test_retired_names_do_not_crowd_out_the_target(self):
        # 4 retired rows for one survivor must not use up the result cap:
        # the cap is on PEOPLE after the dedupe, not on rows.
        out = server.person_context("brown")
        self.assertTrue(out.get("found"), out)
        uris = [m["person_uri"] for m in out.get("matches", [])]
        self.assertEqual(len(uris), len(set(uris)), uris)
        self.assertIn(B + "target", uris)
        self.assertIn(B + "crowder", uris)
        self.assertLessEqual(len(uris), 5)

    def test_control_human_named_person_still_found(self):
        p = self._one("Tom Jones")
        self.assertEqual(p["person_uri"], B + "control")
        self.assertEqual(p["name"], "Tom Jones")

    def test_control_absent_name_is_not_found(self):
        self.assertFalse(server.person_context("no such person zzq").get("found"))


if __name__ == "__main__":
    unittest.main()
