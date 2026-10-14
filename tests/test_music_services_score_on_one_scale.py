#!/usr/bin/env python3
"""Every music service is scored on one scale, from plays and recency.
(CM051 walk #27, Andy 2026-10-14: no service is down-weighted; whichever one
the owner really uses leads.)

THE DEFECT. The CM019 frequency filter counted ROWS. Spotify writes one row per
play; a library export (Apple Music) writes one row per track carrying its play
count. So 42 Spotify plays scored frequency 42 and 42 Apple Music plays scored
frequency 1. And the recency used for decay was the FIRST row seen, so a
streaming history read oldest-first decayed every track to its first play.

Drives the SHIPPED vendor/cm019_preferences filters.py on synthetic
preferences (no real listening data).
"""
from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm019_preferences"))

from services.ingest.src.filters import PreferenceFilter  # noqa: E402
from services.ingest.src.parsers.base import ParsedPreference  # noqa: E402

NOW = datetime.now(timezone.utc)


def _play_rows(source, subject, plays, last, step_days=3):
    """One row per play, oldest first (how a streaming history reads)."""
    return [
        ParsedPreference(subject=subject, category="music", strength=0.10, source=source,
                         observed_at=last - timedelta(days=step_days * (plays - 1 - i)))
        for i in range(plays)
    ]


def _library_row(source, subject, plays, last):
    """One row per track carrying its play count (how a library reads)."""
    return [ParsedPreference(subject=subject, category="music", strength=0.10, source=source,
                             observed_at=last, extra={"play_count": plays})]


def _strengths(rows):
    f = PreferenceFilter(enable_dedup=True, aggregate_frequency=True)
    for r in rows:
        f.is_duplicate(r)
    return {(p.source, p.subject): p for p in f.get_aggregated_preferences()}


def test_same_plays_same_recency_same_strength_whichever_service():
    last = NOW - timedelta(days=10)
    out = _strengths(_play_rows("spotify", "fixture-band - song", 42, last)
                     + _library_row("apple_music", "fixture-band - other-song", 42, last))
    s = out[("spotify", "fixture-band - song")]
    a = out[("apple_music", "fixture-band - other-song")]
    print(f"spotify freq={s.extra['frequency']} strength={s.strength:.4f}; "
          f"apple_music freq={a.extra['frequency']} strength={a.strength:.4f}")
    assert s.extra["frequency"] == a.extra["frequency"] == 42
    assert s.strength == pytest.approx(a.strength)


def test_the_service_the_owner_really_uses_leads():
    recent = NOW - timedelta(days=2)
    heavy_apple = _strengths(_play_rows("spotify", "fixture-a - one", 5, recent)
                             + _library_row("apple_music", "fixture-b - two", 300, recent))
    assert heavy_apple[("apple_music", "fixture-b - two")].strength > \
        heavy_apple[("spotify", "fixture-a - one")].strength
    heavy_spotify = _strengths(_play_rows("spotify", "fixture-a - one", 300, recent, step_days=0)
                               + _library_row("apple_music", "fixture-b - two", 5, recent))
    assert heavy_spotify[("spotify", "fixture-a - one")].strength > \
        heavy_spotify[("apple_music", "fixture-b - two")].strength


def test_recency_is_the_last_play_not_the_first_row():
    last = NOW - timedelta(days=1)
    rows = _play_rows("spotify", "fixture-band - song", 20, last, step_days=200)
    fwd = _strengths(rows)[("spotify", "fixture-band - song")]
    rev = _strengths(list(reversed(rows)))[("spotify", "fixture-band - song")]
    assert fwd.extra["days_since_last"] <= 2, fwd.extra["days_since_last"]
    assert fwd.strength == pytest.approx(rev.strength)


def test_more_recent_listening_scores_higher_on_the_same_plays():
    recent = _strengths(_library_row("apple_music", "fixture - recent", 30, NOW - timedelta(days=3)))
    stale = _strengths(_library_row("apple_music", "fixture - stale", 30, NOW - timedelta(days=3650)))
    assert recent[("apple_music", "fixture - recent")].strength > \
        stale[("apple_music", "fixture - stale")].strength


@pytest.mark.parametrize("source", ["spotify", "apple_music", "youtube", "some_new_service"])
def test_no_source_is_weighted_by_name(source):
    last = NOW - timedelta(days=30)
    ref = _strengths(_library_row("apple_music", "fixture - song", 17, last))[("apple_music", "fixture - song")]
    got = _strengths(_library_row(source, "fixture - song", 17, last))[(source, "fixture - song")]
    assert got.strength == pytest.approx(ref.strength)


@pytest.mark.parametrize("raw,expect", [(None, 1), (0, 1), (1, 1), (7, 7), ("12", 12),
                                        ("x", 1), (-5, 1), (True, 1)])
def test_observation_weight_is_never_zero_or_negative(raw, expect):
    extra = {} if raw is None else {"play_count": raw}
    p = ParsedPreference(subject="fixture - song", source="s", extra=extra)
    assert PreferenceFilter._observation_weight(p) == expect


def test_rows_without_a_play_count_are_unchanged():
    """A source that writes one row per event (email, likes) keeps counting rows."""
    rows = [ParsedPreference(subject="fixture-newsletter", category="newsletter", strength=0.3,
                             source="email") for _ in range(4)]
    out = _strengths(rows)[("email", "fixture-newsletter")]
    assert out.extra["frequency"] == 4


# ── the Apple privacy export (privacy.apple.com) on the same scale ────────

def _apple_export_prefs(tmp_path, rows, name="Apple Music Play Activity.csv"):
    import asyncio
    import csv
    from services.ingest.src.parsers.apple import AppleParser
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


def _activity_rows(song, plays, last, ms=200000, step_days=3):
    # newest FIRST, the opposite order to the Spotify fixture
    return [{"Song Name": song, "Album Name": "fixture-album",
             "Event Timestamp": (last - timedelta(days=step_days * i)).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "Event Type": "PLAY_END", "Play Duration Milliseconds": str(ms)}
            for i in range(plays)]


def test_apple_play_activity_export_scores_like_spotify(tmp_path):
    last = (NOW - timedelta(days=10)).replace(microsecond=0)
    rows = _activity_rows("export-song", 42, last) + _activity_rows("export-song", 5, last, ms=12000)
    prefs = _apple_export_prefs(tmp_path, rows)
    assert len(prefs) == 1 and prefs[0].extra["play_count"] == 42      # 5 plays under 30 s dropped
    assert prefs[0].strength == 0.10                                    # Spotify's passive-play base
    assert prefs[0].observed_at == last                                 # the LATEST play
    out = _strengths(_play_rows("spotify", "fixture-band - song", 42, last) + prefs)
    s = out[("spotify", "fixture-band - song")]
    a = next(v for (src, _), v in out.items() if src == "apple")
    print(f"spotify strength={s.strength:.4f}; apple export strength={a.strength:.4f}")
    assert a.extra["frequency"] == 42
    assert a.strength == pytest.approx(s.strength)


def test_apple_daily_tracks_count_plays_not_skips(tmp_path):
    rows = [{"Track Description": "fixture-band - daily-song", "Play Count": "3", "Skip Count": "9",
             "Date Played": d} for d in ("20260101", "20260301", "20260201")]
    prefs = _apple_export_prefs(tmp_path, rows, name="Apple Music - Play History Daily Tracks.csv")
    assert len(prefs) == 1
    assert prefs[0].extra["play_count"] == 9 and prefs[0].strength == 0.10
    assert prefs[0].observed_at.strftime("%Y%m%d") == "20260301"
