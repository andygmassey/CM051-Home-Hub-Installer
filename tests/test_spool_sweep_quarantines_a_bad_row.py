"""The assert-spool sweep must not die on one bad row (walk #29, F1).

Measured on a Hub: "[memory/assert] spool sweep error: ValueError" every 20 s,
1,032+ times. One row whose asserted_at is not an ISO timestamp made
datetime.fromisoformat raise INSIDE the per-row loop, which aborted the whole
sweep: the row was never counted against, so it was retried forever and every
row behind it was starved.

Contract (synthetic rows, the real sweep function loaded from the vendored
server, the graph stubbed):
  * a bad row raises nothing out of the sweep, and the good rows behind it
    are written in the same pass;
  * the bad row is retried, counted, and QUARANTINED after N attempts with a
    reason (type and file:line only, never content);
  * a quarantined row is not picked up again;
  * an outage-shaped error (graph down) counts against nobody;
  * the Doctor status file carries the quarantined count.
The spool here is a plain sqlite file behind a stand-in _secure_connect that
demands the key; the real sqlcipher arm is CANNOT-RUN where sqlcipher3 is
absent (printed, not skipped silently).
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import sqlite3
import tempfile
import contextlib
import unittest
from pathlib import Path
from unittest.mock import patch

SERVER_FILE = Path(__file__).resolve().parent.parent / "vendor/cm041/assistant_api/ical-server.py"
import sys
ROOT = SERVER_FILE.parent.parent.parent.parent
for _p in (ROOT / "vendor", ROOT / "vendor/cm041", ROOT / "vendor/cm041/assistant_api"):
    sys.path.insert(0, str(_p))
KEY = "synthetic-test-key-0003"


class SpoolSweep(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.p = patch.dict(os.environ, {
            "HOME": self.tmp.name,
            "ASSERT_SPOOL_DB": str(self.home / "assert_spool.db"),
            "ASSERT_SPOOL_STATUS": str(self.home / "status.json"),
        })
        self.p.start()
        for n in ("PWG_HOME", "OSTLER_DB_KEY"):
            os.environ.pop(n, None)
        spec = importlib.util.spec_from_file_location("ical_spool", SERVER_FILE)
        self.s = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.s)
        self.s._ENCRYPTION_KEY = KEY

        def secure(path, key):
            assert key == KEY, "wrong key"
            return sqlite3.connect(path)
        self.s._secure_connect = secure
        self.s.ASSERT_SPOOL_MAX_ATTEMPTS = 3
        self.s._assert_fact_person = lambda fid: None
        self.written = []

        def resolve(subject, fact_text, rel, via, now=None, **kw):
            self.written.append(subject)
            return ({"status": "stored", "person_uri": "u:" + subject,
                     "person_slug": subject}, 200)
        self.s._assert_resolve_and_write = resolve

    def tearDown(self):
        self.p.stop()
        self.tmp.cleanup()

    def _add(self, tag, asserted_at="2026-01-01T00:00:00+00:00", level="L1", n=0):
        conn = self.s._assert_spool_connect()
        conn.execute(
            "INSERT INTO assert_spool (spool_id, subject, fact_text, relationship,"
            " asserted_via, privacy_level, asserted_at, fact_id, person_id,"
            " created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
            ("spool_" + tag, tag, "likes tea", None, "t", level, asserted_at,
             "fact_" + tag, "p" + tag, "2026-01-01T00:00:0%d+00:00" % n))
        conn.commit()
        conn.close()

    def _state(self, tag):
        conn = self.s._assert_spool_connect()
        try:
            return conn.execute(
                "SELECT state, attempts, last_reason FROM assert_spool "
                "WHERE spool_id=?", ("spool_" + tag,)).fetchone()
        finally:
            conn.close()

    def _sweep(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            c = self.s._assert_spool_sweep()
        return c, err.getvalue()

    def test_bad_row_is_quarantined_and_good_rows_are_processed(self):
        self._add("alpha", n=1)
        self._add("bad", asserted_at="not-a-date", n=2)
        self._add("badlevel", level="L9", n=3)
        self._add("omega", n=4)
        c, err = self._sweep()  # must not raise
        self.assertEqual(sorted(self.written), ["alpha", "omega"],
                         "good rows behind a bad row must be written")
        self.assertEqual(self._state("bad")[:2], ("pending", 1))
        self._sweep()
        self.assertEqual(self._state("bad")[0], "pending")
        c, err = self._sweep()
        for tag in ("bad", "badlevel"):
            state, attempts, reason = self._state(tag)
            self.assertEqual((state, attempts), ("quarantined", 3), tag)
            self.assertIn("ValueError", reason)
        self.assertEqual(c["quarantined"], 2)
        # no content in the log or the reason
        self.assertNotIn("not-a-date", err)
        self.assertNotIn("not-a-date", self._state("bad")[2])
        # a quarantined row is not retried
        before = self.written[:]
        c, _ = self._sweep()
        self.assertEqual(c["pending"], 0)
        self.assertEqual(self.written, before)
        status = json.loads((self.home / "status.json").read_text())
        self.assertEqual(status["quarantined"], 2)

    def test_outage_counts_against_nobody(self):
        self._add("alpha")

        def down(*a, **k):
            raise ConnectionError("graph down")
        self.s._assert_resolve_and_write = down
        for _ in range(6):
            self._sweep()
        self.assertEqual(self._state("alpha")[:2], ("pending", 0))

    def test_doctor_shows_the_quarantine_count(self):
        sys.path.insert(0, str(ROOT / "vendor/doctor/agent"))
        import diagnostic_rules as dr
        f = self.home / "st.json"
        f.write_text(json.dumps({"quarantined": 2, "pending": 0}))
        with patch.object(dr, "_ostler_assert_spool_status_path", lambda: str(f)):
            got = dr.check_parked_facts(None)
            self.assertEqual([g.get("quarantined_facts") for g in got], [2])
            f.write_text(json.dumps({"quarantined": 0}))
            self.assertEqual(dr.check_parked_facts(None), [])

    def test_real_sqlcipher_arm(self):
        try:
            import sqlcipher3  # noqa: F401
        except ImportError:
            print("CANNOT-RUN: sqlcipher3 absent; real encrypted arm not exercised")
            self.skipTest("sqlcipher3 absent")


if __name__ == "__main__":
    unittest.main()
