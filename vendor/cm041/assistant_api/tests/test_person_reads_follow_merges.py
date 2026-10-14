"""Every slug- or name-keyed person read lands on the LIVE survivor of a merge.

Walk #27 (Mini16, 2026-10-14). A contact merge leaves the losing nodes with
pwg:mergedInto <survivor>: typed pwg:RetiredPerson, untyped tombstones, and
145 nodes an FDA rerun re-typed back to pwg:Person while they still carry
mergedInto. person_context walked the chain (#2864); these routes did not:

  person view   person_enrichment   slug -> first Person whose name slugs equal
  timeline      person_timeline     same
  forget        api_people_forget   same, then erased ONE node
  memory/assert _resolve_person_uri_by_name   exact name, LIMIT 1
  birthdays     people_birthdays    Person + birthday, deduped by NAME

All five now use one resolver (_merge_aware_name_rows and friends). The store
is a REAL pyoxigraph engine behind a socket (tests/_fake_oxigraph.py): the
defect lives in the SPARQL text, so the SPARQL has to run.

Cast names only. No phone numbers or real data.
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
sys.path.insert(0, str(REPO / "tests"))
sys.path.insert(0, str(HERE))

from _fake_oxigraph import FakeOxigraph  # noqa: E402
from test_people_list_endpoint import server  # noqa: E402  (loads ical-server.py with its stubs)

B = "urn:test:person:"


def _mmdd(days_ahead):
    d = datetime.now() + timedelta(days=days_ahead)
    return d.strftime("%m-%d")


def _triples():
    soon = _mmdd(2)
    return f"""
