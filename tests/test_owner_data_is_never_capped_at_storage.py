#!/usr/bin/env python3
"""The owner's whole library is stored, for every source. (CM051 #28)

Andy, 2026-10-14: "That's not good enough. Need everything."

THE DEFECT. PreferenceFilter.MAX_PREFS_PER_SOURCE = 5000, applied by
cap_by_source on both ingest paths (pipeline.py ingest_file_with_aggregation and
_ingest_directory_with_aggregation), stored at most 5000 preferences per source.
A 12,000-track listening history stored 5000; the other 7000 were logged and
gone.

WHAT THIS DRIVES: the SHIPPED vendor/cm019_preferences pipeline, end to end
through the real SpotifyParser on a synthetic StreamingHistory export, with the
two stores replaced by in-memory fakes that record every write. No real
listening data.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm019_preferences"))

from services.ingest.src import pipeline as pl  # noqa: E402
from services.ingest.src.filters import PreferenceFilter  # noqa: E402

TOP_PLAYED = 50   # the first TOP_PLAYED tracks are played more, most-played first


class _Qdrant:
    def __init__(self):
        self.points = {}
        self.payload_bytes = 0

    async def upsert_vectors(self, vectors, payloads, ids):
        for i, p in zip(ids, payloads):
            self.points[i] = p
            self.payload_bytes += len(json.dumps(p, default=str))
        return True

    async def delete_by_user(self, *a, **k):  # pragma: no cover
        raise AssertionError("ingest must never delete")


class _Oxigraph:
    def __init__(self):
        self.triples_bytes = 0

    async def insert_triples(self, ttl, graph=None):
        self.triples_bytes += len(ttl)
        return True


def _write_history(root: Path, n_tracks: int) -> Path:
    """A synthetic Spotify StreamingHistory with n_tracks distinct tracks.
    Track k < TOP_PLAYED is played (TOP_PLAYED - k + 1) times, so track 0 is
    the most played; every other track is played once."""
    d = root / "my_spotify_data"
    d.mkdir(parents=True)
    base = datetime(2026, 9, 1)
    rows = []
    for k in range(n_tracks):
        plays = (TOP_PLAYED - k + 1) if k < TOP_PLAYED else 1
        for p in range(plays):
            rows.append({
                "endTime": (base - timedelta(minutes=k * 7 + p)).strftime("%Y-%m-%d %H:%M"),
                "artistName": f"artist-k{k % 997}",
                "trackName": f"track-k{k}",
                "msPlayed": 200000,
            })
    path = d / "StreamingHistory_music_0.json"
    path.write_text(json.dumps(rows))
    return d


def _ingest(root: Path, monkeypatch, cap=None):
    pipe = pl.IngestPipeline()
    pipe.qdrant, pipe.oxigraph = _Qdrant(), _Oxigraph()
    if cap is not None:
        monkeypatch.setattr(PreferenceFilter, "MAX_PREFS_PER_SOURCE", cap)
    monkeypatch.setattr(pl.vectorizer, "embed_batch", lambda texts: [[0.0] * 4 for _ in texts])
    order = []
    real = pipe._process_batch

    async def spy(batch, user_id):
        order.extend(p.subject for p in batch)
        return await real(batch, user_id)
    pipe._process_batch = spy
    t0 = time.perf_counter()
    res = asyncio.run(pipe.ingest_directory(root, user_id="fixture"))
    return pipe, res, order, time.perf_counter() - t0


def test_a_12000_item_source_stores_12000(tmp_path, monkeypatch):
    _write_history(tmp_path, 12000)
    pipe, res, order, _ = _ingest(tmp_path, monkeypatch)
    spotify = [p for p in pipe.qdrant.points.values() if p["source"] == "spotify"]
    print(f"stored={len(spotify)} capped={res.get('total_capped')}")
    assert len(spotify) == 12000, f"stored {len(spotify)} of 12000"
    assert res.get("total_capped", 0) == 0


def test_the_top_of_the_order_is_what_the_cap_used_to_keep(tmp_path, monkeypatch):
    """Ranking is unchanged: the first 5000 rows written with no cap are,
    in order, exactly the 5000 the old cap kept; the most-played lead."""
    _write_history(tmp_path, 12000)
    _, _, uncapped, _ = _ingest(tmp_path, monkeypatch)
    _, _, capped, _ = _ingest(tmp_path, monkeypatch, cap=5000)
    assert len(capped) == 5000
    assert uncapped[:5000] == capped
    # the most-played tracks lead, most-played first
    assert [s.split(" - ")[1] for s in uncapped[:TOP_PLAYED]] == [f"track-k{k}" for k in range(TOP_PLAYED)]


def test_no_shipped_cap_remains():
    assert PreferenceFilter.MAX_PREFS_PER_SOURCE is None


@pytest.mark.skipif(os.environ.get("OSTLER_MEASURE_50K") != "1",
                    reason="measurement run, set OSTLER_MEASURE_50K=1")
def test_measure_50000(tmp_path, monkeypatch):
    _write_history(tmp_path / "in", 50000)
    pipe, res, _, secs = _ingest(tmp_path / "in", monkeypatch)
    n = len(pipe.qdrant.points)
    print(f"\nMEASURE items=50000 stored={n} ingest_s={secs:.2f} "
          f"payload_bytes={pipe.qdrant.payload_bytes} triples_bytes={pipe.oxigraph.triples_bytes}")
    assert n == 50000


@pytest.mark.skipif(os.environ.get("OSTLER_MEASURE_INSTALL") != "1",
                    reason="measurement run, set OSTLER_MEASURE_INSTALL=1")
def test_measure_install_path_50000(tmp_path, monkeypatch):
    """The INSTALL path on a 50,000-row source, embedding modelled at 1 ms per
    text. Same harness runs on origin/main (built-in 5000 cap; the env vars
    are ignored there) and on this branch (foreground 5000 + queued tail)."""
    _write_history(tmp_path / "in", 50000)
    monkeypatch.setenv("OSTLER_PREFS_FOREGROUND_PER_SOURCE", "5000")
    monkeypatch.setenv("OSTLER_PREFS_TAIL_QUEUE", str(tmp_path / "queue"))

    def slow_embed(texts):
        time.sleep(0.001 * len(texts))
        return [[0.0] * 4 for _ in texts]
    monkeypatch.setattr(pl.vectorizer, "embed_batch", slow_embed)
    pipe = pl.IngestPipeline()
    pipe.qdrant, pipe.oxigraph = _Qdrant(), _Oxigraph()
    t0 = time.perf_counter()
    asyncio.run(pipe.ingest_directory(tmp_path / "in", user_id="fixture"))
    secs = time.perf_counter() - t0
    q = sum(1 for _ in (tmp_path / "queue").glob("*.jsonl")) if (tmp_path / "queue").exists() else 0
    print(f"\nINSTALL items=50000 foreground_stored={len(pipe.qdrant.points)} queue_files={q} wall_s={secs:.2f}")


# ── Archie's condition: foreground bounded, tail drained in the background ──

def _foreground(tmp_path, monkeypatch, n=12000):
    src = tmp_path / "in"
    _write_history(src, n)
    q = tmp_path / "queue"
    monkeypatch.setenv("OSTLER_PREFS_FOREGROUND_PER_SOURCE", "5000")
    monkeypatch.setenv("OSTLER_PREFS_TAIL_QUEUE", str(q))
    pipe, res, order, _ = _ingest(src, monkeypatch)
    return pipe, res, order, q


def test_foreground_stores_the_same_top_5000_and_queues_the_rest(tmp_path, monkeypatch):
    from services.ingest.src import tail_queue
    pipe, res, order, q = _foreground(tmp_path, monkeypatch)
    assert len(pipe.qdrant.points) == 5000 and res["total_queued"] == 7000
    assert tail_queue.pending(q) == 7000
    # the same 5000, in the same order, the old cap kept
    monkeypatch.delenv("OSTLER_PREFS_FOREGROUND_PER_SOURCE")
    _, _, capped, _ = _ingest(tmp_path / "in", monkeypatch, cap=5000)
    assert order == capped


def test_after_the_drain_the_store_holds_every_row(tmp_path, monkeypatch):
    from services.ingest.src import tail_queue
    pipe, _, _, q = _foreground(tmp_path, monkeypatch)
    out = asyncio.run(tail_queue.drain(pipe, q, budget_seconds=600))
    print(f"drain={out} stored={len(pipe.qdrant.points)}")
    assert out["written"] == 7000 and out["remaining"] == 0
    assert len(pipe.qdrant.points) == 12000
    assert not list(q.glob("*"))


def test_a_queue_that_cannot_be_written_stores_everything_now(tmp_path, monkeypatch):
    blocker = tmp_path / "not-a-dir"
    blocker.write_text("x")
    _write_history(tmp_path / "in", 6000)
    monkeypatch.setenv("OSTLER_PREFS_FOREGROUND_PER_SOURCE", "5000")
    monkeypatch.setenv("OSTLER_PREFS_TAIL_QUEUE", str(blocker / "queue"))
    pipe, res, _, _ = _ingest(tmp_path / "in", monkeypatch)
    assert len(pipe.qdrant.points) == 6000 and res["total_queued"] == 0


_CHILD = r"""
import asyncio, json, sys, time
sys.path.insert(0, sys.argv[1])
from services.ingest.src import pipeline as pl, tail_queue
from pathlib import Path
log = open(sys.argv[3], "a", buffering=1)
class Q:
    async def upsert_vectors(self, vectors, payloads, ids):
        for i, p in zip(ids, payloads):
            log.write(f"{i}\t{p['created_at']}\n")
        return True
