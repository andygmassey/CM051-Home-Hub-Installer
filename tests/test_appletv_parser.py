#!/usr/bin/env python3
"""Tests for AppleTVParser.

Verifies can_parse() detection and parse() record yield using SYNTHETIC
Apple TV CSV fixtures only -- no real personal data anywhere here.
See PRODUCTISATION_CHECKLIST.md Rule 0.

Test cases:
  1. can_parse() returns True for a Playback Activity CSV in an Apple TV path
  2. can_parse() returns True for an Apple TV Bookmarks CSV
  3. can_parse() returns True for an Apple TV Favorites and Wishlist CSV
  4. can_parse() returns False for a Netflix ViewingActivity.csv shape
  5. can_parse() returns False for a file with AppleTV columns but no path hint
  6. parse() on Playback Activity yields correct record count (played items only)
  7. parse() on Wishlist yields Neutral preferences
  8. Real dump smoke test: can_parse() returns True + count only
"""

import asyncio
import csv
import sys
import tempfile
import zipfile
from pathlib import Path
from unittest.mock import MagicMock, patch

# Make the vendor tree importable without an installed package.
REPO = Path(__file__).resolve().parent.parent
INGEST_SRC_PARENT = REPO / "vendor" / "cm019_preferences" / "services" / "ingest"
sys.path.insert(0, str(INGEST_SRC_PARENT))

import src.parsers.appletv as _appletv_module  # noqa: E402
from src.parsers.appletv import AppleTVParser  # noqa: E402


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Synthetic fixture helpers
# ---------------------------------------------------------------------------

_PLAYBACK_HEADER = [
    "Item Reference",
    "Item Description",
    "Last activity timestamp",
    "Playback position",
    "Play count",
    "Has been played?",
]

_BOOKMARKS_HEADER = [
    "Item Reference",
    "Last activity timestamp",
    "Item Description",
    "Marked as unwatched?",
    "Has been played?",
    "Playback position",
    "Play count",
    "Has been rented?",
]

_WISHLIST_HEADER = [
    "Item Reference",
    "Created",
    "Item Description",
    "Type",
]


def _write_playback_csv(path: Path, rows: list) -> None:
    """Write a synthetic Playback Activity CSV."""
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=_PLAYBACK_HEADER)
        w.writeheader()
        for row in rows:
            w.writerow(row)


def _write_bookmarks_csv(path: Path, rows: list) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=_BOOKMARKS_HEADER)
        w.writeheader()
        for row in rows:
            w.writerow(row)


def _write_wishlist_csv(path: Path, rows: list) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=_WISHLIST_HEADER)
        w.writeheader()
        for row in rows:
            w.writerow(row)


_SYNTHETIC_PLAYBACK_ROWS = [
    {
        "Item Reference": "100000001",
        "Item Description": "Synthetic Film Alpha",
        "Last activity timestamp": "2024-01-10T12:00:00Z",
        "Playback position": "0.980",
        "Play count": "1",
        "Has been played?": "Yes",
    },
    {
        "Item Reference": "100000002",
        "Item Description": "Synthetic Series Beta",
        "Last activity timestamp": "2024-02-14T18:30:00Z",
        "Playback position": "1.000",
        "Play count": "3",
        "Has been played?": "Yes",
    },
    {
        "Item Reference": "100000003",
        "Item Description": "Synthetic Documentary Gamma",
        "Last activity timestamp": "2024-03-01T09:00:00Z",
        "Playback position": "0.000",
        "Play count": "0",
        "Has been played?": "No",  # Never actually watched -- should be skipped
    },
]

_SYNTHETIC_WISHLIST_ROWS = [
    {
        "Item Reference": "200000001",
        "Created": "2024-05-01T08:00:00Z",
        "Item Description": "Synthetic Thriller Delta",
        "Type": "Movie",
    },
    {
        "Item Reference": "200000002",
        "Created": "2024-06-15T14:00:00Z",
        "Item Description": "Synthetic Comedy Epsilon",
        "Type": "Show",
    },
]

