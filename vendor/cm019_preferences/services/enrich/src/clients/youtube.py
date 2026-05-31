"""YouTube Data API client for video and channel enrichment.

Enriches YouTube preferences with categories, tags, and channel information.
Supports batch lookups (up to 50 videos per request) for efficient quota usage.

YouTube API quota: 10,000 units/day
- videos.list costs 1 unit per request (up to 50 videos)
- channels.list costs 1 unit per request (up to 50 channels)
"""

import logging
import re
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from .base import BaseClient, InMemoryCache
from ..config import settings
from ..models.enrichment import (
    EnrichmentResult,
    EnrichmentSource,
    MatchType,
    TopicResult,
    EntityResult,
    YouTubeVideoMetadata,
    YouTubeChannelMetadata,
)

logger = logging.getLogger(__name__)


# YouTube video category ID to name mapping
# https://developers.google.com/youtube/v3/docs/videoCategories/list
YOUTUBE_CATEGORIES = {
    1: "Film & Animation",
    2: "Autos & Vehicles",
    10: "Music",
    15: "Pets & Animals",
    17: "Sports",
    18: "Short Movies",
    19: "Travel & Events",
    20: "Gaming",
    21: "Videoblogging",
    22: "People & Blogs",
    23: "Comedy",
    24: "Entertainment",
    25: "News & Politics",
    26: "Howto & Style",
    27: "Education",
    28: "Science & Technology",
    29: "Nonprofits & Activism",
    30: "Movies",
    31: "Anime/Animation",
    32: "Action/Adventure",
    33: "Classics",
    34: "Comedy",
    35: "Documentary",
    36: "Drama",
    37: "Family",
    38: "Foreign",
    39: "Horror",
    40: "Sci-Fi/Fantasy",
    41: "Thriller",
    42: "Shorts",
    43: "Shows",
    44: "Trailers",
}


def extract_video_id(url_or_id: str) -> Optional[str]:
    """
    Extract video ID from a YouTube URL or return the ID if already bare.

    Handles:
    - youtube.com/watch?v=VIDEO_ID
    - youtu.be/VIDEO_ID
    - youtube.com/embed/VIDEO_ID
    - youtube.com/v/VIDEO_ID
    - youtube.com/shorts/VIDEO_ID
    - bare VIDEO_ID (11 characters)

    Args:
        url_or_id: YouTube URL or video ID

    Returns:
        Video ID or None if not extractable
    """
    if not url_or_id:
        return None

    url_or_id = url_or_id.strip()

    # Already a bare video ID (typically 11 chars, alphanumeric + - + _)
    if re.match(r'^[\w-]{10,12}$', url_or_id):
        return url_or_id

    # youtube.com/watch?v=VIDEO_ID
    match = re.search(r'[?&]v=([^&]+)', url_or_id)
    if match:
        return match.group(1)

    # youtu.be/VIDEO_ID
    match = re.search(r'youtu\.be/([^?&/]+)', url_or_id)
    if match:
        return match.group(1)

    # youtube.com/embed/VIDEO_ID or /v/VIDEO_ID or /shorts/VIDEO_ID
    match = re.search(r'youtube\.com/(?:embed|v|shorts)/([^?&/]+)', url_or_id)
    if match:
        return match.group(1)

    return None


def extract_channel_id(url_or_id: str) -> Optional[str]:
    """
    Extract channel ID from a YouTube URL or return the ID if already bare.

    Handles:
    - youtube.com/channel/CHANNEL_ID
    - bare CHANNEL_ID (starts with UC, 24 chars)

    Note: Does NOT handle @username or /c/customname - those require API lookup.

    Args:
        url_or_id: YouTube URL or channel ID

    Returns:
        Channel ID or None if not extractable
    """
    if not url_or_id:
        return None

    url_or_id = url_or_id.strip()

    # Already a bare channel ID (starts with UC, 24 chars)
    if re.match(r'^UC[\w-]{22}$', url_or_id):
        return url_or_id

    # youtube.com/channel/CHANNEL_ID
    match = re.search(r'youtube\.com/channel/([^?&/]+)', url_or_id)
    if match:
        return match.group(1)

    return None


