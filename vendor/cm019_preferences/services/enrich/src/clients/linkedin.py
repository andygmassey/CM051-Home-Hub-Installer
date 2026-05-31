"""LinkedIn reaction enrichment client.

Fetches OpenGraph metadata from LinkedIn post URLs to extract meaningful content
from reaction data. LinkedIn GDPR exports only provide URLs without post content,
but public/semi-public posts expose og:title metadata that reveals the topic.

Rate limit: Conservative 3 second delays to avoid IP blocking.
No authentication required - uses public OG metadata.
"""

import asyncio
import html
import logging
import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional
from urllib.parse import unquote

import httpx

from .base import BaseClient, InMemoryCache

logger = logging.getLogger(__name__)


@dataclass
class LinkedInPostMetadata:
    """Metadata extracted from a LinkedIn post URL."""

    url: str  # Original URL
    title: Optional[str] = None  # og:title content
    author: Optional[str] = None  # Extracted from title format "Content | Author Name"
    content_preview: Optional[str] = None  # First part of title (the actual content)
    hashtags: List[str] = field(default_factory=list)  # Extracted #hashtags
    comment_count: Optional[int] = None  # Extracted from "| N comments"
    og_type: Optional[str] = None  # og:type
    og_image: Optional[str] = None  # og:image
    canonical_url: Optional[str] = None  # Canonical URL with slug

    # Status
    success: bool = False
    error: Optional[str] = None
    requires_auth: bool = False

    @property
    def has_content(self) -> bool:
        """Check if meaningful content was extracted."""
        return bool(self.content_preview or self.hashtags)

    @property
    def topics(self) -> List[str]:
        """Get all extracted topics (hashtags without # prefix)."""
        return [h.lstrip("#") for h in self.hashtags]


@dataclass
class LinkedInEnrichmentResult:
    """Result of enriching a batch of LinkedIn reactions."""

    total_processed: int = 0
    successful: int = 0
    auth_wall: int = 0
    errors: int = 0
    posts: List[LinkedInPostMetadata] = field(default_factory=list)

    @property
    def success_rate(self) -> float:
        """Calculate success rate."""
        if self.total_processed == 0:
            return 0.0
        return self.successful / self.total_processed

    def summary(self) -> str:
        """Get summary string."""
        return (
            f"Processed: {self.total_processed}, "
            f"Success: {self.successful} ({self.success_rate:.1%}), "
            f"Auth wall: {self.auth_wall}, "
            f"Errors: {self.errors}"
        )


