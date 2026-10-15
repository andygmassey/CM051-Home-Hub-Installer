#!/usr/bin/env python3
"""A play is a listen, not a like. (CM051, Andy's v1.0.107 candidate #28 walk)

THE DEFECT. Every one of the 51,808 music preferences on the walk box was
"Like". Two layers did it:

  1. the CM019 parsers stamped preference_type="Like" on every PLAY (Spotify
     streaming history, Apple Music play activity / play history / daily
     tracks / top content / container rows, and a library track the owner
     never loved, rated or put in a playlist);
  2. the frequency filter then re-derived the type from the SIGN of the
     strength, so any positive row came out "Like" whatever the parser said.

THE FIX. Plays keep their play count and strength, under their own kind,
"Listen" (pwg:ListenPreference in the graph). "Like" is kept for what the
owner said: a saved or loved track, a playlist they made, a star rating, a
followed artist. When the same track has both, the explicit kind wins.

The front page reader (vendored CM059 interest_profile) must still read the
listens, or Music would vanish from the front page: that is asserted too.

Drives the SHIPPED vendor/cm019_preferences parsers + filters.py and the
SHIPPED vendor/cm059_editor projector + reader, on synthetic data only.
"""
from __future__ import annotations

import asyncio
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm019_preferences"))
sys.path.insert(0, str(ROOT / "vendor" / "cm059_editor"))

from services.ingest.src.filters import PreferenceFilter  # noqa: E402
from services.ingest.src.parsers.apple import AppleParser  # noqa: E402
from services.ingest.src.parsers.apple_music_library import (  # noqa: E402
    AppleMusicLibraryParser,
)
from services.ingest.src.parsers.base import ParsedPreference  # noqa: E402
from services.ingest.src.parsers.spotify import SpotifyParser  # noqa: E402

NOW = datetime.now(timezone.utc)


def _collect(agen):
    async def run():
        return [p async for p in agen]
    return asyncio.run(run())


def _ts(days_ago: int) -> str:
    return (NOW - timedelta(days=days_ago)).strftime("%Y-%m-%d %H:%M")


# ── synthetic fixtures (no real artist, title or person) ──────────────────

def _spotify_dir(tmp_path: Path) -> Path:
    d = tmp_path / "my_spotify_data"
    d.mkdir()
    plays = [
        {"endTime": _ts(i + 1), "artistName": "fixture-band",
         "trackName": "played-only-song", "msPlayed": 200000}
        for i in range(12)
    ] + [
        {"endTime": _ts(i + 1), "artistName": "fixture-band",
         "trackName": "saved-and-played-song", "msPlayed": 200000}
        for i in range(5)
    ]
    (d / "StreamingHistory_music_0.json").write_text(json.dumps(plays))
    (d / "YourLibrary.json").write_text(json.dumps({
        "tracks": [{"artist": "fixture-band", "track": "saved-and-played-song",
                    "album": "fixture-album", "uri": "spotify:track:fixture1"}],
    }))
    return d


def _apple_csvs(tmp_path: Path) -> Path:
    d = tmp_path / "apple_export"
    d.mkdir()
    ms = int((NOW - timedelta(days=3)).timestamp() * 1000)
    rows = ["Track Name,Last Played Date,Is User Initiated"]
    rows += [f"sample-tune,{ms},true"] * 7
    (d / "Apple Music - Track Play History.csv").write_text("\n".join(rows) + "\n")
    (d / "Apple Music - Favorites.csv").write_text(
        "Favorite Type,Item Reference,Item Description,Last Modified,Preference\n"
        f"Song,1,sample-loved-tune,{(NOW - timedelta(days=2)).isoformat()},LIKE\n"
    )
    return d


def _library_export(tmp_path: Path) -> Path:
    p = tmp_path / "ostler_apple_music_library.json"
    p.write_text(json.dumps({
        "source": "apple_music_library",
        "reader": "fixture",
        "tracks": [
            {"id": "L1", "title": "library-played-only", "artist": "sample-ensemble",
             "play_count": 300, "last_played": "2026-10-01T08:00:00Z"},
            {"id": "L2", "title": "library-loved", "artist": "sample-ensemble",
             "play_count": 4, "loved": True},
            {"id": "L3", "title": "library-in-my-playlist", "artist": "sample-ensemble",
             "play_count": 2, "in_user_playlist": True},
            {"id": "L4", "title": "library-five-stars", "artist": "sample-ensemble",
             "play_count": 1, "rating": 100},
            {"id": "L5", "title": "library-disliked", "artist": "sample-ensemble",
             "play_count": 9, "disliked": True},
        ],
    }))
    return p


def _by_subject(prefs):
    return {p.subject: p for p in prefs}


# ── 1. the parsers ─────────────────────────────────────────────────────────

def test_spotify_streaming_plays_are_listens(tmp_path):
    d = _spotify_dir(tmp_path)
    rows = _collect(SpotifyParser().parse(d / "StreamingHistory_music_0.json", 2))
    kinds = {p.preference_type for p in rows}
    print(f"spotify plays: {len(rows)} rows, kinds={sorted(kinds)}")
    assert len(rows) == 17
    assert kinds == {"Listen"}
    assert all(p.strength > 0 for p in rows)


def test_spotify_saved_track_is_still_a_like(tmp_path):
    d = _spotify_dir(tmp_path)
    rows = _collect(SpotifyParser().parse(d / "YourLibrary.json", 2))
    assert [p.preference_type for p in rows] == ["Like"]


