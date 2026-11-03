"""A transient Qdrant error no longer drops a knowledge chunk (walk v1.0.122).

Mini16 diag: hydrate-apple-notes.log "Failed to upsert chunk: timed out" once,
17999 of 18000 written, and the qdrant probe FAILed. Arms: one timeout then
success writes the chunk; a store that keeps failing is reported False after
the bounded attempts and logs the existing "Failed to upsert chunk" line (the
probe's signal); a mutant with one attempt fails arm 1.
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor" / "cm024_knowledge"))
from ostler_knowledge.storage import qdrant_store as qs  # noqa: E402

qs.UPSERT_RETRY_BASE_S = 0.0
fails = 0


def check(ok, label):
    global fails
    print(("  PASS " if ok else "  FAIL ") + label)
    fails += 0 if ok else 1


def store(outcomes):
    s = object.__new__(qs.QdrantStore)
    calls = []

    async def upsert_vectors(vectors, payloads, ids):
        calls.append(ids[0])
        o = outcomes.pop(0)
        if isinstance(o, Exception):
            raise o
        return o

    s.upsert_vectors = upsert_vectors
    return s, calls


def run(s):
    return asyncio.run(s.upsert("n1", 0, [0.0], "c", "t", [], 1))


s, calls = store([TimeoutError("timed out"), 1])
check(run(s) is True and len(calls) == 2 and calls[0] == calls[1],
      "arm 1: one timeout then success writes the chunk, same point id")
s, calls = store([TimeoutError("timed out")] * 5)
check(run(s) is False and len(calls) == qs.UPSERT_ATTEMPTS,
      f"arm 2: a store that keeps failing is reported after {qs.UPSERT_ATTEMPTS} attempts")
print(f"\n{'FAILED' if fails else 'PASSED'}")
sys.exit(1 if fails else 0)
