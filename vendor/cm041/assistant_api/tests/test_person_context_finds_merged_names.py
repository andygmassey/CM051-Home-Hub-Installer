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
  <{B}survivor-email> a pwg:Person ; pwg:displayName "casey.ward@example.com" .
  <{B}retired-a> a pwg:RetiredPerson ; pwg:displayName "Casey Ward" ;
      pwg:mergedInto <{B}survivor-email> .
  <{B}retired-b> a pwg:RetiredPerson ; pwg:displayName "Casey W Ward" ;
      pwg:mergedInto <{B}survivor-email> .

  # Two hops: a merge of a merge. Survivor named only by a phone number.
  <{B}survivor-phone> a pwg:Person ; pwg:displayName "+447700900123" .
  <{B}retired-mid> a pwg:RetiredPerson ; pwg:displayName "morgan.lee@example.com" ;
      pwg:mergedInto <{B}survivor-phone> .
  <{B}retired-far> a pwg:RetiredPerson ; pwg:displayName "Morgan Lee" ;
      pwg:mergedInto <{B}retired-mid> .

  # Control: an ordinary human-named live person.
  <{B}control> a pwg:Person ; pwg:displayName "Jordan Blake" .
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
        p = self._one("Casey Ward")
        self.assertEqual(p["person_uri"], B + "survivor-email")
        self.assertIn(p["name"], ("Casey Ward", "Casey W Ward"))

    def test_both_retired_names_collapse_to_one_survivor(self):
        # "casey" matches both retired nodes AND the survivor's own email:
        # one live person, reported once, under a human name.
        p = self._one("casey")
        self.assertEqual(p["person_uri"], B + "survivor-email")
        self.assertNotIn("@", p["name"])

    def test_two_hop_chain_resolves_to_live_terminus(self):
        p = self._one("Morgan Lee")
        self.assertEqual(p["person_uri"], B + "survivor-phone")
        self.assertEqual(p["name"], "Morgan Lee")

    def test_retired_node_is_never_returned_itself(self):
        for q in ("Casey", "Morgan"):
            out = server.person_context(q)
            uris = [m["person_uri"] for m in out.get("matches", [])] or \
                [out.get("person", {}).get("person_uri")]
            self.assertFalse(any("retired" in (u or "") for u in uris), (q, uris))

    def test_control_human_named_person_still_found(self):
        p = self._one("Jordan Blake")
        self.assertEqual(p["person_uri"], B + "control")
        self.assertEqual(p["name"], "Jordan Blake")

    def test_control_absent_name_is_not_found(self):
        self.assertFalse(server.person_context("Nobody Here At All").get("found"))


if __name__ == "__main__":
    unittest.main()
