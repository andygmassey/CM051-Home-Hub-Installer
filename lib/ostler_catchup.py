#!/usr/bin/env python3
"""ostler_catchup -- full-history background catch-up, shared machinery.

WHY (Andy, v1.0.108: "it was supposed to work as you described")
===============================================================
The install reads a recent window per source so that install stays fast:
iMessage 30 days, WhatsApp the newest 2,000 per chat, photos and AI chats a
year, browser and mail five years, a dropped mailbox 250,000 messages. The
recurring ticks only ever look FORWARD from there. So everything older than
the install window was never read, by anything, ever.

This module is the one mechanism that walks each source BACKWARDS to its
oldest item, in small batches, in the background. It does not replace any
forward feed and it does not touch the install-time windows.

HOW IT RUNS
===========
Driven by com.ostler.export-scan (RunAtLoad, every 4 hours, on by default),
straight after #2891's preference-tail drain, with the same shape: a time
budget (OSTLER_CATCHUP_BUDGET_SECONDS, default 1800), bounded resumable slices,
and nothing lost when the budget runs out. Each source family has a runner in
~/.ostler/bin/catchup.d/ that calls ``run()`` from the family's own venv with
its adapters. This file is stdlib only so every venv can import it.

THE CONTRACT
============
An adapter walks one source from newest to oldest:

    start_cursor()            where the walk begins (the install window's edge)
    next_batch(cursor, limit) -> Batch(items, next_cursor, oldest_at, exhausted)
    key(item)                 the dedupe key (stable across runs)
    process(item) -> bool     hand the item to the source's existing sink

RESUMABLE AND IDEMPOTENT, AND WHY A KILL LOSES NOTHING
=====================================================
* The watermark (cursor, oldest date reached, complete) is written atomically,
  and ONLY after every item of a batch has succeeded.
* Each item's key is written to the ledger the moment its sink accepts it.
* A failure, a spent budget or a busy machine part-way through a batch stops
  the tick WITHOUT moving the cursor. The next tick re-reads the same batch and
  the ledger skips what was already done.
* A kill between a sink accepting an item and its ledger write repeats exactly
  that one item. Every sink catch-up feeds is a keyed upsert (CM048 state dir
  per conversation id, uuid5 point and node ids, identifier lookup before a
  person is created), so the repeat is the same write, not a second copy.

QUIET MACHINE
=============
Before every batch and between items: busy if the one-minute load per core is
over CONVERSATION_RETRY_MAX_LOAD_PER_CORE, the same predicate and the same
number #2869 gave the conversation retry (tests pin the two together), or if a
live chat turn is in progress (the interactive marker the bundle ticks already
yield to), or while the install is still running (#2895's marker). Busy means
stop and spend nothing; the next tick looks again.

Counts only in every log line and state file. No content, no names.
"""
from __future__ import annotations

import argparse
import contextlib
import importlib
import json
import logging
import os
import sqlite3
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, List, Optional

logger = logging.getLogger("ostler_catchup")

SCHEMA = 1
DEFAULT_BUDGET_SECONDS = 1800
DEFAULT_BATCH_SIZE = 25

# An item whose sink refuses it this many ticks running is QUARANTINED: skipped,
# counted, and no longer allowed to hold the cursor. One tick makes one attempt
# (a failure stops that source for the tick), so this is also "N ticks".
# Without it a single item that always fails stops its whole source for good:
# one rejected iMessage session would end all iMessage catch-up and the Doctor
# would read "Catching up" for ever.
MAX_ITEM_ATTEMPTS = 3

# The same number, and the same predicate, as #2869's conversation retry
# (vendor/cm041/assistant_api/ical-server.py CONVERSATION_RETRY_MAX_LOAD_PER_CORE).
# tests/test_catchup_core.py reads that file and fails if the two differ.
MAX_LOAD_PER_CORE = 0.75

# The live-chat marker the conversation bundle ticks yield to, and its window.
INTERACTIVE_TTL_SECONDS = 120

