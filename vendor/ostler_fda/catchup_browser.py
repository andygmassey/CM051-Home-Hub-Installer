"""Full-history catch-up for Safari and Chrome browsing history (v1.0.108).

The install reads OSTLER_SAFARI_BACKFILL_DAYS / OSTLER_BROWSER_BACKFILL_DAYS
of history (install.sh defaults both to 1825, five years) and nothing ever
read further back. These adapters walk each browser backwards from that edge
in fixed 30-day windows to the oldest visit the browser still holds, through
the SAME converter (``to_timeline_entries``) and the SAME sink
(``pwg_ingest.ingest_browser_history``) the install uses, so sensitive-domain
filtering, embedding and payload shape are identical.

Driven by lib/ostler_catchup.py from com.ostler.export-scan (runner
``20-browser``, registered by install.sh). Per-source consent is honoured:
a browser runs only if it is in OSTLER_FDA_SOURCES, resolved exactly as
extract_all resolves it.

KEYS AND DUPLICATES. One item is one window; its key is source + the
window's two epoch bounds. The sink is keyed too: every Qdrant point id is
uuid5(source, url, timestamp), so a window repeated after a kill rewrites the
same points. A window is only marked done when EVERY ingestible visit in it
landed (``sent == total``); a partial landing is retried next tick.

CHROME NOT INSTALLED vs NOT READABLE. No Chrome History file at all means
Chrome is not a source on this Mac: no adapter, no watermark, no Doctor
claim. A History file that cannot be read (Full Disk Access missing) raises
from ``next_batch``; the core records ``read_failed:PermissionError`` for that
source, leaves it incomplete, and Safari still runs.

Counts only in logs. No URLs, titles or domains leave this module except into
the sink.
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import sqlite3
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import ostler_catchup as oc

logger = logging.getLogger(__name__)

DAY = 86400
DEFAULT_WINDOW_DAYS = 30
# install.sh resolves both backfill windows to 1825 when unset
# (install.sh `: "${OSTLER_SAFARI_BACKFILL_DAYS:=1825}"`); extract_all's own
# fallback (365) is never the shipped value, so the catch-up edge follows
# install.sh, never extract_all's dead default.
DEFAULT_INSTALL_DAYS = 1825


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


class _BrowserAdapter(oc.Adapter):
    doctor_row = "browsing"
    batch_size = 2            # windows per batch: the budget is checked between windows
    module = None             # safari_history or chrome_history
    json_name = ""            # file name ingest_browser_history reads
    edge_env = ""

    def __init__(self, db_path: Optional[Path] = None, now: Optional[float] = None,
                 window_days: Optional[int] = None):
        self.db_path = db_path
        self.now = now
        self.window = (window_days or _env_int("OSTLER_CATCHUP_BROWSER_WINDOW_DAYS",
                                               DEFAULT_WINDOW_DAYS)) * DAY

    # The edge is the install window's lower bound. Recomputed at the first
    # tick, which is after the install, so it can only OVERLAP what install
    # read (harmless: keyed sink), never leave a gap.
    def start_cursor(self):
        now = int(self.now if self.now is not None else time.time())
        days = _env_int(self.edge_env, DEFAULT_INSTALL_DAYS)
        return {"end": now - days * DAY, "floor": None}

    def next_batch(self, cursor, limit):
        end = int(cursor["end"])
        floor = cursor.get("floor")
        if floor is None:
            oldest = self.module.oldest_visit(self.db_path)  # raises when unreadable
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
        oldest_at = oc.to_iso(max(hi, floor))
        return oc.Batch(items=items, next_cursor={"end": hi, "floor": floor},
                        oldest_at=oldest_at, exhausted=exhausted)

    def key(self, item):
        lo, hi = item
        return f"{self.source}:{lo}:{hi}"

    def process(self, item):
        from . import pwg_ingest
        lo, hi = item
        try:
            entries = self.module.extract_history(self.db_path, since=_dt(lo - 1), until=_dt(hi),
                                                  strict=True)
        except (sqlite3.OperationalError, PermissionError) as exc:
            # A query error is not an empty window. extract_history used to
            # return [] for it, which fell through to "no entries -> done" and
            # let the walk finish over history it never read.
            reason = "read_denied" if isinstance(exc, PermissionError) else "query_failed"
            raise oc.CannotRun(reason) from exc
        # extract_history's lower bound is exclusive; lo-1 makes the window
        # [lo, hi) so a visit exactly on a boundary lands in one window only.
        entries = [e for e in entries if e.visit_time.timestamp() >= lo]
        if not entries:
            return True
        work = Path(tempfile.mkdtemp(prefix="ostler-catchup-browser-"))
        try:
            (work / self.json_name).write_text(
                json.dumps(self.module.to_timeline_entries(entries), default=str))
            res = pwg_ingest.ingest_browser_history(work)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        status = res.get("status")
        if status == "no_data":
            return True       # every visit in it was sensitive or unusable
        ok = status == "ok" and res.get("sent") == res.get("total")
        if not ok:
            logger.warning("browser catch-up %s: window landed %s of %s; retrying next tick",
                           self.source, res.get("sent"), res.get("total"))
        return ok


class SafariAdapter(_BrowserAdapter):
    source = "browsing_safari"
    json_name = "safari_history.json"
    edge_env = "OSTLER_SAFARI_BACKFILL_DAYS"

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        from . import safari_history
        self.module = safari_history


class ChromeAdapter(_BrowserAdapter):
    source = "browsing_chrome"
    json_name = "chrome_history.json"
    edge_env = "OSTLER_BROWSER_BACKFILL_DAYS"

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        from . import chrome_history
        self.module = chrome_history


def adapters():
    """The runner's factory: the browsers this customer consented to."""
    from .extract_all import _resolve_enabled_sources
    from . import chrome_history, safari_history
    enabled = _resolve_enabled_sources()
    out = []
    if "safari_history" in enabled:
        out.append(SafariAdapter())
    if "chrome_history" in enabled:
        if chrome_history.DEFAULT_HISTORY_PATH.exists():
            out.append(ChromeAdapter())
        else:
            logger.info("browser catch-up: Chrome is not installed; nothing to read")
    if not out:
        logger.info("browser catch-up: no browser source is enabled")
    return out