class O:
    async def insert_triples(self, ttl, graph=None):
        return True
def emb(texts):
    time.sleep(0.02)
    return [[0.0] * 4 for _ in texts]
pl.vectorizer.embed_batch = emb
p = pl.IngestPipeline(); p.qdrant, p.oxigraph = Q(), O()
print(json.dumps(asyncio.run(tail_queue.drain(p, Path(sys.argv[2]), budget_seconds=600))))
"""


def test_the_drain_survives_a_kill_mid_tail_with_no_duplicates(tmp_path, monkeypatch):
    import signal
    import subprocess
    from services.ingest.src import tail_queue
    _, _, _, q = _foreground(tmp_path, monkeypatch)
    rows = [json.loads(l) for f in q.glob("*.jsonl") for l in f.read_text().splitlines()[1:]]
    want = {r["id"]: r["created_at"] for r in rows}
    assert len(want) == 7000
    child, log = tmp_path / "child.py", tmp_path / "upserts.log"
    child.write_text(_CHILD)
    argv = [sys.executable, str(child), str(ROOT / "vendor" / "cm019_preferences"), str(q), str(log)]

    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.time() + 60
    while time.time() < deadline and (not log.exists() or log.read_text().count("\n") < 1000):
        time.sleep(0.05)
    proc.send_signal(signal.SIGKILL)
    proc.wait(timeout=10)
    killed_at = log.read_text().count("\n")
    left = tail_queue.pending(q)
    print(f"killed after {killed_at} upserts, {left} pending")
    assert proc.returncode == -signal.SIGKILL and 0 < left < 7000

    done = subprocess.run(argv, capture_output=True, text=True, timeout=300)
    assert done.returncode == 0, done.stderr[-2000:]
    lines = [l.split("\t") for l in log.read_text().splitlines()]
    seen = {}
    for i, created in lines:
        assert want[i] == created, "a rewritten row changed (not idempotent)"
        seen[i] = seen.get(i, 0) + 1
    rewrites = sum(n - 1 for n in seen.values())
    print(f"after restart: {len(seen)} distinct ids, {len(lines)} upserts, {rewrites} idempotent rewrite(s)")
    assert set(seen) == set(want)
    assert rewrites <= 32          # at most the one batch in flight at the kill
    assert tail_queue.pending(q) == 0 and not list(q.glob("*.jsonl"))


def test_apple_music_records_keep_every_artist_and_genre():
    """ostler_fda.apple_music.to_records kept the top 200 artists and top 100
    genres of the owner's library and dropped the rest."""
    sys.path.insert(0, str(ROOT / "vendor"))
    from ostler_fda import apple_music as am
    lib = am.MusicLibrary(tracks=[
        am.Track(str(i), f"track-k{i}", f"artist-k{i}", None, f"genre-k{i}", i % 7, None, None, False)
        for i in range(450)])
    recs = am.to_records(lib)
    kinds = {t: sum(1 for r in recs if r["type"] == t) for t in ("music_artist", "music_genre")}
    assert kinds == {"music_artist": 450, "music_genre": 450}, kinds
    # still ranked: the most-played artist leads
    artists = [r for r in recs if r["type"] == "music_artist"]
    assert artists[0]["total_plays"] == max(a["total_plays"] for a in artists)


