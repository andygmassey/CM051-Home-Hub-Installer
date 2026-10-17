"""AuditLog readers must use the encrypted connection's own Row class.

sqlite3.Row on a SQLCipher connection raises "Row() argument 1 must be
sqlite3.Cursor, not sqlcipher3.dbapi2.Cursor" on the first fetch (v1.0.107
walk #12, same defect in ical-server). The stand-in arm always runs; the
real arm needs sqlcipher3 and is skipped with its reason where absent.
Synthetic data only.
"""
from __future__ import annotations

import sqlite3
import sys
import types

import pytest

from ostler_security import audit_log as al
from ostler_security.audit_log import AuditLog

try:
    from sqlcipher3 import dbapi2 as _sqlcipher
except ImportError:  # pragma: no cover - depends on the host
    _sqlcipher = None


def _standin(path):
    mod = types.ModuleType("standin_cipher_dbapi2")

    class Row(sqlite3.Row):
        pass

    class Connection:
        def __init__(self):
            self._c = sqlite3.connect(path)
            self.row_factory = None

        def execute(self, *a):
            if self.row_factory is sqlite3.Row:
                raise TypeError("Row() argument 1 must be sqlite3.Cursor, "
                                "not standin_cipher_dbapi2.Cursor")
            self._c.row_factory = self.row_factory
            return self._c.execute(*a)

        def commit(self):
            self._c.commit()

        def close(self):
            self._c.close()

    Connection.__module__ = mod.__name__
    mod.Row, mod.Connection = Row, Connection
    sys.modules[mod.__name__] = mod
    return mod


def _check(log):
    log.log(al.EVENT_DIAGNOSTIC_PAYLOAD, "synthetic-test", details={"synthetic": True})
    assert log.recent(limit=5)
    assert log.diagnostic_payloads(limit=5)


def test_standin_encrypted_connection(tmp_path, monkeypatch):
    db = tmp_path / "audit.db"
    log = AuditLog(db)
    mod = _standin(db)
    try:
        monkeypatch.setattr(log, "_connect", lambda: mod.Connection())
        _check(log)
    finally:
        sys.modules.pop(mod.__name__, None)


@pytest.mark.skipif(_sqlcipher is None,
                    reason="sqlcipher3 not installed on this host: real arm CANNOT-RUN")
def test_real_sqlcipher_connection(tmp_path, monkeypatch):
    db = tmp_path / "audit.db"

    def connect():
        c = _sqlcipher.connect(str(db))
        c.execute("PRAGMA key = 'synthetic-test-key-0003'")
        return c

    log = AuditLog(tmp_path / "plain_for_init.db")
    log.db_path = db
    monkeypatch.setattr(log, "_connect", connect)
    log._ensure_schema()
    _check(log)
    assert db.read_bytes()[:16] != b"SQLite format 3\x00"
