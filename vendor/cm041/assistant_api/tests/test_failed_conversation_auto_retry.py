"""VENDOR COPY (CM051 graft of CM041 v1.0.107 #11). Failed conversations are retried automatically, on a backoff, and never lost
(v1.0.107 #11, Andy's "nothing lost" rule).

Measured on a walk box: 2 of 129 conversations failed at the processor step;
the single in-process retry was spent and only the manual ``pwg-convo
retry-all`` would resume them, which nothing schedules. All data synthetic.
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import types
import typing
import unittest
from datetime import datetime, timedelta, timezone
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


T0 = datetime(2026, 10, 8, 12, 0, 0, tzinfo=timezone.utc)
RAW = "Alice: synthetic line one.\nBob: synthetic line two.\n"
META = {"conversation_id": "2026-10-08_alice_bob", "channel": "spoken"}


def _load():
    spec = importlib.util.spec_from_file_location("ical_server_auto_retry", SERVER_FILE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _Done:
    def __init__(self, rc):
        self.returncode, self.stdout, self.stderr = rc, "", ""


class AutoRetry(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self._env = patch.dict(os.environ, {"OSTLER_PROCESSING_DIR": self._tmp.name})
        self._env.start()
        self.s = _load()

    def tearDown(self):
        self._env.stop()
        self._tmp.cleanup()

    def _failed(self, name="conv_a", age_s=0, reason_class=None):
        d = self.root / name
        d.mkdir()
        (d / "00_raw_transcript.md").write_text(RAW, encoding="utf-8")
        (d / "00_metadata.json").write_text(json.dumps(META), encoding="utf-8")
        (d / "state.json").write_text(json.dumps({
            "conversation_id": name, "created_at": T0.isoformat(),
            "last_updated_at": (T0 - timedelta(seconds=age_s)).isoformat(),
            "current_step": "00_raw", "completed_steps": ["00_raw"],
            "failed_step": "processor", "failure_reason": "x", "retry_count": 1,
            "prompt_versions": {}, "sink_idempotency_keys": {}}), encoding="utf-8")
        return d

    def _snapshot(self, d):
        return {p.name: p.read_bytes() for p in d.iterdir()
                if p.name in ("00_raw_transcript.md", "00_metadata.json")}

    def _runner(self, d, rc, calls):
        def run(tp, mp):
            calls.append(tp)
            if rc == 0:
                st = json.loads((d / "state.json").read_text())
                st["failed_step"] = None
                st["failure_reason"] = None
                st["completed_steps"] = ["00_raw", "01_classify", "09_bundle"]
                (d / "state.json").write_text(json.dumps(st))
            return _Done(rc)
        return run

    # -- on schedule -------------------------------------------------------
    def test_not_retried_before_first_backoff_then_retried(self):
        d = self._failed(age_s=0)
        calls = []
        r = self._runner(d, 1, calls)
        self.s._conversation_retry_sweep(now=T0 + timedelta(minutes=14), runner=r)
        self.assertEqual(calls, [])
        self.s._conversation_retry_sweep(now=T0 + timedelta(minutes=16), runner=r)
        self.assertEqual(len(calls), 1)

    def test_backoff_is_15m_1h_6h_then_daily(self):
        self.assertEqual(
            [self.s._conversation_retry_backoff(n) for n in range(6)],
            [900, 3600, 21600, 86400, 86400, 86400])

    def test_next_attempt_waits_for_the_next_backoff(self):
        d = self._failed(age_s=0)
        calls = []
        r = self._runner(d, 1, calls)
        t1 = T0 + timedelta(minutes=16)
        self.s._conversation_retry_sweep(now=t1, runner=r)
        self.s._conversation_retry_sweep(now=t1 + timedelta(minutes=59), runner=r)
        self.assertEqual(len(calls), 1)
        self.s._conversation_retry_sweep(now=t1 + timedelta(minutes=61), runner=r)
        self.assertEqual(len(calls), 2)

    # -- success clears ----------------------------------------------------
    def test_success_clears_failed_state_and_sidecar(self):
        d = self._failed()
        calls = []
        # one failure first so a sidecar exists
        self.s._conversation_retry_sweep(now=T0 + timedelta(minutes=16),
                                         runner=self._runner(d, 1, calls))
        self.assertTrue((d / "auto_retry.json").exists())
        out = self.s._conversation_retry_sweep(now=T0 + timedelta(hours=2),
                                               runner=self._runner(d, 0, calls))
        self.assertEqual(out["recovered"], 1)
        st = json.loads((d / "state.json").read_text())
        self.assertIsNone(st["failed_step"])
        self.assertFalse((d / "auto_retry.json").exists())
        prog = self.s._wiki_conversations_progress()
        # (the vendored completed-predicate is the pre-#201 one, so only the
        # failed count is asserted here)
        self.assertEqual(prog["failed"], 0)
        # and a recovered conversation is never retried again
        self.s._conversation_retry_sweep(now=T0 + timedelta(days=3),
                                         runner=self._runner(d, 1, calls))
        self.assertEqual(len(calls), 2)

    # -- the cap -----------------------------------------------------------
    def test_cap_is_respected_and_state_stays_visible(self):
        d = self._failed()
        calls = []
        r = self._runner(d, 1, calls)
        t = T0
        for _ in range(self.s.CONVERSATION_RETRY_MAX_ATTEMPTS + 4):
            t += timedelta(days=2)
            self.s._conversation_retry_sweep(now=t, runner=r)
        self.assertEqual(len(calls), self.s.CONVERSATION_RETRY_MAX_ATTEMPTS)
        side = json.loads((d / "auto_retry.json").read_text())
        self.assertTrue(side["gave_up"])
        prog = self.s._wiki_conversations_progress()
        self.assertEqual((prog["failed"], prog["gave_up"], prog["retrying"]), (1, 1, 0))

    def test_gave_up_surfaces_needs_attention_with_the_agreed_wording(self):
        d = self._failed()
        (d / "auto_retry.json").write_text(json.dumps({"attempts": 8, "gave_up": True}))
        s = self.s
        with patch.object(s, "_wiki_people_count", return_value=10), \
             patch.object(s, "_wiki_triples_count", return_value=100), \
             patch.object(s, "_wiki_read_compiler_status",
                          return_value={"complete": True, "stage_done": 4, "stage_total": 4}):
            r = s.api_hydration_status()
        conv = [p for p in r["phases"] if p["key"] == "conversations"][0]
        self.assertEqual(conv["state"], "needs_attention")
        self.assertEqual(conv["message"], "couldn't process, will retry on the next update")

    def test_still_retrying_is_not_needs_attention(self):
        self._failed()
        s = self.s
        with patch.object(s, "_wiki_people_count", return_value=10), \
             patch.object(s, "_wiki_triples_count", return_value=100), \
             patch.object(s, "_wiki_read_compiler_status",
                          return_value={"complete": True, "stage_done": 4, "stage_total": 4}):
            r = s.api_hydration_status()
        conv = [p for p in r["phases"] if p["key"] == "conversations"][0]
        self.assertEqual(conv["state"], "running")

    def test_manual_control_and_update_rearm_a_gave_up_conversation(self):
        d = self._failed()
        (d / "auto_retry.json").write_text(json.dumps(
            {"attempts": 8, "gave_up": True, "code_stamp": "an-older-build"}))
        self.assertEqual(self.s._conversation_retry_rearm(force=False), 1)
        side = json.loads((d / "auto_retry.json").read_text())
        self.assertEqual((side["attempts"], side["gave_up"]), (0, False))
        # same build, still spent: a plain restart must NOT re-arm (cap holds)
        side.update({"attempts": 8, "gave_up": True})
        self.s._write_retry_sidecar(d, side)
        self.assertEqual(self.s._conversation_retry_rearm(force=False), 0)
        self.assertEqual(self.s._conversation_retry_rearm(force=True), 1)

    # -- raw data is never deleted -----------------------------------------
    def test_raw_data_survives_every_kind_of_failure(self):
        for kind in ("nonzero", "timeout", "crash", "missing_runner_binary"):
            d = self._failed(name="conv_" + kind)
            before = self._snapshot(d)

            def run(tp, mp, kind=kind):
                if kind == "timeout":
                    raise subprocess.TimeoutExpired("x", 1)
                if kind == "crash":
                    raise RuntimeError("boom")
                if kind == "missing_runner_binary":
                    raise FileNotFoundError("x")
                return _Done(1)
            t = T0
            for _ in range(self.s.CONVERSATION_RETRY_MAX_ATTEMPTS + 1):
                t += timedelta(days=2)
                self.s._conversation_retry_sweep(now=t, runner=run)
            self.assertEqual(self._snapshot(d), before, kind)
            self.assertTrue((d / "state.json").exists(), kind)

    def test_missing_raw_input_is_kept_visible_not_deleted_or_looped(self):
        d = self._failed()
        (d / "00_raw_transcript.md").unlink()
        calls = []
        self.s._conversation_retry_sweep(now=T0 + timedelta(hours=1),
                                         runner=self._runner(d, 0, calls))
        self.assertEqual(calls, [])
        self.assertTrue((d / "state.json").exists())
        self.assertTrue(json.loads((d / "auto_retry.json").read_text())["gave_up"])

    def test_dispatch_failure_keeps_cm048_progress_and_error_class(self):
        # The dispatcher's final write used to wipe CM048's own completed_steps
        # and real cause. Simulate pwg-convo leaving its state, then failing.
        s = self.s
        d = self.root / "2026-10-08_alice_bob_conversation"

        def fake_run(args, **kw):
            d.mkdir(exist_ok=True)
            (d / "state.json").write_text(json.dumps({
                "conversation_id": d.name, "created_at": "x", "last_updated_at": "x",
                "current_step": "01_classify",
                "completed_steps": ["00_raw", "01_classify"],
                "failed_step": "02_enrich",
                "failure_reason": "EXHAUSTED: ReadTimeout: synthetic\nTraceback..."}))
            return _Done(1)
        with patch.object(s, "PROCESSING_DIR", self.root), \
             patch.object(s, "_invoke_pwg_convo", side_effect=fake_run), \
             patch("time.sleep"):
            s._conversation_process_background(d.name, RAW, dict(META))
        st = json.loads((d / "state.json").read_text())
        self.assertEqual(st["failed_step"], "processor")
        self.assertIn("01_classify", st["completed_steps"])
        side = json.loads((d / "auto_retry.json").read_text())
        self.assertEqual(side["cm048_error_class"], "ReadTimeout")
        self.assertEqual(side["cm048_failed_step"], "02_enrich")
        self.assertEqual((d / "00_raw_transcript.md").read_text(), RAW)

    def test_in_flight_dispatch_is_not_double_run(self):
        d = self._failed(age_s=3600)
        calls = []
        self.s._CONVERSATIONS_IN_FLIGHT.add(d.name)
        self.s._conversation_retry_sweep(now=T0 + timedelta(hours=2),
                                         runner=self._runner(d, 1, calls))
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