def parse_iso8601_duration(duration: str) -> Optional[int]:
    """
    Parse ISO 8601 duration to seconds.

    Examples:
    - PT5M30S -> 330
    - PT1H2M3S -> 3723
    - PT45S -> 45

    Args:
        duration: ISO 8601 duration string

    Returns:
        Duration in seconds, or None if unparseable
    """
    if not duration:
        return None

    match = re.match(
        r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$',
        duration.upper()
    )

    if not match:
        return None

    hours = int(match.group(1) or 0)
    minutes = int(match.group(2) or 0)
    seconds = int(match.group(3) or 0)

    return hours * 3600 + minutes * 60 + seconds


def extract_topic_name(wikipedia_url: str) -> Optional[str]:
    """
    Extract topic name from a Wikipedia URL.

    YouTube topicDetails returns URLs like:
    https://en.wikipedia.org/wiki/Music
    https://en.wikipedia.org/wiki/Video_game

    Args:
        wikipedia_url: Wikipedia article URL

    Returns:
        Topic name with underscores replaced by spaces
    """
    if not wikipedia_url:
        return None

    match = re.search(r'wikipedia\.org/wiki/([^?#]+)', wikipedia_url)
    if match:
        topic = match.group(1)
        # Replace underscores with spaces and URL decode
        topic = topic.replace('_', ' ')
        # Handle URL encoding (basic)
        topic = re.sub(r'%20', ' ', topic)
        topic = re.sub(r'%27', "'", topic)
        return topic

    return None


@dataclass
class BatchVideoResult:
    """Result of batch video lookup."""
    videos: Dict[str, YouTubeVideoMetadata]  # video_id -> metadata
    not_found: List[str]  # video_ids that weren't found
    errors: List[str]  # video_ids that had errors


@dataclass
class BatchChannelResult:
    """Result of batch channel lookup."""
    channels: Dict[str, YouTubeChannelMetadata]  # channel_id -> metadata
    not_found: List[str]
    errors: List[str]


