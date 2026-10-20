"""Shazam library export parser.

Handles the owner's Shazam tag history from an export file.

SOURCES AND CONFIDENCE (checked 2026-10-21, all third-party; Apple publishes no
file layout for Shazam data):

* The MyShazam library download (shazam.com/myshazam) is a CSV. Two public
  projects (cascooscuro/spotyzam README; the toknow.ai Shazam-to-YouTube
  write-up, which reads it with ``header=1``) agree on the columns
  ``Index,TagTime,Title,Artist,URL,TrackKey`` and on one line above the header
  that is skipped (a "Shazam Library" title line). The sample ``TagTime``
  values there are plain dates (``2024-06-13``).
* Shazam's "Download Your Data" request (shazam.com/privacy, which is also what
  Apple's data request leads to) emails a file. Forum reports say it is a CSV
  of tagged tracks, one reports an EMPTY one when the library lives in iCloud.
  The layout inside a privacy.apple.com package is NOT confirmed by any source
  we could find.

So this parser accepts exactly the documented CSV shape, tolerates the optional
title line, optional extra columns and a date or datetime ``TagTime``, and
REFUSES anything else with ``ShazamExportShapeError`` (a missing required
column, a JSON file, a header we do not recognise). It never guesses a column.

PRIVACY: ``Latitude``/``Longitude`` (or any location-looking column) are
dropped, never stored. The ``URL`` column is not stored either (the TrackKey
already identifies the track). Source is ``shazam``: CM059 lists it in
``_LOCAL_ONLY_SOURCES`` and not in ``DECLARED_MEDIA_SOURCES``, so titles stay
local-only unless the owner has accepted online look-ups.

TIME: ``TagTime`` in an export carries no zone, so it is kept as the naive
local value written in the file, never converted.
"""

import csv
import io
import logging
import unicodedata
import zipfile
from datetime import datetime, timedelta
from pathlib import Path
from typing import AsyncIterator, Dict, Iterator, Optional

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)

_COL_TIME = "TagTime"
_COL_TITLE = "Title"
_COL_ARTIST = "Artist"
_COL_KEY = "TrackKey"
_REQUIRED_COLS = frozenset({_COL_TIME, _COL_TITLE, _COL_ARTIST})

_TITLE_LINE = "shazam library"
# Header may sit on line 1 (no title line) or line 2 (title line present).
_HEADER_SEARCH_LINES = 3
_MAX_FIELD = 300
_FUTURE_SLACK = timedelta(days=1)

_TIME_FORMATS = (
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%Y-%m-%d",
)

# One tag is a weak signal; repeat tags of the same track raise it, capped.
_BASE_STRENGTH = 0.30
_STEP_STRENGTH = 0.05
_MAX_STRENGTH = 0.60


class ShazamExportShapeError(ValueError):
    """The file looks like a Shazam export but not in the documented shape."""


def _clean(value: Optional[str]) -> str:
    text = unicodedata.normalize("NFC", (value or "").strip())
    return text[:_MAX_FIELD]


def _parse_tag_time(raw: str) -> Optional[datetime]:
    raw = (raw or "").strip()
    for fmt in _TIME_FORMATS:
        try:
            return datetime.strptime(raw, fmt)
        except ValueError:
            continue
    return None


def _locate_header(lines: list) -> int:
    """Index of the header line, or raise ShazamExportShapeError."""
    for i, line in enumerate(lines[:_HEADER_SEARCH_LINES]):
        try:
            cells = next(csv.reader([line]))
        except (csv.Error, StopIteration):
            continue
        if _REQUIRED_COLS.issubset({c.strip() for c in cells}):
            return i
    seen = lines[0].strip()[:80] if lines else "<empty file>"
    raise ShazamExportShapeError(
        "Unrecognised Shazam export: expected a CSV with the columns "
        f"{', '.join(sorted(_REQUIRED_COLS))} (MyShazam library shape "
        f"Index,TagTime,Title,Artist,URL,TrackKey). First line was: {seen!r}. "
        "Nothing was imported."
    )


def _rows(text_lines: Iterator[str]) -> Iterator[Dict[str, str]]:
    head = []
    for line in text_lines:
        head.append(line)
        if len(head) == _HEADER_SEARCH_LINES:
            break
    header_at = _locate_header(head)

    def chained() -> Iterator[str]:
        yield from head[header_at:]
        yield from text_lines

    for row in csv.DictReader(chained()):
        yield row


def _is_shazam_name(name: str) -> bool:
    return "shazam" in name.lower()