_SYNTHETIC_BOOKMARKS_ROWS = [
    {
        "Item Reference": "300000001",
        "Last activity timestamp": "2024-07-10T20:00:00Z",
        "Item Description": "Synthetic Thriller Zeta",
        "Marked as unwatched?": "",
        "Has been played?": "Yes",
        "Playback position": "0.500",
        "Play count": "1",
        "Has been rented?": "",
    },
    {
        "Item Reference": "300000002",
        "Last activity timestamp": "2024-08-01T10:00:00Z",
        "Item Description": "Synthetic Action Eta",
        "Marked as unwatched?": "",
        "Has been played?": "No",  # Should be skipped
        "Playback position": "0.000",
        "Play count": "0",
        "Has been rented?": "",
    },
]


# ---------------------------------------------------------------------------
# Helpers to build paths that look like the real Apple TV export hierarchy
# ---------------------------------------------------------------------------

def _appletv_playback_path(tmp: str) -> Path:
    """Return a path that mimics the real Apple TV export hierarchy."""
    base = (
        Path(tmp)
        / "Apple Media Services information"
        / "Apple_Media_Services"
        / "Stores Activity"
        / "Play Position Information"
    )
    base.mkdir(parents=True)
    p = base / "Playback Activity.csv"
    _write_playback_csv(p, _SYNTHETIC_PLAYBACK_ROWS)
    return p


def _appletv_bookmarks_path(tmp: str) -> Path:
    base = (
        Path(tmp)
        / "Apple Media Services information"
        / "Apple_Media_Services"
        / "Stores Activity"
        / "Apple TV and Podcast Information"
    )
    base.mkdir(parents=True)
    p = base / "Apple TV Bookmarks.csv"
    _write_bookmarks_csv(p, _SYNTHETIC_BOOKMARKS_ROWS)
    return p


def _appletv_wishlist_path(tmp: str) -> Path:
    base = (
        Path(tmp)
        / "Apple Media Services information"
        / "Apple_Media_Services"
        / "Stores Activity"
        / "Apple TV and Podcast Information"
    )
    base.mkdir(parents=True, exist_ok=True)
    p = base / "Apple TV Favorites and Wishlist.csv"
    _write_wishlist_csv(p, _SYNTHETIC_WISHLIST_ROWS)
    return p


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_can_parse_playback_activity_true() -> None:
    parser = AppleTVParser()
    with tempfile.TemporaryDirectory() as tmp:
        p = _appletv_playback_path(tmp)
        if not parser.can_parse(p):
            fail("can_parse returned False for Playback Activity CSV in Apple TV path")
    print("PASS: can_parse(Playback Activity.csv in Apple TV path) == True")


def test_can_parse_bookmarks_true() -> None:
    parser = AppleTVParser()
    with tempfile.TemporaryDirectory() as tmp:
        p = _appletv_bookmarks_path(tmp)
        if not parser.can_parse(p):
            fail("can_parse returned False for Apple TV Bookmarks.csv")
    print("PASS: can_parse(Apple TV Bookmarks.csv) == True")


def test_can_parse_wishlist_true() -> None:
    parser = AppleTVParser()
    with tempfile.TemporaryDirectory() as tmp:
        p = _appletv_wishlist_path(tmp)
        if not parser.can_parse(p):
            fail("can_parse returned False for Apple TV Favorites and Wishlist.csv")
    print("PASS: can_parse(Apple TV Favorites and Wishlist.csv) == True")


def test_can_parse_netflix_shape_false() -> None:
    """A Netflix ViewingActivity.csv must NOT be matched."""
    parser = AppleTVParser()
    with tempfile.TemporaryDirectory() as tmp:
        netflix_dir = Path(tmp) / "netflix-report" / "CONTENT_INTERACTION"
        netflix_dir.mkdir(parents=True)
        csv_path = netflix_dir / "ViewingActivity.csv"
        csv_path.write_text(
            "Profile Name,Start Time,Duration,Title\n"
            "Synthetic Profile,2024-01-01 10:00:00,00:45:00,Synthetic Show S01E01\n",
            encoding="utf-8",
        )
        if parser.can_parse(csv_path):
            fail("can_parse wrongly returned True for Netflix ViewingActivity.csv")
    print("PASS: can_parse(Netflix ViewingActivity.csv) == False")


