"""Netflix data parser."""

import csv
import io
import logging
import zipfile
from pathlib import Path
from typing import AsyncIterator, Optional, Dict, Any, List
from datetime import datetime
import aiofiles

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)


class NetflixParser(BaseParser):
    """
    Parser for Netflix data exports.

    Handles GDPR/privacy data exports which typically include:

    Full GDPR Export Structure:
    ```
    netflix-report/
    ├── CONTENT_INTERACTION/
    │   ├── ViewingActivity.csv      # Main viewing history
    │   ├── SearchHistory.csv        # Search queries
    │   ├── IndicatedPreferences.csv # Thumbs up/down ratings
    │   └── MyList.csv               # "My List" items
    ├── PROFILES/
    │   └── Profiles.csv             # Profile names
    └── Cover sheet.pdf              # Data dictionary
    ```

    ViewingActivity.csv columns (10 total):
    - Profile Name: User profile
    - Start Time: When viewing started (YYYY-MM-DD HH:MM:SS, UTC)
    - Duration: How long watched (HH:MM:SS)
    - Attributes: Additional flags
    - Title: Content title (format: "Show: Season X: Episode" or just "Movie Title")
    - Supplemental Video Type: Trailers, previews, etc.
    - Device Type: Device used
    - Bookmark: Playback position
    - Latest Bookmark: Most recent position
    - Country: Viewing country

    Simple Download (NetflixViewingHistory.csv):
    - Title: Content title
    - Date: Date watched (MM/DD/YY or DD/MM/YYYY depending on region)

    Supports:
    - ZIP archive containing full export
    - Individual CSV files (ViewingActivity, SearchHistory, etc.)
    - Simple viewing history download (NetflixViewingHistory.csv)
    """

    source_name = "netflix"

    # Netflix-specific file patterns
    NETFLIX_UNIQUE_PATTERNS = [
        "viewingactivity",
        "netflixviewinghistory",
        "netflix_viewing",
        "indicatedpreferences",
        "ratings",  # Actual ratings file in GDPR exports
        "searchhistory",
        "mylist",
        "gameplaysession",  # Netflix Games
    ]

    # Directory patterns that indicate Netflix export
    NETFLIX_PATH_INDICATORS = [
        "/netflix/",
        "/netflix-",
        "netflix_",
        "/netflix-report/",
        "/content_interaction/",
    ]

    def can_parse(self, file_path: Path) -> bool:
        """
        Check if file is a Netflix data export.

        Matches:
        - ZIP files with 'netflix' in name or containing Netflix files
        - CSV files with Netflix-specific naming patterns
        - Files in Netflix export directory structure
        """
        name = file_path.name.lower()
        path_str = str(file_path).lower()

        # Check for ZIP file
        if file_path.suffix.lower() == '.zip':
            if 'netflix' in name:
                return True
            # Check ZIP contents for Netflix patterns
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = [n.lower() for n in zf.namelist()]
                    return any(
                        any(p in n for p in self.NETFLIX_UNIQUE_PATTERNS)
                        for n in names
                    )
            except Exception:
                return False

        # Check for CSV files
        if file_path.suffix.lower() == '.csv':
            # Check for Netflix-unique filename patterns
            if any(p in name for p in self.NETFLIX_UNIQUE_PATTERNS):
                return True

            # Check if in Netflix directory structure
            if any(ind in path_str for ind in self.NETFLIX_PATH_INDICATORS):
                return True

        return False

    # Default profiles to include (None = all profiles)
    # Set to filter family account to only specific users
    ALLOWED_PROFILES: Optional[List[str]] = ["Andy", "The Masseys"]

    def _is_profile_allowed(
        self,
        profile: str,
        allowed_profiles: Optional[List[str]]
    ) -> bool:
        """Check if a profile should be included."""
        if allowed_profiles is None:
            return True
        if not profile:
            return True  # Include if no profile info available
        return profile in allowed_profiles

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Netflix data export."""
        if default_compartment is None:
            default_compartment = 2  # L2 Trusted

        # Allow override via kwargs
        allowed_profiles = kwargs.get('profiles', self.ALLOWED_PROFILES)

        logger.info(f"Parsing Netflix data from {file_path}")
        if allowed_profiles:
            logger.info(f"Filtering to profiles: {allowed_profiles}")

        if file_path.suffix.lower() == '.zip':
            async for pref in self._parse_zip(file_path, default_compartment, allowed_profiles):
                yield pref
        elif file_path.suffix.lower() == '.csv':
            async for pref in self._parse_csv_file(file_path, default_compartment, allowed_profiles):
                yield pref

    async def _parse_zip(
        self,
        file_path: Path,
        default_compartment: int,
        allowed_profiles: Optional[List[str]] = None
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Netflix ZIP archive."""
        with zipfile.ZipFile(file_path, 'r') as zf:
            for name in zf.namelist():
                name_lower = name.lower()

                if not name_lower.endswith('.csv'):
                    continue

                content = zf.read(name).decode('utf-8')

                if 'viewingactivity' in name_lower or 'viewing_activity' in name_lower:
                    async for pref in self._parse_viewing_activity(
                        content, default_compartment, allowed_profiles
                    ):
                        yield pref

                elif 'netflixviewinghistory' in name_lower:
                    async for pref in self._parse_simple_history(
                        content, default_compartment
                    ):
                        yield pref

                elif 'indicatedpreferences' in name_lower:
                    async for pref in self._parse_ratings(
                        content, default_compartment, allowed_profiles
                    ):
                        yield pref

                elif '/ratings.csv' in name_lower or name_lower.endswith('ratings.csv'):
                    async for pref in self._parse_ratings(
                        content, default_compartment, allowed_profiles
                    ):
                        yield pref

                elif 'gameplaysession' in name_lower:
                    async for pref in self._parse_game_sessions(
                        content, default_compartment, allowed_profiles
                    ):
                        yield pref

                elif 'searchhistory' in name_lower:
                    async for pref in self._parse_search_history(
                        content, default_compartment, allowed_profiles
                    ):
                        yield pref

                elif 'mylist' in name_lower:
                    async for pref in self._parse_my_list(
                        content, default_compartment, allowed_profiles
                    ):
                        yield pref

    async def _parse_csv_file(
        self,
        file_path: Path,
        default_compartment: int,
        allowed_profiles: Optional[List[str]] = None
    ) -> AsyncIterator[ParsedPreference]:
        """Parse individual Netflix CSV file."""
        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        name_lower = file_path.name.lower()

        if 'viewingactivity' in name_lower or 'viewing_activity' in name_lower:
            async for pref in self._parse_viewing_activity(content, default_compartment, allowed_profiles):
                yield pref

        elif 'netflixviewinghistory' in name_lower:
            async for pref in self._parse_simple_history(content, default_compartment):
                yield pref

        elif 'indicatedpreferences' in name_lower:
            async for pref in self._parse_ratings(content, default_compartment, allowed_profiles):
                yield pref

        elif 'searchhistory' in name_lower:
            async for pref in self._parse_search_history(content, default_compartment, allowed_profiles):
                yield pref

        elif 'mylist' in name_lower:
            async for pref in self._parse_my_list(content, default_compartment, allowed_profiles):
                yield pref

    async def _parse_viewing_activity(
        self,
        content: str,
        default_compartment: int,
        allowed_profiles: Optional[List[str]] = None
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse ViewingActivity.csv from full GDPR export.

        Expected columns:
        - Profile Name, Start Time, Duration, Attributes, Title,
          Supplemental Video Type, Device Type, Bookmark, Latest Bookmark, Country

        Yields individual viewing sessions with timestamps.
        """
        logger.info("Parsing Netflix ViewingActivity.csv")

        reader = csv.DictReader(io.StringIO(content))
        view_count = 0
        skipped_count = 0
        profile_skipped = 0

        for row in reader:
            try:
                # Check profile filter first
                profile = (
                    row.get('Profile Name') or
                    row.get('profile_name') or
                    ''
                ).strip()

                if not self._is_profile_allowed(profile, allowed_profiles):
                    profile_skipped += 1
                    continue

                # Get title - handle various column name formats
                title = (
                    row.get('Title') or
                    row.get('title') or
                    row.get('TITLE') or
                    ''
                ).strip()

                if not title:
                    continue

                # Skip supplemental content (trailers, previews)
                supplemental = (
                    row.get('Supplemental Video Type') or
                    row.get('supplemental_video_type') or
                    ''
                ).strip().lower()

                if supplemental in ('trailer', 'preview', 'hook', 'teaser'):
                    skipped_count += 1
                    continue

                # Parse duration to skip very short views
                duration_str = (
                    row.get('Duration') or
                    row.get('duration') or
                    ''
                ).strip()

                duration_seconds = self._parse_duration(duration_str)
                if duration_seconds is not None and duration_seconds < 60:
                    # Skip views under 1 minute (likely accidental)
                    skipped_count += 1
                    continue

                # Parse timestamp
                timestamp_str = (
                    row.get('Start Time') or
                    row.get('start_time') or
                    row.get('Date') or
                    ''
                ).strip()

                observed_at = self._parse_timestamp(timestamp_str)

                # Parse title to extract show/movie info
                parsed = self._parse_title(title)
                view_count += 1

                # Determine category (movie vs tv_show)
                category = 'movie' if parsed['is_movie'] else 'tv_show'

                # Build subject line
                if parsed['is_movie']:
                    subject = parsed['show_name']
                else:
                    # For TV: include season/episode info
                    subject = parsed['show_name']
                    if parsed['episode_title']:
                        subject = f"{parsed['show_name']} - {parsed['episode_title']}"

                extra = {
                    "type": "viewing",
                    "platform": "Netflix",
                    "duration_seconds": duration_seconds,
                }

                if parsed['season']:
                    extra["season"] = parsed['season']
                if parsed['episode_number']:
                    extra["episode_number"] = parsed['episode_number']
                if parsed['episode_title'] and parsed['episode_title'] != title:
                    extra["episode_title"] = parsed['episode_title']

                if profile:
                    extra["profile"] = profile

                device = (
                    row.get('Device Type') or
                    row.get('device_type') or
                    ''
                ).strip()
                if device:
                    extra["device"] = device

                yield ParsedPreference(
                    subject=subject,
                    preference_type="Like",
                    category=category,
                    strength=0.15,  # V2: Passive view (might not have liked)
                    observed_at=observed_at,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra=extra
                )

            except Exception as e:
                logger.warning(f"Error parsing viewing activity row: {e}")
                continue

        logger.info(f"Parsed {view_count} Netflix views ({skipped_count} skipped, {profile_skipped} filtered by profile)")

    async def _parse_simple_history(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse simple NetflixViewingHistory.csv download.

        Expected format: Title, Date (just 2 columns)
        Date format: MM/DD/YY or DD/MM/YYYY depending on region
        """
        logger.info("Parsing Netflix simple viewing history")

        reader = csv.DictReader(io.StringIO(content))
        view_count = 0

        for row in reader:
            try:
                title = (
                    row.get('Title') or
                    row.get('title') or
                    list(row.values())[0] if row else ''
                ).strip()

                if not title:
                    continue

                # Parse date - handle multiple formats
                date_str = (
                    row.get('Date') or
                    row.get('date') or
                    (list(row.values())[1] if len(row) > 1 else '')
                ).strip()

                observed_at = self._parse_timestamp(date_str)

                # Parse title
                parsed = self._parse_title(title)
                category = 'movie' if parsed['is_movie'] else 'tv_show'

                subject = parsed['show_name']
                if not parsed['is_movie'] and parsed['episode_title']:
                    subject = f"{parsed['show_name']} - {parsed['episode_title']}"

                view_count += 1

                extra = {
                    "type": "viewing",
                    "platform": "Netflix",
                }
                if parsed['season']:
                    extra["season"] = parsed['season']
                if parsed['episode_title']:
                    extra["episode_title"] = parsed['episode_title']

                yield ParsedPreference(
                    subject=subject,
                    preference_type="Like",
                    category=category,
                    strength=0.15,  # V2: Passive view
                    observed_at=observed_at,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra=extra
                )

            except Exception as e:
                logger.warning(f"Error parsing simple history row: {e}")
                continue

        logger.info(f"Parsed {view_count} Netflix views from simple history")

    async def _parse_ratings(
        self,
        content: str,
        default_compartment: int,
        allowed_profiles: Optional[List[str]] = None
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Ratings.csv (thumbs up/down ratings from GDPR export).

        Actual GDPR format columns:
        - Profile Name, Device Model, Star Value, Rating Type, Title Name,
          Thumbs Value, Event Utc Ts, Region View Date

        Thumbs Value meanings:
        - 0 = thumbs down
        - 1 = thumbs up
        - 2 = two thumbs down (strong dislike)
        - 3 = two thumbs up (strong like)
        """
        logger.info("Parsing Netflix ratings")

        reader = csv.DictReader(io.StringIO(content))
        rating_count = 0

        for row in reader:
            try:
                # Check profile filter first
                profile = row.get('Profile Name', '').strip()
                if not self._is_profile_allowed(profile, allowed_profiles):
                    continue

                # Try various column names for title (GDPR uses "Title Name")
                title = (
                    row.get('Title Name') or
                    row.get('Show Name') or
                    row.get('Title') or
                    row.get('title') or
                    row.get('Name') or
                    ''
                ).strip()

                if not title:
                    continue

                # Get Thumbs Value (GDPR format: 0=down, 1=up, 2=strong down, 3=strong up)
                thumbs_value = row.get('Thumbs Value', '').strip()

                # Also check legacy format columns
                rating = (
                    row.get('Rating') or
                    row.get('rating') or
                    row.get('Thumb') or
                    row.get('Preference') or
                    ''
                ).strip().lower()

                # Determine preference type and strength (V2: bipolar scale)
                if thumbs_value == '3':
                    # Two thumbs up - strong like
                    preference_type = "Like"
                    strength = 0.50  # V2: Strong positive
                    rating_label = "two_thumbs_up"
                elif thumbs_value == '1':
                    # Thumbs up
                    preference_type = "Like"
                    strength = 0.35  # V2: Explicit positive
                    rating_label = "thumbs_up"
                elif thumbs_value == '0':
                    # Thumbs down
                    preference_type = "Dislike"
                    strength = -0.35  # V2: Explicit negative
                    rating_label = "thumbs_down"
                elif thumbs_value == '2':
                    # Two thumbs down - strong dislike
                    preference_type = "Dislike"
                    strength = -0.50  # V2: Strong negative
                    rating_label = "two_thumbs_down"
                elif rating in ('thumbs up', 'thumb up', 'up', 'liked', 'like', '1', 'positive'):
                    preference_type = "Like"
                    strength = 0.35  # V2: Explicit positive
                    rating_label = "thumbs_up"
                elif rating in ('thumbs down', 'thumb down', 'down', 'disliked', 'dislike', '-1', 'negative'):
                    preference_type = "Dislike"
                    strength = -0.35  # V2: Explicit negative
                    rating_label = "thumbs_down"
                else:
                    # Default to weak like if unclear
                    preference_type = "Like"
                    strength = 0.15  # V2: Weak positive
                    rating_label = "unknown"

                # Parse date (GDPR uses "Event Utc Ts")
                date_str = (
                    row.get('Event Utc Ts') or
                    row.get('Rating Date') or
                    row.get('Date') or
                    ''
                ).strip()
                observed_at = self._parse_timestamp(date_str)

                # Parse title for categorization
                parsed = self._parse_title(title)
                category = 'movie' if parsed['is_movie'] else 'tv_show'

                rating_count += 1

                extra = {
                    "type": "rating",
                    "platform": "Netflix",
                    "rating_type": rating_label,
                }
                if profile:
                    extra["profile"] = profile

                yield ParsedPreference(
                    subject=parsed['show_name'],
                    preference_type=preference_type,
                    category=category,
                    strength=strength,
                    observed_at=observed_at,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",  # Ratings are explicit preferences
                    extra=extra
                )

            except Exception as e:
                logger.warning(f"Error parsing ratings row: {e}")
                continue

        logger.info(f"Parsed {rating_count} Netflix ratings")

    async def _parse_search_history(
        self,
        content: str,
        default_compartment: int,
        allowed_profiles: Optional[List[str]] = None
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse SearchHistory.csv.

        GDPR format columns:
        - Query Typed, Profile Name, Country Iso Code, Displayed Name,
          Utc Timestamp, Action, Is Kids, Section, Device
        """
        logger.info("Parsing Netflix search history")

        reader = csv.DictReader(io.StringIO(content))
        search_count = 0

        for row in reader:
            try:
                # Check profile filter first
                profile = row.get('Profile Name', '').strip()
                if not self._is_profile_allowed(profile, allowed_profiles):
                    continue

                # GDPR uses "Query Typed" column
                query = (
                    row.get('Query Typed') or
                    row.get('Query') or
                    row.get('Search') or
                    row.get('query') or
                    ''
                ).strip()

                if not query or len(query) < 2:
                    continue

                # Parse date - GDPR uses "Utc Timestamp"
                date_str = (
                    row.get('Utc Timestamp') or
                    row.get('Date') or
                    row.get('Time') or
                    ''
                ).strip()
                observed_at = self._parse_timestamp(date_str)

                # Get displayed name (what Netflix showed as result)
                displayed_name = row.get('Displayed Name', '').strip()

                search_count += 1

                extra = {
                    "type": "search",
                    "platform": "Netflix",
                }
                if displayed_name:
                    extra["displayed_result"] = displayed_name
                if profile:
                    extra["profile"] = profile

                yield ParsedPreference(
                    subject=query,
                    preference_type="Like",
                    category="search",
                    strength=0.12,  # V2: Curiosity signal
                    observed_at=observed_at,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra=extra
                )

            except Exception as e:
                logger.warning(f"Error parsing search row: {e}")
                continue

        logger.info(f"Parsed {search_count} Netflix searches")

    async def _parse_my_list(
        self,
        content: str,
        default_compartment: int,
        allowed_profiles: Optional[List[str]] = None
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse MyList.csv (titles added to "My List").

        GDPR format columns:
        - Profile Name, Country, Utc Title Add Date, Title Name

        Being on My List indicates intent to watch - a moderate preference signal.
        """
        logger.info("Parsing Netflix My List")

        reader = csv.DictReader(io.StringIO(content))
        list_count = 0

        for row in reader:
            try:
                # Check profile filter first
                profile = row.get('Profile Name', '').strip()
                if not self._is_profile_allowed(profile, allowed_profiles):
                    continue

                # GDPR uses "Title Name" column
                title = (
                    row.get('Title Name') or
                    row.get('Title') or
                    row.get('title') or
                    row.get('Name') or
                    ''
                ).strip()

                if not title:
                    continue

                # Parse date added - GDPR uses "Utc Title Add Date"
                date_str = (
                    row.get('Utc Title Add Date') or
                    row.get('Date Added') or
                    row.get('Date') or
                    ''
                ).strip()
                observed_at = self._parse_timestamp(date_str)

                parsed = self._parse_title(title)
                category = 'movie' if parsed['is_movie'] else 'tv_show'

                list_count += 1

                extra = {
                    "type": "watchlist",
                    "platform": "Netflix",
                }
                if profile:
                    extra["profile"] = profile

                yield ParsedPreference(
                    subject=parsed['show_name'],
                    preference_type="Like",
                    category=category,
                    strength=0.25,  # V2: Intent to watch
                    observed_at=observed_at,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra=extra
                )

            except Exception as e:
                logger.warning(f"Error parsing My List row: {e}")
                continue

        logger.info(f"Parsed {list_count} Netflix My List items")

    async def _parse_game_sessions(
        self,
        content: str,
        default_compartment: int,
        allowed_profiles: Optional[List[str]] = None
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse GamePlaySession.csv (Netflix Games).

        Expected columns:
        - Duration, Start Time, Profile Name, Country, Game Version, Esn,
          Ip, Device Type, Game Title, Platform
        """
        logger.info("Parsing Netflix game sessions")

        reader = csv.DictReader(io.StringIO(content))
        game_count = 0

        for row in reader:
            try:
                # Check profile filter first
                profile = row.get('Profile Name', '').strip()
                if not self._is_profile_allowed(profile, allowed_profiles):
                    continue

                game_title = (
                    row.get('Game Title') or
                    row.get('game_title') or
                    ''
                ).strip()

                if not game_title:
                    continue

                # Parse duration (in seconds)
                duration_str = row.get('Duration', '').strip()
                try:
                    duration_seconds = int(duration_str) if duration_str else None
                except ValueError:
                    duration_seconds = None

                # Skip very short sessions (under 30 seconds)
                if duration_seconds is not None and duration_seconds < 30:
                    continue

                # Parse timestamp
                timestamp_str = (
                    row.get('Start Time') or
                    row.get('start_time') or
                    ''
                ).strip()
                observed_at = self._parse_timestamp(timestamp_str)

                game_platform = row.get('Platform', '').strip()
                device = row.get('Device Type', '').strip()

                game_count += 1

                extra = {
                    "type": "game_session",
                    "platform": "Netflix Games",
                    "duration_seconds": duration_seconds,
                }
                if profile:
                    extra["profile"] = profile
                if game_platform:
                    extra["game_platform"] = game_platform
                if device:
                    extra["device"] = device

                yield ParsedPreference(
                    subject=game_title,
                    preference_type="Like",
                    category="game",
                    strength=0.20,  # V2: Engagement signal
                    observed_at=observed_at,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra=extra
                )

            except Exception as e:
                logger.warning(f"Error parsing game session row: {e}")
                continue

        logger.info(f"Parsed {game_count} Netflix game sessions")

    def _parse_title(self, title: str) -> Dict[str, Any]:
        """
        Parse Netflix title format.

        Netflix uses colon-separated format:
        - Movies: "Movie Title"
        - TV Shows: "Show Name: Season X: Episode Title (Episode Y)"

        Returns dict with:
        - show_name: Base show/movie name
        - season: Season number (if present)
        - episode_title: Episode title (if present)
        - episode_number: Episode number (if present)
        - is_movie: True if appears to be a movie
        """
        result = {
            'show_name': title,
            'season': None,
            'episode_title': None,
            'episode_number': None,
            'is_movie': True,
        }

        if not title:
            return result

        # Split by colon
        parts = [p.strip() for p in title.split(':')]

        if len(parts) == 1:
            # Single part - likely a movie
            result['show_name'] = parts[0]
            result['is_movie'] = True
            return result

        # Multiple parts - likely a TV show
        result['show_name'] = parts[0]
        result['is_movie'] = False

        for i, part in enumerate(parts[1:], 1):
            part_lower = part.lower()

            # Check for season indicator
            if 'season' in part_lower or part_lower.startswith('s') and part_lower[1:].split()[0].isdigit():
                # Extract season number
                import re
                season_match = re.search(r'season\s*(\d+)|s(\d+)', part_lower)
                if season_match:
                    result['season'] = int(season_match.group(1) or season_match.group(2))
                continue

            # Check for episode info
            episode_match = None
            import re
            episode_match = re.search(r'\(episode\s*(\d+)\)|\bep\.?\s*(\d+)\b|episode\s*(\d+)', part_lower)
            if episode_match:
                result['episode_number'] = int(
                    episode_match.group(1) or
                    episode_match.group(2) or
                    episode_match.group(3)
                )
                # Extract episode title (part before the episode number notation)
                ep_title = re.sub(r'\s*\(episode\s*\d+\)|\s*ep\.?\s*\d+\s*$', '', part, flags=re.IGNORECASE).strip()
                if ep_title:
                    result['episode_title'] = ep_title
            elif i == len(parts) - 1:
                # Last part without episode marker is likely episode title
                result['episode_title'] = part

        return result

    def _parse_duration(self, duration_str: str) -> Optional[int]:
        """
        Parse duration string to seconds.

        Expected format: HH:MM:SS or H:MM:SS
        """
        if not duration_str:
            return None

        try:
            parts = duration_str.split(':')
            if len(parts) == 3:
                hours, minutes, seconds = int(parts[0]), int(parts[1]), int(parts[2])
                return hours * 3600 + minutes * 60 + seconds
            elif len(parts) == 2:
                minutes, seconds = int(parts[0]), int(parts[1])
                return minutes * 60 + seconds
        except (ValueError, IndexError):
            pass

        return None

    def _parse_timestamp(self, value: str) -> Optional[datetime]:
        """
        Parse various Netflix date/time formats.

        Supported formats:
        - YYYY-MM-DD HH:MM:SS (ViewingActivity.csv)
        - MM/DD/YY (simple history, US format)
        - DD/MM/YYYY (simple history, EU format)
        - YYYY-MM-DD (date only)
        """
        if not value:
            return None

        # Try common formats
        formats = [
            "%Y-%m-%d %H:%M:%S",  # Full datetime (ViewingActivity)
            "%Y-%m-%dT%H:%M:%S",  # ISO format
            "%Y-%m-%dT%H:%M:%SZ",  # ISO with Z
            "%m/%d/%y",  # US short date
            "%d/%m/%y",  # EU short date
            "%m/%d/%Y",  # US full year
            "%d/%m/%Y",  # EU full year
            "%Y-%m-%d",  # Date only
            "%Y/%m/%d",  # Alternative date
        ]

        for fmt in formats:
            try:
                return datetime.strptime(value.strip(), fmt)
            except ValueError:
                continue

        return None
