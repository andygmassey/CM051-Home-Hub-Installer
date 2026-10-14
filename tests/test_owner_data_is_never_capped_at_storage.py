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
    _write_history(tmp_path, 50000)
    pipe, res, _, secs = _ingest(tmp_path, monkeypatch)
    n = len(pipe.qdrant.points)
    print(f"\nMEASURE items=50000 stored={n} ingest_s={secs:.2f} "
          f"payload_bytes={pipe.qdrant.payload_bytes} triples_bytes={pipe.oxigraph.triples_bytes}")
    assert n == 50000


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
