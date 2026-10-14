#!/usr/bin/env python3
"""Apple Music: the live library is read without the XML setting, fails
open, and lands in the preference store additively. (CM051, walk #27)

THE DEFECT. vendor/ostler_fda/apple_music.py read ONLY
~/Music/iTunes/iTunes Music Library.xml, which the Music app writes only when
"Share Library XML with other applications" is ticked. The walk box had only
Music Library.musiclibrary, so the reader saw 0 tracks and every music
preference came from Spotify for an owner who mostly uses Apple Music.

WHAT THIS DRIVES, all on synthetic data (no real listening history):
  * the shipped reader (vendor/ostler_fda/apple_music.py) against fake
    helpers that answer the way the real helper answers in each state,
    INCLUDING the state measured on Mini16 over ssh with the permission
    absent (status unavailable, NSCocoaErrorDomain 4097, rc 0);
  * the shipped extract_all arm, end to end into the export file;
  * the shipped CM019 parser and pipeline (vendor/cm019_preferences), with
    the stores replaced by in-memory fakes that record every write, to show
    the writes are additive only.
"""
from __future__ import annotations

import asyncio
import json
import os
import stat
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor"))
sys.path.insert(0, str(ROOT / "vendor" / "cm019_preferences"))

from ostler_fda import apple_music  # noqa: E402

# ── synthetic fixture library ──────────────────────────────────────────────
# Neutral, obviously synthetic labels. No real artist, title or person.
FIXTURE_TRACKS = [
    {"id": "A1", "title": "Fixture Song One", "artist": "Fixture Band", "album": "Fixture Album",
     "genre": "Ambient", "play_count": 42, "skip_count": 1, "rating": 100, "loved": True,
     "last_played": "2026-10-01T08:00:00Z", "added": "2024-01-01T00:00:00Z", "kind": "song"},
    {"id": "A2", "title": "Fixture Song Two", "artist": "Fixture Band", "album": "Fixture Album",
     "genre": "Ambient", "play_count": 3, "skip_count": 0, "rating": 0,
     "last_played": "2025-06-01T08:00:00Z", "added": "2024-01-01T00:00:00Z", "kind": "song"},
    {"id": "A3", "title": "Sample Tune Three", "artist": "Sample Ensemble", "genre": "Jazz",
     "play_count": 0, "skip_count": 0, "rating": 20, "disliked": True,
     "added": "2023-05-05T00:00:00Z", "kind": "song"},
    {"id": "A4", "title": "Sample Tune Four", "artist": "Sample Ensemble", "genre": "Jazz",
     "play_count": 0, "skip_count": 0, "rating": 0, "added": "2026-09-09T00:00:00Z", "kind": "song"},
]
FIXTURE_PLAYLISTS = [
    {"name": "Fixture Mix", "smart": False, "track_ids": ["A2"]},
    {"name": "Top Rule List", "smart": True, "track_ids": ["A1"]},
]


