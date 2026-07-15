"""Extract the user's music taste from the Apple Music / iTunes library.

Apple's Music app (and the older iTunes) can export a full library
description as an XML property list at::

    ~/Music/iTunes/iTunes Music Library.xml

This is a plist (parseable with stdlib ``plistlib``) listing every
track the user owns or has added, with rich per-track metadata:
Name, Artist, Album, Genre, Play Count, Last Played, Rating, plus a
``Playlists`` array describing the user's playlists and their members.

The modern Music app keeps its live database in an opaque Core-Data
bundle at ``~/Music/Music/Music Library.musiclibrary`` which we do NOT
attempt to parse -- it has no documented schema and changes between
macOS releases. The XML export is the stable, documented surface, so
this extractor reads the XML when present and degrades gracefully
(empty result, no crash) when neither file is available.

Music taste is a strong personal-preference signal: top artists,
favourite genres, most-played tracks and named playlists tell Ostler
what the user actually listens to, fully on-device.

The XML lives under the user's home directory and does not require
Full Disk Access on current macOS (it is not a TCC-protected store),
but the path is overridable via ``OSTLER_MUSIC_LIBRARY_XML`` for
custom installs and tests.
"""
from __future__ import annotations

import logging
import os
import plistlib
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional

logger = logging.getLogger(__name__)

# Source label used on emitted records + downstream provenance.
SOURCE = "apple_music"

# Music taste is the user's own preference data -- L1 (personal,
# about the user, not third-party PII). The wiki Music wing renders
# it unredacted for the owner.
PRIVACY_LEVEL = "L1"

# Stable namespace for uuid5 ids so re-runs over the same library
# produce identical record ids (idempotent ingest).
_NAMESPACE = uuid.NAMESPACE_URL

# Standard export location. iTunes and the early Music app both write
# here; the trailing filename has a space and mixed case on disk.
DEFAULT_LIBRARY_XML = (
    Path.home() / "Music" / "iTunes" / "iTunes Music Library.xml"
)

# Alternative filename some macOS versions emit alongside the classic
# name. Probed as a fallback when the canonical name is absent.
_ALT_LIBRARY_XML = (
    Path.home() / "Music" / "iTunes" / "iTunes Library.xml"
)

_ENV_OVERRIDE = "OSTLER_MUSIC_LIBRARY_XML"


@dataclass
class Track:
    """A single track from the library with taste-relevant metadata."""
    track_id: str          # The library's Track ID, as a string.
    name: str
    artist: Optional[str]
    album: Optional[str]
    genre: Optional[str]
    play_count: int
    last_played: Optional[datetime]
    rating: Optional[int]  # 0-100 on disk (star * 20); None if unrated.
    loved: bool


@dataclass
class Playlist:
    """A named user playlist and the track ids it contains."""
    name: str
    track_ids: List[str] = field(default_factory=list)


@dataclass
class ArtistTaste:
    """Aggregated listening signal for one artist."""
    artist: str
    total_plays: int
    track_count: int


@dataclass
class GenreTaste:
    """Aggregated listening signal for one genre."""
    genre: str
    total_plays: int
    track_count: int


@dataclass
class MusicLibrary:
    """The parsed library: tracks + playlists."""
    tracks: List[Track] = field(default_factory=list)
    playlists: List[Playlist] = field(default_factory=list)


# Apple's built-in "smart"/system playlists carry a distinct flag in
# the XML. We keep user playlists and drop the system ones so the
# taste signal reflects deliberate curation, not library plumbing.
_SYSTEM_PLAYLIST_KEYS = (
    "Master",
    "Music",
    "Movies",
    "TV Shows",
    "Podcasts",
    "Audiobooks",
    "Purchased",
    "Downloaded",
)


