"""Regression test for H2b: PROCESSING_DIR must resolve to the SAME
directory CM048's actual processor writes conversation state to.

Ported from CM041 PR #197 (vendor graft, walk #6).

CM048 (andygmassey/CM048-PWG-Conversation-Processing) writes
conversation processing state under the two-zone engine room,
~/.ostler/processing by default:

  - src/ostler_paths.py:37-44 `ostler_root()` / `processing_dir()`
    define the canonical default as ``~/.ostler/processing``.
  - src/settings.py:93-94 `Settings.processing_state_dir` defaults to
    `ostler_paths.processing_dir`.
  - settings.yaml.production:143, the file the repo's own header
    instructs copying to ``~/.ostler/settings.yaml`` on the Hub, pins
    it explicitly: ``processing_state_dir: ~/.ostler/processing``.
  - src/processor.py:88 (and 480, 590) writes each conversation's
    state.json at ``settings.processing_state_dir / conversation_id``.
  - src/settings.py:270-276 overrides that default from, in order,
    OSTLER_PROCESSING_DIR, OSTLER_STATE_DIR, PWG_PROCESSING_DIR.

Before this fix, ical-server.py derived PROCESSING_DIR from PWG_HOME,
which defaults to ~/.pwg -- the LEGACY root CM048's own two-zone
migration (ostler_paths.py:124-128 `_ENGINE_ROOM_MAPPING`) moves away
from (and rmdirs) on first launch. The status endpoint and CM048's
real writer never agreed on a directory, so a client polling
GET /api/v1/conversation/status/{id} never saw "completed".

The server module is loaded by file path because of the dash in
"ical-server.py" (same pattern as the other tests in this directory).
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
        "ical_server_h2b_processing_path", SERVER_FILE
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestProcessingDirMatchesCM048Default(unittest.TestCase):
    """With no override env var set, PROCESSING_DIR must equal CM048's
    actual default: <home>/.ostler/processing -- not <home>/.pwg/processing."""

    def setUp(self):
        self._tmp_home = tempfile.TemporaryDirectory()
        env_overrides = {"HOME": self._tmp_home.name}
        self._env_patch = patch.dict(os.environ, env_overrides, clear=False)
        self._env_patch.start()
        # Scrub every override CM048 and the legacy code recognise so the
        # DEFAULT resolution is what's actually under test.
        self._removed = {}
        for name in (
            "PWG_HOME",
            "OSTLER_PROCESSING_DIR",
            "OSTLER_STATE_DIR",
            "PWG_PROCESSING_DIR",
        ):
            self._removed[name] = os.environ.pop(name, None)

    def tearDown(self):
        self._env_patch.stop()
        for name, value in self._removed.items():
            if value is not None:
                os.environ[name] = value
        self._tmp_home.cleanup()

    def test_default_processing_dir_is_ostler_not_pwg(self):
        server = _load_server_module()
        expected = Path(self._tmp_home.name) / ".ostler" / "processing"
        wrong_legacy = Path(self._tmp_home.name) / ".pwg" / "processing"
        self.assertNotEqual(
            server.PROCESSING_DIR,
            wrong_legacy,
            "PROCESSING_DIR must not default to the legacy ~/.pwg path "
            "CM048's own two-zone migration moves away from.",
        )
        self.assertEqual(
            server.PROCESSING_DIR,
            expected,
            "PROCESSING_DIR must match CM048's actual default "
            "(~/.ostler/processing -- ostler_paths.py:42-44, "
            "settings.yaml.production:143), or a polling client never "
            "sees the conversation CM048 is actually writing.",
        )

    def test_status_endpoint_reports_completed_from_cm048_actual_path(self):
        """End-to-end shape of the reported bug: a conversation CM048
        marks completed, at CM048's real default path, must be visible
        through GET /api/v1/conversation/status/{id}."""
        server = _load_server_module()
        conv_id = "2026-10-07_h2b_regression"
        state_dir = server.PROCESSING_DIR / conv_id
        state_dir.mkdir(parents=True, exist_ok=True)
        (state_dir / "state.json").write_text(
            '{"conversation_id": "%s", "current_step": "completed", '
            '"completed_steps": ["00_raw", "classify", "enrich", '
            '"signals", "coach", "facts", "sinks"], '
            '"failed_step": null}' % conv_id,
            encoding="utf-8",
        )
        body, status = server.api_conversation_status(conv_id)
        self.assertEqual(status, 200)
        self.assertEqual(body["current_step"], "completed")

    def test_env_override_precedence_matches_cm048(self):
        """OSTLER_PROCESSING_DIR > OSTLER_STATE_DIR > PWG_PROCESSING_DIR,
        the same chain CM048's settings.py:270-276 resolves, so a Hub
        that overrides CM048's directory keeps this endpoint in sync."""
        os.environ["PWG_PROCESSING_DIR"] = str(
            Path(self._tmp_home.name) / "legacy-override"
        )
        os.environ["OSTLER_STATE_DIR"] = str(
            Path(self._tmp_home.name) / "state-override"
        )
        os.environ["OSTLER_PROCESSING_DIR"] = str(
            Path(self._tmp_home.name) / "winning-override"
        )
        server = _load_server_module()
        self.assertEqual(
            server.PROCESSING_DIR,
            Path(self._tmp_home.name) / "winning-override",
        )


if __name__ == "__main__":
    unittest.main()
