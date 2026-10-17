"""Hub hydration status (v1.0.107 #11): the conversations phase counter must
track CM048's real completions.

Measured on a walk box: 129 "pwg-convo completed" log lines, yet
GET /api/v1/hydration/status read completed 20 / running 90, flat, because
_wiki_conversations_progress only counted ``current_step == "completed"``,
which CM048 never writes for a real run (it records finished work in
``completed_steps``; ``09_bundle`` is the terminal step, same predicate as
CM048 seed.py ``already_enriched``). All data here is synthetic.
"""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import types
import typing
import unittest
from pathlib import Path
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"


def _install_ostler_security_stub() -> None:
    """Stub ostler_security so the vendored ical-server.py imports without
    the full HR015 dependency (it is not on PYTHONPATH here).

    Ported from the sibling test_people_list_endpoint.py /
    test_ical_server_wire_shape.py copy of this stub: the vendor tree's
    ical-server.py also imports ostler_security.db_key.resolve_db_key,
    not just .database/.posture.
    """
    if "ostler_security" in sys.modules:
        return
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg

    db_mod = types.ModuleType("ostler_security.database")

    def _stub_get_db_connection(*args, **kwargs):
        raise RuntimeError("stub: tests must not touch the DB")

    db_mod.get_db_connection = _stub_get_db_connection
    sys.modules["ostler_security.database"] = db_mod

    posture_mod = types.ModuleType("ostler_security.posture")
    posture_mod.record_posture = lambda *args, **kwargs: None
    sys.modules["ostler_security.posture"] = posture_mod

    db_key_mod = types.ModuleType("ostler_security.db_key")
    db_key_mod.SOURCE_ENV = "OSTLER_DB_KEY"
    db_key_mod.SOURCE_KEY_FILE = "OSTLER_DB_KEY_FILE"
    db_key_mod.REASON_NO_KEY = "no_key"

    class _DbKey(typing.NamedTuple):
        key: typing.Optional[str]
        source: typing.Optional[str]
        reason: typing.Optional[str]
        detail: typing.Optional[str]

    db_key_mod.DbKey = _DbKey
    db_key_mod.resolve_db_key = lambda: _DbKey(None, None, "no_key", None)
    sys.modules["ostler_security.db_key"] = db_key_mod


_install_ostler_security_stub()


def _load_server_module():
    spec = importlib.util.spec_from_file_location(
        "ical_server_hydration_counter", SERVER_FILE
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


import json
from datetime import datetime, timedelta, timezone

ALL_STEPS = ["00_raw", "01_classify", "02_enrich", "03_relationship_signal",
             "05_fact_extraction", "06_speaker_feedback", "07_sinks_written",
             "08_linked", "09_bundle"]


def _iso(delta_s=0):
    return (datetime.now(timezone.utc) - timedelta(seconds=delta_s)).isoformat()


class TestConversationsCounterTracksCompletions(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._env = patch.dict(os.environ, {"OSTLER_PROCESSING_DIR": self._tmp.name})
        self._env.start()
        self.server = _load_server_module()

    def tearDown(self):
        self._env.stop()
        self._tmp.cleanup()

    def _write(self, name, current_step, steps, failed=None, age_s=5):
        d = Path(self._tmp.name) / name
        d.mkdir()
        (d / "state.json").write_text(json.dumps({
            "conversation_id": name, "current_step": current_step,
            "completed_steps": steps, "failed_step": failed,
            "last_updated_at": _iso(age_s)}), encoding="utf-8")

    def test_n_completions_logged_counter_must_follow(self):
        # RED before the fix: 6 finished runs (current_step left on the last
        # step, or back on 00_raw), counter read completed 0 / running 6.
        for i in range(4):
            self._write("fin_bundle_%d" % i, "09_bundle", ALL_STEPS)
        for i in range(2):
            self._write("fin_reentered_%d" % i, "00_raw", ALL_STEPS)
        self._write("mid_run", "01_classify", ALL_STEPS[:2])
        r = self.server._wiki_conversations_progress()
        self.assertEqual(r["dispatched"], 7)
        self.assertEqual(r["completed"], 6)
        self.assertEqual(r["running"], 1)
        self.assertEqual(r["failed"], 0)

    def test_legacy_completed_marker_still_counts(self):
        self._write("legacy", "completed", ["00_raw"])
        self.assertEqual(self.server._wiki_conversations_progress()["completed"], 1)

    def test_failed_beats_complete(self):
        self._write("bad", "09_bundle", ALL_STEPS, failed="processor")
        r = self.server._wiki_conversations_progress()
        self.assertEqual((r["failed"], r["completed"]), (1, 0))

    def test_stale_running_is_reconciled_as_stalled(self):
        self._write("stuck", "01_classify", ALL_STEPS[:2], age_s=3 * 3600)
        self._write("live", "01_classify", ALL_STEPS[:2], age_s=10)
        r = self.server._wiki_conversations_progress()
        self.assertEqual((r["running"], r["stalled"]), (2, 1))

    def test_in_progress_work_alone_is_not_needs_attention(self):
        for i in range(3):
            self._write("fin_%d" % i, "09_bundle", ALL_STEPS)
        for i in range(5):
            self._write("run_%d" % i, "02_enrich", ALL_STEPS[:3])
        s = self.server
        with patch.object(s, "_wiki_people_count", return_value=10), \
             patch.object(s, "_wiki_triples_count", return_value=100), \
             patch.object(s, "_wiki_read_compiler_status",
                          return_value={"done": 4, "total": 4}):
            r = s.api_hydration_status()
        states = {p["key"]: p["state"] for p in r["phases"]}
        self.assertEqual(states["conversations"], "running")
        self.assertNotEqual(r["overall_state"], "needs_attention")


if __name__ == "__main__":
    unittest.main()
