"""Regression tests for POST /api/v1/conversation/process conversation_id
generation (vendor graft, mirrors CM041 PR #196).

CM051 v1.0.107 candidate #10 (SILENT DATA LOSS): the id was built as
date_firstTwoSpeakerLabels_type and ignored metadata.meeting_id, the
per-session UUID the iOS/Watch app sends. Every Watch conversation on
the same day collided as <date>_s1_wearable: the second POST overwrote
the first conversation's raw transcript, CM048 skipped the overwritten
one as already-complete, and the Hub still returned 202 so the app
deleted its (now only) copy. The conversation was gone.

Fix: prefer a validated metadata.meeting_id; fall back to the old
scheme plus a collision guard that suffixes rather than overwrites.

The server module is loaded by file path because of the dash in
"ical-server.py". This vendor tree additionally requires:

  - the ostler_security stub (vendored ical-server.py hard-imports
    ostler_security.db_key.resolve_db_key; see sibling
    test_people_list_endpoint.py's _install_ostler_security_stub,
    ported here verbatim),
  - a stub for _invoke_pwg_convo, the vendor's own divergence from
    CM041 source: api_conversation_process here probes a pwg-convo
    CLI binary before generating conversation_id at all, which would
    503 on every call in a bare test environment (no pwg-convo on
    PATH). The id-generation logic under test sits entirely AFTER
    that probe, so the probe is stubbed out, not exercised.

_subscription_paused is ALSO stubbed, for the opposite reason its
own docstring might suggest: assistant_api/subscription_gate.py sits
on sys.path beside ical-server.py (pytest's rootdir insertion stops at
assistant_api/, which has no __init__.py), so the real module IS
importable here and reports the default unlicensed state as paused --
it does not fail open in this environment. That gate is orthogonal to
conversation_id generation, so it is bypassed directly.
"""
from __future__ import annotations

import importlib.util
import subprocess
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

    Ported verbatim from test_people_list_endpoint.py.
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

import os as _os  # noqa: E402

_os.environ["OSTLER_SERVICE_TOKEN"] = "test-only-meeting-id-token"