# #2895's install-in-progress marker. Older than this is an aborted install's
# leftover and does not count (the marker's own lifetime).
INSTALL_MARKER_MAX_AGE_SECONDS = 6 * 3600


# ── paths, resolved on every call (never at import: backfill_ladder.py) ──────

def ostler_home() -> Path:
    for var in ("OSTLER_HOME", "OSTLER_DIR"):
        raw = os.environ.get(var, "").strip()
        if raw:
            return Path(raw).expanduser()
    return Path.home() / ".ostler"


def state_dir() -> Path:
    raw = os.environ.get("OSTLER_CATCHUP_STATE_DIR", "").strip()
    if raw:
        return Path(raw).expanduser()
    return ostler_home() / "state" / "catchup"


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def to_iso(value: Any) -> Optional[str]:
    """A datetime or epoch seconds as a UTC ISO string; None passes through."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        value = datetime.fromtimestamp(float(value), tz=timezone.utc)
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    return str(value)


def _older(a: Optional[str], b: Optional[str]) -> Optional[str]:
    """The older of two ISO stamps (same format, so string order is time order)."""
    if not a:
        return b
    if not b:
        return a
    return a if a <= b else b


# ── quiet machine ───────────────────────────────────────────────────────────

def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _file_age_seconds(path: Path) -> Optional[float]:
    try:
        return max(0.0, time.time() - path.stat().st_mtime)
    except OSError:
        return None


def busy_reason() -> Optional[str]:
    """Why the machine is too busy for catch-up now, or None when quiet."""
    marker = ostler_home() / "state" / "install-in-progress"
    age = _file_age_seconds(marker)
    if age is not None and age < INSTALL_MARKER_MAX_AGE_SECONDS:
        return "installing"

    ttl = _env_float("OSTLER_INTERACTIVE_TTL_SECS", INTERACTIVE_TTL_SECONDS)
    if ttl > 0:
        imarker = os.environ.get("OSTLER_INTERACTIVE_MARKER", "").strip()
        if imarker:
            ipath = Path(imarker).expanduser()
        else:
            ws = os.environ.get("OSTLER_STATE_DIR", "").strip()
            ipath = (Path(ws).expanduser() if ws else ostler_home() / "workspace") / "interactive-chat.active"
        iage = _file_age_seconds(ipath)
        if iage is not None and iage < ttl:
            return "interactive"

    try:
        load1 = os.getloadavg()[0]
    except (AttributeError, OSError):
        return None
    ceiling = _env_float("OSTLER_CATCHUP_MAX_LOAD_PER_CORE", MAX_LOAD_PER_CORE)
    if load1 / max(os.cpu_count() or 1, 1) > ceiling:
        return "load"
    return None


# ── ledger: what has already reached a sink ──────────────────────────────────

class Ledger:
    """(source, key) pairs whose sink has accepted them, plus counters.

    SQLite so that a kill mid-write leaves either the row or no row. One commit
    per add: an item is expensive (a conversation is a model call), a commit is
    not, and a lost ledger row costs a repeat of a keyed write."""

    def __init__(self, path: Optional[Path] = None):
        self.path = Path(path) if path else state_dir() / "ledger.sqlite"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(self.path), timeout=30)
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS done (source TEXT NOT NULL, key TEXT NOT NULL, "
            "at INTEGER NOT NULL, PRIMARY KEY (source, key))")
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS counts (source TEXT NOT NULL, key TEXT NOT NULL, "
            "n INTEGER NOT NULL, PRIMARY KEY (source, key))")
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS quarantined (source TEXT NOT NULL, key TEXT NOT NULL, "
            "at INTEGER NOT NULL, PRIMARY KEY (source, key))")
        self._db.commit()

    def is_quarantined(self, source: str, key: str) -> bool:
        return self._db.execute(
            "SELECT 1 FROM quarantined WHERE source = ? AND key = ?", (source, key)).fetchone() is not None

    def quarantine(self, source: str, key: str) -> None:
        with self._db:
            self._db.execute(
                "INSERT OR IGNORE INTO quarantined (source, key, at) VALUES (?, ?, ?)",
                (source, key, int(time.time())))

    def count_quarantined(self, source: str) -> int:
        return self._db.execute(
            "SELECT COUNT(*) FROM quarantined WHERE source = ?", (source,)).fetchone()[0]

    def has(self, source: str, key: str) -> bool:
        row = self._db.execute(
            "SELECT 1 FROM done WHERE source = ? AND key = ?", (source, key)).fetchone()
        return row is not None

    def add(self, source: str, key: str) -> None:
        self._db.execute(
            "INSERT OR IGNORE INTO done (source, key, at) VALUES (?, ?, ?)",
            (source, key, int(time.time())))
        self._db.commit()

    def count_done(self, source: str) -> int:
        return self._db.execute(
            "SELECT COUNT(*) FROM done WHERE source = ?", (source,)).fetchone()[0]

    def bump(self, source: str, key: str, delta: int = 1) -> int:
        """Add to a running counter and return the new value (one transaction)."""
        with self._db:
            self._db.execute(
                "INSERT INTO counts (source, key, n) VALUES (?, ?, ?) "
                "ON CONFLICT(source, key) DO UPDATE SET n = n + excluded.n",
                (source, key, delta))
            return self._db.execute(
                "SELECT n FROM counts WHERE source = ? AND key = ?", (source, key)).fetchone()[0]

    def get_count(self, source: str, key: str) -> int:
        row = self._db.execute(
            "SELECT n FROM counts WHERE source = ? AND key = ?", (source, key)).fetchone()
        return row[0] if row else 0

    def close(self) -> None:
        with contextlib.suppress(Exception):
            self._db.close()


# ── watermark ────────────────────────────────────────────────────────────────

_UNSET = object()


@dataclass
class Watermark:
    source: str
    doctor_row: str = ""
    cursor: Any = _UNSET
    oldest_at: Optional[str] = None
    complete: bool = False
    items_done: int = 0
    items_skipped: int = 0
    items_quarantined: int = 0
    batches: int = 0
    ticks: int = 0
    started_at: Optional[str] = None
    updated_at: Optional[str] = None
    completed_at: Optional[str] = None
    last_tick: dict = field(default_factory=dict)
    cannot_run: Optional[str] = None

    @staticmethod
    def path_for(source: str) -> Path:
        return state_dir() / f"{source}.json"

    @property
    def has_cursor(self) -> bool:
        return self.cursor is not _UNSET

    @classmethod
    def load(cls, source: str, doctor_row: str = "") -> "Watermark":
        p = cls.path_for(source)
        try:
            raw = json.loads(p.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return cls(source=source, doctor_row=doctor_row or source)
        except (OSError, ValueError) as exc:
            # A corrupt watermark restarts the walk; the ledger still skips
            # everything already done, so a restart costs reads, not writes.
            logger.warning("catch-up %s: unreadable watermark (%s); restarting the walk",
                           source, type(exc).__name__)
            return cls(source=source, doctor_row=doctor_row or source)
        if not isinstance(raw, dict) or raw.get("schema") != SCHEMA:
            return cls(source=source, doctor_row=doctor_row or source)
        wm = cls(source=source, doctor_row=raw.get("doctor_row") or doctor_row or source)
        if "cursor" in raw:
            wm.cursor = raw["cursor"]
        for name in ("oldest_at", "started_at", "updated_at", "completed_at"):
            setattr(wm, name, raw.get(name))
        wm.complete = bool(raw.get("complete"))
        for name in ("items_done", "items_skipped", "items_quarantined", "batches", "ticks"):
            v = raw.get(name)
            setattr(wm, name, v if isinstance(v, int) else 0)
        wm.cannot_run = raw.get("cannot_run") if isinstance(raw.get("cannot_run"), str) else None
        wm.last_tick = raw.get("last_tick") if isinstance(raw.get("last_tick"), dict) else {}
        if doctor_row:
            wm.doctor_row = doctor_row
        return wm

    def to_dict(self) -> dict:
        d = {
            "schema": SCHEMA, "source": self.source, "doctor_row": self.doctor_row or self.source,
            "oldest_at": self.oldest_at, "complete": self.complete,
            "items_done": self.items_done, "items_skipped": self.items_skipped,
            "items_quarantined": self.items_quarantined,
            "batches": self.batches, "ticks": self.ticks,
            "started_at": self.started_at, "updated_at": self.updated_at,
            "completed_at": self.completed_at, "last_tick": self.last_tick,
            "cannot_run": self.cannot_run,
        }
        if self.has_cursor:
            d["cursor"] = self.cursor
        return d

    def save(self) -> None:
        p = self.path_for(self.source)
        p.parent.mkdir(parents=True, exist_ok=True)
        self.updated_at = _now_iso()
        tmp = p.with_name(p.name + ".tmp")
        tmp.write_text(json.dumps(self.to_dict(), indent=2, default=str), encoding="utf-8")
        os.replace(tmp, p)


def read_all_watermarks(directory: Optional[Path] = None) -> List[dict]:
    """Every watermark on disk, as dicts (Doctor and the status command)."""
    d = Path(directory) if directory else state_dir()
    out = []
    try:
        files = sorted(d.glob("*.json"))
    except OSError:
        return out
    for f in files:
        try:
            raw = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(raw, dict) and raw.get("schema") == SCHEMA and raw.get("source"):
            out.append(raw)
    return out


# ── adapter contract ─────────────────────────────────────────────────────────

class CannotRun(Exception):
    """Raised by an adapter's ``next_batch`` or ``process`` when the source
    cannot be READ right now (permission refused, store unreadable, schema not
    recognised). Not an item failure: it is never counted as an attempt, never
    quarantines anything, never marks the walk complete, and the Doctor says so.
    ``reason`` is a short code, never content."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = str(reason)


