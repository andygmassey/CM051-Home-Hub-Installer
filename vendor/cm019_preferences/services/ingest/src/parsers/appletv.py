"""Apple TV viewing activity parser.

Handles Apple Media Services GDPR data exports, specifically the playback /
viewing-history CSVs exported from an Apple ID under Settings > Privacy >
Data and Privacy > Request a copy of your data > Apple Media Services.

The export lands inside a directory tree such as:

    Apple Media Services information/
    Apple_Media_Services/
    Stores Activity/
    Play Position Information/
        Playback Activity.csv       <- primary: 462 rows, play counts + dates
    Apple TV and Podcast Information/
        Apple TV Bookmarks.csv      <- secondary: bookmarks + play state
        Apple TV Favorites and Wishlist.csv  <- wishlist/favourites

``can_parse()`` is tight: it requires the Apple TV / Apple Media Services
directory fingerprint so it cannot false-match Netflix, Disney+, or the
generic AppleParser (Apple Music play history).
"""

import csv
import io
import logging
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import AsyncIterator, Optional

import aiofiles

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Column constants
# ---------------------------------------------------------------------------

# Playback Activity.csv
_PA_ITEM_REF = "Item Reference"
_PA_ITEM_DESC = "Item Description"
_PA_LAST_TS = "Last activity timestamp"
_PA_PLAY_COUNT = "Play count"
_PA_HAS_PLAYED = "Has been played?"
_PA_PLAY_POS = "Playback position"

# Apple TV Bookmarks.csv
_BM_ITEM_REF = "Item Reference"
_BM_ITEM_DESC = "Item Description"
_BM_LAST_TS = "Last activity timestamp"
_BM_HAS_PLAYED = "Has been played?"

# Apple TV Favorites and Wishlist.csv
_WL_ITEM_REF = "Item Reference"
_WL_ITEM_DESC = "Item Description"
_WL_CREATED = "Created"
_WL_TYPE = "Type"

# Minimum column sets used to identify each file unambiguously.
_PLAYBACK_REQUIRED_COLS = frozenset({
    _PA_ITEM_REF, _PA_ITEM_DESC, _PA_LAST_TS, _PA_PLAY_COUNT, _PA_HAS_PLAYED
})
_BOOKMARKS_REQUIRED_COLS = frozenset({
    _BM_ITEM_REF, _BM_ITEM_DESC, _BM_LAST_TS, _BM_HAS_PLAYED
})
_WISHLIST_REQUIRED_COLS = frozenset({
    _WL_ITEM_REF, _WL_ITEM_DESC, _WL_CREATED, _WL_TYPE
})

# Path fragments that confirm the Apple TV export hierarchy.
# All three fragments may appear anywhere in the lowercased path string.
_APPLE_TV_PATH_INDICATORS = [
    "apple media services",
    "apple_media_services",
    "apple tv",
]

# Filename fragments that identify the three Apple TV CSV files.
_APPLE_TV_FILE_NAMES = [
    "playback activity",
    "apple tv bookmarks",
    "apple tv favorites",
    "apple tv favourites",  # defensive variant
    "apple tv wishlist",
]


def _has_apple_tv_path(path_lower: str) -> bool:
    """Return True if the path string contains an Apple TV export indicator."""
    return any(ind in path_lower for ind in _APPLE_TV_PATH_INDICATORS)


def _cols_match(content: str, required: frozenset) -> bool:
    """Return True if the CSV header contains all required column names."""
    try:
        reader = csv.DictReader(io.StringIO(content, newline=""))
        fieldnames = set(reader.fieldnames or [])
        return required.issubset(fieldnames)
    except Exception:
        return False


def _parse_iso_ts(raw: str) -> Optional[datetime]:
    """Parse an ISO-8601 timestamp string to a UTC-aware datetime."""
    if not raw:
        return None
    raw = raw.strip()
    try:
        # Apple exports use 'Z' suffix (e.g. 2024-03-15T10:22:00Z)
        if raw.endswith("Z"):
            raw = raw[:-1] + "+00:00"
        return datetime.fromisoformat(raw).replace(tzinfo=timezone.utc)
    except ValueError:
        return None


