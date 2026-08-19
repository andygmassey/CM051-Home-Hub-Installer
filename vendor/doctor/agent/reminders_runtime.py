"""Runtime Reminders push outcome reader for Ostler Doctor.

Complement to ``reminders_posture.py``. Where that module reads a
one-shot *install-time* snapshot of the macOS Reminders (EventKit)
permission (a prediction: "would an EventKit write be allowed?"), this
module reads the *runtime* evidence of what actually happened when the
assistant tried to push extracted commitments to the macOS Reminders
app.

Background
----------

CM048's commitment -> Reminders writer (``reminders_push.py``) records
the outcome of every push attempt in a small SQLite mapping table,
``reminders_map``, under the engine room at
``~/.ostler/reminders_map.db``. As of CM048's permission-denied split
(``STATUS_PERMISSION_DENIED = "permission_denied"``), a push that is
refused by macOS because Reminders access is denied or revoked is
recorded with ``status='permission_denied'`` -- distinct from a generic
``failed`` (which the assistant retries on its own cadence) so Doctor
can tell "you need to grant Reminders access in System Settings" apart
from a transient failure.

This reader surfaces that runtime signal. It catches a case the
install-time marker cannot: access granted at install (marker says
``granted``) but later revoked, so todos now silently fail. The
empirical ``permission_denied`` rows reveal it; the predictive marker
does not.

Detection contract
-----------------

We read the ``status`` column of ``reminders_map`` and reduce the table
to one of three runtime states:

* ``permission_denied`` -- at least one row has
  ``status='permission_denied'``. Reminders access is currently denied
  or revoked; extracted todos are not reaching the Reminders app. This
  is the action-needed (amber) state.
* ``ok`` -- the table exists and has rows, none of them
  ``permission_denied``. Pushes are getting through (or are at worst a
  transient ``failed`` the assistant retries). This is the healthy
  (green) state.
* ``no-data`` -- the DB file is absent, or present but with no rows.
  The feature is unused / has not run yet. Doctor renders a neutral row
  or (at the rendering layer's discretion) no row.

**Doctor-side reader only**. The mapping DB is *written* by CM048's
assistant-side writer; this module never writes, and opens the DB
read-only so a Doctor read can never lock or mutate the writer's table.
Per the soft-fall-through convention the rest of Doctor's posture
readers follow, a missing or unreadable DB is **not** an error -- it
maps to ``no-data`` and Doctor keeps rendering.
"""
from __future__ import annotations

import logging
import os
import sqlite3
from pathlib import Path
from typing import Optional, TypedDict

logger = logging.getLogger(__name__)


# Runtime states this module reduces the reminders_map table to. Kept
# as plain strings (not the CM048 row-level status constants) because
# Doctor only cares about the table-level verdict, not per-row status.
STATE_PERMISSION_DENIED = "permission_denied"
STATE_OK = "ok"
STATE_NO_DATA = "no-data"

# Mirror of CM048 reminders_push.STATUS_PERMISSION_DENIED. Duplicated
# (not imported) so Doctor carries no build-time dependency on the
# CM048 package -- the two repos ship separately. The value is the
# load-bearing contract; this constant documents that we know it.
_CM048_PERMISSION_DENIED = "permission_denied"


class RemindersRuntime(TypedDict, total=False):
    """Parsed runtime verdict from ``~/.ostler/reminders_map.db``."""

    state: str
    denied_count: int
    total_rows: int
    # Most recent ``last_seen_at`` across permission_denied rows, ISO-8601,
    # for the "how long has this been broken" relative-time line. Absent
    # when there are no permission_denied rows.
    latest_denied_at: Optional[str]
    # A representative push_title from a permission_denied row, so the
    # operator can see a concrete example of a todo that did not sync.
    example_title: Optional[str]


def _db_path() -> Path:
    """Return ``~/.ostler/reminders_map.db``.

    Honours ``$OSTLER_HOME`` for tests and non-default deployments;
    defaults to ``~/.ostler/``. Mirrors CM048
    ``reminders_push.default_db_path()`` (which derives from the same
    engine-room root) without importing the CM048 package.
    """
    base = Path(os.environ.get("OSTLER_HOME", os.path.expanduser("~/.ostler")))
    return base / "reminders_map.db"


def read_reminders_runtime() -> RemindersRuntime:
    """Read the runtime Reminders push outcome from the mapping DB.

    Returns:
        A :class:`RemindersRuntime` dict. Never raises -- a missing,
        unreadable, or malformed DB reduces to ``state='no-data'`` so
        Doctor keeps rendering.
    """
    db = _db_path()
    if not db.exists():
        return {"state": STATE_NO_DATA, "denied_count": 0, "total_rows": 0}

    conn: Optional[sqlite3.Connection] = None
    try:
        # Open read-only via URI so a Doctor read can never lock or
        # mutate the writer's table. immutable=0 (default) so we still
        # see live WAL writes from the assistant.
        uri = f"file:{db}?mode=ro"
        conn = sqlite3.connect(uri, uri=True, timeout=2.0)
        cur = conn.cursor()

        # The table may not exist yet (DB file created but writer never
        # ran the schema). Treat absence as no-data, not an error.
        cur.execute(
            "SELECT name FROM sqlite_master "
            "WHERE type='table' AND name='reminders_map'"
        )
        if cur.fetchone() is None:
            return {"state": STATE_NO_DATA, "denied_count": 0, "total_rows": 0}

        cur.execute("SELECT COUNT(*) FROM reminders_map")
        total_rows = int(cur.fetchone()[0])
        if total_rows == 0:
            return {"state": STATE_NO_DATA, "denied_count": 0, "total_rows": 0}

        cur.execute(
            "SELECT COUNT(*) FROM reminders_map WHERE status = ?",
            (_CM048_PERMISSION_DENIED,),
        )
        denied_count = int(cur.fetchone()[0])

        if denied_count == 0:
            return {
                "state": STATE_OK,
                "denied_count": 0,
                "total_rows": total_rows,
            }

        # Pull the most recent denied row for the relative-time line and
        # a representative title. ORDER BY last_seen_at DESC; that column
        # is NOT NULL in the CM048 schema so the ordering is well-defined.
        cur.execute(
            "SELECT last_seen_at, push_title FROM reminders_map "
            "WHERE status = ? ORDER BY last_seen_at DESC LIMIT 1",
            (_CM048_PERMISSION_DENIED,),
        )
        row = cur.fetchone()
        latest_denied_at = row[0] if row and row[0] else None
        example_title = row[1] if row and row[1] else None

        return {
            "state": STATE_PERMISSION_DENIED,
            "denied_count": denied_count,
            "total_rows": total_rows,
            "latest_denied_at": latest_denied_at,
            "example_title": example_title,
        }
    except sqlite3.Error as exc:
        logger.warning(
            "Could not read Reminders runtime DB %s: %s", db, exc,
        )
        return {"state": STATE_NO_DATA, "denied_count": 0, "total_rows": 0}
    finally:
        if conn is not None:
            try:
                conn.close()
            except sqlite3.Error:
                pass
