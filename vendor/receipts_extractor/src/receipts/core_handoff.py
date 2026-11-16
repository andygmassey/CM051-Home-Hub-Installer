"""Handoff of extracted receipts to the receipts core (PWG services/ingest, Bursar "Expenses").

The core's entry is `python -m receipts.cli ingest.email` with {"rows": [...]} on stdin. Each row is the
extractor's own fields. The extractor does NOT decide a book: `book` is left out, so the core files
nothing and every row lands in Check (the owner rule: a sender-side guess is never a filing).

Refuses to run without an explicit core directory: no default path is guessed.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any, Callable, Dict, Iterable, List, Optional

ROW_KEYS = ("message_id", "merchant", "occurred_at", "total", "currency", "sender")


def rows_from_records(records: Iterable[Dict[str, Any]]) -> Dict[str, Any]:
    """Map ReceiptStore records to the core's ingest.email request. Missing fields are sent as null."""
    rows = []
    for r in records:
        rows.append({k: r.get(k) for k in ROW_KEYS if k != "sender"} | {"sender": r.get("sender")})
    return {"rows": rows}


def handoff(records: List[Dict[str, Any]], core_dir: str, *,
            runner: Callable[..., Any] = subprocess.run, python: Optional[str] = None) -> Dict[str, Any]:
    """Send records to the core and return its parsed reply. Raises if the core cannot run (fail closed)."""
    if not core_dir or not os.path.isdir(core_dir):
        raise RuntimeError("CANNOT-RUN: receipts core directory missing: %r" % core_dir)
    env = dict(os.environ, OSTLER_RECEIPTS="1", PYTHONPATH=os.path.join(core_dir, "src"))
    proc = runner([python or sys.executable, "-m", "receipts.cli", "ingest.email"],
                  input=json.dumps(rows_from_records(records)), capture_output=True, text=True, env=env, timeout=300)
    if proc.returncode != 0:
        raise RuntimeError("CANNOT-RUN: receipts core exited %s" % proc.returncode)
    reply = json.loads(proc.stdout)
    if reply.get("state") != "ok":
        raise RuntimeError("CANNOT-RUN: receipts core state %r" % reply.get("state"))
    return reply
