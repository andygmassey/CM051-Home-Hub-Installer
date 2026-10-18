#!/usr/bin/env python3
"""A play is not a like (Ostler #30 console walk, 2026-10-15).

THE DEFECT. 51,808 Apple music items were ALL "like", 0 dislike, 0 neutral:
every play row was written preference_type "Like" and the aggregated type was
derived from the sign of the strength, which a passive play always has.

THE RULE. Explicit love/like -> Like. Explicit dislike -> Dislike. Plays only ->
Neutral, with the strength and play_count UNCHANGED, so nothing is down-weighted
(Andy: weighting must be equitable, old data is not automatically down-weighted)
and Apple and Spotify are treated identically.

Synthetic data only.
"""
from __future__ import annotations

import asyncio
import csv
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm019_preferences"))
sys.path.insert(0, str(ROOT / "vendor" / "cm059_editor"))

from services.ingest.src.filters import PreferenceFilter  # noqa: E402
from services.ingest.src.parsers.apple import AppleParser  # noqa: E402
from services.ingest.src.parsers.base import ParsedPreference  # noqa: E402

NOW = datetime.now(timezone.utc)


def _parse(tmp_path, rows, name):
    path = tmp_path / name
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    p = AppleParser()
    assert p.can_parse(path)

    async def go():
        return [x async for x in p.parse(path, default_compartment=2)]
    return asyncio.run(go())


def _aggregate(rows):
    f = PreferenceFilter(enable_dedup=True, aggregate_frequency=True)
    for r in rows:
        f.is_duplicate(r)
    return f.get_aggregated_preferences()


def _plays(song, n=3):
    return [{"Song Name": song, "Album Name": "fixture-album",
             "Event Timestamp": (NOW - timedelta(days=i)).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "Event Type": "PLAY_END", "Play Duration Milliseconds": "200000"}
            for i in range(n)]


def test_apple_play_only_tracks_are_neutral_not_like(tmp_path):
    prefs = _parse(tmp_path, _plays("fixture-song"), "Apple Music Play Activity.csv")
    out = _aggregate(prefs)
    assert [p.preference_type for p in out] == ["Neutral"], [p.preference_type for p in out]
    # not down-weighted: strength is still the positive passive-play strength
    assert out[0].strength > 0 and out[0].extra["frequency"] == 3


def test_apple_and_spotify_plays_are_treated_identically():
    spot = [ParsedPreference(subject="fixture-band - song", category="music", strength=0.10,
                             source="spotify", preference_type="Like",
                             observed_at=NOW - timedelta(days=i)) for i in range(3)]
    # the SHIPPED spotify parser path: exercise its constructor site via a stream row
    import asyncio as aio
    import json
    import tempfile
    from services.ingest.src.parsers.spotify import SpotifyParser
    row = [{"ts": (NOW - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"), "ms_played": 200000,
            "master_metadata_track_name": "song", "master_metadata_album_artist_name": "fixture-band",
            "master_metadata_album_album_name": "album", "spotify_track_uri": "spotify:track:x",
            "skipped": False}]
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "Streaming_History_Audio_2026.json"
        p.write_text(json.dumps(row))
        sp = SpotifyParser()
        assert sp.can_parse(p)

        async def go():
            return [x async for x in sp.parse(p, default_compartment=2)]
        got = aio.run(go())
    assert got and all(g.preference_type == "Neutral" for g in got if g.category == "music")
    assert [p.preference_type for p in _aggregate(spot)] == ["Like"]  # control: unflagged rows keep the old rule


def test_explicit_favourite_is_like_and_explicit_dislike_is_dislike(tmp_path):
    rows = [
        {"Favorite Type": "Song", "Item Reference": "1", "Item Description": "fixture-loved",
         "Last Modified": "2025-01-01T00:00:00.000Z", "Preference": "LIKE"},
        {"Favorite Type": "Song", "Item Reference": "2", "Item Description": "fixture-hated",
         "Last Modified": "2025-01-01T00:00:00.000Z", "Preference": "DISLIKE"},
        {"Favorite Type": "Song", "Item Reference": "3", "Item Description": "fixture-meh",
         "Last Modified": "2025-01-01T00:00:00.000Z", "Preference": "UNKNOWN_VALUE"},
    ]
    out = {p.subject: p for p in _aggregate(_parse(tmp_path, rows, "Apple Music - Favorites.csv"))}
    assert out["fixture-loved"].preference_type == "Like" and out["fixture-loved"].strength > 0
    assert out["fixture-hated"].preference_type == "Dislike" and out["fixture-hated"].strength < 0
    assert out["fixture-meh"].preference_type == "Neutral"


def test_explicit_like_beats_passive_plays_of_the_same_track():
    passive = ParsedPreference(subject="fixture-song", category="music", strength=0.10,
                               source="apple", preference_type="Neutral",
                               observed_at=NOW, extra={"play_count": 9, "passive_play": True})
    liked = ParsedPreference(subject="fixture-song", category="music", strength=0.85,
                             source="apple", preference_type="Like", observed_at=NOW)
    for order in ([passive, liked], [liked, passive]):
        out = _aggregate(order)
        assert [p.preference_type for p in out] == ["Like"], order


def test_neutral_survives_into_the_graph_and_the_profile():
    from compiler import project_preferences as pp
    pts = [{"id": "a", "payload": {"preference_type": "Neutral", "subject": "fixture-song",
                                    "category": "music", "strength": 0.1, "source": "apple"}}]
    lines, skipped = pp.to_triples(pts)
    assert skipped == 0 and any("NeutralPreference" in l for l in lines)
