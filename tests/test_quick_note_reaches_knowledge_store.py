"""An iOS Quick Note must reach the knowledge store, not just a spool file.

Before: POST /api/v1/ingest/ios answered 200 and wrote ios-*.jsonl in
INGEST_DIR, which nothing reads, so the note never reached the Hub.
Now: api_ingest_ios hands each quick_note point to the Save-to-Knowledge
drain (EnrichQueue); one real drain tick (run_once) writes it to the
knowledge collection through the real _enrich_store.

Real code called: the vendored server's api_ingest_ios, the real EnrichQueue
and the real _enrich_summarise/_enrich_store. Stubbed boundary: only the
Qdrant HTTP functions and the embedder (an in-memory dict store).
All data synthetic.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SERVER_FILE = Path(__file__).resolve().parent.parent / "vendor/cm041/assistant_api/ical-server.py"
ROOT = SERVER_FILE.parent.parent.parent.parent
for _p in (ROOT / "vendor", ROOT / "vendor/cm041", ROOT / "vendor/cm041/assistant_api"):
    sys.path.insert(0, str(_p))


def point(pid="11111111-aaaa-bbbb-cccc-000000000001", text="Remember the synthetic widget order",
          level="L1", **kw):
    f = {"type": "quick_note", "timestamp": "2026-10-15T09:30:00Z", "text": text,
         "person_name": "Jane", "location_name": None, "privacy_level": level}
    f.update(kw)
    return {"id": pid, "payload": f}


class QuickNote(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        home = Path(self.tmp.name)
        self.p = patch.dict(os.environ, {
            "HOME": self.tmp.name, "INGEST_DIR": str(home / "ingest"),
            "OSTLER_BROWSING_QUEUE_DIR": str(home / "queue"),
            "OSTLER_SUBSCRIPTION_STATE": str(home / "none"),
        })
        self.p.start()
        spec = importlib.util.spec_from_file_location("ical_qn", SERVER_FILE)
        self.s = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.s)
        self.s.INGEST_DIR = str(home / "ingest")
        self.s._subscription_paused = lambda *_a, **_k: None
        bn = self.s._bn()
        self.bn = bn
        self.store = {}
        for name, fn in (
                ("qdrant_ensure_collection", lambda *a, **k: None),
                ("qdrant_upsert", lambda base, coll, pid, vec, payload: (
                    self.store.__setitem__((coll, pid), payload) or True)),
                ("qdrant_set_payload", lambda *a, **k: True)):
            pp = patch.object(bn, name, fn)   # restored in tearDown: bn is shared
            pp.start()
            self.addCleanup(pp.stop)
        self.s._embed_text = lambda t, timeout=30: [0.1, 0.2, 0.3]
        self.q = bn.EnrichQueue(str(home / "queue"), self.s._enrich_summarise,
                                self.s._enrich_store, min_interval_s=0,
                                is_user_active=lambda: False, sleep=lambda _s: None)
        self.s._enrich_queue = lambda: self.q

    def tearDown(self):
        self.p.stop()
        self.tmp.cleanup()

    def post(self, *points):
        return self.s.api_ingest_ios({"points": list(points)})

    def tick_all(self):
        n = 0
        while self.q.run_once():
            n += 1
        return n

    def test_note_posted_then_one_drain_tick_is_in_the_store(self):
        body, status = self.post(point())
        self.assertEqual(status, 200)
        self.assertEqual(body["quick_notes"]["queued"], 1)
        self.assertEqual(self.store, {})            # 200 means queued, not yet stored
        self.assertEqual(self.tick_all(), 1)
        (coll, pid), payload = next(iter(self.store.items()))
        self.assertEqual(coll, self.bn.KNOWLEDGE_COLLECTION)
        self.assertIn("Remember the synthetic widget order", payload["content"])
        self.assertEqual(payload["source"], self.bn.QUICK_NOTE_SOURCE)
        self.assertIn("Jane", payload["tags"])
        self.assertEqual(payload["summary_status"], "done")
        self.assertEqual(self.q.depth(), 0)

    def test_replay_of_the_same_note_is_one_point_not_two(self):
        self.post(point()); self.tick_all()
        self.post(point()); self.tick_all()
        self.assertEqual(len(self.store), 1)

    def test_level_is_raised_to_the_notes_level_never_lowered(self):
        self.post(point(level="L1")); self.tick_all()
        self.assertEqual(next(iter(self.store.values()))["compartment_level"], 2)

    def test_l3_note_is_withheld_and_never_reaches_the_store(self):
        body, status = self.post(point(level="L3"))
        self.assertEqual(status, 200)
        self.assertEqual(body["quick_notes"], {"queued": 0, "withheld_l3": 1, "quarantined": 0})
        self.assertEqual(self.q.depth(), 0)
        self.tick_all()
        self.assertEqual(self.store, {})

    def test_unreadable_level_fails_closed(self):
        body, _ = self.post(point(level="banana"))
        self.assertEqual(body["quick_notes"]["withheld_l3"], 1)
        self.assertEqual(self.q.depth(), 0)

    def test_malformed_notes_are_quarantined_with_a_reason_and_good_ones_still_land(self):
        bad = [point(pid="b1", text="   "), point(pid="b2", timestamp="not a date"),
               point(pid="b3", text=None), {"id": "", "payload": point()["payload"]}]
        body, status = self.post(*bad, point(pid="good-1"))
        self.assertEqual(status, 200)
        self.assertEqual(body["quick_notes"], {"queued": 1, "withheld_l3": 0, "quarantined": 4})
        qdir = Path(self.s.INGEST_DIR) / "quarantine"
        reasons = sorted(json.loads(p.read_text())["reason"] for p in qdir.glob("*.json"))
        self.assertEqual(reasons, ["bad_timestamp", "missing_id", "missing_text", "missing_text"])
        self.tick_all()
        self.assertEqual(len(self.store), 1)

    def test_other_ios_types_are_untouched(self):
        body, status = self.post({"id": "m1", "payload": {"type": "music_listen", "track_name": "x"}})
        self.assertEqual(status, 200)
        self.assertNotIn("quick_notes", body)
        self.assertEqual(self.q.depth(), 0)

    def test_the_raw_spool_still_written(self):
        body, _ = self.post(point())
        self.assertTrue(Path(body["path"]).exists())


if __name__ == "__main__":
    unittest.main()
