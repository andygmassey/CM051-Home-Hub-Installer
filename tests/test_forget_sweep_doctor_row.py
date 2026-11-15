"""The Doctor source-status table shows the forget sweep, and only once a forget has
written its sentinel.

Arms (real read_source_status on a temp hydrate dir; synthetic values):
  1. no forget_sweep.done: no forget_sweep row (no forget has run).
  2. forget_sweep.done status=residuals_found: row present with that status and item_count 1.
  3. forget_sweep.done status=cannot_run: row present as cannot_run, not as a pass.
  4. a sentinel that cannot be read: row is unreadable, never absent.
Mutation control: arms 2 and 3 fail on the pre-change reader (no forget row at all).

Run: HOME=<sandbox> python3 tests/test_forget_sweep_doctor_row.py
"""
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "doctor" / "agent"))
sys.path.insert(0, str(ROOT / "vendor" / "doctor"))

import web_ui  # noqa: E402


def _row(rows, name):
    hits = [r for r in rows if r.get("source") == name]
    return hits[0] if hits else None


class ForgetSweepDoctorRow(unittest.TestCase):

    def setUp(self):
        self.hydrate = Path(tempfile.mkdtemp(prefix="hydrate-"))

    def _write(self, status, item_count=None):
        lines = ["status=%s" % status, "recorded_at=2026-11-15T03:00:00Z"]
        if item_count is not None:
            lines.append("item_count=%d" % item_count)
        (self.hydrate / "forget_sweep.done").write_text("\n".join(lines) + "\n")

    def test_1_absent_sentinel_means_no_forget_row(self):
        rows = web_ui.read_source_status(hydrate_dir=self.hydrate)
        self.assertIsNone(_row(rows, "forget_sweep"))

    def test_2_residuals_found_is_shown_with_its_count(self):
        self._write("residuals_found", item_count=1)
        row = _row(web_ui.read_source_status(hydrate_dir=self.hydrate), "forget_sweep")
        self.assertIsNotNone(row, "the forget row is missing")
        self.assertEqual("residuals_found", row["status"])
        self.assertEqual(1, row["item_count"])
        self.assertEqual("forget", row["kind"])

    def test_3_cannot_run_is_shown_as_cannot_run_not_as_a_pass(self):
        self._write("cannot_run")
        row = _row(web_ui.read_source_status(hydrate_dir=self.hydrate), "forget_sweep")
        self.assertEqual("cannot_run", row["status"])

    def test_4_unreadable_sentinel_is_unreadable_never_absent(self):
        p = self.hydrate / "forget_sweep.done"
        p.write_bytes(b"\xff\xfe\x00bad")
        p.chmod(0)
        self.addCleanup(lambda: p.chmod(0o644))
        row = _row(web_ui.read_source_status(hydrate_dir=self.hydrate), "forget_sweep")
        self.assertIsNotNone(row, "an unreadable sentinel was dropped")
        self.assertIn(row["status"], ("unreadable", "unknown"))


if __name__ == "__main__":
    unittest.main()
