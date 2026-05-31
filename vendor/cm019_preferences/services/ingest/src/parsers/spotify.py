"""Spotify data parser."""

import json
import logging
from pathlib import Path
from typing import AsyncIterator, Optional
from datetime import datetime
import aiofiles

from .base import BaseParser, ParsedPreference
from ..config import settings

logger = logging.getLogger(__name__)


class SpotifyParser(BaseParser):
    """
    Parser for Spotify data exports.

    Handles:
    - StreamingHistory*.json (play history)
    - YourLibrary.json (saved tracks/albums)
    - Playlist*.json (playlists)
    - Follow.json (followed artists)
    """

    source_name = "spotify"

    # Spotify-specific file patterns (unique to Spotify exports)
    # Includes both standard (streaminghistory) and extended (streaming_history) formats
    SPOTIFY_UNIQUE_PATTERNS = [
        "streaminghistory",
        "streaming_history",
        "yourlibrary",
        "inferences",
        "podcastinteractivity",
    ]

    # Ambiguous patterns that exist in multiple platforms (e.g., "follow" in Meta)
    SPOTIFY_AMBIGUOUS_PATTERNS = [
        "playlist",
        "follow"
    ]

    def can_parse(self, file_path: Path) -> bool:
        """
        Check if file is a Spotify data export.

        Uses directory path verification to avoid false positives:
        - Unique patterns (streaminghistory, yourlibrary) can match anywhere
        - Ambiguous patterns (follow, playlist) require Spotify directory context
        """
        if file_path.suffix.lower() != '.json':
            return False

        name = file_path.name.lower()
        path_str = str(file_path).lower()

        # Check for Spotify-unique patterns (safe to match without directory check)
        if any(p in name for p in self.SPOTIFY_UNIQUE_PATTERNS):
            return True

        # For ambiguous patterns, verify the file is in a Spotify directory
        # This prevents matching Facebook/Instagram "follow.json" files
        if any(p in name for p in self.SPOTIFY_AMBIGUOUS_PATTERNS):
            spotify_path_indicators = [
                "/spotify/",
                "/spotify_",
                "spotify-",
                "/my_spotify_data/",
                "spotify account data",
            ]
            return any(indicator in path_str for indicator in spotify_path_indicators)

        return False

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Spotify data export."""
        if default_compartment is None:
            default_compartment = settings.default_compartment

        file_name = file_path.name.lower()

        # Handle both standard (StreamingHistory) and extended (Streaming_History) formats
        if "streaminghistory" in file_name or "streaming_history" in file_name:
            async for pref in self._parse_streaming_history(file_path, default_compartment):
                yield pref
        elif "yourlibrary" in file_name:
            async for pref in self._parse_library(file_path, default_compartment):
                yield pref
        elif "playlist" in file_name:
            async for pref in self._parse_playlist(file_path, default_compartment):
                yield pref
        elif "follow" in file_name:
            async for pref in self._parse_follows(file_path, default_compartment):
                yield pref
        elif "inferences" in file_name:
            async for pref in self._parse_inferences(file_path, default_compartment):
                yield pref
        elif "podcastinteractivity" in file_name:
            async for pref in self._parse_podcast_ratings(file_path, default_compartment):
                yield pref

    async def _parse_streaming_history(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Spotify streaming history files.

        Handles two formats:
        - Standard: StreamingHistory*.json (artistName, trackName, msPlayed, endTime)
        - Extended: Streaming_History_*.json (master_metadata_*, ms_played, ts, plus podcasts/audiobooks)

        Yields individual plays with timestamps to enable date-range filtering.
        The pipeline's PreferenceFilter handles frequency aggregation.
        """
        logger.info(f"Parsing Spotify streaming history from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            return

        play_count = 0
        skipped_count = 0

        for item in data:
            try:
                # Detect format by checking for extended format fields
                is_extended = 'master_metadata_track_name' in item or 'ms_played' in item

                if is_extended:
                    # Extended format field names
                    artist_name = (item.get('master_metadata_album_artist_name') or '').strip()
                    track_name = (item.get('master_metadata_track_name') or '').strip()
                    album_name = (item.get('master_metadata_album_album_name') or '').strip()
                    ms_played = item.get('ms_played', 0)
                    skipped = item.get('skipped', False)
                    track_uri = item.get('spotify_track_uri')
                    timestamp_str = item.get('ts')

                    # Podcast episode
                    episode_name = (item.get('episode_name') or '').strip()
                    show_name = (item.get('episode_show_name') or '').strip()

                    # Audiobook
                    audiobook_title = (item.get('audiobook_title') or '').strip()
                else:
                    # Standard format field names
                    artist_name = (item.get('artistName') or '').strip()
                    track_name = (item.get('trackName') or '').strip()
                    album_name = ''
                    ms_played = item.get('msPlayed', 0)
                    skipped = False
                    track_uri = None
                    timestamp_str = item.get('endTime')
                    episode_name = ''
                    show_name = ''
                    audiobook_title = ''

                # Parse timestamp
                observed_at = None
                if timestamp_str:
                    try:
                        # Handle both ISO format with Z suffix and standard format
                        if timestamp_str.endswith('Z'):
                            observed_at = datetime.fromisoformat(timestamp_str.replace('Z', '+00:00'))
                        else:
                            observed_at = datetime.fromisoformat(timestamp_str)
                    except ValueError:
                        pass

                # Skip very short plays (< 30 seconds)
                if ms_played < 30000:
                    skipped_count += 1
                    continue

                play_count += 1

                # Yield music track plays individually
                if track_name and artist_name:
                    extra = {
                        "artist": artist_name,
                        "track": track_name,
                        "duration_ms": ms_played
                    }
                    if album_name:
                        extra["album"] = album_name
                    if track_uri:
                        extra["spotify_uri"] = track_uri
                    if skipped:
                        extra["skipped"] = True

                    yield ParsedPreference(
                        subject=f"{artist_name} - {track_name}",
                        preference_type="Like",
                        category="music",
                        strength=0.10,  # V2: Passive play (could be playlist/shuffle)
                        observed_at=observed_at,
                        source=self.source_name,
                        source_id=track_uri,
                        compartment_level=default_compartment,
                        size="Small",
                        extra=extra
                    )

                # Yield podcast episode plays
                elif episode_name and show_name:
                    yield ParsedPreference(
                        subject=f"{show_name} - {episode_name}",
                        preference_type="Like",
                        category="podcast",
                        strength=0.15,  # V2: Passive consumption
                        observed_at=observed_at,
                        source=self.source_name,
                        compartment_level=default_compartment,
                        size="Small",
                        extra={
                            "show": show_name,
                            "episode": episode_name,
                            "duration_ms": ms_played
                        }
                    )

                # Yield audiobook plays
                elif audiobook_title:
                    yield ParsedPreference(
                        subject=audiobook_title,
                        preference_type="Like",
                        category="book",
                        strength=0.15,  # V2: Passive consumption
                        observed_at=observed_at,
                        source=self.source_name,
                        compartment_level=default_compartment,
                        size="Small",
                        extra={
                            "type": "audiobook",
                            "duration_ms": ms_played
                        }
                    )

            except Exception as e:
                logger.warning(f"Error parsing streaming history item: {e}")
                continue

        logger.info(f"Yielded {play_count} plays ({skipped_count} skipped for short duration)")

    async def _parse_library(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Spotify YourLibrary.json - saved/liked content.

        Contains:
        - tracks: Saved songs (high signal - explicit save action)
        - albums: Saved albums
        - artists: Followed artists
        - shows: Followed podcasts
        """
        logger.info(f"Parsing Spotify library from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse library JSON: {e}")
            return

        # Saved tracks - high signal, explicit save action
        tracks = data.get('tracks', [])
        for track in tracks:
            artist = track.get('artist', '').strip()
            track_name = track.get('track', '').strip()
            album = track.get('album', '').strip()
            uri = track.get('uri', '')

            if track_name and artist:
                yield ParsedPreference(
                    subject=f"{artist} - {track_name}",
                    preference_type="Like",
                    category="music",
                    strength=0.40,  # V2: Explicit like
                    source=self.source_name,
                    source_id=uri,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "type": "saved_track",
                        "artist": artist,
                        "track": track_name,
                        "album": album,
                        "spotify_uri": uri
                    }
                )

        # Saved albums
        albums = data.get('albums', [])
        for album in albums:
            artist = album.get('artist', '').strip()
            album_name = album.get('album', '').strip()
            uri = album.get('uri', '')

            if album_name and artist:
                yield ParsedPreference(
                    subject=f"{artist} - {album_name}",
                    preference_type="Like",
                    category="music",
                    strength=0.45,  # V2: Strong signal (entire album)
                    source=self.source_name,
                    source_id=uri,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "type": "saved_album",
                        "artist": artist,
                        "album": album_name,
                        "spotify_uri": uri
                    }
                )

        # Followed artists
        artists = data.get('artists', [])
        for artist in artists:
            artist_name = artist.get('name', '').strip()
            uri = artist.get('uri', '')

            if artist_name:
                yield ParsedPreference(
                    subject=artist_name,
                    preference_type="Like",
                    category="music",
                    strength=0.45,  # V2: Want updates
                    source=self.source_name,
                    source_id=uri,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "type": "followed_artist",
                        "artist": artist_name,
                        "spotify_uri": uri
                    }
                )

        # Followed shows (podcasts)
        shows = data.get('shows', [])
        for show in shows:
            show_name = show.get('name', '').strip()
            publisher = show.get('publisher', '').strip()
            uri = show.get('uri', '')

            if show_name:
                yield ParsedPreference(
                    subject=show_name,
                    preference_type="Like",
                    category="podcast",
                    strength=0.40,  # V2: Subscription
                    source=self.source_name,
                    source_id=uri,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "type": "followed_show",
                        "show": show_name,
                        "publisher": publisher,
                        "spotify_uri": uri
                    }
                )

        logger.info(f"Parsed library: {len(tracks)} tracks, {len(albums)} albums, {len(artists)} artists, {len(shows)} shows")

    async def _parse_playlist(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Spotify Playlist*.json - user-created or saved playlists.

        Playlist tracks are curated selections - high signal preferences.
        """
        logger.info(f"Parsing Spotify playlist from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse playlist JSON: {e}")
            return

        playlists = data.get('playlists', [])
        total_tracks = 0

        for playlist in playlists:
            playlist_name = playlist.get('name', '').strip()
            items = playlist.get('items', [])

            if not playlist_name:
                continue

            # Yield each track in the playlist
            for item in items:
                track_info = item.get('track', {})
                artist = track_info.get('artistName', '').strip()
                track_name = track_info.get('trackName', '').strip()
                album = track_info.get('albumName', '').strip()
                uri = track_info.get('trackUri', '')

                if track_name and artist:
                    total_tracks += 1
                    yield ParsedPreference(
                        subject=f"{artist} - {track_name}",
                        preference_type="Like",
                        category="music",
                        strength=0.30,  # V2: Curated selection
                        source=self.source_name,
                        source_id=uri,
                        compartment_level=default_compartment,
                        size="Small",
                        extra={
                            "type": "playlist_track",
                            "playlist": playlist_name,
                            "artist": artist,
                            "track": track_name,
                            "album": album,
                            "spotify_uri": uri
                        }
                    )

        logger.info(f"Parsed {len(playlists)} playlists with {total_tracks} total tracks")

    async def _parse_follows(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Spotify Follow.json - social follows.

        Note: This contains user IDs/usernames, not artists.
        Artist follows are in YourLibrary.json.
        """
        logger.info(f"Parsing Spotify follows from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse follows JSON: {e}")
            return

        # Users being followed (these are Spotify users, not artists)
        following = data.get('userIsFollowing', [])

        # We don't yield these as preferences since they're just user IDs
        # which aren't meaningful for preference extraction
        # (artist follows are captured in YourLibrary.json)

        logger.info(f"Found {len(following)} users followed (not yielded - user IDs only)")

        # Must yield at least once to be a valid async generator (even if nothing to yield)
        return
        yield  # Makes this a proper async generator

    async def _parse_inferences(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Spotify Inferences.json - Spotify's demographic/behavioral inferences.

        V2: SKIP these - ML-derived inferences are noise, not real preference signals.
        Contains ML-derived insights about the user (age range, gender, device habits)
        that don't represent actual user preferences.
        """
        logger.info(f"Skipping Spotify inferences (V2: ML noise)")

        # V2: Don't yield ML inferences as preferences
        return
        yield  # Makes this a proper async generator

    async def _parse_podcast_ratings(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Spotify PodcastInteractivityRatedShow.json - explicit podcast ratings.

        Very high signal - user explicitly rated a show.
        """
        logger.info(f"Parsing Spotify podcast ratings from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse podcast ratings JSON: {e}")
            return

        rated_shows = data.get('ratedShows', [])

        for show in rated_shows:
            show_name = show.get('showName', '').strip()
            rating = show.get('rating', 0)
            rated_at = show.get('ratedAt', '')

            if not show_name:
                continue

            # Parse timestamp
            observed_at = None
            if rated_at:
                try:
                    observed_at = datetime.fromisoformat(rated_at.replace('Z', '+00:00'))
                except ValueError:
                    pass

            # Map rating to strength (V2: 1-5 stars to bipolar scale)
            # 5 stars = +0.55, 4 = +0.40, 3 = +0.15, 2 = -0.25, 1 = -0.45
            rating_map = {
                5: (0.55, "Like"),
                4: (0.40, "Like"),
                3: (0.15, "Like"),
                2: (-0.25, "Dislike"),
                1: (-0.45, "Dislike"),
            }
            strength, preference_type = rating_map.get(rating, (0.0, "Neutral"))

            yield ParsedPreference(
                subject=show_name,
                preference_type=preference_type,
                category="podcast",
                strength=strength,
                observed_at=observed_at,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "podcast_rating",
                    "show": show_name,
                    "rating": rating,
                    "rating_max": 5
                }
            )

        logger.info(f"Parsed {len(rated_shows)} podcast ratings")
