"""Disney+ data parser."""

import json
import csv
import io
import logging
import os
import zipfile
from pathlib import Path
from typing import AsyncIterator, Optional, Dict, Any, List
from datetime import datetime
import aiofiles

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)

# Optional Excel dependencies (only needed for .xlsx exports)
try:
    import openpyxl
    import msoffcrypto
    HAS_EXCEL_SUPPORT = True
except ImportError:
    HAS_EXCEL_SUPPORT = False


class DisneyPlusParser(BaseParser):
    """
    Parser for Disney+ data exports.

    Handles GDPR/privacy data exports which typically include:
    - Viewing history (shows/movies watched)
    - Watchlist data
    - Account information
    - Profile preferences

    Supports common export formats:
    - ZIP archive with JSON/CSV files
    - Direct JSON files
    - Direct CSV files

    IMPORTANT: This parser is strict about matching ONLY Disney+ exports.
    Generic patterns like 'viewing' or 'profile' alone are NOT matched
    to prevent false positives from other data exports (e.g., Amazon Alexa).
    """

    source_name = "disney_plus"

    # Content types that are definitely NOT TV/movie content
    REJECTED_CONTENT_TYPES = {
        'appliance', 'alias', 'device', 'scene', 'light', 'switch',
        'sensor', 'thermostat', 'routine', 'automation', 'smart_home',
    }

    # Default profiles to include (None = all profiles)
    # Set to filter family account to only specific users
    ALLOWED_PROFILES: Optional[List[str]] = ["Andy", "The Masseys"]

    # Patterns in subjects that indicate non-viewing data (smart home, calendar, etc.)
    BAD_SUBJECT_PATTERNS = [
        # Smart home devices
        'echo show', 'alexa', 'hue lights', 'aircon', 'dehumidifier',
        'purifier', 'charger', 'sensor', 'switch', 'lamp', 'lights off',
        'lights on', 'dyson', 'nanoleaf', 'firetv', 'fire tv', 'bedroom',
        'living room', 'man cave', 'massey\'s home',
        # Calendar/reminder patterns
        'pay tax', 'pay bill', 'meeting', 'parking due', 'easter holidays',
        'christmas', 'birthday', ' - pay ', ' - call ', ' - meet ',
        # Trailers and promotional content (not actual viewing)
        'trailer |', '| a special look', '| special look',
    ]

    # Regex-like patterns for subjects that are too generic to be useful
    # (episode numbers without series context)
    GENERIC_EPISODE_PATTERNS = [
        'episode ',  # "Episode 1", "Episode 13", etc.
        'part ',     # "Part I", "Part V", etc. (but not "Part I and Part II" compounds)
    ]

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a Disney+ data export.

        STRICT matching: Requires explicit 'disney' in the path or filename
        to avoid false positives from other streaming/media exports.
        """
        name = file_path.name.lower()
        full_path = str(file_path).lower()

        # STRICT: Must have 'disney' somewhere in the path or filename
        if 'disney' not in full_path:
            return False

        # Check for ZIP file with Disney naming
        if file_path.suffix.lower() == '.zip':
            if 'disney' in name:
                return True
            # Check ZIP contents - but still require 'disney' in path (already checked above)
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = [n.lower() for n in zf.namelist()]
                    disney_patterns = ['viewing', 'watchlist', 'watch_history']
                    return any(any(p in n for p in disney_patterns) for n in names)
            except Exception:
                return False

        # Check for Excel files (GDPR exports often arrive as encrypted xlsx)
        if file_path.suffix.lower() in ('.xlsx', '.xls'):
            return True  # 'disney' already confirmed in path above

        # Check for individual files
        if file_path.suffix.lower() in ('.json', '.csv'):
            disney_patterns = ['disney', 'viewing_history', 'watchlist', 'watch_history']
            return any(p in name for p in disney_patterns)

        return False

    def _is_profile_allowed(
        self, profile_name: Optional[str], allowed_profiles: Optional[List[str]]
    ) -> bool:
        """Check if a profile should be included."""
        if not allowed_profiles:
            return True  # No filter = include all
        if not profile_name:
            return True  # No profile info = include (can't filter)
        return profile_name in allowed_profiles

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Disney+ data export.

        Args:
            file_path: Path to export file
            default_compartment: Privacy compartment level
            **kwargs:
                profiles: List of profile names to include (overrides ALLOWED_PROFILES)
                password: Password for encrypted xlsx files (or set DISNEY_XLSX_PASSWORD env var)
        """
        if default_compartment is None:
            default_compartment = 2  # L2 Trusted

        allowed_profiles = kwargs.get('profiles', self.ALLOWED_PROFILES)

        logger.info(f"Parsing Disney+ data from {file_path}")
        if allowed_profiles:
            logger.info(f"Profile filter: {allowed_profiles}")

        if file_path.suffix.lower() in ('.xlsx', '.xls'):
            password = kwargs.get('password') or os.environ.get('DISNEY_XLSX_PASSWORD')
            async for pref in self._parse_xlsx_file(file_path, default_compartment, allowed_profiles, password):
                yield pref
        elif file_path.suffix.lower() == '.zip':
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == '.json':
            async for pref in self._parse_json_file(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == '.csv':
            async for pref in self._parse_csv_file(file_path, default_compartment):
                yield pref

    async def _parse_xlsx_file(
        self,
        file_path: Path,
        default_compartment: int,
        allowed_profiles: Optional[List[str]] = None,
        password: Optional[str] = None
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Disney+ encrypted XLSX export (GDPR format).

        Disney+ GDPR exports arrive as password-protected Excel files with:
        - Profile sheet: account info (email, DOB, etc.)
        - watchHistoryDetails sheet: viewing history with columns:
            date, service, profile_id, device_id, program_title, create_ts, end_ts
        """
        if not HAS_EXCEL_SUPPORT:
            logger.error("openpyxl and msoffcrypto-tool required for Excel parsing. "
                         "Install with: pip install openpyxl msoffcrypto-tool")
            return

        # Read and decrypt the file
        wb = None
        try:
            with open(file_path, 'rb') as f:
                ms = msoffcrypto.OfficeFile(f)
                if ms.is_encrypted():
                    if not password:
                        logger.error(f"File is encrypted. Provide password via 'password' kwarg "
                                     f"or DISNEY_XLSX_PASSWORD env var")
                        return
                    decrypted = io.BytesIO()
                    ms.load_key(password=password)
                    ms.decrypt(decrypted)
                    decrypted.seek(0)
                    wb = openpyxl.load_workbook(decrypted, read_only=True)
                else:
                    wb = openpyxl.load_workbook(file_path, read_only=True)
        except Exception as e:
            logger.error(f"Failed to open Excel file: {e}")
            return

        try:
            # Find the watch history sheet (name may have trailing space)
            watch_sheet = None
            for name in wb.sheetnames:
                if 'watchhistory' in name.lower().replace(' ', ''):
                    watch_sheet = wb[name]
                    break

            if not watch_sheet:
                logger.warning(f"No watch history sheet found. Sheets: {wb.sheetnames}")
                return

            # Read header row to map columns
            rows = list(watch_sheet.iter_rows(values_only=True))
            if not rows:
                return

            header = [str(h).strip().lower() if h else '' for h in rows[0]]
            data_rows = rows[1:]

            logger.info(f"Found {len(data_rows)} rows in watch history sheet")
            logger.info(f"Columns: {header}")

            # Map columns by name for flexibility
            col_map = {name: idx for idx, name in enumerate(header)}

            # Convert rows to dicts for _parse_viewing_list
            viewing_items = []
            profile_counts = {}
            filtered_by_profile = 0

            for row in data_rows:
                # Extract profile for filtering
                profile_idx = col_map.get('profile_id', col_map.get('profile', None))
                profile = str(row[profile_idx]).strip() if profile_idx is not None and row[profile_idx] else None

                # Track profile distribution
                profile_counts[profile] = profile_counts.get(profile, 0) + 1

                # Apply profile filter
                if not self._is_profile_allowed(profile, allowed_profiles):
                    filtered_by_profile += 1
                    continue

                # Extract title
                title_idx = col_map.get('program_title', col_map.get('title', col_map.get('name', None)))
                title = str(row[title_idx]).strip() if title_idx is not None and row[title_idx] else None
                if not title:
                    continue

                # Extract timestamp
                ts_idx = col_map.get('create_ts', col_map.get('date', col_map.get('timestamp', None)))
                timestamp_val = row[ts_idx] if ts_idx is not None else None

                # Build item dict compatible with existing _parse_viewing_list
                item = {
                    'title': title,
                    'content_type': 'unknown',  # XLSX doesn't distinguish movies vs episodes
                }

                # Parse timestamp
                if timestamp_val:
                    if isinstance(timestamp_val, datetime):
                        item['watched_at'] = timestamp_val.strftime('%Y-%m-%dT%H:%M:%S')
                    elif isinstance(timestamp_val, str):
                        item['watched_at'] = timestamp_val[:19]

                viewing_items.append(item)

            logger.info(f"Profile distribution: {profile_counts}")
            logger.info(f"Filtered by profile: {filtered_by_profile}")
            logger.info(f"Items to process: {len(viewing_items)}")

            # Use existing viewing list aggregation logic
            async for pref in self._parse_viewing_list(viewing_items, default_compartment):
                yield pref

        finally:
            wb.close()

    async def _parse_zip(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Disney+ ZIP archive."""
        with zipfile.ZipFile(file_path, 'r') as zf:
            for name in zf.namelist():
                name_lower = name.lower()

                if name_lower.endswith('.json'):
                    content = zf.read(name).decode('utf-8')
                    try:
                        data = json.loads(content)
                        async for pref in self._parse_json_content(data, name_lower, default_compartment):
                            yield pref
                    except json.JSONDecodeError:
                        logger.warning(f"Failed to parse JSON: {name}")

                elif name_lower.endswith('.csv'):
                    content = zf.read(name).decode('utf-8')
                    async for pref in self._parse_csv_content(content, name_lower, default_compartment):
                        yield pref

    async def _parse_json_file(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Disney+ JSON file."""
        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
            async for pref in self._parse_json_content(data, file_path.name.lower(), default_compartment):
                yield pref
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")

    async def _parse_csv_file(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Disney+ CSV file."""
        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()
        async for pref in self._parse_csv_content(content, file_path.name.lower(), default_compartment):
            yield pref

    async def _parse_json_content(
        self,
        data: Any,
        filename: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse JSON content from Disney+ export."""

        # Handle different possible JSON structures
        if isinstance(data, list):
            # List of viewing records
            async for pref in self._parse_viewing_list(data, default_compartment):
                yield pref
        elif isinstance(data, dict):
            # Check for common keys
            if 'viewingHistory' in data or 'viewing_history' in data:
                history = data.get('viewingHistory', data.get('viewing_history', []))
                async for pref in self._parse_viewing_list(history, default_compartment):
                    yield pref

            if 'watchlist' in data or 'Watchlist' in data:
                watchlist = data.get('watchlist', data.get('Watchlist', []))
                async for pref in self._parse_watchlist(watchlist, default_compartment):
                    yield pref

            if 'profiles' in data:
                for profile in data.get('profiles', []):
                    if 'preferences' in profile:
                        async for pref in self._parse_preferences(profile['preferences'], default_compartment):
                            yield pref

            # Handle flat viewing record
            if 'title' in data or 'contentTitle' in data:
                pref = self._create_viewing_preference(data, default_compartment)
                if pref:
                    yield pref

    async def _parse_csv_content(
        self,
        content: str,
        filename: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse CSV content from Disney+ export."""
        reader = csv.DictReader(io.StringIO(content))

        for row in reader:
            try:
                pref = self._create_viewing_preference(row, default_compartment)
                if pref:
                    yield pref
            except Exception as e:
                logger.warning(f"Error parsing CSV row: {e}")

    async def _parse_viewing_list(
        self,
        items: list,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse list of viewing history items."""
        # Aggregate by title to count watches
        title_watches = {}

        for item in items:
            title = self._extract_title(item)
            if not title:
                continue

            if title not in title_watches:
                title_watches[title] = {
                    'count': 0,
                    'content_type': self._extract_content_type(item),
                    'series': self._extract_series(item),
                    'last_watched': None
                }

            title_watches[title]['count'] += 1

            # Track last watched
            timestamp = self._extract_timestamp(item)
            if timestamp:
                if not title_watches[title]['last_watched'] or timestamp > title_watches[title]['last_watched']:
                    title_watches[title]['last_watched'] = timestamp

        logger.info(f"Processed {len(title_watches)} unique Disney+ titles")

        # Yield preferences
        for title, data in title_watches.items():
            # Skip bad subjects (smart home, calendar, etc.)
            if self._is_bad_subject(title):
                logger.debug(f"Skipped bad subject in aggregation: {title}")
                continue

            content_type = data['content_type']

            # Skip non-viewing content types
            if content_type in self.REJECTED_CONTENT_TYPES:
                logger.debug(f"Skipped content_type '{content_type}' in aggregation: {title}")
                continue

            count = data['count']
            strength = min(0.5 + (count * 0.1), 0.95)

            # Determine category based on content type
            if content_type in ('movie', 'film'):
                category = 'movie'
            elif content_type in ('episode', 'series', 'tv', 'show', 'tv_show'):
                category = 'tv_show'
            elif content_type == 'unknown':
                # Unknown could be legitimate if subject looks like a title
                category = 'tv_show'
            else:
                # Unrecognized content type - skip to be safe
                logger.debug(f"Skipped unrecognized content_type '{content_type}' in aggregation: {title}")
                continue

            subject = title
            if data['series'] and data['series'] != title:
                subject = f"{data['series']} - {title}"

            yield ParsedPreference(
                subject=subject,
                preference_type="Like",
                category=category,
                strength=strength,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small" if data['series'] else "Medium",
                observed_at=data['last_watched'],
                extra={
                    "type": "viewing",
                    "watch_count": count,
                    "content_type": content_type,
                    "platform": "Disney+"
                }
            )

    async def _parse_watchlist(
        self,
        items: list,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse watchlist items (intent to watch)."""
        for item in items:
            title = self._extract_title(item)
            if not title:
                continue

            # Skip bad subjects
            if self._is_bad_subject(title):
                continue

            content_type = self._extract_content_type(item)

            # Skip non-viewing content types
            if content_type in self.REJECTED_CONTENT_TYPES:
                continue

            if content_type in ('movie', 'film'):
                category = 'movie'
            elif content_type in ('episode', 'series', 'tv', 'show', 'tv_show', 'unknown'):
                category = 'tv_show'
            else:
                continue

            yield ParsedPreference(
                subject=title,
                preference_type="Like",
                category=category,
                strength=0.20,  # V2: Watchlist intent
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "watchlist",
                    "content_type": content_type,
                    "platform": "Disney+"
                }
            )

    async def _parse_preferences(
        self,
        prefs: dict,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse profile preferences (genres, content ratings, etc.)."""
        # Genre preferences
        for genre in prefs.get('favoriteGenres', prefs.get('genres', [])):
            yield ParsedPreference(
                subject=f"{genre} content",
                preference_type="Like",
                category="entertainment",
                strength=0.28,  # V2: Download/save
                source=self.source_name,
                compartment_level=default_compartment,
                size="Large",
                extra={"type": "genre_preference", "platform": "Disney+"}
            )

    def _is_bad_subject(self, subject: str) -> bool:
        """Check if a subject is clearly not TV/movie content or too generic."""
        if not subject:
            return True
        subject_lower = subject.lower().strip()

        # Check explicit bad patterns
        if any(pattern in subject_lower for pattern in self.BAD_SUBJECT_PATTERNS):
            return True

        # Check for generic episode names (e.g. "Episode 1", "Part V")
        # These are meaningless without series context
        for pattern in self.GENERIC_EPISODE_PATTERNS:
            if subject_lower.startswith(pattern):
                # Allow compound names like "Part I and Part II"
                remainder = subject_lower[len(pattern):]
                # If it's just a number or roman numeral, it's too generic
                if remainder.strip().replace('.', '').replace(',', '').isdigit():
                    return True
                # Roman numerals (single)
                if remainder.strip() in ('i', 'ii', 'iii', 'iv', 'v', 'vi', 'vii', 'viii', 'ix', 'x'):
                    return True

        return False

    def _create_viewing_preference(
        self,
        item: Dict[str, Any],
        default_compartment: int
    ) -> Optional[ParsedPreference]:
        """Create a preference from a single viewing record."""
        title = self._extract_title(item)
        if not title:
            return None

        # Reject bad subjects (smart home, calendar, etc.)
        if self._is_bad_subject(title):
            logger.debug(f"Rejected bad subject: {title}")
            return None

        content_type = self._extract_content_type(item)

        # Reject non-viewing content types (appliances, devices, etc.)
        if content_type in self.REJECTED_CONTENT_TYPES:
            logger.debug(f"Rejected content_type '{content_type}': {title}")
            return None

        # Only accept recognized viewing content types
        if content_type in ('movie', 'film'):
            category = 'movie'
        elif content_type in ('episode', 'series', 'tv', 'show', 'tv_show'):
            category = 'tv_show'
        elif content_type == 'unknown':
            # Unknown could be legitimate if subject looks like a title
            # But log it for review
            logger.debug(f"Unknown content_type, accepting cautiously: {title}")
            category = 'tv_show'
        else:
            # Unrecognized content type - reject to be safe
            logger.debug(f"Rejected unrecognized content_type '{content_type}': {title}")
            return None

        return ParsedPreference(
            subject=title,
            preference_type="Like",
            category=category,
            strength=0.15,  # V2: View
            source=self.source_name,
            compartment_level=default_compartment,
            size="Small",
            observed_at=self._extract_timestamp(item),
            extra={
                "type": "viewing",
                "content_type": content_type,
                "platform": "Disney+"
            }
        )

    def _extract_title(self, item: Any) -> Optional[str]:
        """Extract title from various field names."""
        if isinstance(item, str):
            return item.strip() if item.strip() else None

        if isinstance(item, dict):
            for key in ['title', 'Title', 'contentTitle', 'content_title', 'name', 'Name',
                       'episodeTitle', 'episode_title', 'movieTitle', 'movie_title']:
                if key in item and item[key]:
                    return str(item[key]).strip()

        return None

    def _extract_content_type(self, item: Any) -> str:
        """Extract content type (movie, series, episode, appliance, etc.)."""
        if isinstance(item, dict):
            for key in ['type', 'Type', 'contentType', 'content_type', 'mediaType',
                        'deviceType', 'device_type']:
                if key in item and item[key]:
                    value = str(item[key]).lower()
                    # Map device types to 'appliance'
                    if value in ('scene', 'light', 'switch', 'sensor', 'thermostat',
                                 'automation', 'activity_trigger', 'application'):
                        return 'appliance'
                    return value

            # Infer from other fields
            if any(k in item for k in ['episodeNumber', 'episode_number', 'seasonNumber']):
                return 'episode'
            if any(k in item for k in ['seriesTitle', 'series_title', 'showName']):
                return 'episode'

            # Detect smart home data by common fields
            if any(k in item for k in ['Device Name', 'deviceName', 'Is Device Enabled',
                                        'Manufacturer Name', 'Mac Address']):
                return 'appliance'

        return 'unknown'

    def _extract_series(self, item: Any) -> Optional[str]:
        """Extract series/show name for episodes."""
        if isinstance(item, dict):
            for key in ['seriesTitle', 'series_title', 'showName', 'show_name', 'showTitle']:
                if key in item and item[key]:
                    return str(item[key]).strip()
        return None

    def _extract_timestamp(self, item: Any) -> Optional[datetime]:
        """Extract timestamp from viewing record."""
        if isinstance(item, dict):
            for key in ['watchedAt', 'watched_at', 'timestamp', 'date', 'viewedAt',
                       'playbackDate', 'lastWatched', 'last_watched']:
                if key in item and item[key]:
                    try:
                        value = item[key]
                        if isinstance(value, datetime):
                            return value
                        if isinstance(value, str):
                            # Try common formats
                            for fmt in ['%Y-%m-%dT%H:%M:%S', '%Y-%m-%d %H:%M:%S',
                                       '%Y-%m-%d', '%d/%m/%Y', '%m/%d/%Y']:
                                try:
                                    return datetime.strptime(value[:19], fmt)
                                except ValueError:
                                    continue
                    except Exception:
                        pass
        return None