class LinkedInClient(BaseClient[LinkedInPostMetadata]):
    """
    Client for extracting metadata from LinkedIn post URLs.

    LinkedIn's GDPR export only includes reaction URLs, not post content.
    This client fetches the public OpenGraph metadata from each URL to
    extract the post title, author, and hashtags.

    Features:
    - Extracts og:title, og:type, og:image
    - Parses LinkedIn title format: "Content preview | Author Name | N comments"
    - Extracts hashtags from content
    - Handles auth walls gracefully (marks as requires_auth)
    - Conservative rate limiting to avoid IP blocks

    Rate limit: 3 second delays (configurable)
    No API key required.
    """

    BASE_URL = "https://www.linkedin.com"
    CACHE_PREFIX = "linkedin"

    # Title patterns that indicate auth wall (no real content)
    AUTH_WALL_TITLES = {
        "Sign Up | LinkedIn",
        "LinkedIn",
        "Log In or Sign Up",
        "Join LinkedIn",
    }

    def __init__(
        self,
        cache: Optional[InMemoryCache] = None,
        delay_seconds: float = 3.0,  # Delay between requests
        timeout: float = 15.0,
    ):
        """
        Initialize LinkedIn client.

        Args:
            cache: Optional cache instance
            delay_seconds: Seconds to wait between requests (default 3.0)
            timeout: Request timeout in seconds
        """
        # Use rate_limit=1.0 for the parent class (we'll handle delays ourselves)
        super().__init__(
            rate_limit=1.0,
            max_retries=2,
            timeout=timeout,
            cache=cache,
        )
        self._delay_seconds = delay_seconds

    def _get_headers(self) -> Dict[str, str]:
        """Get headers for requests."""
        return {
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/120.0.0.0 Safari/537.36"
            ),
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.5",
            "Accept-Encoding": "gzip, deflate",
            "Connection": "keep-alive",
        }

    def decode_url(self, url: str) -> str:
        """Decode URL-encoded LinkedIn URL."""
        return unquote(url)

    async def fetch_post_metadata(self, url: str) -> LinkedInPostMetadata:
        """
        Fetch metadata from a LinkedIn post URL.

        Args:
            url: LinkedIn post URL (may be URL-encoded)

        Returns:
            LinkedInPostMetadata with extracted content
        """
        result = LinkedInPostMetadata(url=url)

        try:
            # Decode URL if needed
            decoded_url = self.decode_url(url)

            # Fetch the page (no rate limiter, we use explicit delays in batch)
            async with httpx.AsyncClient(
                timeout=self.timeout,
                follow_redirects=True,
            ) as client:
                self._request_count += 1

                response = await client.get(
                    decoded_url,
                    headers=self._get_headers(),
                )

                if response.status_code == 429:
                    logger.warning("LinkedIn rate limited")
                    result.error = "rate_limited"
                    return result

                if response.status_code >= 400:
                    logger.debug(f"LinkedIn error {response.status_code}: {url}")
                    result.error = f"http_{response.status_code}"
                    self._errors += 1
                    return result

                html_content = response.text

            # Extract OpenGraph metadata
            result = self._parse_og_metadata(html_content, url)

        except httpx.TimeoutException:
            result.error = "timeout"
            self._errors += 1
        except Exception as e:
            logger.debug(f"Error fetching {url}: {e}")
            result.error = str(e)
            self._errors += 1

        return result

    def _parse_og_metadata(self, html_content: str, url: str) -> LinkedInPostMetadata:
        """Parse OpenGraph metadata from HTML content."""
        result = LinkedInPostMetadata(url=url)

        # Extract og:title
        og_title_match = re.search(
            r'<meta\s+property="og:title"\s+content="([^"]*)"',
            html_content,
            re.IGNORECASE,
        )
        if og_title_match:
            raw_title = og_title_match.group(1)
            result.title = html.unescape(raw_title)

        # Check for auth wall
        if result.title in self.AUTH_WALL_TITLES or not result.title:
            result.requires_auth = True
            result.error = "auth_wall"
            return result

        # Extract og:type
        og_type_match = re.search(
            r'<meta\s+property="og:type"\s+content="([^"]*)"',
            html_content,
            re.IGNORECASE,
        )
        if og_type_match:
            result.og_type = og_type_match.group(1)

        # Extract og:image
        og_image_match = re.search(
            r'<meta\s+property="og:image"\s+content="([^"]*)"',
            html_content,
            re.IGNORECASE,
        )
        if og_image_match:
            result.og_image = html.unescape(og_image_match.group(1))

        # Extract canonical URL (often contains a slug with keywords)
        canonical_match = re.search(
            r'<link\s+rel="canonical"\s+href="([^"]*)"',
            html_content,
            re.IGNORECASE,
        )
        if canonical_match:
            result.canonical_url = html.unescape(canonical_match.group(1))

        # Parse the title format: "Content | Author Name | N comments"
        if result.title:
            self._parse_title_components(result)

        # Extract hashtags from content preview
        if result.content_preview:
            hashtags = re.findall(r"#(\w+)", result.content_preview)
            result.hashtags = [f"#{tag}" for tag in hashtags]

        result.success = True
        return result

    def _parse_title_components(self, result: LinkedInPostMetadata) -> None:
        """Parse LinkedIn title format into components."""
        if not result.title:
            return

        # Split by " | " separator
        parts = result.title.split(" | ")

        if len(parts) >= 1:
            result.content_preview = parts[0].strip()

        if len(parts) >= 2:
            # Second part is usually author name
            author_part = parts[1].strip()
            # Check if it's a comment count instead
            comment_match = re.match(r"(\d+)\s+comments?", author_part)
            if comment_match:
                result.comment_count = int(comment_match.group(1))
            else:
                result.author = author_part

        if len(parts) >= 3:
            # Third part is usually comment count
            comment_part = parts[2].strip()
            comment_match = re.match(r"(\d+)\s+comments?", comment_part)
            if comment_match:
                result.comment_count = int(comment_match.group(1))

    async def enrich_reactions(
        self,
        urls: List[str],
        progress_callback: Optional[Any] = None,
    ) -> LinkedInEnrichmentResult:
        """
        Enrich a batch of LinkedIn reaction URLs.

        Args:
            urls: List of LinkedIn post URLs
            progress_callback: Optional callback(processed, total, current_result)

        Returns:
            LinkedInEnrichmentResult with all processed posts
        """
        result = LinkedInEnrichmentResult()
        result.total_processed = len(urls)

        for i, url in enumerate(urls):
            post = await self.fetch_post_metadata(url)
            result.posts.append(post)

            if post.success:
                result.successful += 1
            elif post.requires_auth:
                result.auth_wall += 1
            else:
                result.errors += 1

            # Progress callback
            if progress_callback:
                progress_callback(i + 1, len(urls), post)

            # Log progress every 100 items
            if (i + 1) % 100 == 0:
                logger.info(
                    f"LinkedIn enrichment progress: {i + 1}/{len(urls)} "
                    f"({result.successful} successful)"
                )

            # Rate limiting delay (except for last item)
            if i < len(urls) - 1:
                await asyncio.sleep(self._delay_seconds)

        logger.info(f"LinkedIn enrichment complete: {result.summary()}")
        return result

    async def enrich_reactions_from_csv(
        self,
        csv_path: str,
        progress_callback: Optional[Any] = None,
    ) -> LinkedInEnrichmentResult:
        """
        Enrich LinkedIn reactions directly from a Reactions.csv file.

        Args:
            csv_path: Path to LinkedIn Reactions.csv file
            progress_callback: Optional progress callback

        Returns:
            LinkedInEnrichmentResult
        """
        import csv
        from pathlib import Path

        csv_file = Path(csv_path)
        if not csv_file.exists():
            raise FileNotFoundError(f"Reactions file not found: {csv_path}")

        # Read URLs from CSV
        urls = []
        with open(csv_file, "r", encoding="utf-8-sig") as f:
            reader = csv.DictReader(f)
            for row in reader:
                link = row.get("Link", "").strip()
                if link:
                    urls.append(link)

        logger.info(f"Loaded {len(urls)} reactions from {csv_path}")

        return await self.enrich_reactions(urls, progress_callback)

    # Required abstract method implementations
    async def search(self, query: str) -> Optional[LinkedInPostMetadata]:
        """Not applicable for LinkedIn client."""
        raise NotImplementedError("LinkedIn client does not support search")

    async def get_details(self, item_id: str) -> Optional[LinkedInPostMetadata]:
        """Get post metadata by URL."""
        return await self.fetch_post_metadata(item_id)