@pytest.mark.parametrize("title", [
    "composer-k1 - Symphony No. 9 in D minor, Op. 125: IV. Presto - Allegro assai - Allegro moderato",
    "band-k2 - Click Here",
    "band-k3 - Your Order",
])
def test_a_long_or_odd_music_title_is_kept(title):
    from services.ingest.src.parsers.base import ParsedPreference
    f = PreferenceFilter()
    assert not f.is_low_value(ParsedPreference(subject=title, category="music", source="apple_music"))


def test_the_prose_gate_still_drops_prose_outside_music():
    from services.ingest.src.parsers.base import ParsedPreference
    f = PreferenceFilter()
    prose = "I had the pleasure of working with them for many years on a great many projects"
    assert f.is_low_value(ParsedPreference(subject=prose, category="recommendation", source="linkedin"))
    # the artifact checks still apply to music
    assert f.is_low_value(ParsedPreference(subject="band - https://example.invalid/x", category="music", source="s"))


# ── no parser keeps only a top-N of what it yields as preferences ─────────
import ast  # noqa: E402

PARSERS = ROOT / "vendor/cm019_preferences/services/ingest/src/parsers"


def _top_n_yield_loops(src: str):
    """(line, shape) for every `for` loop that YIELDS ParsedPreference while
    iterating `x.most_common(<int>)` or `x[:<int>]`: a top-N storage cap."""
    hits = []
    for node in ast.walk(ast.parse(src)):
        if not isinstance(node, (ast.For, ast.AsyncFor)):
            continue
        it = node.iter
        capped = (
            (isinstance(it, ast.Call) and isinstance(it.func, ast.Attribute)
             and it.func.attr == "most_common" and it.args
             and isinstance(it.args[0], ast.Constant))
            or (isinstance(it, ast.Subscript) and isinstance(it.slice, ast.Slice)
                and it.slice.lower is None and isinstance(it.slice.upper, ast.Constant))
        )
        if not capped:
            continue
        yields = any(
            isinstance(n, (ast.Yield,)) and isinstance(n.value, ast.Call)
            and getattr(n.value.func, "id", "") == "ParsedPreference"
            for b in node.body for n in ast.walk(b))
        if yields:
            hits.append((node.lineno, ast.unparse(it)))
    return hits


