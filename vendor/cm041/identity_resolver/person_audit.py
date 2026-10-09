"""Append-only audit of every Person removal from the graph (walk #15).

WHY. Walk #15 left one vector whose Person node had no triples at all, and
nothing on the box recorded who removed it. A prune that silently clears such a
vector would hide a writer that is destroying people. So every writer that can
remove a Person node, its rdf:type, its displayName or all of its triples calls
``record_person_removal`` FIRST, and the box-walk probe people_stores_reconcile
joins each orphan to its record by URI digest.

WHAT IS WRITTEN. One JSON line: UTC time, component, reason, ``uri_fp`` (the
first 12 hex of sha256 of the URI, the same digest the probe already uses) and
``uri_shape`` (hex and digit runs replaced). NEVER a name, never the URI.

WHERE. ``~/.ostler/logs/person-deletions.jsonl``, or the path in
``OSTLER_PERSON_DELETION_LOG``. Opened O_APPEND so concurrent writers interleave
whole lines. The log is never truncated by product code.

NEVER RAISES. An audit failure must not stop a merge or a forget, but it is not
silent either: it is logged at WARNING. This file is deliberately identical in
every vendored tree that carries a copy (a test pins that).
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

LOG_ENV = "OSTLER_PERSON_DELETION_LOG"
DEFAULT_LOG = "~/.ostler/logs/person-deletions.jsonl"


def log_path() -> str:
    return os.path.expanduser(os.environ.get(LOG_ENV) or DEFAULT_LOG)


def uri_fp(uri: str) -> str:
    return hashlib.sha256(uri.encode("utf-8")).hexdigest()[:12]


def uri_shape(uri: str) -> str:
    t = re.sub(r"[0-9a-fA-F]{6,}", "<h>", uri or "")
    t = re.sub(r"[0-9]+", "<n>", t)
    return t.replace(",", "_").replace(" ", "_")[:90]


def record_person_removal(uri: str, component: str, reason: str) -> bool:
    """Append one record. Returns True when written, False (and a WARNING) when not."""
    try:
        if not uri:
            return False
        rec = {
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "component": str(component),
            "reason": str(reason),
            "uri_fp": uri_fp(uri),
            "uri_shape": uri_shape(uri),
        }
        path = log_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, (json.dumps(rec, sort_keys=True) + "\n").encode("utf-8"))
        finally:
            os.close(fd)
        return True
    except Exception as exc:  # noqa: BLE001 -- must never stop the caller
        logger.warning("person removal audit NOT written: %s", type(exc).__name__)
        return False
