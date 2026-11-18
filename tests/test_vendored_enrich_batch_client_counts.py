#!/usr/bin/env python3
"""The enricher logs ONE counts-only per-client line per batch, and the walk probe
enrichment_reaches_clients reads that exact line.

Runs the REAL vendored ``EnrichmentService.enrich_batch`` over a synthetic seed
(every network client a recorder, the people store a mock, no request leaves the
process), captures what it really logged, then:

  A  the line "enrichment looked up per client: music=N ..." is emitted once, with
     the counts the seed implies (music 2, books 1, films 1, podcasts 1, places 1,
     food 1, interests 1)
  B  the line carries counts only: no seed subject appears in anything logged
  C  positive: the REAL captured log goes through the probe's judge -> PASS
  D  negative control: the same seed minus the podcast item, run through the same
     enricher, emits podcasts=0 and the judge says FAIL
  E  negative control: a refused (L2) item is not counted
  F  a second batch reports its own deltas, not the running total

Synthetic values only. Exit 0 pass, 1 assertion failed, 2 cannot-run.
"""
from __future__ import annotations

import asyncio
import logging
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
VENDOR = ROOT / "vendor" / "cm019_preferences" / "services"
JUDGE = ROOT / "scripts" / "box_walk_probes" / "lib" / "walk134_judges.py"
for p in (VENDOR / "enrich", VENDOR / "common", TESTS):
    sys.path.insert(0, str(p))

try:
    import test_vendored_enrich_seed_lookups as base  # reuse its recorder and store mock
    from src.enricher import EnrichmentService as Enricher
    import httpx
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: vendored enricher or its seed harness did not import: {exc!r}")
    sys.exit(2)

STAMP = {"privacy_level": "L0", "privacyScale": "canonical-2026-11",
         "extra": {"category_inferred": False}}
SEED = [
    {"id": "c-01", "category": "music", "subject": "seed-subject-01", **STAMP},
    {"id": "c-02", "category": "album", "subject": "seed-subject-02", **{**STAMP, "extra": {"category_inferred": False, "artist": "seed artist"}}},
    {"id": "c-03", "category": "book", "subject": "seed-subject-03", **STAMP, "author": "seed author"},
    {"id": "c-04", "category": "movie", "subject": "seed-subject-04", **STAMP},
    {"id": "c-05", "category": "podcast", "subject": "seed-subject-05", **STAMP},
    {"id": "c-06", "category": "place", "subject": "seed venue harbour", **STAMP},
    {"id": "c-07", "category": "food", "subject": "seed-subject-07", **STAMP},
    {"id": "c-08", "category": "interest", "subject": "seed-subject-08", **STAMP},
    {"id": "c-09", "category": "podcast", "subject": "seed-subject-09", "privacy_level": "L2",
     "privacyScale": "canonical-2026-11"},  # refused by the gate: never counted
]
PREFIX = "enrichment looked up per client:"
WANT = "music=2 books=1 films=1 podcasts=1 places=1 food=1 interests=1"


class Capture(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


async def run_batches(batches):
    """Run enrich_batch once per seed list on ONE service; return the logged lines."""
    base._RealAsyncClient = httpx.AsyncClient
    rec = base.Recorder([])
    cap = Capture()
    lg = logging.getLogger("src.enricher")
    lg.addHandler(cap)
    lg.setLevel(logging.DEBUG)
    try:
        with mock.patch.object(Enricher, "_consent_or_log", staticmethod(lambda ep: True)), \
             mock.patch.object(Enricher, "__init__", lambda self: base._init(self, rec)), \
             mock.patch.object(Enricher, "_osm_cuisine", property(lambda self: rec), create=True), \
             mock.patch.object(Enricher, "_foursquare", property(lambda self: rec), create=True), \
             mock.patch.object(Enricher, "_google_places", property(lambda self: rec), create=True), \
             mock.patch.object(Enricher, "_check_already_enriched", mock.AsyncMock(return_value=False)), \
             mock.patch.object(Enricher, "_store_enrichment", mock.AsyncMock(return_value=True)), \
             mock.patch.object(httpx, "AsyncClient", base._StoreClient):
            e = Enricher()
            for seed in batches:
                await e.enrich_batch([dict(p) for p in seed], Enricher_stats())
    finally:
        lg.removeHandler(cap)
    return cap.lines


def Enricher_stats():
    from src.enricher import EnrichmentStats
    return EnrichmentStats()


def judge(lines):
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "enrich.log"
        f.write_text("\n".join("2026-11-18 INFO " + ln for ln in lines) + "\n")
        r = subprocess.run([sys.executable, "-I", str(JUDGE), "enrich", str(f)],
                           capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def per_client(lines):
    return [ln for ln in lines if ln.startswith(PREFIX)]


def main() -> int:
    fails = []
    try:
        lines = asyncio.run(run_batches([SEED]))
        no_pod = [p for p in SEED if p["category"] != "podcast"]
        lines_d = asyncio.run(run_batches([no_pod]))
        lines_f = asyncio.run(run_batches([SEED, SEED]))
    except Exception as exc:  # noqa: BLE001
        print(f"CANNOT-RUN: enrich_batch failed to run: {exc!r}")
        return 2

    got = per_client(lines)
    print("emitted:", got)
    if len(got) != 1 or got[0] != f"{PREFIX} {WANT}":
        fails.append(f"A: expected exactly one line '{PREFIX} {WANT}', got {got}")
    leaked = [s["subject"] for s in SEED if any(s["subject"] in ln for ln in lines)]
    if leaked:
        fails.append(f"B: seed subjects appear in the log: {len(leaked)}")
    rc, out = judge(lines)
    print("judge on real log ->", rc, out.splitlines()[-1] if out else "")
    if rc != 0:
        fails.append(f"C: judge on the real emitted log gave rc {rc}, wanted 0 (PASS)")
    got_d = per_client(lines_d)
    print("emitted (no podcast item):", got_d)
    if len(got_d) != 1 or "podcasts=0" not in got_d[0]:
        fails.append(f"D: podcast-less seed should log podcasts=0, got {got_d}")
    rc_d, out_d = judge(lines_d)
    print("judge on zero-client real log ->", rc_d, out_d.splitlines()[-1] if out_d else "")
    if rc_d != 1:
        fails.append(f"D: judge on a zero-client real log gave rc {rc_d}, wanted 1 (FAIL)")
    if not got or "podcasts=1" not in got[0]:  # seed has two podcasts, one L2
        fails.append("E: the L2 podcast was counted (or no line)")
    got_f = per_client(lines_f)
    if len(got_f) != 2 or got_f[0] != got_f[1]:
        fails.append(f"F: two identical batches must log identical deltas, got {got_f}")
    for f in fails:
        print("FAIL " + f)
    print("PASS" if not fails else f"FAIL ({len(fails)} assertion(s))")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
