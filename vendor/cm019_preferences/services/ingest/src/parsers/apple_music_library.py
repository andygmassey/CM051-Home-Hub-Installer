"""Apple Music library parser (the owner's live Music app library).

Reads ``ostler_apple_music_library.json``, written on the Hub by
``ostler_fda.apple_music`` from the signed ``ostler-music-library`` helper
(Apple's iTunesLibrary framework) or, as a fallback, from the Music app's
optional XML export. One row per track, carrying the raw evidence:

    play_count, skip_count, last_played, added, rating (0-100),
    loved, disliked, in_user_playlist

WHY THIS EXISTS (CM051, Andy 2026-10-14, walk #27). The owner mostly uses
Apple Music, and the Hub's Music taste came 100% from Spotify, because the
only Apple Music path was the optional XML export nobody turns on.

SCORING. Base strengths use the SAME constants the Spotify parser uses for
the same kind of evidence, so neither service is down-weighted by its
parser:

    explicit dislike          -0.45   (Spotify: 1-star)
    star rating 1..5          Spotify's rating map, identical
    loved / favourited         0.40   (Spotify: saved track, explicit like)
    in a playlist they made    0.30   (Spotify: playlist track, curated)
    played or in the library   0.10   (Spotify: passive play), kind "Listen"

An explicit negative (disliked, or a 1-2 star rating) wins over any
positive, because it is the owner saying so. Otherwise the strongest
positive wins. Play count and recency ride in ``extra`` and
``observed_at``; turning them into strength on one shared scale is the
filter's job, not a parser's.
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import AsyncIterator, Optional

from .base import LISTEN, BaseParser, ParsedPreference, describe_json_parse_failure
from ..config import settings

logger = logging.getLogger(__name__)

EXPORT_FILE_NAME = "ostler_apple_music_library.json"
EXPORT_SOURCE = "apple_music_library"

# Identical to SpotifyParser's podcast rating map (stars -> strength, type).
RATING_MAP = {
    5: (0.55, "Like"),
    4: (0.40, "Like"),
    3: (0.15, "Like"),
    2: (-0.25, "Dislike"),
    1: (-0.45, "Dislike"),
}
DISLIKED_STRENGTH = -0.45
LOVED_STRENGTH = 0.40
CURATED_STRENGTH = 0.30
PASSIVE_STRENGTH = 0.10


def _parse_dt(raw) -> Optional[datetime]:
    if not isinstance(raw, str) or not raw:
        return None
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _stars(rating) -> int:
    try:
        r = int(rating or 0)
    except (TypeError, ValueError):
        return 0
    if r <= 0:
        return 0
    return max(1, min(5, round(r / 20)))


def score_track(row: dict) -> tuple:
    """(strength, preference_type, evidence) for one library row."""
    stars = _stars(row.get("rating"))
    if row.get("disliked") is True:
        return DISLIKED_STRENGTH, "Dislike", "disliked"
    if stars in (1, 2):
        s, t = RATING_MAP[stars]
        return s, t, f"rated_{stars}"
    candidates = [(PASSIVE_STRENGTH, "library")]
    if stars:
        candidates.append((RATING_MAP[stars][0], f"rated_{stars}"))
    if row.get("loved") is True:
        candidates.append((LOVED_STRENGTH, "loved"))
    if row.get("in_user_playlist") is True:
        candidates.append((CURATED_STRENGTH, "playlist"))
    strength, evidence = max(candidates, key=lambda c: c[0])
    # Only something the owner SAID is a like: loved, rated, or put in a
    # playlist they made. A track that is merely in the library or played is
    # a listen; its play count still rides in extra and the filter turns it
    # into strength.
    return strength, (LISTEN if evidence == "library" else "Like"), evidence


class AppleMusicLibraryParser(BaseParser):
    """Parser for the Hub's own Apple Music library export."""

    source_name = "apple_music"

    def can_parse(self, file_path: Path) -> bool:
        return file_path.name == EXPORT_FILE_NAME

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs,
    ) -> AsyncIterator[ParsedPreference]:
        if default_compartment is None:
            default_compartment = settings.default_compartment
        content = file_path.read_text(encoding="utf-8", errors="replace")
        try:
            data = json.loads(content)
        except json.JSONDecodeError as exc:
            logger.error(
                "Apple Music library: %s", describe_json_parse_failure(content, exc)
            )
            return
        if not isinstance(data, dict) or data.get("source") != EXPORT_SOURCE:
            logger.warning("Apple Music library: %s is not an Ostler library export", file_path.name)
            return

        n = 0
        for row in data.get("tracks") or []:
            if not isinstance(row, dict):
                continue
            title = (row.get("title") or "").strip()
            if not title:
                continue
            artist = (row.get("artist") or "").strip()
            subject = f"{artist} - {title}" if artist else title
            strength, pref_type, evidence = score_track(row)
            last_played = _parse_dt(row.get("last_played"))
            added = _parse_dt(row.get("added"))
            extra = {
                "type": "library_track",
                "evidence": evidence,
                "track": title,
                "play_count": int(row.get("play_count") or 0),
                "skip_count": int(row.get("skip_count") or 0),
                "rating": int(row.get("rating") or 0),
                "loved": row.get("loved") is True,
                "disliked": row.get("disliked") is True,
                "in_user_playlist": row.get("in_user_playlist") is True,
                "reader": data.get("reader") or "unknown",
            }
            if artist:
                extra["artist"] = artist
            for key in ("album", "genre"):
                if row.get(key):
                    extra[key] = row[key]
            if last_played:
                extra["last_played"] = last_played.isoformat()
            if added:
                extra["added"] = added.isoformat()
            n += 1
            yield ParsedPreference(
                subject=subject,
                preference_type=pref_type,
                category="music",
                strength=strength,
                observed_at=last_played or added,
                source=self.source_name,
                source_id=f"apple_music:{row.get('id')}" if row.get("id") else None,
                compartment_level=default_compartment,
                size="Small",
                extra=extra,
            )
        logger.info("Parsed %d Apple Music library tracks", n)