def _resolve_library_path(xml_path: Optional[Path]) -> Optional[Path]:
    """Pick the library XML path: arg > env override > defaults.

    Returns None when no candidate exists on disk so callers can
    degrade gracefully rather than raise.
    """
    if xml_path is not None:
        return xml_path if xml_path.exists() else None

    override = os.environ.get(_ENV_OVERRIDE, "").strip()
    if override:
        cand = Path(override).expanduser()
        return cand if cand.exists() else None

    for cand in (DEFAULT_LIBRARY_XML, _ALT_LIBRARY_XML):
        if cand.exists():
            return cand
    return None


def _as_datetime(raw) -> Optional[datetime]:
    """Normalise a plist date value to a tz-aware UTC datetime.

    plistlib returns naive datetimes for ``<date>`` values; the
    iTunes XML stores them as UTC, so we attach UTC explicitly.
    """
    if isinstance(raw, datetime):
        if raw.tzinfo is None:
            return raw.replace(tzinfo=timezone.utc)
        return raw.astimezone(timezone.utc)
    return None


def _parse_track(raw: dict) -> Optional[Track]:
    """Build a Track from one Tracks-dict entry.

    Skips non-song entries (movies, podcasts, the rare row with no
    Name) so aggregates reflect music only.
    """
    name = raw.get("Name")
    if not name:
        return None

    # Drop non-music media kinds when the flags are present. Absent
    # flags => treat as music (the common case for audio tracks).
    if raw.get("Podcast") or raw.get("Movie") or raw.get("TV Show"):
        return None
    kind = (raw.get("Kind") or "").lower()
    if "video" in kind:
        return None

    track_id = raw.get("Track ID")
    if track_id is None:
        return None

    return Track(
        track_id=str(track_id),
        name=name,
        artist=raw.get("Artist"),
        album=raw.get("Album"),
        genre=raw.get("Genre"),
        play_count=int(raw.get("Play Count") or 0),
        last_played=_as_datetime(raw.get("Play Date UTC")),
        rating=(
            int(raw["Rating"]) if isinstance(raw.get("Rating"), int) else None
        ),
        loved=bool(raw.get("Loved", False)),
    )


def _parse_playlist(raw: dict) -> Optional[Playlist]:
    """Build a Playlist from one Playlists-array entry.

    Drops Apple's system/built-in playlists; keeps user playlists.
    """
    name = raw.get("Name")
    if not name:
        return None
    if name in _SYSTEM_PLAYLIST_KEYS:
        return None
    # Smart system playlists set "Distinguished Kind" or the
    # Master/Visible flags; the named-key check above already covers
    # the common ones, but honour the explicit flag too.
    if raw.get("Master") or raw.get("Distinguished Kind") is not None:
        return None

    items = raw.get("Playlist Items") or []
    track_ids = [
        str(item["Track ID"])
        for item in items
        if isinstance(item, dict) and item.get("Track ID") is not None
    ]
    return Playlist(name=name, track_ids=track_ids)


def extract_library(xml_path: Optional[Path] = None) -> MusicLibrary:
    """Parse the iTunes/Music library XML into a MusicLibrary.

    Args:
        xml_path: Override the library XML path. When None, the
            ``OSTLER_MUSIC_LIBRARY_XML`` env var is consulted, then
            the standard ``~/Music/iTunes/`` locations.

    Returns:
        A MusicLibrary. Empty (no tracks, no playlists) when no
        library file exists or the file is unreadable -- callers
        degrade gracefully rather than handle an exception.
    """
    path = _resolve_library_path(xml_path)
    if path is None:
        logger.info("No Apple Music / iTunes library XML found; skipping.")
        return MusicLibrary()

    try:
        with open(path, "rb") as fh:
            data = plistlib.load(fh)
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        # Corrupt or partially-written export -- treat as empty.
        logger.warning(
            "Could not parse music library at %s (%s); skipping.",
            path, type(exc).__name__,
        )
        return MusicLibrary()

    raw_tracks = data.get("Tracks") or {}
    tracks: List[Track] = []
    for raw in raw_tracks.values():
        if not isinstance(raw, dict):
            continue
        parsed = _parse_track(raw)
        if parsed is not None:
            tracks.append(parsed)

    raw_playlists = data.get("Playlists") or []
    playlists: List[Playlist] = []
    for raw in raw_playlists:
        if not isinstance(raw, dict):
            continue
        parsed = _parse_playlist(raw)
        if parsed is not None:
            playlists.append(parsed)

    logger.info(
        "Parsed Apple Music library: %d tracks, %d user playlists (from %s)",
        len(tracks), len(playlists), path,
    )
    return MusicLibrary(tracks=tracks, playlists=playlists)


