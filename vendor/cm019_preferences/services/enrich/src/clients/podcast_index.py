"""Podcast Index API client for podcast/episode enrichment.

Enriches podcast preferences with categories, descriptions, and keywords
using the Podcast Index API.

API Documentation: https://podcastindex-org.github.io/docs-api/

Authentication:
- X-Auth-Key: API key
- X-Auth-Date: Unix timestamp
- Authorization: SHA-1 hash of (api_key + api_secret + timestamp)

Key endpoints:
- /search/byterm: Search podcasts by name
- /podcasts/byfeedid: Get podcast details by feed ID
- /episodes/bytitle: Search episodes by title
- /podcasts/bytitle: Search podcasts by exact title
"""

import hashlib
import logging
import time
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
    PodcastMetadata,
    PodcastEpisodeMetadata,
)

logger = logging.getLogger(__name__)


# Podcast Index category IDs to human-readable names
# See: https://podcastindex-org.github.io/docs-api/#get-/categories/list
PODCAST_CATEGORIES = {
    1: "Arts",
    2: "Books",
    3: "Design",
    4: "Fashion & Beauty",
    5: "Food",
    6: "Performing Arts",
    7: "Visual Arts",
    8: "Business",
    9: "Careers",
    10: "Entrepreneurship",
    11: "Investing",
    12: "Management",
    13: "Marketing",
    14: "Non-Profit",
    15: "Comedy",
    16: "Comedy Interviews",
    17: "Improv",
    18: "Stand-Up",
    19: "Education",
    20: "Courses",
    21: "How To",
    22: "Language Learning",
    23: "Self-Improvement",
    24: "Fiction",
    25: "Comedy Fiction",
    26: "Drama",
    27: "Science Fiction",
    28: "Government",
    29: "History",
    30: "Health & Fitness",
    31: "Alternative Health",
    32: "Fitness",
    33: "Medicine",
    34: "Mental Health",
    35: "Nutrition",
    36: "Sexuality",
    37: "Kids & Family",
    38: "Education for Kids",
    39: "Parenting",
    40: "Pets & Animals",
    41: "Stories for Kids",
    42: "Leisure",
    43: "Animation & Manga",
    44: "Automotive",
    45: "Aviation",
    46: "Crafts",
    47: "Games",
    48: "Hobbies",
    49: "Home & Garden",
    50: "Video Games",
    51: "Music",
    52: "Music Commentary",
    53: "Music History",
    54: "Music Interviews",
    55: "News",
    56: "Business News",
    57: "Daily News",
    58: "Entertainment News",
    59: "News Commentary",
    60: "Politics",
    61: "Sports News",
    62: "Tech News",
    63: "Religion & Spirituality",
    64: "Buddhism",
    65: "Christianity",
    66: "Hinduism",
    67: "Islam",
    68: "Judaism",
    69: "Religion",
    70: "Spirituality",
    71: "Science",
    72: "Astronomy",
    73: "Chemistry",
    74: "Earth Sciences",
    75: "Life Sciences",
    76: "Mathematics",
    77: "Natural Sciences",
    78: "Nature",
    79: "Physics",
    80: "Social Sciences",
    81: "Society & Culture",
    82: "Documentary",
    83: "Personal Journals",
    84: "Philosophy",
    85: "Places & Travel",
    86: "Relationships",
    87: "Sports",
    88: "Baseball",
    89: "Basketball",
    90: "Cricket",
    91: "Fantasy Sports",
    92: "Football",
    93: "Golf",
    94: "Hockey",
    95: "Rugby",
    96: "Soccer",
    97: "Swimming",
    98: "Tennis",
    99: "Volleyball",
    100: "Wilderness",
    101: "Wrestling",
    102: "Technology",
    103: "True Crime",
    104: "TV & Film",
    105: "After Shows",
    106: "Film History",
    107: "Film Interviews",
    108: "Film Reviews",
    109: "TV Reviews",
}


