"""conversation_upload: reassembly, idempotency, bounds, traversal. Synthetic data."""
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import conversation_upload as cu  # noqa: E402


class Upload(unittest.TestCase):
    def setUp(self):
        self.spool = Path(tempfile.mkdtemp()) / "spool"
        self.calls = []

    def proc(self, payload):
        self.calls.append(payload)
        return {"job_id": payload["metadata"]["meeting_id"], "status": "accepted"}, 202

    def send(self, idx, total, text="x\n", mid="m-1", **kw):
        return cu.receive_part({"meeting_id": mid, "part_index": idx, "part_total": total,
                                "transcript": text, **kw}, self.proc, self.spool)

    def test_out_of_order_parts_join_in_index_order_and_process_once(self):
        self.assertEqual(self.send(2, 3, "C\n")[0]["missing"], [0, 1])
        self.assertEqual(self.send(0, 3, "A\n", metadata={"type": "call"})[1], 200)
        body, st = self.send(1, 3, "B\n")
        self.assertEqual((st, body["parts"]), (202, 3))
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0]["transcript"], "A\nB\nC\n")
        self.assertEqual(self.calls[0]["metadata"], {"type": "call", "meeting_id": "m-1"})
        self.assertEqual(list(self.spool.iterdir()), [])  # spool cleaned

    def test_resend_is_idempotent_and_conflict_is_409(self):
        self.send(0, 2, "A\n")
        self.assertEqual(self.send(0, 2, "A\n")[1], 200)
        self.assertEqual(self.send(0, 2, "DIFFERENT\n")[1], 409)
        self.assertEqual(self.send(1, 5, "B\n")[1], 409)  # part_total changed

    def test_single_part_upload_processes_immediately(self):
        self.assertEqual(self.send(0, 1)[1], 202)

    def test_bounds(self):
        self.assertEqual(self.send(0, cu.MAX_PARTS + 1)[1], 400)
        self.assertEqual(self.send(3, 3)[1], 400)
        self.assertEqual(self.send(-1, 3)[1], 400)
        self.assertEqual(self.send(0, 1, "x" * (cu.MAX_PART_BYTES + 1))[1], 413)
        self.assertEqual(self.send(True, 3)[1], 400)
        self.assertEqual(self.send(0, 3, "")[1], 400)

    def test_total_size_cap(self):
        cu.MAX_ASSEMBLED_BYTES, saved = 10, cu.MAX_ASSEMBLED_BYTES
        try:
            self.assertEqual(self.send(0, 3, "123456")[1], 200)
            self.assertEqual(self.send(1, 3, "123456")[1], 413)
        finally:
            cu.MAX_ASSEMBLED_BYTES = saved

    def test_traversal_ids_rejected(self):
        for bad in ("../x", "a/b", "..", "", None, 5, "a" * 129):
            self.assertEqual(self.send(0, 1, mid=bad)[1], 400, bad)
        self.assertFalse(self.spool.exists() and any(self.spool.iterdir()))

    def test_abandoned_uploads_expire(self):
        self.send(0, 2, "A\n", mid="old")
        old = time.time() - cu.EXPIRY_SECONDS - 10
        os.utime(self.spool / "old", (old, old))
        self.send(0, 2, "A\n", mid="new")
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), ["new"])

    def test_processing_failure_is_reported_not_swallowed(self):
        def fail(_):
            return {"error": "not configured"}, 503
        cu.receive_part({"meeting_id": "m", "part_index": 0, "part_total": 2, "transcript": "A"}, fail, self.spool)
        body, st = cu.receive_part({"meeting_id": "m", "part_index": 1, "part_total": 2, "transcript": "B"},
                                   fail, self.spool)
        self.assertEqual(st, 503)


if __name__ == "__main__":
    unittest.main()
