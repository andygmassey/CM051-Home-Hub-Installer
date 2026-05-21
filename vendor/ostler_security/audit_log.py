"""Local audit log – records all system access events.

Every access to Ostler is logged locally:
- System unlock (passphrase entry)
- API queries
- Diagnostic-service sessions
- Data exports

The log is stored in an encrypted SQLite database (same key as
other Ostler databases). It never leaves the machine.

This serves two purposes:
1. The user can review who/what accessed their system and when
2. If a device is compromised, the log helps assess what was exposed
"""
from __future__ import annotations

import json
import logging
import os
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


# ── Schema ───────────────────────────────────────────────────────────

CREATE_TABLE = """
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    event_type TEXT NOT NULL,
    source TEXT NOT NULL,
    details TEXT,
    ip_address TEXT,
    success INTEGER NOT NULL DEFAULT 1
)
"""

CREATE_INDEX = """
CREATE INDEX IF NOT EXISTS idx_audit_timestamp
ON audit_log (timestamp DESC)
"""


# ── Event types ──────────────────────────────────────────────────────

EVENT_UNLOCK = "system_unlock"
EVENT_UNLOCK_FAILED = "unlock_failed"
EVENT_LOCK = "system_lock"
EVENT_API_QUERY = "api_query"
EVENT_DIAGNOSTIC_SESSION = "diagnostic_session"
EVENT_DIAGNOSTIC_PAYLOAD = "diagnostic_payload_sent"
EVENT_DATA_EXPORT = "data_export"
EVENT_IMPORT_RUN = "import_run"
EVENT_PASSPHRASE_CHANGE = "passphrase_change"
EVENT_RECOVERY_KEY_USED = "recovery_key_used"
# Added 2026-04-23 as part of passkey auth work. Passkey registration
# happens at setup + after a recovery-phrase unlock on a new device;
# assertion failure is what we log on NO_CREDENTIAL / USER_CANCELED
# / PRF_UNSUPPORTED. Successful passkey assertions still log as
# EVENT_UNLOCK – the underlying unlock-the-DEK invariant is the same,
# only the auth mechanism differs.
EVENT_PASSKEY_REGISTER = "passkey_register"
EVENT_PASSKEY_ASSERT_FAILED = "passkey_assert_failed"

# BT8-4: whitelist of valid event types to prevent log injection
VALID_EVENT_TYPES = {
    EVENT_UNLOCK, EVENT_UNLOCK_FAILED, EVENT_LOCK, EVENT_API_QUERY,
    EVENT_DIAGNOSTIC_SESSION, EVENT_DIAGNOSTIC_PAYLOAD, EVENT_DATA_EXPORT,
    EVENT_IMPORT_RUN, EVENT_PASSPHRASE_CHANGE, EVENT_RECOVERY_KEY_USED,
    EVENT_PASSKEY_REGISTER, EVENT_PASSKEY_ASSERT_FAILED,
}

# BT8-9: maximum query limit to prevent OOM
MAX_QUERY_LIMIT = 1000


# ── Log writer ───────────────────────────────────────────────────────


