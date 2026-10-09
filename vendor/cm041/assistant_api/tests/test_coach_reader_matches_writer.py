"""Coach observations: the reader must read where the writer writes, with
the writer's key, and must refuse loudly otherwise (v1.0.107 #11).

Ported from CM041 PR #202 (vendor graft).

Writer: CM048 ingest.py `_write_coach` at ostler_paths.coach_db_path() =
~/.ostler/coach/observations.db, SQLCipher-encrypted. Reader used to default
to ~/.pwg/coach/observations.db and returned an empty list, silently.

SQLCipher is not installed in CI, so the "encrypted" file is a non-SQLite
blob and the injected _secure_connect opens a plain backing db only when the
right key is presented. That stands in for the real wrapper's key check.
All data is synthetic.
"""
from __future__ import annotations

import importlib.util
import os
import sqlite3
import tempfile
import sys
import types
import typing
import unittest
from pathlib import Path
from unittest.mock import patch

SERVER_FILE = Path(__file__).resolve().parent.parent / "ical-server.py"
KEY = "synthetic-test-key-0001"
USER = "synthetic-user"


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


def _load():
    spec = importlib.util.spec_from_file_location("ical_coach_reader", SERVER_FILE)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class CoachReaderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.p = patch.dict(os.environ, {"HOME": self.tmp.name})
        self.p.start()
        for n in ("PWG_HOME", "OSTLER_COACH_DB", "OSTLER_DB_KEY"):
            os.environ.pop(n, None)
        # Layout from the walk box: 0-byte decoy at the legacy path, the real
        # (non-SQLite header) file at the writer's path.
        legacy = self.home / ".pwg" / "coach"
        legacy.mkdir(parents=True)
        (legacy / "observations.db").write_bytes(b"")
        self.real = self.home / ".ostler" / "coach" / "observations.db"
        self.real.parent.mkdir(parents=True)
        self.real.write_bytes(b"\x8f\x02ENCRYPTED-NOT-SQLITE" + b"\x00" * 64)
        self.backing = self.home / "backing.sqlite"
        c = sqlite3.connect(self.backing)
        c.execute(
            "CREATE TABLE observations (user_id TEXT, observed_at TEXT, "
            "conversation_id TEXT, tip_json TEXT)"
        )
        c.execute(
            "INSERT INTO observations VALUES (?,?,?,?)",
            (USER, "2999-01-01T00:00:00", "synthetic-conv", '["tip"]'),
        )
        c.commit()
        c.close()

    def tearDown(self):
        self.p.stop()
        self.tmp.cleanup()

    def _server(self, key):
        s = _load()
        s._ENCRYPTION_KEY = key

        def fake_secure(path, k):
            if k != KEY or Path(path) != self.real:
                raise sqlite3.DatabaseError("file is not a database")
            return sqlite3.connect(self.backing)

        s._secure_connect = fake_secure
        return s

    def test_reader_path_equals_writer_path(self):
        s = self._server(KEY)
        self.assertEqual(s.COACH_DB, self.real)
        self.assertNotEqual(s.COACH_DB, self.home / ".pwg" / "coach" / "observations.db")

    def test_reader_path_equals_the_vendored_cm048_writer_path(self):
        """The real writer's own path function, loaded from the vendored
        CM048 tree, not a restated literal."""
        spec = importlib.util.spec_from_file_location(
            "cm048_ostler_paths_for_coach",
            SERVER_FILE.parents[2] / "cm048_pipeline" / "src" / "ostler_paths.py",
        )
        paths = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = paths
        spec.loader.exec_module(paths)
        self.assertEqual(_load().COACH_DB, paths.coach_db_path())

    def test_reader_returns_rows_from_encrypted_db_with_key(self):
        s = self._server(KEY)
        out = s.coach_recent(user_id=USER, hours=24 * 365 * 2000, limit=10)
        self.assertEqual(out["count"], 1)
        self.assertEqual(out["observations"][0]["conversation_id"], "synthetic-conv")

    def test_missing_key_is_loud_not_empty(self):
        s = self._server(None)
        with self.assertRaises(s.CoachDbError):
            s.coach_recent(user_id=USER)

    def test_wrong_key_is_loud_not_empty(self):
        s = self._server("some-other-key")
        with self.assertRaises(s.CoachDbError):
            s.coach_recent(user_id=USER)

    def test_fresh_box_absent_db_is_200_shape_with_db_state(self):
        # Fresh install: the writer has not created the file yet.
        self.real.unlink()
        s = self._server(KEY)
        out = s.coach_recent(user_id=USER)
        self.assertEqual(out["observations"], [])
        self.assertEqual(out["db_state"], "absent")

    def test_zero_byte_decoy_never_masks_the_real_db(self):
        # Pointing the reader at the decoy (the old behaviour) must refuse.
        s = self._server(KEY)
        s.COACH_DB = self.home / ".pwg" / "coach" / "observations.db"
        with self.assertRaises(s.CoachDbError):
            s.coach_recent(user_id=USER)


if __name__ == "__main__":
    unittest.main()
