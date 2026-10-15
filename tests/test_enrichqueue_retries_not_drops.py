"""EnrichQueue must RETRY through a store outage, never drop (web saves and
quick notes), and quarantine only on an item-specific error.

Real code: the vendored server's api_ingest_ios (quick note) and
api_safari_save-shaped knowledge jobs, the real EnrichQueue, the real
_enrich_summarise/_enrich_store/_knowledge_store_up wiring. Stubbed: the
Qdrant HTTP functions (an in-memory store with an up/down switch) and the
embedder. A restart is a NEW EnrichQueue on the same spool dir. Synthetic data.
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


class Retry(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        home = Path(self.tmp.name)
        self.qdir = str(home / "queue")
        self.p = patch.dict(os.environ, {"HOME": self.tmp.name})
        self.p.start()
        spec = importlib.util.spec_from_file_location("ical_retry", SERVER_FILE)
        self.s = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.s)
        self.s.INGEST_DIR = str(home / "ingest")
        self.s._subscription_paused = lambda *_a, **_k: None
        self.s._embed_text = lambda t, timeout=30: [0.1, 0.2]
        bn = self.bn = self.s._bn()
        self.up = True
        self.reject = False          # store up but refuses THIS item
        self.store = {}
        self.now = 1000.0

        def upsert(base, coll, pid, vec, payload):
            if not self.up:
                raise OSError("connection refused")
            if self.reject:
                return False
            self.store[pid] = payload
            return True
        for name, fn in (("qdrant_ensure_collection",
                          lambda *a, **k: (_ for _ in ()).throw(OSError("down")) if not self.up else None),
                         ("qdrant_upsert", upsert),
                         ("qdrant_set_payload", lambda *a, **k: True)):
            pp = patch.object(bn, name, fn)
            pp.start()
            self.addCleanup(pp.stop)
        self.q = self.new_queue()

    def new_queue(self):
        """A fresh queue on the same spool dir = a daemon restart."""
        q = self.bn.EnrichQueue(self.qdir, self.s._enrich_summarise, self.s._enrich_store,
                                min_interval_s=0, is_user_active=lambda: False,
                                sleep=lambda _s: None, clock=lambda: self.now,
                                store_up=lambda: self.up)
        self.s._enrich_queue = lambda: q
        return q

    def tearDown(self):
        self.p.stop()
        self.tmp.cleanup()

    def note(self, pid="n1"):
        return {"id": pid, "payload": {"type": "quick_note", "timestamp": "2026-10-15T09:30:00Z",
                                       "text": "synthetic note body", "privacy_level": "L1"}}

    def web_job(self):
        bn = self.bn
        return {"id": "k-web1", "kind": bn.KIND_KNOWLEDGE, "url": "https://example.test/a",
                "title": "T", "text": "", "note": "my web note", "timestamp": "2026-10-15T09:30:00Z",
                "device": "d", "user_tags": []}

    def drain(self, advance=2000.0):
        n = 0
        for _ in range(8):
            self.now += advance
            while self.q.run_once() and n < 40:
                n += 1
        return n

    def test_qdrant_down_then_up_then_one_tick_indexes_the_note(self):
        self.up = False
        body, st = self.s.api_ingest_ios({"points": [self.note()]})
        self.assertEqual(st, 200)
        self.q.run_once()
        self.assertEqual(self.store, {})
        self.assertEqual(self.q.depth(), 1, "an outage must keep the job, not drop it")
        self.assertEqual(self.q.quarantined(), 0)
        self.up = True
        self.now += 2000
        self.assertTrue(self.q.run_once())
        self.assertEqual(len(self.store), 1)
        self.assertEqual(self.q.depth(), 0)

    def test_web_save_survives_the_same_outage(self):
        self.up = False
        self.q.enqueue(self.web_job())
        self.q.run_once()
        self.assertEqual((self.q.depth(), self.q.quarantined()), (1, 0))
        self.up = True
        self.drain()
        self.assertEqual(len(self.store), 1)

    def test_restart_while_down_still_indexes_afterwards(self):
        self.up = False
        self.s.api_ingest_ios({"points": [self.note()]})
        self.q.run_once()
        self.q = self.new_queue()                  # daemon restart, still down
        self.q.run_once()
        self.assertEqual(self.q.depth(), 1)
        self.q = self.new_queue()                  # and again
        self.up = True
        self.drain()
        self.assertEqual(len(self.store), 1)
        self.assertEqual(self.q.depth(), 0)

    def test_backoff_grows_and_is_honoured(self):
        self.up = False
        self.s.api_ingest_ios({"points": [self.note()]})
        self.q.run_once()
        j1 = self.q._jobs()[0]
        self.assertGreater(j1["next_retry_at"], self.now)
        self.assertFalse(self.q.run_once(), "not due yet: no attempt")
        self.now = j1["next_retry_at"] + 1
        self.q.run_once()
        j2 = self.q._jobs()[0]
        self.assertGreater(j2["next_retry_at"] - self.now, j1["next_retry_at"] - (j1["next_retry_at"] - 30))
        self.assertEqual(j2["outage_retries"], 2)

    def test_outage_never_quarantines_however_long(self):
        self.up = False
        self.s.api_ingest_ios({"points": [self.note()]})
        for _ in range(12):
            self.now += 5000
            self.q.run_once()
        self.assertEqual((self.q.depth(), self.q.quarantined()), (1, 0))

    def test_item_specific_error_is_quarantined_with_a_reason(self):
        self.reject = True                          # store is UP, refuses this item
        self.s.api_ingest_ios({"points": [self.note()]})
        self.drain()
        self.assertEqual(self.q.depth(), 0)
        self.assertEqual(self.q.quarantined(), 1)
        f = next((Path(self.qdir) / "quarantine").glob("*.json"))
        self.assertTrue(json.loads(f.read_text())["quarantine_reason"].startswith("store_rejected_item"))
        self.assertEqual(self.store, {})

    def test_a_poison_item_does_not_block_the_good_one(self):
        self.reject = True
        self.s.api_ingest_ios({"points": [self.note("bad")]})
        self.drain()
        self.reject = False
        self.s.api_ingest_ios({"points": [self.note("good")]})
        self.drain()
        self.assertEqual(len(self.store), 1)

    def test_default_predicate_unjudgeable_is_down(self):
        with patch.dict(os.environ, {"OSTLER_ENGINE_SUPERVISOR": str(Path(self.tmp.name) / "none.sh")}):
            with patch.object(self.s._bn(), "_q", lambda *a, **k: (_ for _ in ()).throw(OSError("x"))):
                self.assertFalse(self.s._knowledge_store_up())


if __name__ == "__main__":
    unittest.main()