@dataclass
class Batch:
    items: list
    next_cursor: Any
    oldest_at: Optional[str] = None   # oldest moment this batch covers, ISO UTC
    exhausted: bool = False           # nothing older exists after this batch
    # Nothing more to do THIS tick, but not finished: a mirror of a walk that
    # another agent performs (Apple Mail bodies, email-ingest) reports where
    # that walk has reached and steps aside until the next tick. Exempt from
    # the no-progress guard, which would otherwise call it complete.
    pause: bool = False
    # The source could not be READ at all this tick (permission refused, store
    # unreadable, query error). Not done and not empty: the cursor stays put,
    # the walk is never marked complete, and the Doctor says it could not run.
    # A short reason code, never content.
    cannot_run: Optional[str] = None


class Adapter:
    """Subclass per source. ``source`` names the watermark; ``doctor_row`` is
    the Doctor row it reports under (several sources may share one row)."""

    source: str = ""
    doctor_row: str = ""
    batch_size: int = DEFAULT_BATCH_SIZE

    def start_cursor(self) -> Any:
        return None

    def next_batch(self, cursor: Any, limit: int) -> Batch:  # pragma: no cover - interface
        raise NotImplementedError

    def key(self, item: Any) -> str:  # pragma: no cover - interface
        raise NotImplementedError

    def process(self, item: Any) -> bool:  # pragma: no cover - interface
        raise NotImplementedError