def top_artists(
    library: MusicLibrary, limit: int = 50
) -> List[ArtistTaste]:
    """Aggregate tracks by artist, ranked by total play count.

    Ties on play count fall back to track count then artist name so
    the ordering is deterministic across runs.
    """
    agg: dict[str, dict] = {}
    for t in library.tracks:
        if not t.artist:
            continue
        a = agg.setdefault(t.artist, {"plays": 0, "tracks": 0})
        a["plays"] += t.play_count
        a["tracks"] += 1

    result = [
        ArtistTaste(artist=name, total_plays=d["plays"], track_count=d["tracks"])
        for name, d in agg.items()
    ]
    result.sort(key=lambda a: (-a.total_plays, -a.track_count, a.artist))
    return result[:limit]


def top_genres(
    library: MusicLibrary, limit: int = 30
) -> List[GenreTaste]:
    """Aggregate tracks by genre, ranked by total play count."""
    agg: dict[str, dict] = {}
    for t in library.tracks:
        if not t.genre:
            continue
        g = agg.setdefault(t.genre, {"plays": 0, "tracks": 0})
        g["plays"] += t.play_count
        g["tracks"] += 1

    result = [
        GenreTaste(genre=name, total_plays=d["plays"], track_count=d["tracks"])
        for name, d in agg.items()
    ]
    result.sort(key=lambda g: (-g.total_plays, -g.track_count, g.genre))
    return result[:limit]


def most_played(library: MusicLibrary, limit: int = 50) -> List[Track]:
    """Return the most-played individual tracks, highest first."""
    played = [t for t in library.tracks if t.play_count > 0]
    played.sort(
        key=lambda t: (-t.play_count, (t.artist or ""), t.name)
    )
    return played[:limit]


def _stable_id(*parts: str) -> str:
    """Deterministic uuid5 over the supplied parts.

    Same inputs => same id, so re-ingesting an unchanged library is
    idempotent.
    """
    key = "|".join(parts)
    return str(uuid.uuid5(_NAMESPACE, f"pwg:apple_music:{key}"))


def to_records(library: MusicLibrary) -> List[dict]:
    """Flatten the library into PWG ingest records.

    Emits three record kinds, each with a stable uuid5 id, the
    ``apple_music`` source label and the L1 privacy level:

    - ``music_artist``   one per artist, with play + track counts.
    - ``music_genre``    one per genre, with play + track counts.
    - ``music_playlist`` one per user playlist, with its size.

    Per-track rows are intentionally NOT emitted in bulk here -- the
    aggregates are the durable taste signal; the wiki Music wing
    renders the most-played list from ``most_played()`` directly.
    """
    records: List[dict] = []

    for a in top_artists(library, limit=200):
        records.append({
            "id": _stable_id("artist", a.artist),
            "type": "music_artist",
            "artist": a.artist,
            "total_plays": a.total_plays,
            "track_count": a.track_count,
            "source": SOURCE,
            "privacy_level": PRIVACY_LEVEL,
        })

    for g in top_genres(library, limit=100):
        records.append({
            "id": _stable_id("genre", g.genre),
            "type": "music_genre",
            "genre": g.genre,
            "total_plays": g.total_plays,
            "track_count": g.track_count,
            "source": SOURCE,
            "privacy_level": PRIVACY_LEVEL,
        })

    for p in library.playlists:
        records.append({
            "id": _stable_id("playlist", p.name),
            "type": "music_playlist",
            "name": p.name,
            "track_count": len(p.track_ids),
            "source": SOURCE,
            "privacy_level": PRIVACY_LEVEL,
        })

    return records


