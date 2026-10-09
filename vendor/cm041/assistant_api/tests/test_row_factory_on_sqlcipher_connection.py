"""An encrypted connection must get its OWN Row class (v1.0.107 walk #12).

ical-server set ``conn.row_factory = sqlite3.Row`` on the connection
``_secure_connect`` returns. On a customer Hub that is a sqlcipher3
connection, and the first fetch raises

    Row() argument 1 must be sqlite3.Cursor, not sqlcipher3.dbapi2.Cursor

so every coach read was a 500. test_coach_reader_matches_writer.py could
not see it: its fake _secure_connect returns a plain sqlite3 connection.

Two arms. The stand-in arm always runs: a connection from a module that is
not sqlite3, which refuses sqlite3.Row the way sqlcipher3 does. The real
arm uses sqlcipher3 itself and is skipped, with the reason printed, where
the package is absent. All data is synthetic.
"""
from __future__ import annotations

import importlib.util
import os
import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

SERVER_FILE = Path(__file__).resolve().parent.parent / "ical-server.py"
KEY = "synthetic-test-key-0002"
USER = "synthetic-user"
OBS = ("synthetic-user", "2999-01-01T00:00:00", "synthetic-conv", '["tip"]')

try:
    from sqlcipher3 import dbapi2 as _sqlcipher
except ImportError:  # pragma: no cover - depends on the host
    _sqlcipher = None


def _standin_module():
    """A dbapi module that is not sqlite3 and rejects sqlite3.Row."""
    mod = types.ModuleType("standin_cipher_dbapi2")

    class Row(sqlite3.Row):
        pass

    class Connection:
        def __init__(self, path):
            self._c = sqlite3.connect(path)
            self.row_factory = None

        def execute(self, *a):
            if self.row_factory is sqlite3.Row:
                raise TypeError(
                    "Row() argument 1 must be sqlite3.Cursor, "
                    "not standin_cipher_dbapi2.Cursor"
                )
            self._c.row_factory = self.row_factory
            return self._c.execute(*a)

        def commit(self):
            self._c.commit()

        def close(self):
            self._c.close()

    Connection.__module__ = mod.__name__
    mod.Row = Row
    mod.Connection = Connection
    return mod


class RowFactoryOnEncryptedConnection(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.p = patch.dict(os.environ, {"HOME": self.tmp.name})
        self.p.start()
        for n in ("PWG_HOME", "OSTLER_COACH_DB", "OSTLER_DB_KEY"):
            os.environ.pop(n, None)
        self.coach = self.home / ".ostler" / "coach" / "observations.db"
        self.coach.parent.mkdir(parents=True)

    def tearDown(self):
        self.p.stop()
        self.tmp.cleanup()
        sys.modules.pop("standin_cipher_dbapi2", None)

    def _load(self, secure):
        spec = importlib.util.spec_from_file_location("ical_rowfactory", SERVER_FILE)
        s = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(s)
        s._ENCRYPTION_KEY = KEY
        s._secure_connect = secure
        return s

    def _seed(self, conn):
        conn.execute(
            "CREATE TABLE observations (user_id TEXT, observed_at TEXT, "
            "conversation_id TEXT, tip_json TEXT)"
        )
        conn.execute("INSERT INTO observations VALUES (?,?,?,?)", OBS)
        conn.commit()

    def _assert_coach_reads(self, s):
        out = s.coach_recent(user_id=USER, hours=24 * 365 * 2000, limit=10)
        self.assertEqual(out["count"], 1)
        self.assertEqual(out["observations"][0]["conversation_id"], "synthetic-conv")

    def test_standin_coach_read(self):
        mod = _standin_module()
        sys.modules[mod.__name__] = mod
        # Encrypted-looking header so the plaintext sniff does not fire.
        backing = self.home / "backing.sqlite"
        c = sqlite3.connect(backing)
        self._seed(c)
        c.close()
        self.coach.write_bytes(b"\x8f\x02ENCRYPTED-NOT-SQLITE" + b"\x00" * 64)
        s = self._load(lambda path, key: mod.Connection(backing))
        self._assert_coach_reads(s)

    def test_standin_memory_corrections_connect(self):
        mod = _standin_module()
        sys.modules[mod.__name__] = mod
        s = self._load(lambda path, key: mod.Connection(self.home / "mc.sqlite"))
        conn = s._memory_corrections_connect()
        self.assertIs(conn.row_factory, mod.Row)
        self.assertEqual(conn.execute("SELECT 1 AS a").fetchone()["a"], 1)
        conn.close()

    def test_plain_sqlite3_connection_still_gets_sqlite3_row(self):
        s = self._load(lambda path, key: sqlite3.connect(":memory:"))
        conn = s._memory_corrections_connect()
        self.assertIs(conn.row_factory, sqlite3.Row)
        conn.close()

    @unittest.skipIf(_sqlcipher is None, "sqlcipher3 not installed on this host: real arm CANNOT-RUN")
    def test_real_sqlcipher_coach_read(self):
        def secure(path, key):
            conn = _sqlcipher.connect(str(path))
            conn.execute(f"PRAGMA key = '{key}'")
            return conn

        c = secure(self.coach, KEY)
        self._seed(c)
        c.close()
        self.assertNotEqual(self.coach.read_bytes()[:16], b"SQLite format 3\x00")
        s = self._load(secure)
        self._assert_coach_reads(s)


if __name__ == "__main__":
    unittest.main()