INSERT DATA {{
  # The survivor. Two displayNames on the live node itself (257 such on the
  # box, 48 with a birthday), and a birthday.
  <{B}survivor> a pwg:Person ; pwg:displayName "Jane Doe" , "Jane Coe" ;
      pwg:birthday "{soon}" .
  # A retired alias, an untyped tombstone, and the RESURRECTED duplicate:
  # still `a pwg:Person`, same name as the survivor, but merged into it.
  <{B}retired> a pwg:RetiredPerson ; pwg:displayName "Jane Smith" ;
      pwg:mergedInto <{B}survivor> .
  <{B}tomb> pwg:displayName "Jo Doe" ; pwg:mergedInto <{B}retired> .
  <{B}dup> a pwg:Person ; pwg:displayName "Jane Doe" ;
      pwg:birthday "{soon}" ; pwg:mergedInto <{B}survivor> .

  # Two DIFFERENT people who share a name. Both have birthdays this week.
  <{B}sam-1> a pwg:Person ; pwg:displayName "Sam Brown" ; pwg:birthday "{_mmdd(3)}" .
  <{B}sam-2> a pwg:Person ; pwg:displayName "Sam Brown" ; pwg:birthday "{_mmdd(4)}" .

  # Birthday held only on a retired node: it belongs to the survivor.
  <{B}tom> a pwg:Person ; pwg:displayName "Tom Jones" .
  <{B}tom-old> a pwg:RetiredPerson ; pwg:displayName "Thomas Jones" ;
      pwg:birthday "{_mmdd(1)}" ; pwg:mergedInto <{B}tom> .

  # Control: an ordinary person, no merge.
  <{B}control> a pwg:Person ; pwg:displayName "Carl Stewart" .

  # A decision filed against the RETIRED node, one against the survivor.
  <{B}dec-old> a pwg:Decision ; pwg:decisionSummary "Agreed the venue" ;
      pwg:decisionAbout <{B}retired> .
  <{B}dec-new> a pwg:Decision ; pwg:decisionSummary "Agreed the date" ;
      pwg:decisionAbout <{B}survivor> .
}}
"""


class _Base(unittest.TestCase):
    def setUp(self):
        self.ox = FakeOxigraph()
        self.ox.update(_triples())
        self._saved = (server.OXIGRAPH_URL, server.QDRANT_URL, server._RECOMPILE_QUEUE_DIR)
        server.OXIGRAPH_URL = self.ox.url
        # Unreachable on purpose: Qdrant is not under test here.
        server.QDRANT_URL = "http://127.0.0.1:9"
        self.tmp = tempfile.TemporaryDirectory()
        server._RECOMPILE_QUEUE_DIR = Path(self.tmp.name) / "queue"
        self._env = {k: os.environ.get(k) for k in (
            "OSTLER_FORGET_TOMBSTONE_FILE", "OSTLER_PERSON_DELETION_LOG")}
        os.environ["OSTLER_FORGET_TOMBSTONE_FILE"] = str(Path(self.tmp.name) / "tomb.json")
        os.environ["OSTLER_PERSON_DELETION_LOG"] = str(Path(self.tmp.name) / "del.log")

    def tearDown(self):
        server.OXIGRAPH_URL, server.QDRANT_URL, server._RECOMPILE_QUEUE_DIR = self._saved
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.ox.close()
        self.tmp.cleanup()


class PersonViewAndTimeline(_Base):
    def _check(self, fn):
        for slug in ("jane-doe", "jane-coe", "jane-smith", "jo-doe"):
            out, code = fn(slug)
            self.assertEqual(code, 200, (slug, out))
            uri = out.get("person_uri") or out.get("person", {}).get("person_uri")
            self.assertEqual(uri, B + "survivor", slug)

    def test_person_view_opens_the_survivor_for_every_name(self):
        self._check(server.person_enrichment)

    def test_timeline_opens_the_survivor_for_every_name(self):
        self._check(server.person_timeline)

    def test_control_unmerged_person_and_unknown_slug(self):
        out, code = server.person_enrichment("carl-stewart")
        self.assertEqual((code, out["person_uri"]), (200, B + "control"))
        out, code = server.person_enrichment("nobody-here")
        self.assertEqual(code, 404)


class ChatPersonContext(_Base):
    def test_the_resurrected_duplicate_is_not_a_second_match(self):
        # "Jane Doe" is the survivor's name AND the merged duplicate's name.
        out = server.person_context("Jane Doe")
        self.assertTrue(out.get("found"), out)
        uris = [m["person_uri"] for m in out.get("matches", [])] or \
            [out.get("person", {}).get("person_uri")]
        self.assertEqual(uris, [B + "survivor"], out)


class MemoryAssert(_Base):
    def test_a_fact_about_a_merged_name_lands_on_the_survivor(self):
        for name in ("Jane Doe", "Jane Smith", "Jo Doe"):
            self.assertEqual(server._resolve_person_uri_by_name(name), B + "survivor", name)

    def test_control(self):
        self.assertEqual(server._resolve_person_uri_by_name("Carl Stewart"), B + "control")
        self.assertIsNone(server._resolve_person_uri_by_name("Nobody Here"))


class Forget(_Base):
    def _subjects_left(self, uris):
        return [u for u in uris if self.ox.ask(f"ASK {{ <{u}> ?p ?o }}")]

    def test_forget_by_a_retired_name_erases_the_whole_person(self):
        out, code = server.api_people_forget("jane-smith")
        self.assertEqual(code, 200, out)
        self.assertIn("oxigraph", out["stores_purged"])
        cluster = [B + n for n in ("survivor", "retired", "tomb", "dup")]
        self.assertEqual(self._subjects_left(cluster), [], out)
        # Nothing else touched.
        self.assertEqual(self._subjects_left([B + "control", B + "sam-1", B + "tom"]),
                         [B + "control", B + "sam-1", B + "tom"])

    def test_forget_by_the_shared_name_erases_the_survivor_not_just_the_duplicate(self):
        out, code = server.api_people_forget("jane-doe")
        self.assertEqual(code, 200, out)
        self.assertEqual(self._subjects_left([B + "survivor", B + "dup"]), [])


class DecisionsAndSpeakers(_Base):
    def test_decisions_about_a_person_include_those_filed_on_merged_nodes(self):
        for slug in ("jane-doe", "jane-smith"):
            out, code = server.decisions_list(about=slug)
            self.assertEqual(code, 200, out)
            got = sorted(d["summary"] for d in out["decisions"])
            self.assertEqual(got, ["Agreed the date", "Agreed the venue"], (slug, out))

    def test_speaker_directory_lists_each_name_once_including_retired_names(self):
        names = [r["name"] for r in server._speaker_directory_rows()]
        self.assertEqual(len(names), len(set(names)), names)
        self.assertIn("Jane Smith", names)
        self.assertEqual(names.count("Jane Doe"), 1)


class Birthdays(_Base):
    def test_one_entry_per_person_and_same_name_people_both_listed(self):
        people = server.people_birthdays(days=7)["people"]
        uris = [p["person_uri"] for p in people]
        self.assertEqual(len(uris), len(set(uris)), people)
        self.assertEqual(uris.count(B + "survivor"), 1, people)
        self.assertNotIn(B + "dup", uris)
        self.assertNotIn(B + "retired", uris)
        # Two different people called Sam Brown: two birthdays.
        self.assertIn(B + "sam-1", uris)
        self.assertIn(B + "sam-2", uris)
        # A birthday held on a retired node is the survivor's.
        self.assertIn(B + "tom", uris)
        self.assertNotIn(B + "tom-old", uris)


if __name__ == "__main__":
    unittest.main()
