"""Google Takeout data parser."""

import csv
import io
import json
import logging
from pathlib import Path
from typing import Any, AsyncIterator, Dict, List, Optional
from datetime import datetime
import aiofiles
import zipfile
import tempfile

from .base import BaseParser, ParsedPreference
from ..config import settings

logger = logging.getLogger(__name__)


class GoogleTakeoutParser(BaseParser):
    """
    Parser for Google Takeout data exports.

    Handles:
    - YouTube watch history and likes
    - Google Maps saved places
    - Chrome bookmarks
    - Google Play activity
    - Search history (for interest extraction)
    """

    source_name = "google_takeout"

    # File patterns to look for in takeout
    SUPPORTED_FILES = {
        "youtube_history": "Takeout/YouTube and YouTube Music/history/watch-history.json",
        "youtube_history_extracted": "Takeout/YouTube and YouTube Music/history/watch-history-extracted.json",
        "youtube_likes": "Takeout/YouTube and YouTube Music/playlists/Liked videos.json",
        "maps_saved": "Takeout/Maps (your places)/Saved Places.json",
        "maps_reviews": "Takeout/Maps (your places)/Reviews.json",
        "chrome_bookmarks": "Takeout/Chrome/Bookmarks.json",
        "chrome_bookmarks_extracted": "Takeout/Chrome/bookmarks_extracted.json",
        "chrome_history": "Takeout/Chrome/History.json",
        "play_installs": "Takeout/Google Play Store/Installs.json",
        "youtube_subscriptions": "Takeout/YouTube and YouTube Music/subscriptions/subscriptions.csv",
        "youtube_playlists": "Takeout/YouTube and YouTube Music/playlists/playlists.csv",
        "youtube_comments": "Takeout/YouTube and YouTube Music/comments/comments.csv",
        "youtube_searches": "Takeout/YouTube and YouTube Music/history/search-history.json",
        "youtube_searches_extracted": "Takeout/YouTube and YouTube Music/history/search-history-extracted.json",
        "youtube_live_chats": "Takeout/YouTube and YouTube Music/live chats/live chats.csv",
        "search_watched": "Takeout/Search Contributions/Watched.json",
        "google_calendar": "Takeout/Calendar/*.ics",
        "my_maps": "Takeout/My Maps/*.kmz",
        "maps_suggested_edits": "Takeout/Maps/Suggested edits to business establishments/*.json",
    }

    # Sensitive keywords for calendar events to SKIP (privacy protection)
    CALENDAR_SENSITIVE_KEYWORDS = [
        "doctor", "hospital", "clinic", "medical", "appointment", "injection",
        "surgery", "dentist", "physio", "physiotherapy", "therapy", "counseling",
        "blood", "scan", "test results", "prescription", "medication", "health",
        "lawyer", "solicitor", "court", "legal", "contract", "settlement",
        "bank", "mortgage", "loan", "insurance", "tax", "accountant", "financial",
        "interview", "salary", "performance review", "termination", "hr meeting",
    ]

    # Venue categories for location classification
    VENUE_CATEGORIES = {
        "restaurant": ["cafe", "restaurant", "grill", "bistro", "bar", "pub", "deli",
                       "kitchen", "steakhouse", "pizz", "sushi", "thai", "chinese",
                       "japanese", "italian", "greek", "indian", "mexican", "korean",
                       "dim sum", "noodle", "burger", "coffee", "espresso", "brew"],
        "hotel": ["hotel", "hyatt", "hilton", "marriott", "sheraton", "inn", "resort",
                  "airbnb", "hostel", "lodge", "suites"],
        "airport": ["airport", "hkg", "lhr", "jfk", "cdg", "ams", "bkk", "nrt", "sin",
                    "dxb", "bhx", "edi", "gla", "dub", "mla", "mnl", "tpe", "zrh",
                    "ist", "dps", "oka", "fra", "terminal"],
        "sports": ["football", "rugby", "swim", "gym", "fitness", "yoga", "running",
                   "club", "stadium", "pitch", "court", "sports", "athletic"],
        "school": ["school", "academy", "university", "college", "campus", "education"],
        "office": ["office", "tower", "centre", "center", "building", "floor", "/f"],
        "barber": ["barber", "haircut", "salon", "handsome factory"],
        "coworking": ["dim sum labs", "wework", "eaton club", "the hive", "spaces"],
    }

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a Google Takeout export."""
        if file_path.suffix.lower() == ".zip":
            # Check if it contains takeout data
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = zf.namelist()
                    return any("Takeout/" in n for n in names)
            except Exception:
                return False

        # Also accept JSON files from extracted takeout
        if file_path.suffix.lower() == ".json":
            # Check for Maps data in GeoJSON format
            if "Maps" in str(file_path) or "maps" in str(file_path):
                if "Reviews.json" in file_path.name or "Saved Places.json" in file_path.name:
                    return True
                # Also accept suggested edits (user-contributed places)
                if "suggested edits" in str(file_path).lower():
                    return True
            return "takeout" in file_path.name.lower() or any(
                pattern.split("/")[-1] in file_path.name
                for pattern in self.SUPPORTED_FILES.values()
                if pattern.endswith('.json')
            )

        # Accept CSV files from YouTube takeout
        if file_path.suffix.lower() == ".csv":
            name = file_path.name.lower()
            if "subscriptions.csv" in name or "playlists.csv" in name or "comments.csv" in name or "live chats.csv" in name:
                # Verify it's in a YouTube path
                path_str = str(file_path).lower()
                return "youtube" in path_str or "takeout" in path_str
            return False

        # Accept ICS files from Google Calendar takeout
        if file_path.suffix.lower() == ".ics":
            path_str = str(file_path).lower()
            # Must be in Calendar folder from Takeout
            return "calendar" in path_str and ("takeout" in path_str or "@" in file_path.name)

        # Accept KMZ files from My Maps takeout
        if file_path.suffix.lower() == ".kmz":
            path_str = str(file_path).lower()
            return "my maps" in path_str or "my_maps" in path_str

        return False

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Google Takeout data."""
        if default_compartment is None:
            default_compartment = settings.default_compartment

        if file_path.suffix.lower() == ".zip":
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == ".csv":
            async for pref in self._parse_csv(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == ".ics":
            async for pref in self._parse_google_calendar(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == ".kmz":
            async for pref in self._parse_mymaps(file_path, default_compartment):
                yield pref
        else:
            async for pref in self._parse_json(file_path, default_compartment):
                yield pref

    async def _parse_zip(
        self,
        zip_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse a Google Takeout zip file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            with zipfile.ZipFile(zip_path, 'r') as zf:
                zf.extractall(tmpdir)

            # Process each supported file type
            for file_type, pattern in self.SUPPORTED_FILES.items():
                file_path = Path(tmpdir) / pattern
                if file_path.exists():
                    logger.info(f"Processing {file_type} from takeout")
                    async for pref in self._parse_file_type(file_path, file_type, default_compartment):
                        yield pref

    async def _parse_csv(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse a CSV file from takeout."""
        file_name = file_path.name.lower()

        async with aiofiles.open(file_path, 'r', encoding='utf-8') as f:
            content = await f.read()

        if "subscriptions" in file_name:
            async for pref in self._parse_youtube_subscriptions(content, default_compartment):
                yield pref
        elif "playlists" in file_name:
            async for pref in self._parse_youtube_playlists(content, default_compartment):
                yield pref
        elif "comments" in file_name:
            async for pref in self._parse_youtube_comments(content, default_compartment):
                yield pref
        elif "live chats" in file_name:
            async for pref in self._parse_youtube_live_chats(content, default_compartment):
                yield pref
        else:
            logger.warning(f"Unknown Google Takeout CSV file type: {file_path}")

    async def _parse_json(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse a single JSON file from takeout."""
        # Detect file type from name and path
        file_name = file_path.name.lower()
        path_str = str(file_path).lower()

        if "watch-history" in file_name:
            file_type = "youtube_history"
        elif "search-history" in file_name:
            file_type = "youtube_searches"
        elif "liked" in file_name:
            file_type = "youtube_likes"
        elif "saved places" in file_name.replace("_", " "):
            file_type = "maps_saved"
        elif "reviews" in file_name and ("maps" in path_str or "your places" in path_str):
            file_type = "maps_reviews"
        elif "bookmarks_extracted" in file_name:
            file_type = "chrome_bookmarks_extracted"
        elif "bookmark" in file_name:
            file_type = "chrome_bookmarks"
        elif file_name == "history.json" and "chrome" in path_str:
            file_type = "chrome_history"
        elif "install" in file_name:
            file_type = "play_installs"
        elif file_name == "watched.json" and "search contributions" in path_str:
            file_type = "search_watched"
        elif "suggested edits" in path_str:
            file_type = "maps_suggested_edits"
        else:
            logger.warning(f"Unknown Google Takeout file type: {file_path}")
            return

        async for pref in self._parse_file_type(file_path, file_type, default_compartment):
            yield pref

    async def _parse_file_type(
        self,
        file_path: Path,
        file_type: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse a specific file type."""
        async with aiofiles.open(file_path, 'r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            return

        parser_method = getattr(self, f"_parse_{file_type}", None)
        if parser_method:
            async for pref in parser_method(data, default_compartment):
                yield pref

    async def _parse_youtube_history(
        self,
        data: Any,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse YouTube watch history.

        Handles two formats:
        1. Original JSON from Takeout (with 'subtitles' for channel)
        2. Extracted JSON from streaming HTML parser (with 'entries' wrapper)
        """
        # Handle extracted JSON format (from streaming parser)
        if isinstance(data, dict) and "entries" in data:
            items = data["entries"]
        elif isinstance(data, list):
            items = data
        else:
            logger.warning("Unknown YouTube history format")
            return

        # Count video watches to determine interest strength
        watch_counts: Dict[str, int] = {}
        video_info: Dict[str, Dict] = {}

        for item in items:
            # Handle both original and extracted formats
            title = item.get("title", "").replace("Watched ", "")
            if not title:
                continue

            # Extract channel - different field names in different formats
            if "channel" in item:
                # Extracted JSON format
                channel = item.get("channel", "")
            else:
                # Original Takeout JSON format
                subtitles = item.get("subtitles", [])
                channel = subtitles[0].get("name", "") if subtitles else ""

            # Get video ID and URL if available
            video_id = item.get("video_id", "")
            url = item.get("url", "")

            key = f"{title}|{channel}"
            watch_counts[key] = watch_counts.get(key, 0) + 1
            video_info[key] = {
                "title": title,
                "channel": channel,
                "time": item.get("time", item.get("timestamp", "")),
                "video_id": video_id,
                "url": url,
                "channel_url": item.get("channel_url", "")
            }

        # Generate preferences - yield all videos (even single watches)
        for key, count in watch_counts.items():
            info = video_info[key]

            # Calculate strength based on watch count
            if count >= 5:
                strength = 0.85  # Frequently rewatched
            elif count >= 3:
                strength = 0.75  # Multiple rewatches
            elif count >= 2:
                strength = 0.65  # Rewatched once
            else:
                strength = 0.5   # Single watch

            # Parse timestamp
            observed_at = None
            time_str = info["time"]
            if time_str:
                try:
                    observed_at = datetime.fromisoformat(time_str.replace("Z", "+00:00"))
                except Exception:
                    pass

            subject = info["title"]
            if info["channel"]:
                subject = f"{info['title']} by {info['channel']}"

            extra = {"watch_count": count}
            if info["channel"]:
                extra["channel"] = info["channel"]
            if info["video_id"]:
                extra["video_id"] = info["video_id"]
            if info["url"]:
                extra["url"] = info["url"]
            if info["channel_url"]:
                extra["channel_url"] = info["channel_url"]

            yield ParsedPreference(
                subject=subject,
                preference_type="Like",
                strength=strength,
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=info["video_id"] or key,
                category="video",
                observed_at=observed_at,
                size=self.classify_size(subject, "video"),
                extra=extra
            )

    async def _parse_youtube_likes(
        self,
        data: Dict,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse YouTube liked videos."""
        items = data.get("items", data) if isinstance(data, dict) else data

        for item in items:
            if isinstance(item, dict):
                title = item.get("snippet", {}).get("title", "") or item.get("title", "")
                channel = item.get("snippet", {}).get("videoOwnerChannelTitle", "")
            else:
                continue

            if not title:
                continue

            subject = f"{title} by {channel}" if channel else title

            yield ParsedPreference(
                subject=subject,
                preference_type="Like",
                strength=0.30,  # V2
                compartment_level=default_compartment,
                source=self.source_name,
                category="video",
                size=self.classify_size(subject, "video"),
                extra={"channel": channel}
            )

    async def _parse_maps_saved(
        self,
        data: Dict,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Google Maps saved places (GeoJSON FeatureCollection format)."""
        features = data.get("features", [])
        count = 0

        for feature in features:
            props = feature.get("properties", {})

            # GeoJSON format: location info is nested under properties.location
            location = props.get("location", {})
            name = location.get("name", "") if isinstance(location, dict) else ""

            # Fallback to older format
            if not name:
                name = props.get("Title", "") or props.get("name", "")

            if not name:
                continue

            # Get location details
            address = location.get("address", "") if isinstance(location, dict) else ""
            country_code = location.get("country_code", "") if isinstance(location, dict) else ""

            # Get coordinates
            geometry = feature.get("geometry", {})
            coords = geometry.get("coordinates", [])
            lat, lng = None, None
            if len(coords) >= 2:
                lng, lat = coords[0], coords[1]

            # Parse timestamp
            observed_at = None
            date_str = props.get("date", "")
            if date_str:
                try:
                    observed_at = datetime.fromisoformat(date_str.replace("Z", "+00:00"))
                except Exception:
                    pass

            extra = {
                "type": "saved_place",
                "address": address,
                "country_code": country_code,
            }
            if lat and lng:
                extra["coordinates"] = {"lat": lat, "lng": lng}
            if props.get("google_maps_url"):
                extra["google_maps_url"] = props["google_maps_url"]

            yield ParsedPreference(
                subject=name,
                preference_type="Like",
                strength=0.25,  # V2
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=props.get("google_maps_url", ""),
                category="place",
                observed_at=observed_at,
                size="Small",
                extra=extra
            )
            count += 1

        logger.info(f"Parsed {count} saved places from Google Maps")

    async def _parse_maps_reviews(
        self,
        data: Dict,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Google Maps reviews (GeoJSON FeatureCollection format)."""
        # Handle GeoJSON FeatureCollection format
        features = data.get("features", []) if isinstance(data, dict) else data
        count = 0

        for feature in features:
            # Handle both direct list and GeoJSON feature format
            if isinstance(feature, dict) and "properties" in feature:
                props = feature.get("properties", {})
                geometry = feature.get("geometry", {})
            else:
                # Fallback for older format
                props = feature
                geometry = {}

            # Get location info from GeoJSON format
            location = props.get("location", {})
            place = location.get("name", "") if isinstance(location, dict) else ""

            # Fallback to older format
            if not place:
                place = props.get("placeName", "")

            if not place:
                continue

            # Get rating
            rating = props.get("five_star_rating_published", props.get("starRating", 3))

            # Get review text
            review_text = props.get("review_text_published", props.get("comment", ""))

            # Get coordinates
            coords = geometry.get("coordinates", [])
            lat, lng = None, None
            if len(coords) >= 2:
                lng, lat = coords[0], coords[1]

            # Parse timestamp
            observed_at = None
            date_str = props.get("date", "")
            if date_str:
                try:
                    observed_at = datetime.fromisoformat(date_str.replace("Z", "+00:00"))
                except Exception:
                    pass

            # Convert star rating to preference type
            if rating >= 4:
                pref_type = "Like"
                strength = min(0.6 + (rating - 3) * 0.15, 0.95)  # 4-star=0.75, 5-star=0.9
            elif rating <= 2:
                pref_type = "Dislike"
                strength = min(0.6 + (3 - rating) * 0.15, 0.9)  # 2-star=0.75, 1-star=0.9
            else:
                pref_type = "Neutral"
                strength = 0.5

            # Get location details
            address = location.get("address", "") if isinstance(location, dict) else ""
            country_code = location.get("country_code", "") if isinstance(location, dict) else ""

            # Build extra data
            extra = {
                "type": "place_review",
                "rating": rating,
                "address": address,
                "country_code": country_code,
            }
            if review_text:
                extra["review_text"] = review_text
            if lat and lng:
                extra["coordinates"] = {"lat": lat, "lng": lng}
            if props.get("google_maps_url"):
                extra["google_maps_url"] = props["google_maps_url"]

            # Include structured questions if present (hotel reviews)
            questions = props.get("questions", [])
            if questions:
                extra["questions"] = questions

            yield ParsedPreference(
                subject=place,
                preference_type=pref_type,
                strength=strength,
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=props.get("google_maps_url", ""),
                category="place",
                observed_at=observed_at,
                size="Small",
                extra=extra
            )
            count += 1

        logger.info(f"Parsed {count} reviews from Google Maps")

    async def _parse_play_installs(
        self,
        data: List[Dict],
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Google Play app installs."""
        for app in data:
            name = app.get("install", {}).get("doc", {}).get("title", "")
            if not name:
                continue

            yield ParsedPreference(
                subject=name,
                preference_type="Like",
                strength=0.18,  # V2
                compartment_level=default_compartment,
                source=self.source_name,
                category="app",
                size="Small"
            )

    async def _parse_chrome_bookmarks(
        self,
        data: Dict,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Chrome bookmarks."""
        async def process_node(node: Dict):
            if node.get("type") == "url":
                name = node.get("name", "")
                url = node.get("url", "")

                if name and url:
                    yield ParsedPreference(
                        subject=name,
                        preference_type="Like",
                        strength=0.18,  # V2
                        compartment_level=default_compartment,
                        source=self.source_name,
                        category="website",
                        size="Small",
                        extra={"url": url}
                    )

            # Recurse into children
            for child in node.get("children", []):
                async for pref in process_node(child):
                    yield pref

        roots = data.get("roots", {})
        for root_name, root_node in roots.items():
            if isinstance(root_node, dict):
                async for pref in process_node(root_node):
                    yield pref

    async def _parse_youtube_subscriptions(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse YouTube channel subscriptions from CSV."""
        reader = csv.DictReader(io.StringIO(content))
        count = 0

        for row in reader:
            channel_title = row.get("Channel title", "").strip()
            channel_id = row.get("Channel ID", "").strip()
            channel_url = row.get("Channel URL", "").strip()

            if not channel_title:
                continue

            yield ParsedPreference(
                subject=f"YouTube: {channel_title}",
                preference_type="Like",
                strength=0.35,  # V2: Subscription
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=channel_id,
                category="video",
                size="Small",
                extra={
                    "type": "youtube_subscription",
                    "channel_id": channel_id,
                    "channel_url": channel_url,
                    "channel_title": channel_title,
                }
            )
            count += 1

        logger.info(f"Parsed {count} YouTube channel subscriptions")

    async def _parse_youtube_playlists(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse YouTube playlists from CSV."""
        reader = csv.DictReader(io.StringIO(content))
        count = 0

        for row in reader:
            playlist_title = row.get("Playlist title (original)", "").strip()
            playlist_id = row.get("Playlist ID", "").strip()
            visibility = row.get("Playlist visibility", "").strip()
            create_ts = row.get("Playlist create timestamp", "").strip()
            update_ts = row.get("Playlist update timestamp", "").strip()

            if not playlist_title:
                continue

            # Skip generic playlists
            if playlist_title.lower() in ["watch later", "liked videos"]:
                continue

            # Parse timestamps
            observed_at = None
            if create_ts:
                try:
                    observed_at = datetime.fromisoformat(create_ts.replace("Z", "+00:00"))
                except Exception:
                    pass

            # Calculate strength based on whether playlist is public (higher signal)
            # and whether it's been updated (indicates active curation)
            strength = 0.65
            if visibility.lower() == "public":
                strength = 0.75  # Public playlists show stronger interest

            yield ParsedPreference(
                subject=f"YouTube playlist: {playlist_title}",
                preference_type="Like",
                strength=strength,
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=playlist_id,
                category="video",
                observed_at=observed_at,
                size="Small",
                extra={
                    "type": "youtube_playlist",
                    "playlist_id": playlist_id,
                    "playlist_title": playlist_title,
                    "visibility": visibility,
                    "created": create_ts,
                    "updated": update_ts,
                }
            )
            count += 1

        logger.info(f"Parsed {count} YouTube playlists")

    async def _parse_youtube_comments(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse YouTube comments from CSV.

        NOTE: Comment text itself isn't a useful preference subject.
        The signal is that the user engaged deeply with certain videos.

        Since YouTube exports only include video_id (not video title), we
        aggregate comments by video_id but don't yield preferences.
        The video watch history (parsed separately) provides the actual
        video titles and subjects.

        Comment activity is logged for reference.
        """
        reader = csv.DictReader(io.StringIO(content))

        video_comment_counts: dict[str, int] = {}
        for row in reader:
            video_id = row.get("Video ID", "").strip()
            if video_id:
                video_comment_counts[video_id] = video_comment_counts.get(video_id, 0) + 1

        total_comments = sum(video_comment_counts.values())
        logger.info(
            f"YouTube comments: {total_comments} comments on {len(video_comment_counts)} videos "
            "(skipped - comment text isn't a useful preference subject, video titles come from watch history)"
        )

        # Don't yield - comment text creates garbage preferences
        return
        yield  # Make this a generator

    async def _parse_chrome_history(
        self,
        data: Dict,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Chrome browsing history from History.json.

        Extracts from multiple sources:
        - Browser History (actual history if sync enabled)
        - Typed URLs (addresses typed in address bar)
        - Session data (tab snapshots from sync)
        """
        import re
        count = 0

        # Extract unique URLs with titles
        url_data = {}  # url -> {title, count, last_seen, source}

        def extract_domain(url: str) -> str:
            match = re.search(r'https?://(?:www\.)?([^/]+)', url)
            return match.group(1) if match else url

        def add_url(url: str, title: str, timestamp_ms: int, source: str):
            # Skip internal Chrome pages
            if not url or url.startswith("chrome://") or url.startswith("chrome-extension://"):
                return

            # Use domain as fallback title
            if not title:
                title = extract_domain(url)

            if url not in url_data:
                url_data[url] = {
                    "title": title,
                    "count": 0,
                    "last_seen": 0,
                    "source": source
                }

            url_data[url]["count"] += 1
            if timestamp_ms > url_data[url]["last_seen"]:
                url_data[url]["last_seen"] = timestamp_ms
                if title and title != extract_domain(url):
                    url_data[url]["title"] = title  # Prefer real title over domain

        # 1. Browser History (actual browsing history if sync enabled)
        for item in data.get("Browser History", []):
            url = item.get("url", "")
            title = item.get("title", "").strip()
            # Browser history uses different timestamp format
            time_usec = item.get("time_usec", 0)
            timestamp_ms = time_usec // 1000 if time_usec else 0
            add_url(url, title, timestamp_ms, "browser_history")

        # 2. Typed URLs (addresses typed directly in address bar - strong intent)
        for item in data.get("Typed Url", []):
            url = item.get("url", "")
            title = item.get("title", "").strip()
            add_url(url, title, 0, "typed_url")

        # 3. Session data (tab snapshots from sync)
        for session in data.get("Session", []):
            tab = session.get("tab", {})
            navigations = tab.get("navigation", [])

            for nav in navigations:
                url = nav.get("virtual_url", "")
                title = nav.get("title", "").strip()
                timestamp_ms = nav.get("timestamp_msec", 0)
                add_url(url, title, timestamp_ms, "session")

        # Extract Google searches from URLs (explicit intent signals)
        from urllib.parse import unquote_plus
        search_queries = {}  # query -> {count, last_seen, url}

        for url, info in url_data.items():
            # Check for Google search URLs
            if 'google.com/search' in url or 'google.co' in url and '/search' in url:
                match = re.search(r'[?&]q=([^&]+)', url)
                if match:
                    query = unquote_plus(match.group(1)).strip()
                    if query and len(query) > 1:
                        if query not in search_queries:
                            search_queries[query] = {"count": 0, "last_seen": 0, "url": url}
                        search_queries[query]["count"] += info["count"]
                        if info["last_seen"] > search_queries[query]["last_seen"]:
                            search_queries[query]["last_seen"] = info["last_seen"]

            # Also check title pattern "X - Google Search"
            title = info.get("title", "")
            if " - Google Search" in title:
                query = title.replace(" - Google Search", "").strip()
                if query and len(query) > 1 and query not in search_queries:
                    search_queries[query] = {"count": info["count"], "last_seen": info["last_seen"], "url": url}

        # Yield Google search queries as search_interest preferences
        search_count = 0
        for query, qinfo in search_queries.items():
            observed_at = None
            if qinfo["last_seen"] > 0:
                try:
                    observed_at = datetime.fromtimestamp(qinfo["last_seen"] / 1000)
                except Exception:
                    pass

            yield ParsedPreference(
                subject=f"Google search: {query}",
                preference_type="Like",
                strength=0.12,  # V2: Search intent
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=qinfo["url"],
                category="search_interest",
                observed_at=observed_at,
                size="Small",
                extra={
                    "type": "google_search",
                    "query": query,
                    "search_count": qinfo["count"],
                }
            )
            search_count += 1

        # Generate preferences for non-search URLs
        for url, info in url_data.items():
            # Skip Google search result pages (already extracted as searches)
            if 'google.com/search' in url or ('google.co' in url and '/search' in url):
                continue

            domain = extract_domain(url)

            # Calculate strength based on visit count and source
            visit_count = info["count"]
            source_type = info.get("source", "session")

            # Typed URLs show strongest intent (user explicitly typed it)
            if source_type == "typed_url":
                base_strength = 0.7
            elif source_type == "browser_history":
                base_strength = 0.6
            else:  # session
                base_strength = 0.5

            # Boost for multiple visits
            if visit_count >= 5:
                strength = min(base_strength + 0.25, 0.9)
            elif visit_count >= 3:
                strength = min(base_strength + 0.15, 0.85)
            elif visit_count >= 2:
                strength = min(base_strength + 0.1, 0.8)
            else:
                strength = base_strength

            # Parse timestamp
            observed_at = None
            if info["last_seen"] > 0:
                try:
                    observed_at = datetime.fromtimestamp(info["last_seen"] / 1000)
                except Exception:
                    pass

            yield ParsedPreference(
                subject=info["title"],
                preference_type="Like",
                strength=strength,
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=url,
                category="website",
                observed_at=observed_at,
                size="Small",
                extra={
                    "type": "chrome_history",
                    "url": url,
                    "domain": domain,
                    "visit_count": visit_count,
                    "history_source": source_type,
                }
            )
            count += 1

        logger.info(f"Parsed {count} Chrome history entries + {search_count} Google searches")

    async def _parse_chrome_bookmarks_extracted(
        self,
        data: Dict,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Chrome bookmarks from extracted JSON (via streaming parser).

        Bookmarks are saved resources - shows intentional interest.
        """
        bookmarks = data.get("bookmarks", [])
        count = 0

        for bookmark in bookmarks:
            title = bookmark.get("title", "").strip()
            url = bookmark.get("url", "")
            folder_path = bookmark.get("folder_path", "")
            domain = bookmark.get("domain", "")

            if not title or not url:
                continue

            # Skip generic bookmarks
            if title.lower() in ["new tab", "home"]:
                continue

            # Parse timestamp if available
            observed_at = None
            added_at = bookmark.get("added_at", "")
            if added_at:
                try:
                    observed_at = datetime.fromisoformat(added_at)
                except Exception:
                    pass

            # Strength based on folder (organized = higher intent)
            strength = 0.7
            if folder_path and "/" in folder_path:
                strength = 0.75  # Organized into subfolder shows higher intent

            yield ParsedPreference(
                subject=title,
                preference_type="Like",
                strength=strength,
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=url,
                category="website",
                observed_at=observed_at,
                size="Small",
                extra={
                    "type": "chrome_bookmark",
                    "url": url,
                    "domain": domain,
                    "folder": folder_path,
                }
            )
            count += 1

        logger.info(f"Parsed {count} Chrome bookmarks")

    async def _parse_youtube_searches(
        self,
        data: Dict,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse YouTube search history from extracted JSON.

        Search queries show explicit intent - the user actively sought this topic.
        This is goldmine data for understanding interests.
        """
        entries = data.get("entries", [])
        count = 0

        # Aggregate search queries (same query = stronger interest)
        query_data = {}  # query -> {count, last_timestamp}

        for entry in entries:
            query = entry.get("query", "").strip()
            if not query:
                continue

            timestamp = entry.get("timestamp", "")

            if query not in query_data:
                query_data[query] = {
                    "count": 0,
                    "last_timestamp": "",
                    "url": entry.get("url", "")
                }

            query_data[query]["count"] += 1
            if timestamp > query_data[query]["last_timestamp"]:
                query_data[query]["last_timestamp"] = timestamp

        # Generate preferences
        for query, info in query_data.items():
            search_count = info["count"]

            # Calculate strength based on search frequency
            if search_count >= 5:
                strength = 0.85  # Frequently searched
            elif search_count >= 3:
                strength = 0.75  # Multiple searches
            elif search_count >= 2:
                strength = 0.65  # Searched twice
            else:
                strength = 0.6   # Single search still shows intent

            # Parse timestamp
            observed_at = None
            if info["last_timestamp"]:
                try:
                    observed_at = datetime.fromisoformat(info["last_timestamp"])
                except Exception:
                    pass

            yield ParsedPreference(
                subject=f"YouTube search: {query}",
                preference_type="Like",
                strength=strength,
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=info["url"],
                category="search_interest",
                observed_at=observed_at,
                size="Small",
                extra={
                    "type": "youtube_search",
                    "query": query,
                    "search_count": search_count,
                }
            )
            count += 1

        logger.info(f"Parsed {count} YouTube search queries")

    async def _parse_youtube_live_chats(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse YouTube live chat messages from CSV.

        NOTE: Live chat text isn't a useful preference subject (same as comments).
        The signal is participation in live streams, but the chat content itself
        doesn't make a good preference.

        Since exports only include video_id/channel_id (not titles), we log
        activity for reference but don't yield preferences.
        """
        reader = csv.DictReader(io.StringIO(content))

        video_chat_counts: dict[str, int] = {}
        for row in reader:
            video_id = row.get("Video ID", "").strip()
            if video_id:
                video_chat_counts[video_id] = video_chat_counts.get(video_id, 0) + 1

        total_chats = sum(video_chat_counts.values())
        logger.info(
            f"YouTube live chats: {total_chats} messages on {len(video_chat_counts)} streams "
            "(skipped - chat text isn't a useful preference subject)"
        )

        # Don't yield - chat text creates garbage preferences
        return
        yield  # Make this a generator

    async def _parse_search_watched(
        self,
        data: List[Dict],
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Search Contributions Watched.json.

        These are content items the user explicitly marked as "watched" after
        searching for them. Very strong signal of actual consumption/interest.
        """
        count = 0

        # Aggregate by search query (same query = stronger interest)
        query_data = {}  # query -> {count, last_timestamp}

        for item in data:
            query = item.get("Search Query", "").strip()
            timestamp = item.get("Published", "")

            if not query:
                continue

            if query not in query_data:
                query_data[query] = {"count": 0, "last_timestamp": ""}

            query_data[query]["count"] += 1
            if timestamp > query_data[query]["last_timestamp"]:
                query_data[query]["last_timestamp"] = timestamp

        # Generate preferences
        for query, info in query_data.items():
            # Parse timestamp
            observed_at = None
            if info["last_timestamp"]:
                try:
                    observed_at = datetime.fromisoformat(info["last_timestamp"].replace("Z", "+00:00"))
                except Exception:
                    pass

            # Strong signal - user searched AND confirmed watching
            strength = 0.8
            if info["count"] >= 2:
                strength = 0.85

            yield ParsedPreference(
                subject=f"Watched: {query}",
                preference_type="Like",
                strength=strength,
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=query,
                category="movie_tv",  # These appear to be TV show searches
                observed_at=observed_at,
                size="Medium",
                extra={
                    "type": "search_watched",
                    "query": query,
                    "confirmed_count": info["count"],
                }
            )
            count += 1

        logger.info(f"Parsed {count} Search Contributions watched items")

    async def _parse_google_calendar(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Google Calendar ICS file with privacy-focused venue extraction.

        PRIVACY CONTROLS (compartment_level=3):
        - Does NOT store attendee names or email addresses
        - Skips events with sensitive keywords (medical, financial, legal)
        - Focuses on LOCATION data (venues, restaurants, airports, hotels)
        - Aggregates by venue for frequency-based strength

        Extracts:
        1. Venues visited (restaurants, hotels, airports, sports venues)
        2. Flight locations (airports) -> travel patterns
        3. Recurring venues -> indicates strong preference
        """
        import re

        logger.info(f"Parsing Google Calendar from: {file_path}")

        # Read ICS file content
        async with aiofiles.open(file_path, 'r', encoding='utf-8') as f:
            content = await f.read()

        # Statistics for logging
        stats = {
            'total_events': 0,
            'events_with_location': 0,
            'skipped_sensitive': 0,
            'skipped_virtual': 0,
            'venues_extracted': 0,
        }

        # Track venues with visit counts
        # Key: normalized_venue_name -> {name, category, visits, last_seen, locations}
        venue_data = {}

        def normalize_venue_name(name: str) -> str:
            """Normalize venue name for deduplication."""
            # Remove address parts after comma
            name = name.split(',')[0].strip()
            # Remove common suffixes
            name = re.sub(r'\s*\([^)]*\)\s*$', '', name)  # Remove (stuff in parens)
            name = re.sub(r'\s*\|.*$', '', name)  # Remove stuff after |
            # Clean up
            name = name.strip()
            return name

        def categorize_venue(location: str) -> str:
            """Categorize venue based on keywords."""
            location_lower = location.lower()

            for category, keywords in self.VENUE_CATEGORIES.items():
                if any(kw in location_lower for kw in keywords):
                    return category

            return "place"  # Default category

        def is_virtual_meeting(location: str) -> bool:
            """Check if location is a virtual meeting."""
            location_lower = location.lower()
            virtual_indicators = [
                "teams meeting", "zoom", "google meet", "skype", "webex",
                "video-conference", "https://", "http://", "dial-in",
                "what's app", "whatsapp", "call", "phone",
            ]
            return any(v in location_lower for v in virtual_indicators)

        def extract_ics_field(event_block: str, field: str) -> str:
            """Extract a field value from ICS event block, handling line continuations."""
            pattern = rf'^{field}[;:](.*)$'
            lines = event_block.split('\n')

            for i, line in enumerate(lines):
                match = re.match(pattern, line, re.IGNORECASE)
                if match:
                    value = match.group(1).strip()
                    # Handle line continuations (lines starting with space or tab)
                    for j in range(i + 1, len(lines)):
                        if lines[j].startswith((' ', '\t')):
                            value += lines[j].strip()
                        else:
                            break
                    # Unescape ICS values
                    value = value.replace('\\,', ',').replace('\\;', ';')
                    value = value.replace('\\n', ' ').replace('\\N', ' ')
                    return value.strip()
            return ""

        # Parse VEVENT blocks
        events = content.split('BEGIN:VEVENT')

        for event_block in events[1:]:  # Skip first split (before first VEVENT)
            event_block = event_block.split('END:VEVENT')[0]
            stats['total_events'] += 1

            # Extract SUMMARY (event title) for sensitive keyword check
            summary = extract_ics_field(event_block, 'SUMMARY')
            summary_lower = summary.lower() if summary else ""

            # Skip sensitive events
            is_sensitive = any(
                kw in summary_lower
                for kw in self.CALENDAR_SENSITIVE_KEYWORDS
            )
            if is_sensitive:
                stats['skipped_sensitive'] += 1
                continue

            # Extract LOCATION
            location = extract_ics_field(event_block, 'LOCATION')
            if not location:
                continue

            stats['events_with_location'] += 1

            # Skip virtual meetings
            if is_virtual_meeting(location):
                stats['skipped_virtual'] += 1
                continue

            # Extract DTSTART for timestamp
            dtstart = extract_ics_field(event_block, 'DTSTART')
            timestamp = None
            if dtstart:
                # Parse ICS datetime format (20101109T103000Z or 20101109)
                try:
                    if 'T' in dtstart:
                        # Remove timezone suffix if present
                        dtstart_clean = re.sub(r'Z$', '', dtstart)
                        timestamp = datetime.strptime(dtstart_clean, "%Y%m%dT%H%M%S")
                    else:
                        timestamp = datetime.strptime(dtstart[:8], "%Y%m%d")
                except ValueError:
                    pass

            # Normalize and categorize venue
            venue_name = normalize_venue_name(location)
            if not venue_name or len(venue_name) < 3:
                continue

            category = categorize_venue(location)
            venue_key = venue_name.lower()

            # Track venue data
            if venue_key not in venue_data:
                venue_data[venue_key] = {
                    'name': venue_name,
                    'category': category,
                    'visits': 0,
                    'last_seen': None,
                    'full_locations': set(),
                }

            venue_data[venue_key]['visits'] += 1
            venue_data[venue_key]['full_locations'].add(location[:200])  # Store first 200 chars
            if timestamp and (venue_data[venue_key]['last_seen'] is None or
                              timestamp > venue_data[venue_key]['last_seen']):
                venue_data[venue_key]['last_seen'] = timestamp

        # Generate preferences for venues
        count = 0
        for venue_key, info in venue_data.items():
            visits = info['visits']

            # Calculate strength based on visit frequency
            if visits >= 10:
                strength = 0.9  # Frequent visitor
            elif visits >= 5:
                strength = 0.8  # Regular visitor
            elif visits >= 3:
                strength = 0.7  # Multiple visits
            elif visits >= 2:
                strength = 0.65  # Repeat visitor
            else:
                strength = 0.55  # Single visit

            category = info['category']

            # Adjust category label for preference
            if category == "airport":
                pref_category = "travel"
                subject = f"Flew to: {info['name']}"
            elif category == "hotel":
                pref_category = "travel"
                subject = f"Stayed at: {info['name']}"
            elif category == "restaurant":
                pref_category = "food"
                subject = f"Dined at: {info['name']}"
            elif category == "barber":
                pref_category = "personal_care"
                subject = f"Grooming at: {info['name']}"
            elif category == "sports":
                pref_category = "fitness"
                subject = f"Sports at: {info['name']}"
            elif category == "school":
                pref_category = "education"
                subject = f"School: {info['name']}"
            elif category == "coworking":
                pref_category = "professional"
                subject = f"Workspace: {info['name']}"
            else:
                pref_category = "place"
                subject = f"Visited: {info['name']}"

            yield ParsedPreference(
                subject=subject,
                preference_type="Like",
                strength=strength,
                compartment_level=3,  # Medium privacy (contains location data)
                source=self.source_name,
                source_id=venue_key,
                category=pref_category,
                observed_at=info['last_seen'],
                size="Small",
                extra={
                    "type": "calendar_venue",
                    "venue_category": category,
                    "visit_count": visits,
                    "sample_location": list(info['full_locations'])[0] if info['full_locations'] else "",
                }
            )
            count += 1
            stats['venues_extracted'] += 1

        logger.info(
            f"Parsed Google Calendar: {stats['total_events']} events, "
            f"{stats['events_with_location']} with locations, "
            f"{stats['skipped_sensitive']} skipped (sensitive), "
            f"{stats['skipped_virtual']} skipped (virtual), "
            f"{stats['venues_extracted']} venues extracted"
        )

    async def _parse_mymaps(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Google My Maps KMZ files.

        KMZ files are ZIP archives containing KML (XML) files with curated places.
        These are explicitly user-created collections of favorite places,
        often organized into folders/categories.

        Extracts:
        1. Map name (the collection theme)
        2. Folder names (user-defined categories)
        3. Place names with coordinates
        4. Place descriptions (user notes)
        """
        import re

        logger.info(f"Parsing My Maps from: {file_path}")

        # KMZ is a ZIP file containing doc.kml
        try:
            with zipfile.ZipFile(file_path, 'r') as zf:
                # Find the KML file (usually doc.kml)
                kml_files = [n for n in zf.namelist() if n.endswith('.kml')]
                if not kml_files:
                    logger.warning(f"No KML file found in {file_path}")
                    return

                kml_content = zf.read(kml_files[0]).decode('utf-8')
        except Exception as e:
            logger.error(f"Failed to read KMZ file {file_path}: {e}")
            return

        # Extract map name from filename
        map_name = file_path.stem  # e.g., "Places of Interest in HK"

        # Parse KML content
        # Note: KML uses namespaces, but we'll use regex for simplicity
        count = 0

        # Extract folder structure and placemarks
        # Find all folders with their contained placemarks
        folder_pattern = r'<Folder>\s*<name>([^<]+)</name>(.*?)</Folder>'
        placemark_pattern = r'<Placemark>\s*<name>([^<]+)</name>(?:.*?<description>([^<]*)</description>)?.*?<coordinates>\s*([\d.,\-\s]+)\s*</coordinates>'

        # First, extract placemarks within folders
        folder_matches = re.findall(folder_pattern, kml_content, re.DOTALL)
        processed_places = set()

        for folder_name, folder_content in folder_matches:
            folder_name = folder_name.strip()

            # Find placemarks in this folder
            placemark_matches = re.findall(placemark_pattern, folder_content, re.DOTALL)

            for place_name, description, coords in placemark_matches:
                place_name = place_name.strip()
                description = description.strip() if description else ""

                # Clean up CDATA and HTML
                description = re.sub(r'<!\[CDATA\[|\]\]>', '', description)
                description = re.sub(r'<[^>]+>', '', description)
                description = description.strip()

                # Parse coordinates (lon,lat,alt)
                coord_parts = coords.strip().split(',')
                lat, lng = None, None
                if len(coord_parts) >= 2:
                    try:
                        lng = float(coord_parts[0])
                        lat = float(coord_parts[1])
                    except ValueError:
                        pass

                # Skip if already processed (in case of duplicates)
                place_key = f"{place_name.lower()}|{folder_name.lower()}"
                if place_key in processed_places:
                    continue
                processed_places.add(place_key)

                # Determine category based on folder name
                folder_lower = folder_name.lower()
                if any(kw in folder_lower for kw in ["restaurant", "food", "dining", "pizza", "lebanese", "indian", "thai", "chinese"]):
                    pref_category = "food"
                    subject = f"Favorite restaurant: {place_name}"
                elif any(kw in folder_lower for kw in ["kid", "children", "family"]):
                    pref_category = "family"
                    subject = f"Family spot: {place_name}"
                elif any(kw in folder_lower for kw in ["car park", "parking", "motorcycle"]):
                    pref_category = "transportation"
                    subject = f"Parking: {place_name}"
                elif any(kw in folder_lower for kw in ["hotel", "accommodation", "stay"]):
                    pref_category = "travel"
                    subject = f"Stay at: {place_name}"
                elif any(kw in folder_lower for kw in ["shop", "store", "computer"]):
                    pref_category = "shopping"
                    subject = f"Shop: {place_name}"
                else:
                    pref_category = "place"
                    subject = f"Favorite: {place_name}"

                extra = {
                    "type": "mymaps_place",
                    "map_name": map_name,
                    "folder": folder_name,
                }
                if description:
                    extra["description"] = description[:500]  # Limit description length
                if lat and lng:
                    extra["coordinates"] = {"lat": lat, "lng": lng}

                yield ParsedPreference(
                    subject=subject,
                    preference_type="Like",
                    strength=0.38,  # V2: Strong signal  # Curated places are strong signals
                    compartment_level=default_compartment,
                    source=self.source_name,
                    source_id=f"{map_name}:{place_name}",
                    category=pref_category,
                    size="Small",
                    extra=extra
                )
                count += 1

        # Also extract placemarks not in folders (top-level)
        # Remove folder content first to avoid duplicates
        top_level_content = re.sub(folder_pattern, '', kml_content, flags=re.DOTALL)
        top_level_matches = re.findall(placemark_pattern, top_level_content, re.DOTALL)

        for place_name, description, coords in top_level_matches:
            place_name = place_name.strip()
            description = description.strip() if description else ""

            # Clean up
            description = re.sub(r'<!\[CDATA\[|\]\]>', '', description)
            description = re.sub(r'<[^>]+>', '', description)
            description = description.strip()

            # Parse coordinates
            coord_parts = coords.strip().split(',')
            lat, lng = None, None
            if len(coord_parts) >= 2:
                try:
                    lng = float(coord_parts[0])
                    lat = float(coord_parts[1])
                except ValueError:
                    pass

            place_key = f"{place_name.lower()}|_top_"
            if place_key in processed_places:
                continue
            processed_places.add(place_key)

            # Categorize based on map name
            map_lower = map_name.lower()
            if any(kw in map_lower for kw in ["restaurant", "food", "dining"]):
                pref_category = "food"
                subject = f"Favorite restaurant: {place_name}"
            elif any(kw in map_lower for kw in ["car park", "parking", "motorcycle"]):
                pref_category = "transportation"
                subject = f"Parking: {place_name}"
            elif any(kw in map_lower for kw in ["store", "shop"]):
                pref_category = "shopping"
                subject = f"Shop: {place_name}"
            elif any(kw in map_lower for kw in ["seoul", "paris", "beijing", "tokyo"]):
                pref_category = "travel"
                subject = f"Travel spot: {place_name}"
            else:
                pref_category = "place"
                subject = f"Favorite: {place_name}"

            extra = {
                "type": "mymaps_place",
                "map_name": map_name,
            }
            if description:
                extra["description"] = description[:500]
            if lat and lng:
                extra["coordinates"] = {"lat": lat, "lng": lng}

            yield ParsedPreference(
                subject=subject,
                preference_type="Like",
                strength=0.38,  # V2: Strong signal
                compartment_level=default_compartment,
                source=self.source_name,
                source_id=f"{map_name}:{place_name}",
                category=pref_category,
                size="Small",
                extra=extra
            )
            count += 1

        logger.info(f"Parsed {count} places from My Maps: {map_name}")

    async def _parse_maps_suggested_edits(
        self,
        data: Dict,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Maps suggested edits - user-contributed places.

        These are places the user actively added or edited on Google Maps,
        revealing genuine interests (e.g., "Land Rover graveyard" → car enthusiast).
        """
        # Extract place name from the edit
        name_change = data.get("nameChange", {})
        operations = name_change.get("operations", [])

        place_name = None
        for op in operations:
            if op.get("type") == "Set operation":
                text_data = op.get("text", {})
                place_name = text_data.get("text", "").strip()
                break

        if not place_name:
            return

        # Extract category if available
        category_change = data.get("categoryChange", {})
        category_ops = category_change.get("operations", [])
        place_category = None
        for op in category_ops:
            if op.get("type") == "Set operation":
                place_category = op.get("category", "").strip()
                break

        # Extract coordinates
        point_change = data.get("pointChange", {})
        point_ops = point_change.get("operations", [])
        lat, lng = None, None
        for op in point_ops:
            if op.get("type") == "Set operation":
                point = op.get("point", {})
                lat_e7 = point.get("latE7")
                lng_e7 = point.get("lngE7")
                if lat_e7 and lng_e7:
                    lat = lat_e7 / 1e7
                    lng = lng_e7 / 1e7
                break

        # Extract timestamp
        metadata = data.get("metadata", {})
        create_time = metadata.get("createTime", "")
        observed_at = None
        if create_time:
            try:
                observed_at = datetime.fromisoformat(create_time.replace("Z", "+00:00"))
            except Exception:
                pass

        # Determine preference category based on place category or name
        pref_category = "place"
        name_lower = place_name.lower()
        cat_lower = (place_category or "").lower()

        if any(kw in name_lower or kw in cat_lower for kw in ["car", "auto", "motor", "vehicle", "rover", "garage"]):
            pref_category = "automotive"
        elif any(kw in cat_lower for kw in ["restaurant", "cafe", "food", "bar"]):
            pref_category = "food"
        elif any(kw in cat_lower for kw in ["museum", "gallery", "attraction"]):
            pref_category = "culture"

        extra = {
            "type": "maps_suggested_edit",
            "action": data.get("editAction", ""),
        }
        if place_category:
            extra["place_category"] = place_category
        if lat and lng:
            extra["coordinates"] = {"lat": lat, "lng": lng}

        yield ParsedPreference(
            subject=f"Added place: {place_name}",
            preference_type="Like",
            strength=0.45,  # V2: User actively contributed
            compartment_level=default_compartment,
            source=self.source_name,
            source_id=f"suggested_edit:{place_name}",
            category=pref_category,
            observed_at=observed_at,
            size="Small",
            extra=extra
        )

        logger.info(f"Parsed Maps suggested edit: {place_name}")