def library_stats(library: MusicLibrary) -> dict:
    """Privacy-safe summary for the install summary screen.

    Counts and the top-artist / top-genre NAMES only (the user's own
    taste, L1) -- no per-track titles, no last-played timestamps.
    """
    arts = top_artists(library, limit=10)
    gens = top_genres(library, limit=10)
    total_plays = sum(t.play_count for t in library.tracks)
    return {
        "total_tracks": len(library.tracks),
        "total_playlists": len(library.playlists),
        "total_plays": total_plays,
        "distinct_artists": len({t.artist for t in library.tracks if t.artist}),
        "distinct_genres": len({t.genre for t in library.tracks if t.genre}),
        "top_artists": [a.artist for a in arts],
        "top_genres": [g.genre for g in gens],
    }


def main(argv: Optional[List[str]] = None) -> int:
    """CLI mirroring the other FDA parsers.

    ``--json`` emits a single privacy-safe status line (counts + top
    artist/genre names, the user's own L1 taste). ``--dry-run``
    parses + aggregates but writes no output file and -- crucially --
    leaks no per-track titles to stdout.

    Exit codes
    ----------
    0    success or graceful-skip (no library file present).
    2    argparse failure (Python default).
    other: unexpected crash.
    """
    import argparse
    import json as _json
    import sys

    parser = argparse.ArgumentParser(
        prog="pwg-apple-music",
        description=(
            "Extract the user's music taste (top artists, genres, "
            "playlists, most-played tracks) from the Apple Music / "
            "iTunes library XML, fully on-device."
        ),
    )
    parser.add_argument(
        "--xml-path",
        type=Path,
        default=None,
        help=(
            "Override the library XML path. Default: "
            f"{DEFAULT_LIBRARY_XML} (also honours ${_ENV_OVERRIDE})."
        ),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help=(
            "Directory to write apple_music.json. "
            "Default: ~/.ostler/imports/fda/"
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit a single privacy-safe JSON status line to stdout.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Parse + aggregate but do not write the JSON output file.",
    )
    args = parser.parse_args(argv)

    def _stderr(msg: str) -> None:
        print(msg, file=sys.stderr, flush=True)

    result: dict = {
        "total_tracks": 0,
        "total_playlists": 0,
        "total_plays": 0,
        "distinct_artists": 0,
        "distinct_genres": 0,
        "top_artists": [],
        "top_genres": [],
        "records": 0,
        "status": "ok",
        "errors": [],
    }

    try:
        library = extract_library(xml_path=args.xml_path)
    except Exception as exc:  # noqa: BLE001 -- last-resort guard
        msg = type(exc).__name__
        _stderr(f"pwg-apple-music: unexpected failure ({msg})")
        result["status"] = "error"
        result["errors"].append(msg)
        if args.json:
            print(_json.dumps(result))
        return 1

    if not library.tracks and not library.playlists:
        # No library file or empty export -- graceful skip.
        _stderr("pwg-apple-music: no Apple Music / iTunes library found.")
        result["status"] = "no_library"
        if args.json:
            print(_json.dumps(result))
        return 0

    stats = library_stats(library)
    records = to_records(library)
    result.update(stats)
    result["records"] = len(records)

    if not args.dry_run:
        output_dir = args.output_dir or (
            Path.home() / ".ostler" / "imports" / "fda"
        )
        try:
            output_dir.mkdir(parents=True, exist_ok=True)
            (output_dir / "apple_music.json").write_text(
                _json.dumps(records, indent=2)
            )
        except OSError as exc:
            msg = type(exc).__name__
            _stderr(f"pwg-apple-music: could not write JSON ({msg})")
            result["status"] = "write_error"
            result["errors"].append(msg)
            if args.json:
                print(_json.dumps(result))
            return 0

    _stderr(
        f"pwg-apple-music: parsed {stats['total_tracks']} tracks, "
        f"{stats['total_playlists']} playlists, "
        f"{stats['distinct_artists']} artists, "
        f"{stats['distinct_genres']} genres "
        f"({len(records)} records)"
    )

    if args.json:
        print(_json.dumps(result))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