def extract_hashtags_from_results(
    results: LinkedInEnrichmentResult,
) -> Dict[str, int]:
    """
    Extract and count hashtags from enrichment results.

    Args:
        results: LinkedInEnrichmentResult from enrichment run

    Returns:
        Dict mapping hashtag (without #) to occurrence count
    """
    hashtag_counts: Dict[str, int] = {}

    for post in results.posts:
        if post.success and post.hashtags:
            for hashtag in post.hashtags:
                tag = hashtag.lstrip("#").lower()
                hashtag_counts[tag] = hashtag_counts.get(tag, 0) + 1

    return dict(sorted(hashtag_counts.items(), key=lambda x: -x[1]))


def extract_authors_from_results(
    results: LinkedInEnrichmentResult,
) -> Dict[str, int]:
    """
    Extract and count authors from enrichment results.

    Args:
        results: LinkedInEnrichmentResult from enrichment run

    Returns:
        Dict mapping author name to post count
    """
    author_counts: Dict[str, int] = {}

    for post in results.posts:
        if post.success and post.author:
            author_counts[post.author] = author_counts.get(post.author, 0) + 1

    return dict(sorted(author_counts.items(), key=lambda x: -x[1]))


def extract_topics_from_content(
    results: LinkedInEnrichmentResult,
    min_word_length: int = 4,
) -> List[str]:
    """
    Extract potential topics from content previews for Wikidata normalization.

    Extracts:
    - Hashtags (most reliable)
    - Capitalized phrases that might be topics
    - Technical terms

    Args:
        results: LinkedInEnrichmentResult from enrichment run
        min_word_length: Minimum word length to consider

    Returns:
        List of unique topic strings for Wikidata normalization
    """
    topics = set()

    for post in results.posts:
        if not post.success:
            continue

        # Add hashtags (best signal)
        for hashtag in post.hashtags:
            tag = hashtag.lstrip("#")
            if len(tag) >= min_word_length:
                # Convert camelCase/PascalCase to spaces
                spaced = re.sub(r"([a-z])([A-Z])", r"\1 \2", tag)
                topics.add(spaced.lower())

    return sorted(topics)