class ShazamParser(BaseParser):
    """Parser for a Shazam library CSV (plain file or inside a ZIP)."""

    source_name = "shazam"

    def can_parse(self, file_path: Path) -> bool:
        suffix = file_path.suffix.lower()
        if suffix == ".zip":
            try:
                with zipfile.ZipFile(file_path, "r") as zf:
                    return any(
                        _is_shazam_name(Path(m).name) and
                        Path(m).suffix.lower() in (".csv", ".json")
                        for m in zf.namelist()
                    )
            except (zipfile.BadZipFile, OSError):
                return False
        if suffix == ".json":
            # Claimed so the owner gets a clear refusal, not a silent skip.
            return _is_shazam_name(file_path.name)
        if suffix != ".csv":
            return False
        if _is_shazam_name(file_path.name):
            return True
        try:
            with open(file_path, "r", encoding="utf-8-sig", newline="") as fh:
                return fh.readline().strip().lower() == _TITLE_LINE
        except (OSError, UnicodeDecodeError):
            return False

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs,
    ) -> AsyncIterator[ParsedPreference]:
        if default_compartment is None:
            default_compartment = 2
        tracks: Dict[str, dict] = {}

        suffix = file_path.suffix.lower()
        if suffix == ".json":
            raise ShazamExportShapeError(
                f"{file_path.name}: a JSON Shazam export has no documented "
                "shape, so it is refused rather than guessed. Use the "
                "MyShazam library CSV. Nothing was imported."
            )
        if suffix == ".zip":
            self._collect_zip(file_path, tracks)
        else:
            with open(file_path, "r", encoding="utf-8-sig", newline="") as fh:
                self._collect(fh, tracks)

        if not tracks:
            # A header-only file is a real export shape (forum reports: the
            # emailed file can be empty when the library lives in iCloud).
            # Yielding nothing would read as "imported, nothing to add".
            raise ShazamExportShapeError(
                f"{file_path.name}: the Shazam export has the right columns "
                "but no tagged songs in it, so nothing was imported. If your "
                "Shazam library syncs through iCloud, the website download "
                "can come back empty; export from the Shazam app instead."
            )

        for key, t in tracks.items():
            n = t["count"]
            strength = min(_MAX_STRENGTH, _BASE_STRENGTH + (n - 1) * _STEP_STRENGTH)
            subject = f"{t['title']} - {t['artist']}" if t["artist"] else t["title"]
            yield ParsedPreference(
                subject=subject,
                preference_type="Like",
                strength=round(strength, 3),
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=f"shazam|{key}",
                category="music",
                observed_at=t["last"],
                size=self.classify_size(subject, "music"),
                extra={
                    "artist": t["artist"],
                    "title": t["title"],
                    "tag_count": n,
                    "track_key": t["track_key"],
                    "first_tagged": t["first"].isoformat() if t["first"] else None,
                },
            )

    def _collect_zip(self, file_path: Path, tracks: Dict[str, dict]) -> None:
        found = False
        with zipfile.ZipFile(file_path, "r") as zf:
            for member in zf.namelist():
                base = Path(member)
                if not _is_shazam_name(base.name):
                    continue
                if base.suffix.lower() == ".json":
                    raise ShazamExportShapeError(
                        f"{file_path.name}:{member}: a JSON Shazam export has "
                        "no documented shape, so it is refused rather than "
                        "guessed. Nothing was imported."
                    )
                if base.suffix.lower() != ".csv":
                    continue
                found = True
                with zf.open(member) as raw:
                    self._collect(
                        io.TextIOWrapper(raw, encoding="utf-8-sig", newline=""),
                        tracks,
                    )
        if not found:
            raise ShazamExportShapeError(
                f"{file_path.name}: no Shazam CSV inside the archive. "
                "Nothing was imported."
            )

    def _collect(self, fh, tracks: Dict[str, dict]) -> None:
        now = datetime.now()
        skipped = 0
        for row in _rows(iter(fh)):
            title = _clean(row.get(_COL_TITLE))
            if not title:
                skipped += 1
                continue
            artist = _clean(row.get(_COL_ARTIST))
            track_key = _clean(row.get(_COL_KEY))
            when = _parse_tag_time(row.get(_COL_TIME, ""))
            if when is not None and when > now + _FUTURE_SLACK:
                when = None
            ident = track_key or f"{title.lower()}|{artist.lower()}"
            t = tracks.get(ident)
            if t is None:
                tracks[ident] = {
                    "title": title, "artist": artist, "track_key": track_key,
                    "count": 1, "first": when, "last": when,
                }
                continue
            t["count"] += 1
            if when is not None:
                if t["first"] is None or when < t["first"]:
                    t["first"] = when
                if t["last"] is None or when > t["last"]:
                    t["last"] = when
        if skipped:
            logger.warning("ShazamParser: skipped %d rows with no title", skipped)