# ── the loop ─────────────────────────────────────────────────────────────────

def run(
    adapters: Iterable[Adapter],
    *,
    budget_seconds: float = DEFAULT_BUDGET_SECONDS,
    clock: Callable[[], float] = time.monotonic,
    busy: Callable[[], Optional[str]] = busy_reason,
    ledger: Optional[Ledger] = None,
) -> dict:
    """Walk every incomplete adapter backwards until done, busy or out of time.

    Returns a counts-only summary: per source {items, skipped, failed,
    batches, complete, oldest_at, reason} and the tick's overall reason.
    """
    adapters = [a for a in adapters if a is not None]
    t0 = clock()
    own_ledger = ledger is None
    ledger = ledger or Ledger()
    wms = {a.source: Watermark.load(a.source, a.doctor_row or a.source) for a in adapters}
    stats = {a.source: {"items": 0, "skipped": 0, "failed": 0, "quarantined": 0,
                        "batches": 0, "reason": None}
             for a in adapters}
    for a in adapters:
        wm = wms[a.source]
        if wm.started_at is None:
            wm.started_at = _now_iso()
        if wm.complete:
            stats[a.source]["reason"] = "complete"

    def out_of_time() -> bool:
        return clock() - t0 >= budget_seconds

    active = [a for a in adapters if not wms[a.source].complete]
    stop: Optional[str] = None
    try:
        while active and stop is None:
            for a in list(active):
                st, wm = stats[a.source], wms[a.source]
                if out_of_time():
                    stop = "budget"
                    break
                why = busy()
                if why:
                    stop = "busy:" + why
                    break
                try:
                    # start_cursor is inside the guard too: an adapter that
                    # cannot even find its edge must not end the whole tick.
                    cursor = wm.cursor if wm.has_cursor else a.start_cursor()
                    batch = a.next_batch(cursor, max(1, int(a.batch_size or DEFAULT_BATCH_SIZE)))
                except CannotRun as exc:
                    st["reason"] = "cannot_run:" + exc.reason
                    wm.cannot_run = exc.reason
                    active.remove(a)
                    wm.save()
                    continue
                except Exception as exc:  # noqa: BLE001 - one source never stops the others
                    logger.warning("catch-up %s: reading the next batch failed (%s)",
                                   a.source, type(exc).__name__)
                    st["reason"] = "read_failed:" + type(exc).__name__
                    active.remove(a)
                    continue

                if batch.cannot_run:
                    # Said out loud, never read as an empty or finished source.
                    st["reason"] = "cannot_run:" + str(batch.cannot_run)
                    wm.cannot_run = str(batch.cannot_run)
                    active.remove(a)
                    wm.save()
                    continue
                wm.cannot_run = None

                finished = True
                blocked: Optional[str] = None
                for item in batch.items:
                    if out_of_time():
                        stop, finished = "budget", False
                        break
                    why = busy()
                    if why:
                        stop, finished = "busy:" + why, False
                        break
                    k = a.key(item)
                    if ledger.is_quarantined(a.source, k):
                        continue
                    if ledger.has(a.source, k):
                        st["skipped"] += 1
                        wm.items_skipped += 1
                        continue
                    try:
                        ok = bool(a.process(item))
                    except CannotRun as exc:
                        blocked, finished = exc.reason, False
                        break
                    except Exception as exc:  # noqa: BLE001
                        logger.warning("catch-up %s: an item failed (%s)", a.source, type(exc).__name__)
                        ok = False
                    if not ok:
                        tries = ledger.bump(a.source, "attempts:" + k)
                        if tries >= int(getattr(a, "max_attempts", MAX_ITEM_ATTEMPTS) or MAX_ITEM_ATTEMPTS):
                            # Poisoned: stop letting it hold the whole source.
                            ledger.quarantine(a.source, k)
                            st["quarantined"] += 1
                            wm.items_quarantined += 1
                            logger.warning("catch-up %s: an item failed %d ticks running; skipping it",
                                           a.source, tries)
                            continue
                        st["failed"] += 1
                        st["reason"] = "item_failed"
                        finished = False
                        break
                    ledger.add(a.source, k)
                    st["items"] += 1
                    wm.items_done += 1

                if blocked is not None:
                    st["reason"] = "cannot_run:" + blocked
                    wm.cannot_run = blocked
                    active.remove(a)
                    wm.save()
                    continue

                if not finished:
                    # The cursor stays put: the next tick re-reads this batch
                    # and the ledger skips the items already done.
                    if st["reason"] == "item_failed":
                        active.remove(a)
                    wm.save()
                    if stop:
                        break
                    continue

                no_progress = (not batch.items and not batch.exhausted and not batch.pause
                               and wm.has_cursor and batch.next_cursor == wm.cursor)
                wm.cursor = batch.next_cursor
                wm.oldest_at = _older(wm.oldest_at, batch.oldest_at)
                wm.batches += 1
                st["batches"] += 1
                if batch.exhausted or no_progress:
                    # A batch that read nothing and did not move the cursor
                    # would loop for ever; it can only mean nothing older.
                    wm.complete = True
                    wm.completed_at = _now_iso()
                    st["reason"] = "complete"
                    active.remove(a)
                elif batch.pause:
                    active.remove(a)
                wm.save()
    finally:
        reason = stop or ("complete" if not active else "idle")
        seconds = round(clock() - t0, 2)
        for a in adapters:
            st, wm = stats[a.source], wms[a.source]
            if st["reason"] is None:
                st["reason"] = reason
            wm.ticks += 1
            wm.last_tick = {"at": _now_iso(), "items": st["items"], "skipped": st["skipped"],
                            "failed": st["failed"], "quarantined": st["quarantined"],
                            "batches": st["batches"],
                            "reason": st["reason"], "seconds": seconds}
            wm.save()
        if own_ledger:
            ledger.close()

    summary = {"reason": reason, "seconds": seconds, "sources": {}}
    for a in adapters:
        st, wm = stats[a.source], wms[a.source]
        summary["sources"][a.source] = dict(st, complete=wm.complete, oldest_at=wm.oldest_at,
                                            items_done=wm.items_done,
                                            items_quarantined=wm.items_quarantined)
    logger.info("catch-up tick: %s", json.dumps(summary, sort_keys=True))
    return summary


