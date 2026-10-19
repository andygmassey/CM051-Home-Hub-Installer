"""Path-traversal guards on the conversation routes of ical-server.py.

GET /api/v1/conversation/status/{id} used PROCESSING_DIR / id unvalidated,
and POST /api/v1/conversation/process built a directory name from
metadata.date / type / participants unvalidated (a WRITE). Both now go
through _safe_conversation_dir. Each guard has a mutant in
test_conversation_path_safety_mutants.py that must turn this file red.

ICAL_SERVER_UNDER_TEST points the loader at a mutated copy.
"""
from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
# Ported from CM041 assistant_api/tests/test_conversation_path_safety.py at
# e2dffc09 (#225), grafted into vendor/cm041/assistant_api for v1.0.112: runs
# against the VENDORED file. VENDORED DIFFERENCES: (1) the vendored server
# needs ostler_security, stubbed below as in the #221 port; (2) it carries the
# Pro subscription gate, so _post puts the box in the subscribed state;
# (3) it front-loads a pwg-convo --help probe (503 when absent), which _post
# answers as an installed CM048, since the route's id logic is the subject.
SERVER_FILE = Path(os.environ.get("ICAL_SERVER_UNDER_TEST")
                   or HERE.parent / "vendor" / "cm041" / "assistant_api" / "ical-server.py")


def _install_ostler_security_stub() -> None:
    # Same stub as tests/test_cm041_deceased_excluded_from_proactive_surfaces.py:
    # the vendored server refuses to import without ostler_security, which a CI
    # runner does not have; the DB layer is not what this test exercises.
    import sys
    import types
    try:
        import ostler_security  # noqa: F401
        return
    except Exception:
        pass
    import sqlite3 as _sqlite
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    database = types.ModuleType("ostler_security.database")
    database.get_db_connection = lambda path, _key, *a, **k: _sqlite.connect(path)
    sys.modules["ostler_security.database"] = database
    posture = types.ModuleType("ostler_security.posture")
    posture.record_posture = lambda *a, **k: None
    sys.modules["ostler_security.posture"] = posture
    # db_key: the vendored server imports resolve_db_key at load (same stub
    # shape as tests/test_the_timeline_opens_on_today.py).
    db_key = types.ModuleType("ostler_security.db_key")
    db_key.resolve_db_key = lambda *a, **k: types.SimpleNamespace(key="stub", source="test", reason="")
    sys.modules["ostler_security.db_key"] = db_key


_install_ostler_security_stub()


def _load():
    spec = importlib.util.spec_from_file_location("ical_server_pathsafety", SERVER_FILE)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


server = _load()

EVIL_IDS = [
    "../secret", "../../etc/passwd", "/etc/passwd", "a/b", "a/../b", "..",
    ".", ".hidden", "a\x00b", "x\x00", "..\\..\\x", "a b", "", " ",
    "a/", "%2e%2e%2f", "a" * 300, "a..b", "x/..",
]


class _Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name).resolve()
        self.root = base / "processing"
        self.root.mkdir()
        # A sibling directory with a state.json a traversal would reach.
        self.outside = base / "secret"
        self.outside.mkdir()
        (self.outside / "state.json").write_text('{"leak": true}')
        (self.root / "good-id_1").mkdir()
        (self.root / "good-id_1" / "state.json").write_text('{"status": "completed"}')
        p = patch.object(server, "PROCESSING_DIR", self.root)
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)


class IdGrammar(unittest.TestCase):
    def test_evil_ids_invalid(self):
        for evil in EVIL_IDS:
            with self.subTest(evil=repr(evil)):
                self.assertFalse(server._valid_conversation_id(evil))

    def test_good_ids_valid(self):
        for good in ("good-id_1", "2026-10-19_jane_doe_im", "cc-3f9a.v2", "josé"):
            with self.subTest(good=good):
                self.assertTrue(server._valid_conversation_id(good))


