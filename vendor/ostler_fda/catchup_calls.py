"""Full-history catch-up for call history (phone and FaceTime).

extract_all reads OSTLER_CALL_BACKFILL_DAYS (default 365) of calls on every
fda-rerun tick and nothing read further back. This adapter walks
CallHistory.storedata backwards from that edge in fixed 30-day windows to the
oldest call the database still holds, through the SAME reader
(``call_history.extract_calls``) and the SAME sink (``pwg_ingest.ingest_calls``)
the tick uses, so matching, the do-not-suggest / minor / L3 guards and the
event shape are identical.

Driven by lib/ostler_catchup.py from com.ostler.export-scan (runner
``25-calls``, registered by install.sh). Per-source consent is honoured: it
runs only if ``call_history`` is in OSTLER_FDA_SOURCES, resolved exactly as
extract_all resolves it.

KEYS AND DUPLICATES. One item is one window; its key is source + the window's
two epoch bounds. The sink is keyed too: a call event's URI is derived from
Apple's own call id, so a window repeated after a kill rewrites the same
triples and adds none.

A READ THAT FAILS IS NOT AN EMPTY WINDOW. An unreadable database (Full Disk
Access missing) or a schema this reader does not know raises from
``next_batch`` / ``process`` as ``CannotRun``: the walk stops, is never marked
complete, and the Doctor says it could not look.

A GRAPH OUTAGE COUNTS NOTHING. ``ingest_calls`` answers ``cannot_run`` when the
store is down; that is raised as ConnectionError (an outage, not a poison
attempt), so the window is retried and never quarantined.

KNOWN LIMIT. A call to a number that only LATER becomes a contact stays
unattached in an old window the walk has already finished; the forward tick
re-reads the last OSTLER_CALL_BACKFILL_DAYS and picks those up, older ones are
not revisited.

Counts only in logs. No numbers leave this module except into the sink, via a
0700 temp directory that is removed in ``finally``.
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import ostler_catchup as oc

logger = logging.getLogger(__name__)

DAY = 86400
DEFAULT_WINDOW_DAYS = 30
# extract_all's own default for the forward read; the catch-up edge follows it.
DEFAULT_FORWARD_DAYS = 365


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _dt(epoch: int) -> datetime:
    return datetime.fromtimestamp(epoch, tz=timezone.utc)


class CallsAdapter(oc.Adapter):
    source = "calls"
    doctor_row = "calls"
    batch_size = 2            # windows per batch: the budget is checked between windows

    def __init__(self, db_path: Optional[Path] = None, now: Optional[float] = None,
                 window_days: Optional[int] = None):
        from . import call_history
        self.module = call_history
        self.db_path = db_path
        self.now = now
        self.window = (window_days or _env_int("OSTLER_CATCHUP_CALLS_WINDOW_DAYS",
                                               DEFAULT_WINDOW_DAYS)) * DAY

    def _read_denied(self, exc: Exception):
        if isinstance(exc, PermissionError):
            return oc.CannotRun("read_denied")
        if isinstance(exc, self.module.CallHistorySchemaError):
            return oc.CannotRun("schema_unknown")
        return None

    def start_cursor(self):
        now = int(self.now if self.now is not None else time.time())
        days = _env_int("OSTLER_CALL_BACKFILL_DAYS", DEFAULT_FORWARD_DAYS)
        return {"end": now - days * DAY, "floor": None}

    def next_batch(self, cursor, limit):
        end = int(cursor["end"])
        floor = cursor.get("floor")
        if floor is None:
            try:
                oldest = self.module.oldest_call(self.db_path)
            except (PermissionError, self.module.CallHistorySchemaError) as exc:
                raise self._read_denied(exc) from exc
            if oldest is None:
                return oc.Batch(items=[], next_cursor={"end": end, "floor": end},
                                oldest_at=None, exhausted=True)
            floor = int(oldest.timestamp())
        if end <= floor:
            return oc.Batch(items=[], next_cursor={"end": end, "floor": floor},
                            oldest_at=oc.to_iso(floor), exhausted=True)
        items = []
        hi = end
        while len(items) < limit and hi > floor:
            lo = hi - self.window
            items.append((lo, hi))
            hi = lo
        exhausted = hi <= floor
        return oc.Batch(items=items, next_cursor={"end": hi, "floor": floor},
                        oldest_at=oc.to_iso(max(hi, floor)), exhausted=exhausted)

    def key(self, item):
        lo, hi = item
        return f"{self.source}:{lo}:{hi}"

    def process(self, item):
        from . import pwg_ingest
        lo, hi = item
        try:
            extract = self.module.extract_calls(self.db_path, since=_dt(lo - 1), until=_dt(hi))
        except (PermissionError, self.module.CallHistorySchemaError) as exc:
            raise self._read_denied(exc) from exc
        # extract_calls' lower bound is exclusive and its upper bound is
        # INCLUSIVE; filtering to lo <= t < hi makes the window [lo, hi), so a
        # call exactly on a boundary lands in one window only.
        events = [e for e in extract.events if lo <= e.when.timestamp() < hi]
        if not events:
            return True
        work = Path(tempfile.mkdtemp(prefix="ostler-catchup-calls-"))
        work.chmod(0o700)
        try:
            (work / "call_history.json").write_text(
                json.dumps(self.module.to_interaction_events(events)))
            res = pwg_ingest.ingest_calls(work)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        status = res.get("status")
        if status == "cannot_run":
            raise ConnectionError("people graph unavailable")
        ok = status == "ok"
        if not ok:
            logger.warning("calls catch-up: window not landed (%s); retrying next tick", status)
        return ok


def adapters():
    """The runner's factory: the call-history adapter if the customer consented."""
    from .extract_all import _resolve_enabled_sources
    if "call_history" not in _resolve_enabled_sources():
        logger.info("calls catch-up: call_history is not enabled; nothing to read")
        return []
    from . import call_history
    if not call_history.DEFAULT_CALL_DB.exists():
        logger.info("calls catch-up: no call history on this Mac; nothing to read")
        return []
    return [CallsAdapter()]
