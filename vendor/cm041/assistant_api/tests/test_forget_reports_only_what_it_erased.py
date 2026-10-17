"""The forget endpoint says "done" only when the person is actually gone.

Status-honesty sweep 2026-10-15, rows V17 and V22 (walk #28 grading,
privacy). Three ways the erasure promise was broken in the reporting:

  V17a  api_people_forget answered forgotten:true / HTTP 200 when only ONE of
        the two stores was purged (Qdrant deleted, the graph delete failed, or
        the other way round). The person's records were still on the Mac.
  V17b  the "already forgotten" answer read forget_audit.log, and that log was
        written by _queue_wiki_recompile, which memory/assert and a failed
        forget also call. So a later forget could answer already_forgotten
        with nothing ever purged.
  V22   forget_tombstone.record() met an unreadable tombstone file and wrote
        a fresh one over it, wiping every earlier Forget. Forgotten people
        could then come back on the next sync.

The graph is a REAL pyoxigraph engine behind a socket (tests/_fake_oxigraph.py)
and Qdrant is a small HTTP stand-in whose answer each test chooses, so the
handler runs its real requests. Merge-aware: every forget is of a person with
merged-in nodes, and "gone" means the survivor AND every merged node.

Cast names only. No phone numbers or real data.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
sys.path.insert(0, str(REPO / "tests"))
sys.path.insert(0, str(HERE))

from _fake_oxigraph import FakeOxigraph  # noqa: E402
from _fake_qdrant import FakeQdrant  # noqa: E402
from test_people_list_endpoint import server  # noqa: E402  (loads ical-server.py with its stubs)

sys.path.insert(0, str(REPO / "vendor" / "cm041"))
from identity_resolver import forget_tombstone  # noqa: E402

B = "urn:test:person:"
CLUSTER = [B + n for n in ("survivor", "retired", "tomb")]

TRIPLES = f"""
INSERT DATA {{
  <{B}survivor> a pwg:Person ; pwg:displayName "Jane Doe" .
  <{B}retired> a pwg:RetiredPerson ; pwg:displayName "Jane Smith" ;
      pwg:mergedInto <{B}survivor> .
  <{B}tomb> pwg:displayName "Jo Doe" ; pwg:mergedInto <{B}retired> .
  <{B}control> a pwg:Person ; pwg:displayName "Carl Stewart" .
}}
"""


class _Base(unittest.TestCase):
    def setUp(self):
        self.ox = FakeOxigraph()
        self.ox.update(TRIPLES)
        self.qd = FakeQdrant()
        self._saved = (server.OXIGRAPH_URL, server.QDRANT_URL, server._RECOMPILE_QUEUE_DIR,
                       server._sparql_update)
        server.OXIGRAPH_URL = self.ox.url
        server.QDRANT_URL = self.qd.url
        self.tmp = tempfile.TemporaryDirectory()
        server._RECOMPILE_QUEUE_DIR = Path(self.tmp.name) / "queue"
        self.tomb = Path(self.tmp.name) / "tomb.json"
        self._env = {k: os.environ.get(k) for k in (
            "OSTLER_FORGET_TOMBSTONE_FILE", "OSTLER_PERSON_DELETION_LOG")}
        os.environ["OSTLER_FORGET_TOMBSTONE_FILE"] = str(self.tomb)
        os.environ["OSTLER_PERSON_DELETION_LOG"] = str(Path(self.tmp.name) / "del.log")

    def tearDown(self):
        (server.OXIGRAPH_URL, server.QDRANT_URL, server._RECOMPILE_QUEUE_DIR,
         server._sparql_update) = self._saved
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.ox.close()
        self.qd.close()
        self.tmp.cleanup()

    def left(self, uris):
        return [u for u in uris if self.ox.ask(f"ASK {{ <{u}> ?p ?o }}")]

    def audit_lines(self):
        log = server._RECOMPILE_QUEUE_DIR / "forget_audit.log"
        return log.read_text().splitlines() if log.exists() else []


class BothStoresMustBePurged(_Base):
    def test_control_both_stores_purged_is_done_and_audited(self):
        out, code = server.api_people_forget("jane-smith")
        self.assertEqual(code, 200, out)
        self.assertTrue(out["forgotten"], out)
        self.assertEqual(sorted(out["stores_purged"]), ["oxigraph", "qdrant"], out)
        self.assertEqual(self.left(CLUSTER), [], out)
        self.assertEqual(self.left([B + "control"]), [B + "control"])
        # Qdrant was asked to delete the WHOLE cluster, not one node.
        self.assertEqual(sorted(self.qd.deletes[-1][1]["filter"]["must"][0]["match"]["any"]),
                         sorted(CLUSTER))
        self.assertEqual(len([l for l in self.audit_lines() if l.endswith(" forget jane-smith")]), 1)
        # A second forget is the benign, honest "already forgotten".
        out2, code2 = server.api_people_forget("jane-smith")
        self.assertEqual((code2, out2.get("already_forgotten")), (200, True), out2)

    def test_qdrant_failed_is_not_done(self):
        self.qd.status = 500
        out, code = server.api_people_forget("jane-smith")
        self.assertEqual(code, 503, out)
        self.assertFalse(out["forgotten"], out)
        self.assertIn("qdrant", out.get("stores_remaining", []), out)
        self.assertTrue(out.get("retry"), out)
        self.assertEqual(self.audit_lines(), [], "audit written for an incomplete erasure")
        # The retry after the graph half went must not say "already forgotten".
        out2, _ = server.api_people_forget("jane-smith")
        self.assertFalse(out2.get("already_forgotten"), out2)

    def test_graph_delete_failed_is_not_done(self):
        def boom(_q):
            raise RuntimeError("oxigraph update refused")
        server._sparql_update = boom
        out, code = server.api_people_forget("jane-smith")
        self.assertEqual(code, 503, out)
        self.assertFalse(out["forgotten"], out)
        self.assertIn("oxigraph", out.get("stores_remaining", []), out)
        self.assertEqual(self.left(CLUSTER), CLUSTER)
        self.assertEqual(self.audit_lines(), [])

    def test_absent_people_collection_holds_nothing_so_counts_as_purged(self):
        # A Mac whose `people` collection was never created holds no vectors
        # for anyone. That is a measured empty, not a failed delete.
        self.qd.status = 404
        out, code = server.api_people_forget("jane-smith")
        self.assertEqual(code, 200, out)
        self.assertTrue(out["forgotten"], out)
        self.assertIn("qdrant", out["stores_purged"], out)


class RetryPurgesQdrantEvenWhenTheGraphIsEmpty(_Base):
    def test_retry_after_a_qdrant_failure_sends_the_qdrant_delete(self):
        # Call 1: the graph half goes, Qdrant answers 500 -> 503 retry:true.
        # Call 2: the graph is already empty, so the person no longer resolves.
        # The retry must still send the Qdrant delete for the same cluster.
        self.qd.script = [500, 200]
        out, code = server.api_people_forget("jane-smith")
        self.assertEqual(code, 503, out)
        self.assertTrue(out.get("retry"), out)
        self.assertEqual(self.left(CLUSTER), [])
        self.assertEqual(len(self.qd.deletes), 1)
        out2, code2 = server.api_people_forget("jane-smith")
        self.assertEqual(len(self.qd.deletes), 2, "the retry sent no Qdrant delete: %s" % out2)
        self.assertEqual(sorted(self.qd.deletes[-1][1]["filter"]["must"][0]["match"]["any"]),
                         sorted(CLUSTER))
        self.assertEqual(code2, 200, out2)
        self.assertTrue(out2["forgotten"], out2)
        self.assertEqual(sorted(out2["stores_purged"]), ["oxigraph", "qdrant"], out2)
        self.assertEqual(len([l for l in self.audit_lines() if l.endswith(" forget jane-smith")]), 1)
        # Once done, the pending record is gone and a third call is benign.
        out3, code3 = server.api_people_forget("jane-smith")
        self.assertEqual((code3, out3.get("already_forgotten")), (200, True), out3)
        self.assertEqual(len(self.qd.deletes), 2)

    def test_control_unknown_slug_still_sends_no_qdrant_delete(self):
        out, code = server.api_people_forget("nobody-here")
        self.assertTrue(out.get("not_found"), out)
        self.assertEqual(self.qd.deletes, [])


class OnlyAnAbsenceBodyCountsAs404Empty(_Base):
    def test_a_bare_404_is_a_failure(self):
        self.qd.status = 404
        self.qd.bare404 = True
        out, code = server.api_people_forget("jane-smith")
        self.assertEqual(code, 503, out)
        self.assertIn("qdrant", out.get("stores_remaining", []), out)


class DoneIsReadBackNotInferred(_Base):
    def test_qdrant_that_accepts_the_delete_but_still_holds_vectors_is_not_done(self):
        self.qd.held = 3
        out, code = server.api_people_forget("jane-smith")
        self.assertEqual(code, 503, out)
        self.assertIn("qdrant", out.get("stores_remaining", []), out)
        self.assertIn("qdrant_still_holds_vectors", out.get("reason", ""), out)
        self.assertTrue(self.qd.counts, "no read-back query was sent to Qdrant")

    def test_graph_update_that_returns_ok_but_deletes_nothing_is_not_done(self):
        server._sparql_update = lambda _q: None   # accepted, erased nothing
        out, code = server.api_people_forget("jane-smith")
        self.assertEqual(code, 503, out)
        self.assertIn("oxigraph", out.get("stores_remaining", []), out)
        self.assertIn("oxigraph_still_holds_triples", out.get("reason", ""), out)
        self.assertEqual(self.audit_lines(), [])


class AuditOnlyAfterARealPurge(_Base):
    def test_a_memory_assert_recompile_hint_is_not_a_forget(self):
        # memory/assert queues a recompile for the person it wrote about.
        server._queue_wiki_recompile("ghost-person")
        self.assertEqual(self.audit_lines(), [])
        out, code = server.api_people_forget("ghost-person")
        self.assertEqual(code, 200, out)
        self.assertFalse(out.get("already_forgotten"), out)
        self.assertTrue(out.get("not_found"), out)

    def test_an_unknown_slug_writes_no_audit_line(self):
        server.api_people_forget("nobody-here")
        out, _ = server.api_people_forget("nobody-here")
        self.assertFalse(out.get("already_forgotten"), out)
        self.assertEqual(self.audit_lines(), [])


class UnreadableTombstoneIsNeverOverwritten(_Base):
    def test_record_refuses_and_keeps_the_bytes(self):
        bad = b'{"v": 1, "salt": "abc", "entries": [ {"uri": "urn:test:person:earlier"'  # truncated
        self.tomb.write_bytes(bad)
        ok = forget_tombstone.record(B + "survivor", ["jane@example.invalid"], "Jane Doe")
        self.assertFalse(ok)
        self.assertEqual(self.tomb.read_bytes(), bad, "the unreadable tombstone was overwritten")
        asides = list(self.tomb.parent.glob(self.tomb.name + ".unreadable-*"))
        self.assertEqual(len(asides), 1, asides)
        self.assertEqual(asides[0].read_bytes(), bad)
        # Still fail-closed for every syncer.
        self.assertTrue(forget_tombstone.is_forgotten(values=["someone@example.invalid"]))
        self.assertIsNotNone(forget_tombstone.problem())

    def test_control_a_readable_tombstone_is_extended(self):
        self.assertTrue(forget_tombstone.record(B + "earlier", ["sam@example.invalid"], "Sam Brown"))
        self.assertIsNone(forget_tombstone.problem())
        self.assertTrue(forget_tombstone.record(B + "survivor", ["jane@example.invalid"], "Jane Doe"))
        data = json.loads(self.tomb.read_text())
        self.assertEqual([e["uri"] for e in data["entries"]], [B + "earlier", B + "survivor"])

    def test_forget_surfaces_the_unreadable_tombstone(self):
        bad = b"not json at all"
        self.tomb.write_bytes(bad)
        out, code = server.api_people_forget("jane-smith")
        self.assertFalse(out["tombstone_written"], out)
        self.assertIn("tombstone_unreadable", out.get("reason", ""), out)
        self.assertEqual(self.tomb.read_bytes(), bad)


class OstlerFdaCopyStaysIdentical(unittest.TestCase):
    def test_both_copies_are_byte_identical(self):
        a = (REPO / "vendor/cm041/identity_resolver/forget_tombstone.py").read_bytes()
        b = (REPO / "vendor/ostler_fda/forget_tombstone.py").read_bytes()
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main()
