#!/usr/bin/env python3
"""Regression guard: browsing hydrate must self-create its Qdrant collection.

The silent-fail this kills: on a fresh single-Mac install nothing
pre-creates Qdrant collections. ``ingest_browser_history`` embedded
every Safari visit (11k+ on a real box) and then PUT the points into
the ``safari_history`` collection -- but that collection did not exist,
Qdrant does NOT auto-create on upsert, so 0 rows landed. The function
reported ``sent=0`` / ``status=error`` and the CM044 Browsing wing was
permanently empty. Every other ingestor in pwg_ingest.py
(``ingest_bookmarks``, the people ingestor) already calls
``_qdrant_ensure_collection`` before upserting; the browsing path did
not. See the feedback_writer_reader_contracts_silent_fail memory.

This test drives the real ``ingest_browser_history`` with the network
functions stubbed, asserting:
  1. ``_qdrant_ensure_collection`` is called for the ``safari_history``
     collection BEFORE any upsert (order matters -- upsert into a
     missing collection is the exact bug).
  2. Usable visits are sent; a sensitive-domain visit is dropped.

Network-free. Requires only the vendored package + its httpx dep to be
importable (httpx is only touched inside the stubbed functions, never
called here).
"""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "vendor"))

from ostler_fda import pwg_ingest as m  # noqa: E402


def main() -> int:
    tmp = Path(tempfile.mkdtemp())
    visits = [
        {
            "type": "web_visit",
            "timestamp": "2026-07-01T10:00:00",
            "url": "https://example.com/a",
            "domain": "example.com",
            "title": "Example A",
            "visit_count": 3,
            "source": "safari_history",
        },
        {
            "type": "web_visit",
            "timestamp": "2026-07-01T11:00:00",
            "url": "https://news.ycombinator.com/",
            "domain": "news.ycombinator.com",
            "title": "Hacker News",
            "visit_count": 9,
            "source": "safari_history",
        },
        {
            # Sensitive: must be dropped client-side, never embedded.
            "type": "web_visit",
            "timestamp": "2026-07-01T12:00:00",
            "url": "https://secure.bank.example/login",
            "domain": "secure.bank.example",
            "title": "Bank",
            "visit_count": 1,
            "source": "safari_history",
        },
    ]
    (tmp / "safari_history.json").write_text(json.dumps(visits))

    order: list[str] = []
    ensured: list[tuple[str, int]] = []

    def fake_embed(texts):
        return [[0.1] * 768 for _ in texts]

    def fake_ensure(collection, vector_size, distance="Cosine"):
        order.append("ensure")
        ensured.append((collection, vector_size))

    def fake_upsert(collection, points):
        order.append("upsert")
        return len(points)

    m._ollama_embed_batch = fake_embed
    m._qdrant_ensure_collection = fake_ensure
    m._qdrant_upsert_points = fake_upsert

    res = m.ingest_browser_history(tmp)

    failures: list[str] = []
    if res.get("status") != "ok":
        failures.append(f"status != ok: {res}")
    if res.get("sent") != 2:
        failures.append(f"expected sent=2 (2 usable, 1 sensitive), got {res}")
    if res.get("skipped_sensitive") != 1:
        failures.append(f"expected skipped_sensitive=1, got {res}")
    if ensured != [("safari_history", 768)]:
        failures.append(
            f"expected ensure('safari_history', 768), got {ensured}"
        )
    if order[:1] != ["ensure"]:
        failures.append(
            f"collection was NOT ensured before upsert (order={order})"
        )

    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1

    print(
        "ok: ingest_browser_history ensures 'safari_history' collection "
        "before upsert; sent=2, 1 sensitive dropped"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