def test_can_parse_no_path_hint_false() -> None:
    """A CSV with correct Apple TV columns but no Apple TV path hint returns False."""
    parser = AppleTVParser()
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "Playback Activity.csv"
        _write_playback_csv(p, _SYNTHETIC_PLAYBACK_ROWS)
        if parser.can_parse(p):
            fail(
                "can_parse returned True for Playback Activity.csv with no Apple TV path context"
            )
    print("PASS: can_parse(Playback Activity.csv with no path hint) == False")


def test_parse_playback_activity_count_and_types() -> None:
    """parse() on Playback Activity skips 'No' rows and yields correct count."""
    parser = AppleTVParser()

    async def _run(path: Path) -> list:
        results = []
        async for pref in parser.parse(path, default_compartment=2):
            results.append(pref)
        return results

    with tempfile.TemporaryDirectory() as tmp:
        p = _appletv_playback_path(tmp)
        prefs = asyncio.run(_run(p))

    # 3 rows total; 1 has Has been played? = No -> should yield 2 records
    expected = 2
    if len(prefs) != expected:
        fail(
            f"parse(Playback Activity) yielded {len(prefs)} records; expected {expected}"
        )
    if any(pref.preference_type != "Like" for pref in prefs):
        fail("parse(Playback Activity) yielded non-Like preference")
    if any(pref.category != "media/viewing" for pref in prefs):
        fail("parse(Playback Activity) yielded wrong category")
    if any(pref.source != "apple_tv" for pref in prefs):
        fail("parse(Playback Activity) yielded wrong source name")

    # Multi-view item should have higher strength than single-view
    titles = [p.subject for p in prefs]
    strengths = {p.subject: p.strength for p in prefs}
    if strengths.get("Synthetic Series Beta", 0) <= strengths.get("Synthetic Film Alpha", 1):
        fail("Multi-view item should have higher strength than single-view item")

    print(
        f"PASS: parse(Playback Activity) yielded {len(prefs)} Like records "
        f"(skipped 1 unplayed), multi-view strength higher"
    )


def test_parse_wishlist_neutral_preferences() -> None:
    """parse() on the Wishlist/Favourites file yields Neutral preferences."""
    parser = AppleTVParser()

    async def _run(path: Path) -> list:
        results = []
        async for pref in parser.parse(path, default_compartment=2):
            results.append(pref)
        return results

    with tempfile.TemporaryDirectory() as tmp:
        p = _appletv_wishlist_path(tmp)
        prefs = asyncio.run(_run(p))

    if len(prefs) != 2:
        fail(f"parse(Wishlist) yielded {len(prefs)} records; expected 2")
    if any(pref.preference_type != "Neutral" for pref in prefs):
        fail("parse(Wishlist) should yield only Neutral preferences")
    print(f"PASS: parse(Wishlist) yielded {len(prefs)} Neutral records")


def test_real_dump_can_parse_and_count() -> None:
    """Smoke test: can_parse() returns True for the real dump (read-only).

    Reports record count only -- no personal data is printed.
    """
    parser = AppleTVParser()
    real_path = Path(
        "/Users/andy/Documents/Projects/CM019 - Personal World Graph"
        "/03 - Social Media archives/1 Jan 2026/19 - Apple TV"
        "/Apple Media Services information"
        "/Apple_Media_Services"
        "/Stores Activity"
        "/Play Position Information"
        "/Playback Activity.csv"
    )
    if not real_path.exists():
        print("SKIP: real dump not found at expected path (fixture-only environment)")
        return

    if not parser.can_parse(real_path):
        fail(f"can_parse returned False for real Playback Activity dump at {real_path}")

    async def _count(path: Path) -> int:
        count = 0
        async for _ in parser.parse(path, default_compartment=2):
            count += 1
        return count

    count = asyncio.run(_count(real_path))
    if count < 1:
        fail("parse() yielded 0 records from real dump -- check filter logic")

    print(f"PASS: real dump can_parse=True, parse() yielded {count} records")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    test_can_parse_playback_activity_true()
    test_can_parse_bookmarks_true()
    test_can_parse_wishlist_true()
    test_can_parse_netflix_shape_false()
    test_can_parse_no_path_hint_false()
    test_parse_playback_activity_count_and_types()
    test_parse_wishlist_neutral_preferences()
    test_real_dump_can_parse_and_count()
    print("\nALL APPLE TV PARSER TESTS PASSED")


if __name__ == "__main__":
    main()