class YouTubeClient(BaseClient[YouTubeVideoMetadata]):
    """
    Client for YouTube Data API v3.

    API Documentation: https://developers.google.com/youtube/v3

    Features:
    - Get video details (category, tags, description, channel)
    - Get channel details (topic categories, keywords, country)
    - Batch lookup for up to 50 items per request
    - Respect quota limits (10,000 units/day)

    Quota costs:
    - videos.list: 1 unit per request (up to 50 videos)
    - channels.list: 1 unit per request (up to 50 channels)
    """

    BASE_URL = "https://www.googleapis.com/youtube/v3"
    CACHE_PREFIX = "youtube"
    MAX_BATCH_SIZE = 50  # YouTube API limit

    def __init__(
        self,
        api_key: Optional[str] = None,
        cache: Optional[InMemoryCache] = None
    ):
        super().__init__(
            rate_limit=settings.youtube_rate_limit,
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )
        self.api_key = api_key or settings.youtube_api_key
        if not self.api_key:
            logger.warning(
                "YouTube API key not configured. Set YOUTUBE_API_KEY environment variable."
            )

    def _get_headers(self) -> Dict[str, str]:
        return {
            "Accept": "application/json",
            "User-Agent": "PWG-Enrichment/0.1.0",
        }

    async def _get(
        self,
        endpoint: str,
        params: Optional[Dict[str, Any]] = None,
        use_cache: bool = True,
        cache_key: Optional[str] = None,
    ) -> Optional[Dict[str, Any]]:
        """Override _get to add API key as query parameter."""
        if params is None:
            params = {}
        if self.api_key:
            params["key"] = self.api_key
        return await super()._get(endpoint, params, use_cache, cache_key)

    async def get_video_details(self, video_id: str) -> Optional[YouTubeVideoMetadata]:
        """
        Get detailed information about a single video.

        Args:
            video_id: YouTube video ID (e.g., "dQw4w9WgXcQ")

        Returns:
            YouTubeVideoMetadata or None if not found
        """
        if not self.api_key:
            logger.error("Cannot fetch video: YouTube API key not configured")
            return None

        # Extract video ID if URL was passed
        video_id = extract_video_id(video_id) or video_id

        params = {
            "part": "snippet,contentDetails,statistics,topicDetails",
            "id": video_id,
        }

        result = await self._get("/videos", params=params, cache_key=f"video:{video_id}")

        if not result or not result.get("items"):
            logger.debug(f"Video not found: {video_id}")
            return None

        return self._parse_video_item(result["items"][0])

    async def batch_get_videos(
        self,
        video_ids: List[str],
        include_not_found: bool = False
    ) -> BatchVideoResult:
        """
        Get details for multiple videos efficiently.

        YouTube API allows up to 50 videos per request.
        This method handles larger batches by chunking.

        Args:
            video_ids: List of video IDs (or URLs)
            include_not_found: If True, track which videos weren't found

        Returns:
            BatchVideoResult with videos dict and optional not_found list
        """
        result = BatchVideoResult(videos={}, not_found=[], errors=[])

        if not self.api_key:
            logger.error("Cannot fetch videos: YouTube API key not configured")
            result.errors = video_ids.copy()
            return result

        # Extract IDs and deduplicate
        extracted_ids = []
        for vid in video_ids:
            extracted = extract_video_id(vid)
            if extracted:
                extracted_ids.append(extracted)
            else:
                result.errors.append(vid)

        extracted_ids = list(set(extracted_ids))  # Dedupe

        # Process in chunks of MAX_BATCH_SIZE
        for i in range(0, len(extracted_ids), self.MAX_BATCH_SIZE):
            chunk = extracted_ids[i:i + self.MAX_BATCH_SIZE]

            params = {
                "part": "snippet,contentDetails,statistics,topicDetails",
                "id": ",".join(chunk),
            }

            # Use a cache key based on sorted IDs for consistency
            cache_key = f"videos_batch:{','.join(sorted(chunk))}"
            response = await self._get("/videos", params=params, cache_key=cache_key)

            if not response:
                result.errors.extend(chunk)
                continue

            # Track found IDs
            found_ids = set()
            for item in response.get("items", []):
                video = self._parse_video_item(item)
                if video:
                    result.videos[video.video_id] = video
                    found_ids.add(video.video_id)

            # Track not found
            if include_not_found:
                for vid in chunk:
                    if vid not in found_ids:
                        result.not_found.append(vid)

        logger.info(
            f"Batch fetched {len(result.videos)} videos, "
            f"{len(result.not_found)} not found, {len(result.errors)} errors"
        )

        return result

    async def get_channel_details(self, channel_id: str) -> Optional[YouTubeChannelMetadata]:
        """
        Get detailed information about a channel.

        Args:
            channel_id: YouTube channel ID (starts with "UC")

        Returns:
            YouTubeChannelMetadata or None if not found
        """
        if not self.api_key:
            logger.error("Cannot fetch channel: YouTube API key not configured")
            return None

        # Extract channel ID if URL was passed
        channel_id = extract_channel_id(channel_id) or channel_id

        params = {
            "part": "snippet,statistics,topicDetails,brandingSettings",
            "id": channel_id,
        }

        result = await self._get("/channels", params=params, cache_key=f"channel:{channel_id}")

        if not result or not result.get("items"):
            logger.debug(f"Channel not found: {channel_id}")
            return None

        return self._parse_channel_item(result["items"][0])

    async def batch_get_channels(
        self,
        channel_ids: List[str],
        include_not_found: bool = False
    ) -> BatchChannelResult:
        """
        Get details for multiple channels efficiently.

        Args:
            channel_ids: List of channel IDs
            include_not_found: If True, track which channels weren't found

        Returns:
            BatchChannelResult with channels dict and optional not_found list
        """
        result = BatchChannelResult(channels={}, not_found=[], errors=[])

        if not self.api_key:
            logger.error("Cannot fetch channels: YouTube API key not configured")
            result.errors = channel_ids.copy()
            return result

        # Extract IDs and deduplicate
        extracted_ids = []
        for cid in channel_ids:
            extracted = extract_channel_id(cid)
            if extracted:
                extracted_ids.append(extracted)
            else:
                result.errors.append(cid)

        extracted_ids = list(set(extracted_ids))

        # Process in chunks
        for i in range(0, len(extracted_ids), self.MAX_BATCH_SIZE):
            chunk = extracted_ids[i:i + self.MAX_BATCH_SIZE]

            params = {
                "part": "snippet,statistics,topicDetails,brandingSettings",
                "id": ",".join(chunk),
            }

            cache_key = f"channels_batch:{','.join(sorted(chunk))}"
            response = await self._get("/channels", params=params, cache_key=cache_key)

            if not response:
                result.errors.extend(chunk)
                continue

            found_ids = set()
            for item in response.get("items", []):
                channel = self._parse_channel_item(item)
                if channel:
                    result.channels[channel.channel_id] = channel
                    found_ids.add(channel.channel_id)

            if include_not_found:
                for cid in chunk:
                    if cid not in found_ids:
                        result.not_found.append(cid)

        logger.info(
            f"Batch fetched {len(result.channels)} channels, "
            f"{len(result.not_found)} not found, {len(result.errors)} errors"
        )

        return result

    def _parse_video_item(self, item: Dict[str, Any]) -> Optional[YouTubeVideoMetadata]:
        """Parse a video item from the API response."""
        video_id = item.get("id")
        if not video_id:
            return None

        snippet = item.get("snippet", {})
        content_details = item.get("contentDetails", {})
        statistics = item.get("statistics", {})
        topic_details = item.get("topicDetails", {})

        # Get category name from ID
        category_id = None
        category_name = None
        if snippet.get("categoryId"):
            try:
                category_id = int(snippet["categoryId"])
                category_name = YOUTUBE_CATEGORIES.get(category_id)
            except (ValueError, TypeError):
                pass

        # Parse duration
        duration_iso = content_details.get("duration")
        duration_seconds = parse_iso8601_duration(duration_iso) if duration_iso else None

        # Parse statistics
        view_count = None
        like_count = None
        try:
            if statistics.get("viewCount"):
                view_count = int(statistics["viewCount"])
            if statistics.get("likeCount"):
                like_count = int(statistics["likeCount"])
        except (ValueError, TypeError):
            pass

        # Get topic categories from Wikipedia URLs
        topic_categories = topic_details.get("topicCategories", [])

        # Get thumbnail
        thumbnails = snippet.get("thumbnails", {})
        thumbnail_url = None
        for size in ["high", "medium", "default"]:
            if size in thumbnails:
                thumbnail_url = thumbnails[size].get("url")
                break

        return YouTubeVideoMetadata(
            video_id=video_id,
            title=snippet.get("title", ""),
            description=snippet.get("description"),
            channel_id=snippet.get("channelId"),
            channel_title=snippet.get("channelTitle"),
            category_id=category_id,
            category_name=category_name,
            tags=snippet.get("tags", []),
            duration=duration_iso,
            duration_seconds=duration_seconds,
            published_at=snippet.get("publishedAt"),
            view_count=view_count,
            like_count=like_count,
            thumbnail_url=thumbnail_url,
            default_language=snippet.get("defaultLanguage"),
            topic_categories=topic_categories,
        )

    def _parse_channel_item(self, item: Dict[str, Any]) -> Optional[YouTubeChannelMetadata]:
        """Parse a channel item from the API response."""
        channel_id = item.get("id")
        if not channel_id:
            return None

        snippet = item.get("snippet", {})
        statistics = item.get("statistics", {})
        topic_details = item.get("topicDetails", {})
        branding = item.get("brandingSettings", {}).get("channel", {})

        # Parse statistics
        subscriber_count = None
        video_count = None
        view_count = None
        try:
            if statistics.get("subscriberCount"):
                subscriber_count = int(statistics["subscriberCount"])
            if statistics.get("videoCount"):
                video_count = int(statistics["videoCount"])
            if statistics.get("viewCount"):
                view_count = int(statistics["viewCount"])
        except (ValueError, TypeError):
            pass

        # Get thumbnail
        thumbnails = snippet.get("thumbnails", {})
        thumbnail_url = None
        for size in ["high", "medium", "default"]:
            if size in thumbnails:
                thumbnail_url = thumbnails[size].get("url")
                break

        # Get keywords from branding settings
        keywords_str = branding.get("keywords", "")
        keywords = []
        if keywords_str:
            # Keywords can be space-separated or quoted strings
            keywords = re.findall(r'"([^"]+)"|(\S+)', keywords_str)
            keywords = [k[0] or k[1] for k in keywords if k[0] or k[1]]

        return YouTubeChannelMetadata(
            channel_id=channel_id,
            title=snippet.get("title", ""),
            description=snippet.get("description"),
            custom_url=snippet.get("customUrl"),
            country=snippet.get("country"),
            published_at=snippet.get("publishedAt"),
            subscriber_count=subscriber_count,
            video_count=video_count,
            view_count=view_count,
            topic_categories=topic_details.get("topicCategories", []),
            keywords=keywords,
            thumbnail_url=thumbnail_url,
        )

    def _normalize_topic(self, topic: str) -> str:
        """Normalize a topic string to a topic ID."""
        normalized = topic.lower().strip()

        # Check for custom mappings
        if normalized in settings.topic_mappings:
            return settings.topic_mappings[normalized]

        # Replace special chars and spaces
        normalized = re.sub(r"[^\w\s]", "", normalized)
        normalized = re.sub(r"\s+", "_", normalized)

        return normalized

    async def enrich_video(
        self,
        preference_id: str,
        video_id: str,
        min_confidence: float = 0.7
    ) -> EnrichmentResult:
        """
        Enrich a YouTube video preference with categories, tags, and channel info.

        Args:
            preference_id: PWG preference ID
            video_id: YouTube video ID or URL
            min_confidence: Minimum confidence for match (usually high for direct ID lookup)

        Returns:
            EnrichmentResult with topics, genres, and entities
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=video_id,
            source=EnrichmentSource.YOUTUBE,
        )

        if not self.api_key:
            result.error = "YouTube API key not configured"
            return result

        try:
            # Extract and validate video ID
            extracted_id = extract_video_id(video_id)
            if not extracted_id:
                result.error = f"Invalid video ID or URL: {video_id}"
                return result

            # Fetch video details
            metadata = await self.get_video_details(extracted_id)

            if not metadata:
                result.error = f"Video not found: {extracted_id}"
                result.confidence = 0.0
                result.match_type = MatchType.NONE
                return result

            # Direct ID lookup - high confidence
            result.confidence = 0.95
            result.match_type = MatchType.DIRECT_ID
            result.matched_title = metadata.title
            result.exact_match = True
            result.youtube_metadata = metadata

            # Add category as topic/genre
            if metadata.category_name:
                normalized = self._normalize_topic(metadata.category_name)
                result.topics.append(TopicResult(
                    name=metadata.category_name,
                    normalized=normalized,
                    confidence=0.95,
                    source_field="category"
                ))

            # Add tags as topics
            for tag in metadata.tags[:20]:  # Limit to top 20 tags
                normalized = self._normalize_topic(tag)
                result.topics.append(TopicResult(
                    name=tag,
                    normalized=normalized,
                    confidence=0.8,
                    source_field="tags"
                ))

            # Add Wikipedia topic categories
            for wiki_url in metadata.topic_categories:
                topic_name = extract_topic_name(wiki_url)
                if topic_name:
                    normalized = self._normalize_topic(topic_name)
                    result.topics.append(TopicResult(
                        name=topic_name,
                        normalized=normalized,
                        confidence=0.9,
                        source_field="topicCategories"
                    ))

            # Add channel as entity
            if metadata.channel_title:
                result.entities.append(EntityResult(
                    name=metadata.channel_title,
                    entity_type="youtube_channel",
                    external_id=metadata.channel_id
                ))

            logger.info(
                f"Enriched video '{metadata.title}': "
                f"{len(result.topics)} topics, {len(result.entities)} entities"
            )

        except Exception as e:
            logger.error(f"Error enriching video '{video_id}': {e}")
            result.error = str(e)

        return result

    async def enrich_channel(
        self,
        preference_id: str,
        channel_id: str,
        min_confidence: float = 0.7
    ) -> EnrichmentResult:
        """
        Enrich a YouTube channel preference with topics and keywords.

        Args:
            preference_id: PWG preference ID
            channel_id: YouTube channel ID or URL
            min_confidence: Minimum confidence for match

        Returns:
            EnrichmentResult with topics and entities
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=channel_id,
            source=EnrichmentSource.YOUTUBE,
        )

        if not self.api_key:
            result.error = "YouTube API key not configured"
            return result

        try:
            # Extract and validate channel ID
            extracted_id = extract_channel_id(channel_id)
            if not extracted_id:
                result.error = f"Invalid channel ID or URL: {channel_id}"
                return result

            # Fetch channel details
            metadata = await self.get_channel_details(extracted_id)

            if not metadata:
                result.error = f"Channel not found: {extracted_id}"
                result.confidence = 0.0
                result.match_type = MatchType.NONE
                return result

            # Direct ID lookup - high confidence
            result.confidence = 0.95
            result.match_type = MatchType.DIRECT_ID
            result.matched_title = metadata.title
            result.exact_match = True
            result.youtube_channel_metadata = metadata

            # Add keywords as topics
            for keyword in metadata.keywords[:15]:  # Limit keywords
                normalized = self._normalize_topic(keyword)
                result.topics.append(TopicResult(
                    name=keyword,
                    normalized=normalized,
                    confidence=0.85,
                    source_field="keywords"
                ))

            # Add Wikipedia topic categories
            for wiki_url in metadata.topic_categories:
                topic_name = extract_topic_name(wiki_url)
                if topic_name:
                    normalized = self._normalize_topic(topic_name)
                    result.topics.append(TopicResult(
                        name=topic_name,
                        normalized=normalized,
                        confidence=0.9,
                        source_field="topicCategories"
                    ))

            # Add country as entity if available
            if metadata.country:
                result.entities.append(EntityResult(
                    name=metadata.country,
                    entity_type="country"
                ))

            logger.info(
                f"Enriched channel '{metadata.title}': "
                f"{len(result.topics)} topics, {len(result.entities)} entities"
            )

        except Exception as e:
            logger.error(f"Error enriching channel '{channel_id}': {e}")
            result.error = str(e)

        return result

    # Required abstract method implementations
    async def search(self, query: str) -> Optional[YouTubeVideoMetadata]:
        """
        Search is not implemented for YouTube client.

        YouTube search API has a high quota cost (100 units).
        Use get_video_details with known IDs instead.
        """
        logger.warning(
            "YouTubeClient.search() is not implemented. "
            "Use get_video_details() with a video ID instead."
        )
        return None

    async def get_details(self, item_id: str) -> Optional[YouTubeVideoMetadata]:
        """Get video details by ID."""
        return await self.get_video_details(item_id)