class AppleTVParser(BaseParser):
    """Parser for Apple TV / Apple Media Services GDPR export CSVs.

    Ingests three file types from the export:

    1. ``Playback Activity.csv`` -- every item played or partially played,
       with a play count and last-activity timestamp.  Records with
       ``Has been played? = No`` (saved but never started) are skipped.

    2. ``Apple TV Bookmarks.csv`` -- items bookmarked by the user, filtered
       to those actually played (``Has been played? = Yes``).  Provides
       additional coverage when an item appears only here and not in the
       Playback Activity file.

    3. ``Apple TV Favorites and Wishlist.csv`` -- items the user wishlisted or
       marked as favourites.  Ingested as ``Neutral`` preferences (intent to
       watch / interest signal) rather than confirmed viewing.

    Supports both plain CSV files and ZIP archives that contain them.
    """

    source_name = "apple_tv"

    # ------------------------------------------------------------------
    # can_parse
    # ------------------------------------------------------------------

    def can_parse(self, file_path: Path) -> bool:
        """Return True if this parser should handle ``file_path``.

        Matching rules (all are required to avoid false positives):

        * For CSV files: the path must contain an Apple TV/Media Services
          path fragment, AND the filename must match one of the three known
          Apple TV CSV names.

        * For ZIP files: the archive name or path must reference Apple Media
          Services, AND at least one member must match an Apple TV CSV name.

        This deliberately does NOT match on column signatures alone to keep
        ``can_parse()`` fast (no file I/O beyond a ZIP namelist scan).
        """
        name = file_path.name.lower()
        path_lower = str(file_path).lower()

        if file_path.suffix.lower() == ".zip":
            if not _has_apple_tv_path(path_lower):
                return False
            try:
                with zipfile.ZipFile(file_path, "r") as zf:
                    members = [m.lower() for m in zf.namelist()]
                    return any(
                        any(pat in m for pat in _APPLE_TV_FILE_NAMES)
                        for m in members
                    )
            except Exception:
                return False

        if file_path.suffix.lower() == ".csv":
            if not _has_apple_tv_path(path_lower):
                return False
            return any(pat in name for pat in _APPLE_TV_FILE_NAMES)

        return False

    # ------------------------------------------------------------------
    # parse
    # ------------------------------------------------------------------

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs,
    ) -> AsyncIterator[ParsedPreference]:
        """Parse an Apple TV export file and yield ``ParsedPreference`` objects.

        Dispatches to the appropriate sub-parser based on the filename.
        """
        if default_compartment is None:
            default_compartment = 2  # L2 Trusted

        logger.info("Parsing Apple TV data from %s", file_path)

        if file_path.suffix.lower() == ".zip":
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
            return

        name = file_path.name.lower()

        if "playback activity" in name:
            async for pref in self._parse_playback_activity(
                file_path, default_compartment
            ):
                yield pref

        elif "apple tv bookmarks" in name:
            async for pref in self._parse_bookmarks(file_path, default_compartment):
                yield pref

        elif "apple tv favorites" in name or "apple tv favourites" in name or "apple tv wishlist" in name:
            async for pref in self._parse_wishlist(file_path, default_compartment):
                yield pref

        else:
            logger.warning("AppleTVParser: unrecognised filename %s -- skipping", file_path.name)

    # ------------------------------------------------------------------
    # ZIP dispatch
    # ------------------------------------------------------------------

    async def _parse_zip(
        self, file_path: Path, default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        with zipfile.ZipFile(file_path, "r") as zf:
            for member in zf.namelist():
                member_lower = member.lower()
                content = zf.read(member).decode("utf-8-sig")

                if "playback activity" in member_lower and member_lower.endswith(".csv"):
                    async for pref in self._parse_playback_activity_content(
                        content, default_compartment, source_hint=member
                    ):
                        yield pref

                elif "apple tv bookmarks" in member_lower and member_lower.endswith(".csv"):
                    async for pref in self._parse_bookmarks_content(
                        content, default_compartment, source_hint=member
                    ):
                        yield pref

                elif (
                    ("apple tv favorites" in member_lower or "apple tv wishlist" in member_lower)
                    and member_lower.endswith(".csv")
                ):
                    async for pref in self._parse_wishlist_content(
                        content, default_compartment, source_hint=member
                    ):
                        yield pref

    # ------------------------------------------------------------------
    # Playback Activity
    # ------------------------------------------------------------------

    async def _parse_playback_activity(
        self, file_path: Path, default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        async with aiofiles.open(file_path, mode="r", encoding="utf-8-sig") as fh:
            content = await fh.read()
        async for pref in self._parse_playback_activity_content(
            content, default_compartment, source_hint=str(file_path)
        ):
            yield pref

    async def _parse_playback_activity_content(
        self, content: str, default_compartment: int, source_hint: str = ""
    ) -> AsyncIterator[ParsedPreference]:
        reader = csv.DictReader(io.StringIO(content, newline=""))

        if not _PLAYBACK_REQUIRED_COLS.issubset(set(reader.fieldnames or [])):
            logger.warning(
                "AppleTVParser: Playback Activity missing expected columns in %s",
                source_hint,
            )
            return

        for row in reader:
            title = (row.get(_PA_ITEM_DESC) or "").strip()
            if not title:
                continue

            has_played = (row.get(_PA_HAS_PLAYED) or "").strip().lower()
            if has_played == "no":
                # Item was saved or partially downloaded but never started.
                continue

            item_ref = (row.get(_PA_ITEM_REF) or "").strip()
            raw_ts = (row.get(_PA_LAST_TS) or "").strip()
            observed = _parse_iso_ts(raw_ts)

            play_count_raw = (row.get(_PA_PLAY_COUNT) or "").strip()
            try:
                play_count = int(play_count_raw)
            except (ValueError, TypeError):
                play_count = 1

            # Viewing strength: scale up slightly for repeat viewings, cap at 0.75
            base_strength = 0.40
            strength = min(0.75, base_strength + (play_count - 1) * 0.05)

            yield ParsedPreference(
                subject=title,
                preference_type="Like",
                strength=round(strength, 3),
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=f"appletv|{item_ref}" if item_ref else None,
                category="media/viewing",
                observed_at=observed,
                size=self.classify_size(title, "media/viewing"),
                extra={
                    "item_reference": item_ref,
                    "play_count": play_count,
                    "has_been_played": has_played,
                },
            )

    # ------------------------------------------------------------------
    # Bookmarks
    # ------------------------------------------------------------------

    async def _parse_bookmarks(
        self, file_path: Path, default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        async with aiofiles.open(file_path, mode="r", encoding="utf-8-sig") as fh:
            content = await fh.read()
        async for pref in self._parse_bookmarks_content(
            content, default_compartment, source_hint=str(file_path)
        ):
            yield pref

    async def _parse_bookmarks_content(
        self, content: str, default_compartment: int, source_hint: str = ""
    ) -> AsyncIterator[ParsedPreference]:
        reader = csv.DictReader(io.StringIO(content, newline=""))

        if not _BOOKMARKS_REQUIRED_COLS.issubset(set(reader.fieldnames or [])):
            logger.warning(
                "AppleTVParser: Bookmarks missing expected columns in %s",
                source_hint,
            )
            return

        for row in reader:
            title = (row.get(_BM_ITEM_DESC) or "").strip()
            if not title:
                continue

            has_played = (row.get(_BM_HAS_PLAYED) or "").strip().lower()
            if has_played == "no":
                # Bookmarked but never actually watched.
                continue

            item_ref = (row.get(_BM_ITEM_REF) or "").strip()
            raw_ts = (row.get(_BM_LAST_TS) or "").strip()
            observed = _parse_iso_ts(raw_ts)

            yield ParsedPreference(
                subject=title,
                preference_type="Like",
                strength=0.35,
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=f"appletv|bm|{item_ref}" if item_ref else None,
                category="media/viewing",
                observed_at=observed,
                size=self.classify_size(title, "media/viewing"),
                extra={"item_reference": item_ref, "source_file": "bookmarks"},
            )

    # ------------------------------------------------------------------
    # Favourites / Wishlist
    # ------------------------------------------------------------------

    async def _parse_wishlist(
        self, file_path: Path, default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        async with aiofiles.open(file_path, mode="r", encoding="utf-8-sig") as fh:
            content = await fh.read()
        async for pref in self._parse_wishlist_content(
            content, default_compartment, source_hint=str(file_path)
        ):
            yield pref

    async def _parse_wishlist_content(
        self, content: str, default_compartment: int, source_hint: str = ""
    ) -> AsyncIterator[ParsedPreference]:
        reader = csv.DictReader(io.StringIO(content, newline=""))

        if not _WISHLIST_REQUIRED_COLS.issubset(set(reader.fieldnames or [])):
            logger.warning(
                "AppleTVParser: Favourites/Wishlist missing expected columns in %s",
                source_hint,
            )
            return

        for row in reader:
            title = (row.get(_WL_ITEM_DESC) or "").strip()
            if not title:
                continue

            item_ref = (row.get(_WL_ITEM_REF) or "").strip()
            raw_ts = (row.get(_WL_CREATED) or "").strip()
            observed = _parse_iso_ts(raw_ts)
            media_type = (row.get(_WL_TYPE) or "").strip()  # e.g. "Movie", "Show"

            yield ParsedPreference(
                subject=title,
                preference_type="Neutral",
                strength=0.20,
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=f"appletv|wl|{item_ref}" if item_ref else None,
                category="media/viewing",
                observed_at=observed,
                size=self.classify_size(title, "media/viewing"),
                extra={
                    "item_reference": item_ref,
                    "media_type": media_type,
                    "source_file": "wishlist",
                },
            )