def normalize_podcast_name(name: str) -> str:
    """
    Normalize a podcast name for searching.

    - Removes common suffixes that don't help search
    - Cleans up extra whitespace
    - Handles podcast naming conventions
    """
    if not name:
        return name

    result = name.strip()

    # Remove common uninformative suffixes/prefixes
    remove_patterns = [
        " - Podcast",
        " Podcast",
        " podcast",
        " (Audio)",
        " (audio)",
        " (Video)",
        " (video)",
        " | ",  # Often used for taglines
    ]

    for pattern in remove_patterns:
        if result.endswith(pattern):
            result = result[:-len(pattern)]

    # Clean up whitespace
    import re
    result = re.sub(r'\s+', ' ', result).strip()

    return result


@dataclass
class PodcastSearchResult:
    """Result from a podcast search."""
    podcasts: List[PodcastMetadata]
    query: str
    total_results: int = 0


@dataclass
class EpisodeSearchResult:
    """Result from an episode search."""
    episodes: List[PodcastEpisodeMetadata]
    query: str
    total_results: int = 0


class PodcastIndexClient(BaseClient[PodcastMetadata]):
    """
    Client for Podcast Index API.

    Features:
    - Search podcasts by name/term
    - Get full podcast details by feed ID
    - Search episodes by title
    - Extract categories and keywords
    - Full enrichment for podcast preferences

    Authentication uses SHA-1 hash of (api_key + api_secret + unix_timestamp)
    passed in the Authorization header.

    Usage:
        client = PodcastIndexClient()

        # Search for a podcast
        results = await client.search_podcast("The Daily")
        print(f"Found: {results.total_results} podcasts")

        # Get podcast details
        podcast = await client.get_podcast_details(feed_id=123456)
        print(f"Categories: {podcast.categories}")

        # Search for an episode
        episodes = await client.search_episode("climate change")

        # Full enrichment
        result = await client.enrich_podcast("pref_123", "Radiolab")
    """

    BASE_URL = "https://api.podcastindex.org/api/1.0"
    CACHE_PREFIX = "podcast_index"

    def __init__(
        self,
        api_key: Optional[str] = None,
        api_secret: Optional[str] = None,
        cache: Optional[InMemoryCache] = None,
    ):
        """
        Initialize the Podcast Index client.

        Args:
            api_key: Podcast Index API key (or PODCAST_INDEX_API_KEY env var)
            api_secret: Podcast Index API secret (or PODCAST_INDEX_API_SECRET env var)
            cache: Optional shared cache instance
        """
        super().__init__(
            rate_limit=settings.podcast_index_rate_limit,
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )
        self.api_key = api_key or settings.podcast_index_api_key
        self.api_secret = api_secret or settings.podcast_index_api_secret

        if not self.api_key or not self.api_secret:
            logger.warning(
                "Podcast Index API credentials not configured. "
                "Set PODCAST_INDEX_API_KEY and PODCAST_INDEX_API_SECRET environment variables."
            )

    def _get_auth_headers(self) -> Dict[str, str]:
        """
        Generate authentication headers for Podcast Index API.

        Returns headers with:
        - X-Auth-Key: API key
        - X-Auth-Date: Unix timestamp
        - Authorization: SHA-1(api_key + api_secret + timestamp)
        """
        timestamp = str(int(time.time()))

        # Create the authorization hash
        auth_string = self.api_key + self.api_secret + timestamp
        auth_hash = hashlib.sha1(auth_string.encode('utf-8')).hexdigest()

        return {
            "X-Auth-Key": self.api_key,
            "X-Auth-Date": timestamp,
            "Authorization": auth_hash,
            "User-Agent": "PWG-Enrichment/0.1.0",
        }

    def _get_headers(self) -> Dict[str, str]:
        """Return headers including authentication."""
        headers = {
            "Accept": "application/json",
        }

        if self.api_key and self.api_secret:
            headers.update(self._get_auth_headers())
        else:
            headers["User-Agent"] = "PWG-Enrichment/0.1.0"

        return headers

    async def search_podcast(
        self,
        query: str,
        max_results: int = 10,
        clean: bool = True,
    ) -> PodcastSearchResult:
        """
        Search for podcasts by name/term.

        Uses the /search/byterm endpoint.

        Args:
            query: Search text (e.g., "The Daily", "Serial")
            max_results: Maximum results to return (default 10)
            clean: Whether to clean/normalize the query first

        Returns:
            PodcastSearchResult with list of matching podcasts
        """
        result = PodcastSearchResult(podcasts=[], query=query)

        if not self.api_key or not self.api_secret:
            logger.error("Cannot search: Podcast Index credentials not configured")
            return result

        # Normalize query if requested
        search_query = normalize_podcast_name(query) if clean else query
        if not search_query:
            logger.warning("Empty query after normalization")
            return result

        params = {
            "q": search_query,
            "max": max_results,
            "clean": 1,  # Only return clean/safe podcasts
        }

        cache_key = f"search:{search_query}:{max_results}"

        try:
            response = await self._get(
                "/search/byterm",
                params=params,
                cache_key=cache_key,
            )

            if not response:
                logger.debug(f"No response for podcast search: {query}")
                return result

            feeds = response.get("feeds", [])
            result.total_results = response.get("count", len(feeds))

            for feed_data in feeds:
                podcast = self._parse_podcast(feed_data)
                if podcast:
                    result.podcasts.append(podcast)

            logger.info(
                f"Search '{query[:30]}...' found {len(result.podcasts)} podcasts"
            )

        except Exception as e:
            logger.error(f"Error searching '{query}': {e}")

        return result

    async def search_podcast_by_title(
        self,
        title: str,
        max_results: int = 5,
    ) -> PodcastSearchResult:
        """
        Search for podcasts by exact title match.

        Uses the /podcasts/bytitle endpoint for more precise matching.

        Args:
            title: Exact podcast title to search for
            max_results: Maximum results to return

        Returns:
            PodcastSearchResult with matching podcasts
        """
        result = PodcastSearchResult(podcasts=[], query=title)

        if not self.api_key or not self.api_secret:
            logger.error("Cannot search: Podcast Index credentials not configured")
            return result

        params = {
            "q": title,
            "max": max_results,
        }

        cache_key = f"title:{title}:{max_results}"

        try:
            response = await self._get(
                "/podcasts/bytitle",
                params=params,
                cache_key=cache_key,
            )

            if not response:
                return result

            feeds = response.get("feeds", [])
            result.total_results = response.get("count", len(feeds))

            for feed_data in feeds:
                podcast = self._parse_podcast(feed_data)
                if podcast:
                    result.podcasts.append(podcast)

        except Exception as e:
            logger.error(f"Error searching by title '{title}': {e}")

        return result

    async def get_podcast_details(
        self,
        feed_id: int,
    ) -> Optional[PodcastMetadata]:
        """
        Get detailed information about a podcast by its feed ID.

        Uses the /podcasts/byfeedid endpoint.

        Args:
            feed_id: Podcast Index feed ID

        Returns:
            PodcastMetadata or None if not found
        """
        if not self.api_key or not self.api_secret:
            logger.error("Cannot get details: Podcast Index credentials not configured")
            return None

        cache_key = f"feed:{feed_id}"

        try:
            response = await self._get(
                "/podcasts/byfeedid",
                params={"id": feed_id},
                cache_key=cache_key,
            )

            if not response:
                logger.debug(f"Podcast not found: feed_id={feed_id}")
                return None

            feed_data = response.get("feed", {})
            if not feed_data:
                return None

            podcast = self._parse_podcast(feed_data)

            if podcast:
                logger.info(
                    f"Got podcast details for '{podcast.title}': "
                    f"{len(podcast.categories)} categories"
                )

            return podcast

        except Exception as e:
            logger.error(f"Error getting podcast details for feed_id={feed_id}: {e}")
            return None

    async def search_episode(
        self,
        query: str,
        max_results: int = 10,
    ) -> EpisodeSearchResult:
        """
        Search for episodes by title/description.

        Uses the /search/byterm endpoint with episode results.

        Args:
            query: Search text
            max_results: Maximum results to return

        Returns:
            EpisodeSearchResult with matching episodes
        """
        result = EpisodeSearchResult(episodes=[], query=query)

        if not self.api_key or not self.api_secret:
            logger.error("Cannot search: Podcast Index credentials not configured")
            return result

        params = {
            "q": query,
            "max": max_results,
        }

        cache_key = f"episode:{query}:{max_results}"

        try:
            # Use episodes/byterm for episode-specific search
            response = await self._get(
                "/search/byterm",
                params=params,
                cache_key=cache_key,
            )

            if not response:
                return result

            # The API returns feeds with episodes, we need to extract episodes
            feeds = response.get("feeds", [])
            result.total_results = response.get("count", 0)

            for feed_data in feeds:
                episode = self._parse_episode(feed_data)
                if episode:
                    result.episodes.append(episode)

        except Exception as e:
            logger.error(f"Error searching episodes '{query}': {e}")

        return result

    async def get_episodes_by_podcast(
        self,
        feed_id: int,
        max_results: int = 20,
    ) -> List[PodcastEpisodeMetadata]:
        """
        Get recent episodes for a podcast.

        Args:
            feed_id: Podcast Index feed ID
            max_results: Maximum episodes to return

        Returns:
            List of PodcastEpisodeMetadata
        """
        episodes = []

        if not self.api_key or not self.api_secret:
            logger.error("Cannot get episodes: Podcast Index credentials not configured")
            return episodes

        cache_key = f"episodes_by_feed:{feed_id}:{max_results}"

        try:
            response = await self._get(
                "/episodes/byfeedid",
                params={"id": feed_id, "max": max_results},
                cache_key=cache_key,
            )

            if not response:
                return episodes

            items = response.get("items", [])

            for item_data in items:
                episode = self._parse_episode(item_data, feed_id=feed_id)
                if episode:
                    episodes.append(episode)

        except Exception as e:
            logger.error(f"Error getting episodes for feed_id={feed_id}: {e}")

        return episodes

    def _parse_podcast(self, data: Dict[str, Any]) -> Optional[PodcastMetadata]:
        """Parse a podcast from API response."""
        feed_id = data.get("id")
        title = data.get("title", "").strip()

        if not feed_id or not title:
            return None

        # Parse categories from the categories dict
        categories = []
        categories_data = data.get("categories", {})
        if isinstance(categories_data, dict):
            # Categories come as {id: name, id: name, ...}
            categories = list(categories_data.values())

        # Extract keywords from various fields
        keywords = []

        # Add explicit keywords if present
        if data.get("itunesId"):
            keywords.append(f"itunes:{data['itunesId']}")

        # Extract from description
        description = data.get("description", "") or ""

        # Get author/owner info
        author = data.get("author", "") or data.get("ownerName", "") or ""

        # Check for explicit content
        explicit = data.get("explicit", False)
        if isinstance(explicit, int):
            explicit = explicit == 1

        # Get episode count
        episode_count = data.get("episodeCount", 0)

        # Get language
        language = data.get("language", "")

        # Get artwork/image
        image_url = data.get("image", "") or data.get("artwork", "")

        # Get website/link
        website = data.get("link", "") or data.get("url", "")

        # Calculate confidence based on available data
        confidence = 0.7  # Base confidence
        if categories:
            confidence += 0.1
        if description and len(description) > 50:
            confidence += 0.05
        if episode_count and episode_count > 10:
            confidence += 0.1
        if author:
            confidence += 0.05
        confidence = min(confidence, 1.0)

        return PodcastMetadata(
            feed_id=feed_id,
            title=title,
            author=author,
            description=description,
            categories=categories,
            language=language,
            explicit=explicit,
            episode_count=episode_count,
            keywords=keywords,
            image_url=image_url,
            website=website,
            itunes_id=data.get("itunesId"),
            confidence=confidence,
        )

    def _parse_episode(
        self,
        data: Dict[str, Any],
        feed_id: Optional[int] = None,
    ) -> Optional[PodcastEpisodeMetadata]:
        """Parse an episode from API response."""
        episode_id = data.get("id")
        title = data.get("title", "").strip()

        if not episode_id or not title:
            return None

        return PodcastEpisodeMetadata(
            episode_id=episode_id,
            title=title,
            description=data.get("description", ""),
            feed_id=feed_id or data.get("feedId"),
            podcast_title=data.get("feedTitle", ""),
            duration_seconds=data.get("duration"),
            published_at=data.get("datePublished"),
            episode_number=data.get("episode"),
            season_number=data.get("season"),
            link=data.get("link", ""),
            enclosure_url=data.get("enclosureUrl", ""),
        )

    def _normalize_topic(self, topic: str) -> str:
        """Normalize a topic string to a topic ID."""
        import re
        normalized = topic.lower().strip()

        # Check for custom mappings in settings
        if normalized in settings.topic_mappings:
            return settings.topic_mappings[normalized]

        # Replace special chars and spaces
        normalized = re.sub(r"[^\w\s]", "", normalized)
        normalized = re.sub(r"\s+", "_", normalized)

        return normalized

    async def enrich_podcast(
        self,
        preference_id: str,
        podcast_name: str,
        min_confidence: float = 0.5,
    ) -> EnrichmentResult:
        """
        Enrich a podcast preference with categories and metadata.

        Searches for the podcast by name and extracts categories,
        author, and other metadata.

        Args:
            preference_id: PWG preference ID
            podcast_name: The podcast name to search for
            min_confidence: Minimum confidence to accept match

        Returns:
            EnrichmentResult with topics and entities
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=podcast_name,
            source=EnrichmentSource.PODCAST_INDEX,
        )

        if not self.api_key or not self.api_secret:
            result.error = "Podcast Index API credentials not configured"
            return result

        try:
            # Search for the podcast
            search_result = await self.search_podcast(podcast_name, max_results=5)

            if not search_result.podcasts:
                # Try exact title match as fallback
                search_result = await self.search_podcast_by_title(podcast_name)

            if not search_result.podcasts:
                result.error = "No podcasts found"
                result.confidence = 0.0
                result.match_type = MatchType.NONE
                return result

            # Get the best match (first result)
            best_match = search_result.podcasts[0]

            # Optionally fetch full details
            if best_match.feed_id:
                full_details = await self.get_podcast_details(best_match.feed_id)
                if full_details:
                    best_match = full_details

            # Populate enrichment result
            result.confidence = best_match.confidence
            result.match_type = MatchType.FUZZY_TITLE
            result.matched_title = best_match.title
            result.podcast_metadata = best_match

            # Check title similarity for match type
            original_lower = podcast_name.lower().strip()
            matched_lower = best_match.title.lower().strip()
            if original_lower == matched_lower:
                result.match_type = MatchType.EXACT_TITLE
                result.exact_match = True
                result.confidence = max(result.confidence, 0.95)

            if best_match.confidence < min_confidence:
                result.error = f"Low confidence match: {best_match.confidence:.2f}"

            # Add categories as topics
            for category in best_match.categories:
                normalized = self._normalize_topic(category)
                result.topics.append(TopicResult(
                    name=category,
                    normalized=normalized,
                    confidence=best_match.confidence,
                    source_field="category",
                ))

            # Add keywords as topics (lower confidence)
            for keyword in best_match.keywords[:10]:
                if not keyword.startswith("itunes:"):  # Skip internal IDs
                    normalized = self._normalize_topic(keyword)
                    result.topics.append(TopicResult(
                        name=keyword,
                        normalized=normalized,
                        confidence=best_match.confidence * 0.8,
                        source_field="keyword",
                    ))

            # Add author as entity
            if best_match.author:
                result.entities.append(EntityResult(
                    name=best_match.author,
                    entity_type="podcast_host",
                    external_id=f"podcast_index:{best_match.feed_id}",
                ))

            # Add podcast itself as entity
            result.entities.append(EntityResult(
                name=best_match.title,
                entity_type="podcast",
                external_id=f"podcast_index:{best_match.feed_id}",
            ))

            # Add iTunes ID if available
            if best_match.itunes_id:
                result.entities.append(EntityResult(
                    name=f"iTunes: {best_match.itunes_id}",
                    entity_type="external_id",
                    external_id=f"itunes:{best_match.itunes_id}",
                ))

            logger.info(
                f"Enriched podcast '{podcast_name[:30]}...': "
                f"{len(result.topics)} topics, {len(result.entities)} entities, "
                f"confidence={result.confidence:.2f}"
            )

        except Exception as e:
            logger.error(f"Error enriching podcast '{podcast_name}': {e}")
            result.error = str(e)

        return result

    async def enrich_episode(
        self,
        preference_id: str,
        episode_title: str,
        podcast_name: Optional[str] = None,
        min_confidence: float = 0.5,
    ) -> EnrichmentResult:
        """
        Enrich a podcast episode preference.

        If podcast_name is provided, searches within that podcast.
        Otherwise, searches all episodes.

        Args:
            preference_id: PWG preference ID
            episode_title: The episode title to search for
            podcast_name: Optional podcast name to narrow search
            min_confidence: Minimum confidence to accept match

        Returns:
            EnrichmentResult with topics and entities
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=episode_title,
            source=EnrichmentSource.PODCAST_INDEX,
        )

        if not self.api_key or not self.api_secret:
            result.error = "Podcast Index API credentials not configured"
            return result

        try:
            # If we have a podcast name, first find that podcast
            feed_id = None
            podcast_info = None
            if podcast_name:
                podcast_result = await self.search_podcast(podcast_name, max_results=1)
                if podcast_result.podcasts:
                    feed_id = podcast_result.podcasts[0].feed_id
                    podcast_info = podcast_result.podcasts[0]

            # Search for the episode
            if feed_id:
                # Search within the specific podcast
                episodes = await self.get_episodes_by_podcast(feed_id, max_results=50)
                # Find the best matching episode
                best_episode = None
                best_score = 0.0
                for ep in episodes:
                    score = self._title_similarity(episode_title, ep.title)
                    if score > best_score:
                        best_score = score
                        best_episode = ep

                if best_episode and best_score > 0.5:
                    result.confidence = best_score
                    result.match_type = MatchType.FUZZY_TITLE if best_score < 0.95 else MatchType.EXACT_TITLE
                    result.matched_title = best_episode.title
                    result.exact_match = best_score >= 0.95
                    result.podcast_episode_metadata = best_episode

                    # Add podcast categories as topics
                    if podcast_info:
                        for category in podcast_info.categories:
                            result.topics.append(TopicResult(
                                name=category,
                                normalized=self._normalize_topic(category),
                                confidence=best_score * 0.9,
                                source_field="podcast_category",
                            ))

                    # Add episode as entity
                    result.entities.append(EntityResult(
                        name=best_episode.title,
                        entity_type="podcast_episode",
                        external_id=f"podcast_index_episode:{best_episode.episode_id}",
                    ))

                    if best_episode.podcast_title:
                        result.entities.append(EntityResult(
                            name=best_episode.podcast_title,
                            entity_type="podcast",
                        ))
                else:
                    result.error = "Episode not found in podcast"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
            else:
                # General episode search
                episode_result = await self.search_episode(episode_title, max_results=5)
                if episode_result.episodes:
                    best_episode = episode_result.episodes[0]
                    result.confidence = 0.7  # Lower confidence for general search
                    result.match_type = MatchType.FUZZY_TITLE
                    result.matched_title = best_episode.title
                    result.podcast_episode_metadata = best_episode

                    result.entities.append(EntityResult(
                        name=best_episode.title,
                        entity_type="podcast_episode",
                        external_id=f"podcast_index_episode:{best_episode.episode_id}",
                    ))

                    if best_episode.podcast_title:
                        result.entities.append(EntityResult(
                            name=best_episode.podcast_title,
                            entity_type="podcast",
                        ))
                else:
                    result.error = "No episodes found"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE

            logger.info(
                f"Enriched episode '{episode_title[:30]}...': "
                f"{len(result.topics)} topics, {len(result.entities)} entities"
            )

        except Exception as e:
            logger.error(f"Error enriching episode '{episode_title}': {e}")
            result.error = str(e)

        return result

    def _title_similarity(self, a: str, b: str) -> float:
        """Calculate simple title similarity score."""
        a_lower = a.lower().strip()
        b_lower = b.lower().strip()

        if a_lower == b_lower:
            return 1.0

        # Check if one contains the other
        if a_lower in b_lower or b_lower in a_lower:
            return 0.9

        # Simple word overlap
        a_words = set(a_lower.split())
        b_words = set(b_lower.split())

        if not a_words or not b_words:
            return 0.0

        intersection = len(a_words & b_words)
        union = len(a_words | b_words)

        return intersection / union if union > 0 else 0.0

    # Required abstract method implementations
    async def search(self, query: str) -> Optional[PodcastMetadata]:
        """Search for a podcast and return the top result."""
        result = await self.search_podcast(query, max_results=1)
        if result.podcasts:
            return result.podcasts[0]
        return None

    async def get_details(self, item_id: str) -> Optional[PodcastMetadata]:
        """Get podcast details by feed ID."""
        try:
            feed_id = int(item_id)
            return await self.get_podcast_details(feed_id)
        except (ValueError, TypeError):
            logger.error(f"Invalid feed ID: {item_id}")
            return None