def test_the_top_n_detector_fires_on_both_shapes():
    bad = ("def f(c, xs):\n"
           "    for k, n in c.most_common(20):\n        yield ParsedPreference(subject=k)\n"
           "    for x in xs[:50]:\n        yield ParsedPreference(subject=x)\n"
           "    for k, n in c.most_common():\n        yield ParsedPreference(subject=k)\n")
    assert [s for _, s in _top_n_yield_loops(bad)] == ["c.most_common(20)", "xs[:50]"]


def test_no_preference_parser_keeps_only_a_top_n():
    found = {}
    for p in sorted(PARSERS.glob("*.py")):
        hits = _top_n_yield_loops(p.read_text())
        if hits:
            found[p.name] = hits
    assert not found, f"top-N preference caps: {found}"


def test_install_wires_the_foreground_bound_and_the_drain():
    """install.sh sets the bound on the install-time import ONLY, and the
    default-on export-scan agent drains the queue before looking for exports."""
    sh = (ROOT / "install.sh").read_text()
    imp = sh.index('"$IMPORT_SCRIPT" "${_IMPORT_DIRS[@]}"')
    assert 'OSTLER_PREFS_FOREGROUND_PER_SOURCE="${OSTLER_PREFS_FOREGROUND_PER_SOURCE:-5000}"' in sh[imp - 400:imp]
    assert 'OSTLER_PREFS_TAIL_QUEUE="${OSTLER_DIR}/state/prefs-tail"' in sh[imp - 400:imp]
    scan = sh[sh.index("cat > \"${OSTLER_DIR}/bin/ostler-scan-exports\" <<'SCANEOF'"):sh.index("\nSCANEOF\n")]
    drain_at = scan.index("services.ingest.src.cli ingest-tail")
    assert drain_at < scan.index("FOUND=()"), "the drain must run before the new-export early exits"
    assert sh.count("OSTLER_PREFS_FOREGROUND_PER_SOURCE=") == 1, "the bound is for the install import only"