def _load_server_module():
    spec = importlib.util.spec_from_file_location(
        "ical_server_meeting_id", SERVER_FILE
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server_module()


def _fake_pwg_convo_ok(args, timeout=900):
    """Stand-in for _invoke_pwg_convo: the --help probe and the real
    process invocation both route through this one function. Always
    reports success so api_conversation_process's pre-flight probe
    passes and _conversation_process_background's single attempt
    completes without a retry -- neither of which the tests below are
    about; they are about which conversation_id gets used and whether
    an existing raw transcript is ever overwritten.
    """
    return subprocess.CompletedProcess(args=args, returncode=0, stdout="", stderr="")


class _SyncThread:
    """Deterministic stand-in for threading.Thread: runs the target
    synchronously inside start() so a test can assert on its effects
    without racing a real background thread."""

    def __init__(self, target=None, args=(), kwargs=None, daemon=None):
        self._target = target
        self._args = args
        self._kwargs = kwargs or {}

    def start(self):
        self._target(*self._args, **self._kwargs)


class _ConversationProcessTestBase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self._patches = [
            patch.object(server, "PROCESSING_DIR", self.root),
            patch.object(server, "_invoke_pwg_convo", _fake_pwg_convo_ok),
            patch.object(server.threading, "Thread", _SyncThread),
            # Rule 0.8 pause gate: assistant_api/subscription_gate.py sits
            # on sys.path beside ical-server.py in this tree (pytest's
            # rootdir insertion, same mechanism the module's own docstring
            # describes for production), so _subscription_paused does NOT
            # fail open here -- it finds the real module and reports the
            # default unlicensed state as paused. That gate is orthogonal
            # to conversation_id generation, which is what these tests
            # check, so it is bypassed directly rather than also faking a
            # licence.
            patch.object(server, "_subscription_paused", lambda surface: None),
        ]
        for p in self._patches:
            p.start()

    def tearDown(self):
        for p in reversed(self._patches):
            p.stop()
        self._tmp.cleanup()

    def _raw_transcript(self, conversation_id):
        path = self.root / conversation_id / "00_raw_transcript.md"
        return path.read_text(encoding="utf-8") if path.exists() else None

    def _process(self, transcript, metadata):
        return server.api_conversation_process(
            {"transcript": transcript, "metadata": metadata}
        )


class TestMeetingIdPreferred(_ConversationProcessTestBase):
    def test_distinct_meeting_ids_same_day_same_labels_both_survive(self):
        meta_common = {
            "date": "2026-10-07",
            "participants": ["Speaker 1"],
            "type": "wearable",
        }
        meta_a = dict(meta_common, meeting_id="11111111-1111-4111-8111-111111111111")
        meta_b = dict(meta_common, meeting_id="22222222-2222-4222-8222-222222222222")

        result_a, status_a = self._process("transcript A", meta_a)
        result_b, status_b = self._process("transcript B", meta_b)

        self.assertEqual(status_a, 202)
        self.assertEqual(status_b, 202)
        self.assertNotEqual(result_a["job_id"], result_b["job_id"])
        self.assertEqual(result_a["job_id"], meta_a["meeting_id"])
        self.assertEqual(result_b["job_id"], meta_b["meeting_id"])

        self.assertEqual(self._raw_transcript(result_a["job_id"]), "transcript A")
        self.assertEqual(self._raw_transcript(result_b["job_id"]), "transcript B")

    def test_resend_of_same_meeting_id_is_idempotent_no_duplicate(self):
        meta = {
            "date": "2026-10-07",
            "participants": ["Speaker 1"],
            "type": "wearable",
            "meeting_id": "33333333-3333-4333-8333-333333333333",
        }

        result_1, _ = self._process("same transcript", meta)
        result_2, _ = self._process("same transcript", meta)

        self.assertEqual(result_1["job_id"], result_2["job_id"])
        self.assertEqual(
            sum(1 for _ in self.root.glob(f"{meta['meeting_id']}*")), 1
        )

    def test_malicious_meeting_id_is_rejected_falls_back(self):
        meta = {
            "date": "2026-10-07",
            "participants": ["Speaker 1"],
            "type": "wearable",
            "meeting_id": "../x",
        }

        result, status = self._process("transcript", meta)

        self.assertEqual(status, 202)
        self.assertNotEqual(result["job_id"], "../x")
        self.assertNotIn("..", result["job_id"])
        self.assertTrue(result["job_id"].startswith("2026-10-07_speaker_1_wearable"))
        conv_dir = (self.root / result["job_id"]).resolve()
        self.assertEqual(conv_dir.parent, self.root.resolve())

    def test_missing_meeting_id_falls_back_to_legacy_scheme(self):
        meta = {
            "date": "2026-10-07",
            "participants": ["Speaker 1"],
            "type": "wearable",
        }

        result, status = self._process("transcript", meta)

        self.assertEqual(status, 202)
        self.assertEqual(result["job_id"], "2026-10-07_speaker_1_wearable")


class TestFallbackCollisionGuard(_ConversationProcessTestBase):
    def test_two_same_day_same_label_conversations_without_meeting_id_both_survive(self):
        meta = {
            "date": "2026-10-07",
            "participants": ["Speaker 1"],
            "type": "wearable",
        }

        result_1, _ = self._process("first conversation transcript", meta)
        result_2, _ = self._process("second, different conversation transcript", meta)

        self.assertNotEqual(result_1["job_id"], result_2["job_id"])
        self.assertEqual(
            self._raw_transcript(result_1["job_id"]), "first conversation transcript"
        )
        self.assertEqual(
            self._raw_transcript(result_2["job_id"]),
            "second, different conversation transcript",
        )

    def test_fallback_never_overwrites_existing_different_content(self):
        meta = {
            "date": "2026-10-07",
            "participants": ["Speaker 1"],
            "type": "wearable",
        }

        result_1, _ = self._process("original content", meta)
        self._process("colliding content", meta)

        self.assertEqual(self._raw_transcript(result_1["job_id"]), "original content")

    def test_resend_of_identical_transcript_without_meeting_id_is_idempotent(self):
        meta = {
            "date": "2026-10-07",
            "participants": ["Speaker 1"],
            "type": "wearable",
        }

        result_1, _ = self._process("identical content", meta)
        result_2, _ = self._process("identical content", meta)

        self.assertEqual(result_1["job_id"], result_2["job_id"])


if __name__ == "__main__":
    unittest.main()