def _helper(tmp_path: Path, body: str, name: str = "helper") -> Path:
    p = tmp_path / name
    p.write_text("#!/bin/sh\n" + body + "\n")
    p.chmod(p.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return p


def _json_helper(tmp_path: Path, payload: dict, rc: int = 0) -> Path:
    data = tmp_path / "payload.json"
    data.write_text(json.dumps(payload))
    return _helper(tmp_path, f"cat '{data}'\nexit {rc}")


OK_PAYLOAD = {"schema": 1, "status": "ok", "api_version": "1.1",
              "tracks": FIXTURE_TRACKS, "playlists": FIXTURE_PLAYLISTS}
# Byte-for-byte the shape the real helper printed on Mini16 over ssh, where
# tccd logged "Policy disallows prompt" for kTCCServiceMediaLibrary.
DENIED_PAYLOAD = {"schema": 1, "status": "unavailable", "detail": "itlibrary_init_failed",
                  "error_domain": "NSCocoaErrorDomain", "error_code": 4097}


@pytest.fixture(autouse=True)
def _no_ambient_library(monkeypatch, tmp_path):
    """No test may read the machine's real Music library or XML."""
    monkeypatch.delenv("OSTLER_MUSIC_LIBRARY_HELPER", raising=False)
    monkeypatch.setenv("OSTLER_MUSIC_LIBRARY_XML", str(tmp_path / "no-such-library.xml"))


# ── 1. FAIL-OPEN with the permission ABSENT (reviewer condition 1) ─────────

def test_permission_denied_is_empty_not_an_exception(tmp_path):
    lib = apple_music.extract_library(helper=_json_helper(tmp_path, DENIED_PAYLOAD))
    assert lib.tracks == [] and lib.playlists == []
    assert lib.native_status == "unavailable"
    assert lib.native_detail == "NSCocoaErrorDomain:4097"


def test_permission_denied_falls_back_to_the_xml_export(tmp_path, monkeypatch):
    import plistlib
    xml = tmp_path / "lib.xml"
    xml.write_bytes(plistlib.dumps({"Tracks": {"7": {
        "Track ID": 7, "Name": "Xml Fixture Song", "Artist": "Fixture Band",
        "Play Count": 2, "Kind": "MPEG audio file"}}, "Playlists": []}))
    monkeypatch.setenv("OSTLER_MUSIC_LIBRARY_XML", str(xml))
    lib = apple_music.extract_library(helper=_json_helper(tmp_path, DENIED_PAYLOAD))
    assert [t.name for t in lib.tracks] == ["Xml Fixture Song"]
    assert lib.reader == "xml" and lib.native_status == "unavailable"


@pytest.mark.parametrize("label,body,expect", [
    ("empty library", "echo '{\"schema\":1,\"status\":\"empty\"}'", "empty"),
    ("ok but zero songs", "echo '{\"schema\":1,\"status\":\"ok\",\"tracks\":[]}'", "empty"),
    ("garbage on stdout", "echo 'Segmentation fault'", "bad_output"),
    ("nothing on stdout, rc 1", "exit 1", "bad_output"),
    ("crash, rc 139", "kill -SEGV $$", "bad_output"),
    ("wrong schema", "echo '{\"schema\":99,\"status\":\"ok\"}'", "bad_output"),
    ("unknown status", "echo '{\"schema\":1,\"status\":\"maybe\"}'", "bad_output"),
])
def test_every_helper_failure_is_fail_open(tmp_path, label, body, expect):
    lib = apple_music.extract_library(helper=_helper(tmp_path, body))
    assert lib.tracks == [], label
    assert lib.native_status == expect, label


def test_a_hung_helper_is_bounded(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_MUSIC_LIBRARY_HELPER_TIMEOUT", "1")
    lib = apple_music.extract_library(helper=_helper(tmp_path, "exec sleep 30"))
    assert lib.tracks == [] and lib.native_status == "timeout"


def test_no_helper_and_no_xml_is_not_tried_and_empty(tmp_path):
    lib = apple_music.extract_library()
    assert lib.tracks == [] and lib.native_status == "not_tried" and lib.reader == "none"
    # A helper path that does not exist, or is not executable, is "not tried".
    noexec = tmp_path / "noexec"
    noexec.write_text("#!/bin/sh\necho hi\n")
    assert apple_music.extract_library(helper=tmp_path / "missing").native_status == "not_tried"
    assert apple_music.extract_library(helper=noexec).native_status == "not_tried"


def test_cli_exits_zero_and_writes_no_export_when_denied(tmp_path, capsys):
    out = tmp_path / "out"
    rc = apple_music.main(["--helper", str(_json_helper(tmp_path, DENIED_PAYLOAD)),
                           "--output-dir", str(out), "--json"])
    assert rc == 0
    status = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert status["status"] == "no_library" and status["native_status"] == "unavailable"
    assert not (out / apple_music.PREFERENCE_EXPORT_NAME).exists()


# ── 2. the native read itself ──────────────────────────────────────────────

def test_native_read_keeps_every_field(tmp_path):
    lib = apple_music.extract_library(helper=_json_helper(tmp_path, OK_PAYLOAD))
    assert lib.reader == "native" and lib.native_status == "ok"
    assert len(lib.tracks) == 4
    one = next(t for t in lib.tracks if t.track_id == "A1")
    assert one.play_count == 42 and one.rating == 100 and one.loved is True
    assert one.last_played.isoformat() == "2026-10-01T08:00:00+00:00"
    assert one.added.year == 2024 and one.skip_count == 1
    three = next(t for t in lib.tracks if t.track_id == "A3")
    assert three.disliked is True
    assert {p.name: p.smart for p in lib.playlists} == {"Fixture Mix": False, "Top Rule List": True}


def test_native_wins_over_a_present_xml(tmp_path, monkeypatch):
    import plistlib
    xml = tmp_path / "lib.xml"
    xml.write_bytes(plistlib.dumps({"Tracks": {"9": {"Track ID": 9, "Name": "Xml Only"}}}))
    monkeypatch.setenv("OSTLER_MUSIC_LIBRARY_XML", str(xml))
    lib = apple_music.extract_library(helper=_json_helper(tmp_path, OK_PAYLOAD))
    assert lib.reader == "native" and len(lib.tracks) == 4


def test_export_carries_evidence_and_curation(tmp_path):
    lib = apple_music.extract_library(helper=_json_helper(tmp_path, OK_PAYLOAD))
    path = apple_music.write_preference_export(lib, tmp_path / "out")
    data = json.loads(path.read_text())
    assert data["source"] == "apple_music_library" and data["reader"] == "native"
    rows = {r["id"]: r for r in data["tracks"]}
    assert rows["A2"]["in_user_playlist"] is True       # in a playlist they made
    assert rows["A1"]["in_user_playlist"] is False      # only in a SMART list
    assert rows["A1"]["play_count"] == 42 and rows["A3"]["disliked"] is True
    assert data["user_playlists"] == 1


def test_extract_all_arm_writes_the_export(tmp_path, monkeypatch):
    from ostler_fda import extract_all
    monkeypatch.setenv("OSTLER_MUSIC_LIBRARY_HELPER", str(_json_helper(tmp_path, OK_PAYLOAD)))
    out = tmp_path / "fda"
    summary = extract_all.run_all(out, enabled_sources={"apple_music"})
    am = summary["sources"]["apple_music"]
    assert am["status"] == "ok" and am["total_tracks"] == 4
    assert am["reader"] == "native" and am["native_status"] == "ok"
    assert (out / apple_music.PREFERENCE_EXPORT_NAME).is_file()


def test_extract_all_arm_is_ok_and_empty_when_denied(tmp_path, monkeypatch):
    from ostler_fda import extract_all
    monkeypatch.setenv("OSTLER_MUSIC_LIBRARY_HELPER", str(_json_helper(tmp_path, DENIED_PAYLOAD)))
    out = tmp_path / "fda"
    summary = extract_all.run_all(out, enabled_sources={"apple_music"})
    am = summary["sources"]["apple_music"]
    assert am["total_tracks"] == 0 and am["native_status"] == "unavailable"
    assert not (out / apple_music.PREFERENCE_EXPORT_NAME).exists()


# ── 3. the CM019 parser, on the same scale as Spotify ─────────────────────

def _parse(path: Path):
    from services.ingest.src.parsers.apple_music_library import AppleMusicLibraryParser
    p = AppleMusicLibraryParser()
    assert p.can_parse(path)

    async def go():
        return [x async for x in p.parse(path, default_compartment=2)]
    return asyncio.run(go())


def _export(tmp_path: Path) -> Path:
    lib = apple_music.extract_library(helper=_json_helper(tmp_path, OK_PAYLOAD))
    return apple_music.write_preference_export(lib, tmp_path / "prefs" / "apple_music")


def test_parser_scores_with_the_spotify_constants(tmp_path):
    prefs = {p.extra["track"]: p for p in _parse(_export(tmp_path))}
    assert len(prefs) == 4
    # loved + 5 stars: the strongest positive wins (5 stars = 0.55, Spotify's map)
    assert prefs["Fixture Song One"].strength == 0.55
    # in a playlist they made = 0.30 (Spotify playlist track)
    assert prefs["Fixture Song Two"].strength == 0.30
    # explicit dislike wins over everything = -0.45 (Spotify 1-star)
    assert prefs["Sample Tune Three"].strength == -0.45
    assert prefs["Sample Tune Three"].preference_type == "Dislike"
    # in the library, never played = 0.10 (Spotify passive play)
    assert prefs["Sample Tune Four"].strength == 0.10
    p1 = prefs["Fixture Song One"]
    assert p1.subject == "Fixture Band - Fixture Song One" and p1.category == "music"
    assert p1.source == "apple_music" and p1.extra["play_count"] == 42
    assert p1.observed_at.isoformat() == "2026-10-01T08:00:00+00:00"


def test_parser_claims_only_its_own_file(tmp_path):
    from services.ingest.src.parsers.apple_music_library import AppleMusicLibraryParser
    p = AppleMusicLibraryParser()
    assert not p.can_parse(tmp_path / "StreamingHistory0.json")
    assert not p.can_parse(tmp_path / "apple_music.json")
    from services.ingest.src.pipeline import IngestPipeline
    path = _export(tmp_path)
    assert type(IngestPipeline()._get_parser(path)).__name__ == "AppleMusicLibraryParser"


# ── 4. ADDITIVE ONLY (reviewer condition 4) ───────────────────────────────

class _FakeQdrant:
    def __init__(self, seed):
        self.points = dict(seed)
        self.deletes = 0

    async def initialize(self):
        return True

    async def upsert_vectors(self, vectors, payloads, ids):
        for i, pl in zip(ids, payloads):
            self.points[i] = pl
        return True

    async def delete_by_user(self, *a, **k):
        self.deletes += 1
        return True


class _FakeOxigraph:
    def __init__(self):
        self.inserts = []
        self.deletes = 0

    async def initialize(self):
        return True

    async def insert_triples(self, ttl, graph=None):
        self.inserts.append(ttl)
        return True


def test_ingest_is_additive_only(tmp_path, monkeypatch):
    from services.ingest.src import pipeline as pl
    seed = {
        "spotify-pref-1": {"source": "spotify", "subject": "Fixture Band - Fixture Song One",
                           "strength": 0.3, "category": "music"},
        "spotify-pref-2": {"source": "spotify", "subject": "Other Fixture - Track", "strength": 0.2,
                           "category": "music"},
        "person-row-1": {"source": "contacts", "subject": "person:fixture-1"},
        "email-pref-1": {"source": "email", "subject": "Fixture Newsletter", "strength": 0.4},
    }
    before = json.loads(json.dumps(seed))
    pipe = pl.IngestPipeline()
    pipe.qdrant = _FakeQdrant(seed)
    pipe.oxigraph = _FakeOxigraph()
    monkeypatch.setattr(pl.vectorizer, "embed_batch", lambda texts: [[0.0] * 4 for _ in texts])
    _export(tmp_path)

    res = asyncio.run(pipe.ingest_directory(tmp_path / "prefs", user_id="fixture"))
    after = pipe.qdrant.points
    print(f"before={len(before)} after={len(after)} added={len(after) - len(before)}")
    assert len(before) == 4
    assert len(after) == len(before) + 4, res
    for k, v in before.items():
        assert after[k] == v, f"existing row {k} was touched"
    new = {k: v for k, v in after.items() if k not in before}
    assert {v["source"] for v in new.values()} == {"apple_music"}
    assert pipe.qdrant.deletes == 0
    assert all("DELETE" not in t.upper() for t in pipe.oxigraph.inserts)