class AuditLog:
    """Write and query the local audit log."""

    def __init__(self, db_path: str | Path, encryption_key_hex: Optional[str] = None):
        """Initialise the audit log.

        Args:
            db_path: Path to the audit log database.
            encryption_key_hex: If provided, opens the database with
                SQLCipher encryption. If None, uses plain sqlite3.
        """
        self.db_path = str(db_path)
        self._encryption_key_hex = encryption_key_hex
        # ATK-2: write_lock serialises in-process writers so concurrent
        # log() calls don't collide with SQLITE_BUSY. The DB itself
        # still provides ACID across processes; this lock is purely
        # for the in-process contention case.
        self._write_lock = threading.Lock()
        # ATK-3: refuse to open if the path is (or has been replaced
        # by) a symlink, and pre-create as a regular file with
        # O_NOFOLLOW so an attacker can't race a symlink in before
        # sqlite opens it. See _safe_open_path.
        self._safe_open_path(Path(self.db_path))
        self._ensure_schema()

    @staticmethod
    def _safe_open_path(db_path: Path) -> None:
        """Close the symlink-TOCTOU window before sqlite opens the file.

        Two layered defences:

        1. ``Path.is_symlink()`` uses lstat under the hood, so it does
           not follow. If the path is already a symlink we refuse –
           sqlite would otherwise happily write through it to whatever
           the attacker pointed at.
        2. If the path does not exist, we create it ourselves with
           ``O_CREAT | O_EXCL | O_NOFOLLOW`` at mode 0600. Any attacker
           racing to drop a symlink in the same millisecond sees
           ``EEXIST``; the file exists as a regular file owned by us
           by the time sqlite opens it.

        There is a residual TOCTOU window between our check and
        sqlite's open(), but the attacker would need to (a) delete our
        newly-created regular file and (b) replace it with a symlink
        in microseconds – achievable only with write access to the
        parent directory, which ``log_event`` chmods to 0700.
        """
        if db_path.is_symlink():
            raise OSError(
                f"Audit log path is a symlink; refusing to follow: {db_path}"
            )
        if not db_path.exists():
            # Ensure parent exists (caller may not have done it).
            db_path.parent.mkdir(parents=True, exist_ok=True)
            flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
            # O_NOFOLLOW isn't in os.O_* on all platforms but macOS +
            # Linux have it. Fall back gracefully if absent (the
            # is_symlink check + O_EXCL still guard most of the way).
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            fd = os.open(str(db_path), flags, 0o600)
            os.close(fd)

    def _connect(self) -> sqlite3.Connection:
        """Open a connection, encrypted if key is available."""
        try:
            from .database import get_db_connection
            return get_db_connection(self.db_path, self._encryption_key_hex)
        except ImportError:
            return sqlite3.connect(self.db_path)

    def _ensure_schema(self) -> None:
        conn = self._connect()
        try:
            conn.execute(CREATE_TABLE)
            conn.execute(CREATE_INDEX)
            conn.commit()
        finally:
            conn.close()

    def log(
        self,
        event_type: str,
        source: str,
        details: Optional[dict | str] = None,
        ip_address: Optional[str] = None,
        success: bool = True,
    ) -> None:
        """Write an audit log entry.

        Args:
            event_type: One of the EVENT_* constants.
            source: What triggered the event (e.g. "passphrase_check",
                "assistant_api", "diagnostic_web_ui", "import_pipeline").
            details: Optional dict or string with event-specific details.
            ip_address: Source IP if applicable (e.g. for API queries).
            success: Whether the action succeeded (False for failed logins).
        """
        # BT8-4: validate event type against whitelist
        if event_type not in VALID_EVENT_TYPES:
            logger.error("Rejected invalid event type: %s", event_type)
            return

        now = datetime.now(timezone.utc).isoformat()
        details_str = json.dumps(details) if isinstance(details, dict) else details

        # ATK-2: serialise writers inside the process. SQLite provides
        # ACID across processes but can raise SQLITE_BUSY under
        # contention; the lock avoids that for in-process callers.
        # We use write-with-lock rather than write-tmp+rename because
        # the audit log is a SQLite DB – we insert rows, not write
        # files. Rename-based atomicity would require tearing down and
        # rebuilding the DB for every event, which would be
        # catastrophically slow and defeat sqlite's own ACID story.
        with self._write_lock:
            conn = self._connect()
            try:
                conn.execute(
                    """
                    INSERT INTO audit_log (timestamp, event_type, source, details, ip_address, success)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (now, event_type, source, details_str, ip_address, 1 if success else 0),
                )
                conn.commit()
            except Exception as exc:
                # ATK-4: DO NOT swallow audit-log failures silently.
                # Previously this except block only logged and
                # returned, which meant a security-relevant "did this
                # event get recorded?" question always answered
                # yes even when the DB was corrupt or unwritable.
                # Log AND re-raise so the caller sees the failure –
                # missing audit records are the very thing an auditor
                # would want to know about.
                logger.error("Failed to write audit log: %s", exc)
                raise
            finally:
                conn.close()

    def recent(self, limit: int = 50) -> list[dict]:
        """Retrieve recent audit log entries.

        Returns a list of dicts, most recent first.
        """
        # BT8-9: clamp limit to prevent OOM
        limit = min(max(1, limit), MAX_QUERY_LIMIT)
        conn = self._connect()
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(
                "SELECT * FROM audit_log ORDER BY timestamp DESC LIMIT ?",
                (limit,),
            ).fetchall()
            return [dict(row) for row in rows]
        finally:
            conn.close()

    def failed_unlocks_since(self, since_iso: str) -> int:
        """Count failed unlock attempts since a given timestamp.

        Used for rate limiting: if too many failures, lock out.
        """
        conn = self._connect()
        try:
            count = conn.execute(
                """
                SELECT COUNT(*) FROM audit_log
                WHERE event_type = ? AND success = 0 AND timestamp > ?
                """,
                (EVENT_UNLOCK_FAILED, since_iso),
            ).fetchone()[0]
            return count
        finally:
            conn.close()

    def diagnostic_payloads(self, limit: int = 20) -> list[dict]:
        """Retrieve recent diagnostic-service payloads that were sent.

        For the transparent payload viewer – users can see exactly
        what the diagnostic service has transmitted. (Function name
        retained as a stable identifier per the rebrand-paths rule.)
        """
        # BT8-9: clamp limit
        limit = min(max(1, limit), MAX_QUERY_LIMIT)
        conn = self._connect()
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(
                """
                SELECT * FROM audit_log
                WHERE event_type = ?
                ORDER BY timestamp DESC LIMIT ?
                """,
                (EVENT_DIAGNOSTIC_PAYLOAD, limit),
            ).fetchall()
            return [dict(row) for row in rows]
        finally:
            conn.close()


# ── Convenience function ─────────────────────────────────────────────

_default_log: Optional[AuditLog] = None
# ATK-5: guard _default_log initialisation so concurrent callers
# don't each construct their own AuditLog and race on the underlying
# DB. Double-checked locking is correct here because _default_log is
# only ever assigned once and Python's module-level reads are atomic.
_default_log_lock = threading.Lock()


def log_event(
    event_type: str,
    source: str,
    details: Optional[dict | str] = None,
    ip_address: Optional[str] = None,
    success: bool = True,
    db_path: Optional[str | Path] = None,
) -> None:
    """Write an audit log entry using the default log instance.

    If no db_path is provided, uses ~/.ostler/security/audit.db
    """
    global _default_log
    if _default_log is None:
        with _default_log_lock:
            # Re-check inside the lock – another thread may have
            # finished initialisation while we were waiting.
            if _default_log is None:
                path = db_path or Path.home() / ".ostler" / "security" / "audit.db"
                parent = Path(path).parent
                parent.mkdir(parents=True, exist_ok=True)
                parent.chmod(0o700)  # BH-6 fix: restrict directory permissions
                _default_log = AuditLog(path)
    _default_log.log(event_type, source, details, ip_address, success)