# ── single-flight per family ─────────────────────────────────────────────────

@contextlib.contextmanager
def family_lock(family: str):
    """Non-blocking lock so a hand run and the agent never walk one family at
    once. Yields True when held, False when another run has it."""
    import fcntl
    p = state_dir() / f".{family}.lock"
    p.parent.mkdir(parents=True, exist_ok=True)
    fh = open(p, "w")
    try:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        yield True
    finally:
        fh.close()


# ── command line ─────────────────────────────────────────────────────────────

def _load_factory(spec: str) -> Callable[[], List[Adapter]]:
    mod_name, _, attr = spec.partition(":")
    mod = importlib.import_module(mod_name)
    return getattr(mod, attr or "adapters")


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(prog="ostler_catchup",
                                 description="Full-history background catch-up (counts only).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="Walk one family's sources backwards for a bounded time.")
    r.add_argument("--family", required=True, help="Family name, for the single-flight lock.")
    r.add_argument("--adapters", required=True, action="append",
                   help="module:factory returning a list of adapters (repeatable).")
    r.add_argument("--budget-seconds", type=float, default=None)
    s = sub.add_parser("status", help="Print every watermark (counts only).")
    s.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s",
                        stream=sys.stderr)

    if args.cmd == "status":
        rows = read_all_watermarks()
        if args.json:
            print(json.dumps(rows, indent=2, default=str))
        else:
            for w in rows:
                print("%-20s complete=%s back_to=%s items=%s last=%s" % (
                    w["source"], w.get("complete"), w.get("oldest_at"), w.get("items_done"),
                    (w.get("last_tick") or {}).get("reason")))
        return 0

    budget = args.budget_seconds
    if budget is None:
        budget = _env_float("OSTLER_CATCHUP_BUDGET_SECONDS", DEFAULT_BUDGET_SECONDS)
    with family_lock(args.family) as held:
        if not held:
            print(json.dumps({"family": args.family, "reason": "locked"}))
            return 0
        adapters: List[Adapter] = []
        for spec in args.adapters:
            try:
                adapters.extend(a for a in _load_factory(spec)() if a is not None)
            except Exception as exc:  # noqa: BLE001
                # CANNOT-RUN for this spec, said out loud; the others still run.
                logger.warning("catch-up %s: adapter %s could not load (%s: %s)",
                               args.family, spec, type(exc).__name__, exc)
        if not adapters:
            print(json.dumps({"family": args.family, "reason": "no_adapters"}))
            return 3
        summary = run(adapters, budget_seconds=budget)
        summary["family"] = args.family
        print(json.dumps(summary, sort_keys=True))
        failed = any(v.get("reason", "").startswith(("read_failed", "item_failed"))
                     for v in summary["sources"].values())
        return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
