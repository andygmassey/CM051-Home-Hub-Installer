"""Foreground bound + background tail for preference ingest (CM051 #28).

The owner's whole library is stored (no per-source storage cap). But the
install-time import runs in the FOREGROUND, and every stored preference costs
an embedding (measured ~60/s on a Mini), so a 50,000-row source would add a
long silent stretch to the install. Archie's condition on #28: in the
foreground, store the first N per source exactly as before (same ranking, so
the customer sees the same top items when install finishes), and QUEUE THE
TAIL for the existing background preference importer, the com.ostler.export-scan
LaunchAgent (~/.ostler/bin/ostler-scan-exports; RunAtLoad, every 4 h, on by
default), which now runs `cli ingest-tail` before it looks for new exports.

Turned on ONLY by the caller that is in the foreground (install.sh 3.12b):

    OSTLER_PREFS_FOREGROUND_PER_SOURCE=5000
    OSTLER_PREFS_TAIL_QUEUE=~/.ostler/state/prefs-tail

With either unset, nothing is queued and everything is stored now, so the
Downloads watcher and a hand run keep everything in one pass. A set limit with
no queue directory also stores everything: the bound may never become a drop.

QUEUE FORMAT. One JSONL file per ingest run, written to a temp name and
renamed, so a half-written queue file never exists under its real name. Line
1 is a header; every other line is one fully-aggregated ParsedPreference
(id, strength, extra, created_at preserved), so the drain writes exactly what
the foreground would have written.

IDEMPOTENT. Every row keeps its content-keyed id (Qdrant upsert by id) and its
created_at (identical Turtle, and Oxigraph stores a set of triples). The drain
checkpoints the number of rows written per file after each batch. A kill
between a batch's write and its checkpoint re-writes that batch on restart:
same ids, same triples, no duplicate.
"""
from __future__ import annotations

import json
import logging
import os
import time
import uuid
from dataclasses import fields
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from .parsers.base import ParsedPreference

logger = logging.getLogger(__name__)

FOREGROUND_ENV = "OSTLER_PREFS_FOREGROUND_PER_SOURCE"
QUEUE_ENV = "OSTLER_PREFS_TAIL_QUEUE"
SCHEMA = 1
_DT_FIELDS = ("created_at", "observed_at")


def foreground_settings() -> Tuple[Optional[int], Optional[Path]]:
    """(per-source foreground limit, queue dir), or (None, None) when off."""
    raw = os.environ.get(FOREGROUND_ENV, "").strip()
    qdir = os.environ.get(QUEUE_ENV, "").strip()
    try:
        limit = int(raw) if raw else None
    except ValueError:
        limit = None
    if not limit or limit <= 0 or not qdir:
        return None, None
    return limit, Path(qdir).expanduser()


def split_foreground(
    ranked: List[ParsedPreference], limit: int
) -> Tuple[List[ParsedPreference], List[ParsedPreference]]:
    """First `limit` of each source (in the given, already-ranked order) now;
    the rest later. Source order and in-source order are preserved."""
    seen: Dict[str, int] = {}
    now: List[ParsedPreference] = []
    later: List[ParsedPreference] = []
    for p in ranked:
        k = p.source or "unknown"
        seen[k] = seen.get(k, 0) + 1
        (now if seen[k] <= limit else later).append(p)
    return now, later


def _to_row(p: ParsedPreference) -> dict:
    row = {}
    for f in fields(ParsedPreference):
        v = getattr(p, f.name)
        if f.name in _DT_FIELDS and isinstance(v, datetime):
            v = v.isoformat()
        row[f.name] = v
    return row


def _from_row(row: dict) -> ParsedPreference:
    kw = {f.name: row.get(f.name) for f in fields(ParsedPreference) if f.name in row}
    for k in _DT_FIELDS:
        if isinstance(kw.get(k), str):
            kw[k] = datetime.fromisoformat(kw[k])
    return ParsedPreference(**kw)


def write_queue(qdir: Path, prefs: List[ParsedPreference], user_id: str) -> Optional[Path]:
    """Queue `prefs` for the background drain. Returns the file, or None."""
    if not prefs:
        return None
    qdir.mkdir(parents=True, exist_ok=True)
    name = f"{time.strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:8]}.jsonl"
    tmp = qdir / f".{name}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"schema": SCHEMA, "user_id": user_id, "rows": len(prefs)}) + "\n")
        for p in prefs:
            fh.write(json.dumps(_to_row(p), default=str) + "\n")
    os.replace(tmp, qdir / name)
    logger.info("Queued %d preference(s) for the background drain: %s", len(prefs), name)
    return qdir / name


def pending(qdir: Path) -> int:
    """Rows still to write across the queue (counts only)."""
    total = 0
    for f in sorted(qdir.glob("*.jsonl")):
        with open(f, encoding="utf-8") as fh:
            n = json.loads(fh.readline()).get("rows", 0)
        total += max(0, n - _done(f))
    return total


def _ckpt(f: Path) -> Path:
    return f.with_name(f.name + ".done")


def _done(f: Path) -> int:
    try:
        return int(_ckpt(f).read_text().strip() or 0)
    except (OSError, ValueError):
        return 0


async def drain(pipeline, qdir: Path, budget_seconds: float = 600.0,
                batch_size: int = 32) -> Dict[str, int]:
    """Write queued rows through pipeline._process_batch until the queue is
    empty or the budget is spent. Safe to kill at any point."""
    t0 = time.monotonic()
    out = {"files": 0, "written": 0, "errors": 0, "remaining": 0}
    if not qdir.is_dir():
        return out
    for f in sorted(qdir.glob("*.jsonl")):
        with open(f, encoding="utf-8") as fh:
            header = json.loads(fh.readline())
            rows = [json.loads(line) for line in fh if line.strip()]
        user_id = header.get("user_id") or "ostler"
        done = _done(f)
        out["files"] += 1
        while done < len(rows):
            if time.monotonic() - t0 > budget_seconds:
                out["remaining"] = pending(qdir)
                return out
            batch = [_from_row(r) for r in rows[done:done + batch_size]]
            res = await pipeline._process_batch(batch, user_id)
            if res.get("errors"):
                # A store refusal is NOT progress: leave the checkpoint where
                # it is so the next tick retries this batch.
                out["errors"] += len(res["errors"])
                out["remaining"] = pending(qdir)
                return out
            done += len(batch)
            tmp = _ckpt(f).with_name(_ckpt(f).name + ".tmp")
            tmp.write_text(str(done))
            os.replace(tmp, _ckpt(f))
            out["written"] += len(batch)
        f.unlink()
        _ckpt(f).unlink(missing_ok=True)
    out["remaining"] = pending(qdir)
    return out