def test_apple_play_history_is_a_listen_and_favourite_is_a_like(tmp_path):
    d = _apple_csvs(tmp_path)
    plays = _collect(AppleParser()._parse_csv(d / "Apple Music - Track Play History.csv", 2))
    favs = _collect(AppleParser()._parse_csv(d / "Apple Music - Favorites.csv", 2))
    print(f"apple plays kinds={[p.preference_type for p in plays]} "
          f"favourites kinds={[p.preference_type for p in favs]}")
    assert [p.preference_type for p in plays] == ["Listen"]
    assert plays[0].extra["play_count"] == 7
    assert [p.preference_type for p in favs] == ["Like"]


def test_apple_music_library_reserves_like_for_what_the_owner_said(tmp_path):
    rows = _by_subject(_collect(AppleMusicLibraryParser().parse(_library_export(tmp_path), 2)))
    got = {s.split(" - ", 1)[1]: (p.preference_type, p.extra["evidence"]) for s, p in rows.items()}
    print(f"library kinds: {got}")
    assert got["library-played-only"] == ("Listen", "library")
    assert got["library-loved"][0] == "Like"
    assert got["library-in-my-playlist"][0] == "Like"
    assert got["library-five-stars"][0] == "Like"
    assert got["library-disliked"][0] == "Dislike"
    # the play count is kept, not thrown away with the label
    assert rows["sample-ensemble - library-played-only"].extra["play_count"] == 300


# ── 2. the frequency filter must not relabel a listen as a like ────────────

def _aggregate(rows):
    f = PreferenceFilter(enable_dedup=True, aggregate_frequency=True)
    for r in rows:
        f.is_duplicate(r)
    return _by_subject(f.get_aggregated_preferences())


def test_aggregated_plays_stay_listens(tmp_path):
    d = _spotify_dir(tmp_path)
    plays = _collect(SpotifyParser().parse(d / "StreamingHistory_music_0.json", 2))
    out = _aggregate(plays)
    p = out["fixture-band - played-only-song"]
    print(f"aggregated: type={p.preference_type} freq={p.extra['frequency']} "
          f"strength={p.strength:.4f}")
    assert p.preference_type == "Listen"
    assert p.extra["frequency"] == 12
    assert p.strength > 0.10  # play count still raises strength


@pytest.mark.parametrize("library_first", [True, False])
def test_an_explicit_save_wins_over_plays_whatever_the_file_order(tmp_path, library_first):
    d = _spotify_dir(tmp_path)
    plays = _collect(SpotifyParser().parse(d / "StreamingHistory_music_0.json", 2))
    saved = _collect(SpotifyParser().parse(d / "YourLibrary.json", 2))
    rows = (saved + plays) if library_first else (plays + saved)
    out = _aggregate(rows)
    p = out["fixture-band - saved-and-played-song"]
    print(f"library_first={library_first}: type={p.preference_type} "
          f"base={p.extra['base_strength']} freq={p.extra['frequency']}")
    assert p.preference_type == "Like"
    assert p.extra["base_strength"] == pytest.approx(0.40)
    assert p.extra["frequency"] == 6
    assert out["fixture-band - played-only-song"].preference_type == "Listen"


def test_an_explicit_dislike_wins_over_plays():
    listen = ParsedPreference(subject="fixture-band - skipped-song", preference_type="Listen",
                              category="music", strength=0.10, source="spotify",
                              observed_at=NOW)
    dislike = ParsedPreference(subject="fixture-band - skipped-song", preference_type="Dislike",
                               category="music", strength=-0.45, source="spotify",
                               observed_at=NOW)
    out = _aggregate([listen, listen, dislike])
    assert out["fixture-band - skipped-song"].preference_type == "Dislike"
    assert out["fixture-band - skipped-song"].strength < 0


def test_a_like_is_never_downgraded_by_later_plays():
    like = ParsedPreference(subject="fixture-band - saved", preference_type="Like",
                            category="music", strength=0.40, source="spotify")
    listen = ParsedPreference(subject="fixture-band - saved", preference_type="Listen",
                              category="music", strength=0.10, source="spotify")
    out = _aggregate([like, listen, listen])
    assert out["fixture-band - saved"].preference_type == "Like"
    assert out["fixture-band - saved"].extra["base_strength"] == pytest.approx(0.40)


# ── 3. the graph and the front page still see the listens ─────────────────

def test_a_listen_is_written_to_the_graph_as_a_listen():
    p = ParsedPreference(subject="fixture-band - song", preference_type="Listen",
                         category="music", strength=0.3, source="spotify")
    ttl = p.to_turtle("owner")
    assert " a pwg:ListenPreference ;" in ttl
    assert "LikePreference" not in ttl


def test_the_projector_carries_listens_into_the_graph():
    from compiler import project_preferences as pp
    pts = [{"id": "fixture-1", "payload": {
        "preference_type": "Listen", "subject": "fixture-band - song",
        "category": "music", "strength": 0.3, "source": "spotify"}}]
    lines, skipped = pp.to_triples(pts)
    print(f"projector: {len(lines)} lines, {skipped} skipped")
    assert skipped == 0
    assert any(l.endswith(f"<{pp.PWG_NS}ListenPreference> .") for l in lines)


def test_the_front_page_reader_reads_listens_as_positive(monkeypatch):
    from compiler import interest_profile as ip
    asked = []

    def fake_select(url, query):
        asked.append(query)
        if "pwg:ListenPreference" in query:
            return [{"subject": "fixture-band - song", "category": "music",
                     "strength": "0.3", "source": "spotify"}]
        return []

    monkeypatch.setattr(ip, "_sparql_select", fake_select)
    rows = ip.fetch_preferences("http://fixture.invalid")
    print(f"reader asked {len(asked)} queries, got {len(rows)} rows")
    assert [r["polarity"] for r in rows] == ["listen"]
    assert rows[0]["polarity"] != "dislike"