class StatusRoute(_Base):
    def test_valid_id_still_works(self):
        body, code = server.api_conversation_status("good-id_1")
        self.assertEqual(code, 200)
        self.assertEqual(body, {"status": "completed"})

    def test_valid_id_with_dots_and_unicode(self):
        d = self.root / "2026-10-19_josé_im"
        d.mkdir()
        (d / "state.json").write_text('{"status": "x"}')
        self.assertEqual(server.api_conversation_status("2026-10-19_josé_im")[1], 200)

    def test_unknown_valid_id_is_404(self):
        self.assertEqual(server.api_conversation_status("nope")[1], 404)

    def test_traversal_ids_refused_and_nothing_read(self):
        for evil in EVIL_IDS:
            with self.subTest(evil=repr(evil)):
                body, code = server.api_conversation_status(evil)
                self.assertIn(code, (400, 404))
                self.assertNotIn("leak", json.dumps(body))

    def test_sibling_state_not_reachable_via_dotdot(self):
        body, code = server.api_conversation_status("../secret")
        self.assertEqual(code, 400)
        self.assertNotIn("leak", body)

    def test_absolute_path_refused(self):
        body, code = server.api_conversation_status(str(self.outside))
        self.assertEqual(code, 400)
        self.assertNotIn("leak", body)

    def test_symlinked_dir_refused(self):
        (self.root / "link").symlink_to(self.outside, target_is_directory=True)
        body, code = server.api_conversation_status("link")
        self.assertIn(code, (400, 404))
        self.assertNotIn("leak", body)

    def test_symlink_to_dir_inside_root_refused(self):
        # Escapes nothing, so only the symlink guard (not containment) refuses it.
        (self.root / "alias").symlink_to(self.root / "good-id_1", target_is_directory=True)
        body, code = server.api_conversation_status("alias")
        self.assertEqual(code, 400)

    def test_symlinked_state_file_refused(self):
        d = self.root / "withlink"
        d.mkdir()
        (d / "state.json").symlink_to(self.outside / "state.json")
        body, code = server.api_conversation_status("withlink")
        self.assertIn(code, (400, 404))
        self.assertNotIn("leak", body)


class SpeakersRoute(_Base):
    def test_traversal_refused(self):
        for evil in ("../secret", "/etc", "a/b", ".."):
            with self.subTest(evil=evil):
                self.assertIn(server.api_conversation_speakers(evil)[1], (400, 404))

    def test_symlinked_dir_refused(self):
        (self.root / "link").symlink_to(self.outside, target_is_directory=True)
        self.assertIn(server.api_conversation_speakers("link")[1], (400, 404))


class ProcessRoute(_Base):
    """POST builds the directory name from client metadata (a write)."""

    def _post(self, metadata):
        captured = {}

        def fake_tracked(cid, transcript, md):
            captured["cid"] = cid

        class _T:
            def __init__(self, target, args, daemon):
                self.target, self.args = target, args

            def start(self):
                self.target(*self.args)

        with patch.object(server, "OSTLER_VENV_PYTHON", "/x"), \
                patch.object(server, "OSTLER_PROJECT_DIR", "/x"), \
                patch.object(server, "_conversation_process_tracked", fake_tracked), \
                patch.object(server.threading, "Thread", _T), \
                patch.object(server, "_subscription_paused", lambda *_a, **_k: None), \
                patch.object(server, "_invoke_pwg_convo", lambda *_a, **_k: None):
            body, code = server.api_conversation_process(
                {"transcript": "hello", "metadata": metadata})
        return body, code, captured.get("cid")

    def test_traversal_in_date_type_participants_cannot_escape(self):
        cases = [
            {"date": "../../../../tmp/pwn", "participants": ["a"]},
            {"date": "2026-10-19", "type": "../../x", "participants": ["a"]},
            {"date": "2026-10-19", "participants": ["../../evil", "b"]},
            {"date": "/abs/path", "participants": []},
        ]
        for md in cases:
            with self.subTest(md=md):
                body, code, cid = self._post(md)
                self.assertEqual(code, 202)
                self.assertTrue(server._valid_conversation_id(cid), cid)
                d = server._safe_conversation_dir(cid)
                self.assertIsNotNone(d)
                self.assertEqual(d.parent, self.root)

    def test_background_writer_refuses_evil_id(self):
        server._conversation_process_background("../secret", "t", {})
        self.assertFalse((self.outside / "00_raw_transcript.md").exists())
        self.assertEqual(json.loads((self.outside / "state.json").read_text()),
                         {"leak": True})

    def test_normal_fallback_id_unchanged(self):
        body, code, cid = self._post({"date": "2026-10-19", "type": "im",
                                      "participants": ["Jane Doe", "John Smith"]})
        self.assertEqual(code, 202)
        self.assertEqual(cid, "2026-10-19_jane_doe_john_smith_im")


if __name__ == "__main__":
    unittest.main()
