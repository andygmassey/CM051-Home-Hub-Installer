"""URL Metadata Fetcher client for bookmark/URL enrichment.

Extracts metadata from web pages including title, description, keywords,
and OpenGraph/Twitter card tags. Used for enriching Chrome bookmarks
and other saved URLs with topic information.

This is a polite web scraper that:
- Rate limits to 1 request per second
- Uses a respectful User-Agent
- Handles timeouts and dead links gracefully
- Limits download size to avoid memory issues
"""

import logging
import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Dict, List, Optional
from urllib.parse import urlparse

import httpx

from .base import BaseClient, InMemoryCache
from ..config import settings
from ..models.enrichment import (
    EnrichmentResult,
    EnrichmentSource,
    MatchType,
    TopicResult,
    EntityResult,
)

logger = logging.getLogger(__name__)


# Maximum content size to download (1MB)
MAX_CONTENT_SIZE = 1024 * 1024

# Common non-HTML content types to skip
SKIP_CONTENT_TYPES = {
    "application/pdf",
    "application/zip",
    "application/octet-stream",
    "image/",
    "video/",
    "audio/",
    "application/json",
    "application/xml",
}

# Domain category heuristics for fallback categorization
DOMAIN_CATEGORIES = {
    # Developer/Tech
    "github.com": "software_development",
    "gitlab.com": "software_development",
    "stackoverflow.com": "programming",
    "developer.mozilla.org": "web_development",
    "docs.python.org": "programming",
    "docs.google.com": "productivity",
    "aws.amazon.com": "cloud_computing",
    "cloud.google.com": "cloud_computing",
    "azure.microsoft.com": "cloud_computing",
    "npmjs.com": "software_development",
    "pypi.org": "software_development",
    "hackernews.com": "technology",
    "news.ycombinator.com": "technology",
    "techcrunch.com": "technology",
    "theverge.com": "technology",
    "arstechnica.com": "technology",
    "wired.com": "technology",
    # News
    "nytimes.com": "news",
    "washingtonpost.com": "news",
    "theguardian.com": "news",
    "bbc.com": "news",
    "bbc.co.uk": "news",
    "reuters.com": "news",
    "apnews.com": "news",
    "cnn.com": "news",
    # Learning/Education
    "medium.com": "articles",
    "substack.com": "newsletters",
    "wikipedia.org": "reference",
    "coursera.org": "online_learning",
    "udemy.com": "online_learning",
    "edx.org": "online_learning",
    "khanacademy.org": "online_learning",
    "arxiv.org": "academic_research",
    "scholar.google.com": "academic_research",
    "researchgate.net": "academic_research",
    # Shopping/Commerce
    "amazon.com": "shopping",
    "amazon.co.uk": "shopping",
    "ebay.com": "shopping",
    "etsy.com": "shopping",
    # Social
    "twitter.com": "social_media",
    "x.com": "social_media",
    "linkedin.com": "professional_networking",
    "reddit.com": "social_media",
    "facebook.com": "social_media",
    "instagram.com": "social_media",
    # Entertainment
    "youtube.com": "video",
    "youtu.be": "video",
    "vimeo.com": "video",
    "twitch.tv": "streaming",
    "netflix.com": "streaming",
    "spotify.com": "music",
    "soundcloud.com": "music",
    # Finance
    "bloomberg.com": "finance",
    "wsj.com": "finance",
    "ft.com": "finance",
    "investopedia.com": "finance",
    # Design
    "dribbble.com": "design",
    "behance.net": "design",
    "figma.com": "design",
    "canva.com": "design",
    # Food
    "seriouseats.com": "cooking",
    "allrecipes.com": "cooking",
    "food52.com": "cooking",
    "bonappetit.com": "cooking",
    # Travel
    "tripadvisor.com": "travel",
    "airbnb.com": "travel",
    "booking.com": "travel",
    "lonelyplanet.com": "travel",
}


@dataclass
class URLMetadata:
    """Metadata extracted from a URL."""
    url: str
    final_url: Optional[str] = None  # After redirects
    title: Optional[str] = None
    description: Optional[str] = None
    keywords: List[str] = field(default_factory=list)

    # OpenGraph metadata
    og_title: Optional[str] = None
    og_description: Optional[str] = None
    og_type: Optional[str] = None  # article, website, video, etc.
    og_site_name: Optional[str] = None
    og_image: Optional[str] = None

    # Twitter card metadata
    twitter_title: Optional[str] = None
    twitter_description: Optional[str] = None
    twitter_card: Optional[str] = None  # summary, summary_large_image, etc.
    twitter_site: Optional[str] = None  # @username

    # Canonical URL
    canonical_url: Optional[str] = None

    # Derived fields
    domain: Optional[str] = None
    inferred_category: Optional[str] = None
    fetch_timestamp: datetime = field(default_factory=datetime.utcnow)

    # Error tracking
    error: Optional[str] = None
    http_status: Optional[int] = None

    def best_title(self) -> Optional[str]:
        """Get the best available title."""
        return self.og_title or self.twitter_title or self.title

    def best_description(self) -> Optional[str]:
        """Get the best available description."""
        return self.og_description or self.twitter_description or self.description

    def all_keywords(self) -> List[str]:
        """Get all extracted keywords, deduplicated."""
        seen = set()
        result = []
        for kw in self.keywords:
            kw_lower = kw.lower().strip()
            if kw_lower and kw_lower not in seen:
                seen.add(kw_lower)
                result.append(kw.strip())
        return result


def extract_domain(url: str) -> Optional[str]:
    """Extract the domain from a URL."""
    if not url:
        return None
    try:
        parsed = urlparse(url)
        domain = parsed.netloc.lower()
        # Remove www. prefix
        if domain.startswith("www."):
            domain = domain[4:]
        return domain if domain else None
    except Exception:
        return None


def infer_category_from_domain(domain: str) -> Optional[str]:
    """Infer a category based on the domain."""
    if not domain:
        return None

    # Direct match
    if domain in DOMAIN_CATEGORIES:
        return DOMAIN_CATEGORIES[domain]

    # Check for subdomain matches (e.g., docs.python.org)
    for known_domain, category in DOMAIN_CATEGORIES.items():
        if domain.endswith("." + known_domain) or domain == known_domain:
            return category

    # Check for partial matches
    for known_domain, category in DOMAIN_CATEGORIES.items():
        if known_domain in domain:
            return category

    return None


def parse_keywords_string(keywords_str: str) -> List[str]:
    """Parse a comma-separated keywords string."""
    if not keywords_str:
        return []

    keywords = []
    for kw in keywords_str.split(","):
        kw = kw.strip()
        if kw and len(kw) < 100:  # Skip very long "keywords"
            keywords.append(kw)

    return keywords


class HTMLMetadataExtractor:
    """Extracts metadata from HTML content without a full parser.

    Uses regex patterns for lightweight extraction without requiring
    lxml or BeautifulSoup dependencies.
    """

    # Pattern for <title> tag
    TITLE_PATTERN = re.compile(
        r'<title[^>]*>([^<]+)</title>',
        re.IGNORECASE | re.DOTALL
    )

    # Pattern for <meta> tags
    META_PATTERN = re.compile(
        r'<meta\s+[^>]*>',
        re.IGNORECASE | re.DOTALL
    )

    # Pattern for <link rel="canonical">
    CANONICAL_PATTERN = re.compile(
        r'<link\s+[^>]*rel=["\']canonical["\'][^>]*href=["\']([^"\']+)["\'][^>]*>',
        re.IGNORECASE
    )
    CANONICAL_PATTERN_ALT = re.compile(
        r'<link\s+[^>]*href=["\']([^"\']+)["\'][^>]*rel=["\']canonical["\'][^>]*>',
        re.IGNORECASE
    )

    @classmethod
    def extract(cls, html: str, base_url: str) -> URLMetadata:
        """Extract metadata from HTML content."""
        metadata = URLMetadata(url=base_url)
        metadata.domain = extract_domain(base_url)

        # Limit HTML size for extraction
        html = html[:MAX_CONTENT_SIZE]

        # Extract <title>
        title_match = cls.TITLE_PATTERN.search(html)
        if title_match:
            metadata.title = cls._decode_html_entities(title_match.group(1).strip())

        # Extract canonical URL
        canonical_match = cls.CANONICAL_PATTERN.search(html) or cls.CANONICAL_PATTERN_ALT.search(html)
        if canonical_match:
            metadata.canonical_url = canonical_match.group(1)

        # Extract all <meta> tags
        for meta_match in cls.META_PATTERN.finditer(html):
            meta_tag = meta_match.group(0)
            cls._extract_meta_tag(meta_tag, metadata)

        # Infer category from domain
        if metadata.domain:
            metadata.inferred_category = infer_category_from_domain(metadata.domain)

        return metadata

    @classmethod
    def _extract_meta_tag(cls, meta_tag: str, metadata: URLMetadata) -> None:
        """Extract content from a single meta tag."""
        # Get name/property attribute
        name_match = re.search(r'name=["\']([^"\']+)["\']', meta_tag, re.IGNORECASE)
        property_match = re.search(r'property=["\']([^"\']+)["\']', meta_tag, re.IGNORECASE)

        # Get content attribute
        content_match = re.search(r'content=["\']([^"\']*)["\']', meta_tag, re.IGNORECASE)

        if not content_match:
            return

        content = cls._decode_html_entities(content_match.group(1).strip())
        if not content:
            return

        attr_name = None
        if name_match:
            attr_name = name_match.group(1).lower()
        elif property_match:
            attr_name = property_match.group(1).lower()

        if not attr_name:
            return

        # Standard meta tags
        if attr_name == "description":
            metadata.description = content
        elif attr_name == "keywords":
            metadata.keywords.extend(parse_keywords_string(content))
        elif attr_name == "author":
            pass  # Could extract author

        # OpenGraph tags
        elif attr_name == "og:title":
            metadata.og_title = content
        elif attr_name == "og:description":
            metadata.og_description = content
        elif attr_name == "og:type":
            metadata.og_type = content
        elif attr_name == "og:site_name":
            metadata.og_site_name = content
        elif attr_name == "og:image":
            metadata.og_image = content

        # Twitter card tags
        elif attr_name == "twitter:title":
            metadata.twitter_title = content
        elif attr_name == "twitter:description":
            metadata.twitter_description = content
        elif attr_name == "twitter:card":
            metadata.twitter_card = content
        elif attr_name == "twitter:site":
            metadata.twitter_site = content

        # Article-specific tags that might contain keywords
        elif attr_name in ("article:tag", "article:section"):
            metadata.keywords.append(content)
        elif attr_name == "news_keywords":
            metadata.keywords.extend(parse_keywords_string(content))

    @staticmethod
    def _decode_html_entities(text: str) -> str:
        """Decode common HTML entities."""
        if not text:
            return text

        # Common entities
        replacements = {
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": '"',
            "&#39;": "'",
            "&apos;": "'",
            "&nbsp;": " ",
            "&#x27;": "'",
            "&#x2F;": "/",
            "&mdash;": "-",
            "&ndash;": "-",
            "&hellip;": "...",
        }

        for entity, char in replacements.items():
            text = text.replace(entity, char)

        # Numeric entities
        text = re.sub(r'&#(\d+);', lambda m: chr(int(m.group(1))), text)
        text = re.sub(r'&#x([0-9a-fA-F]+);', lambda m: chr(int(m.group(1), 16)), text)

        return text


class URLFetcherClient(BaseClient[URLMetadata]):
    """
    Client for fetching URL metadata from web pages.

    Features:
    - Extract title, description, keywords from HTML
    - Parse OpenGraph and Twitter card metadata
    - Follow redirects and capture final URL
    - Polite crawling with 1 req/sec rate limit
    - Handle dead links and non-HTML content gracefully
    - Limit download size to prevent memory issues

    Usage:
        client = URLFetcherClient()
        metadata = await client.fetch_metadata("https://example.com/article")
        print(f"Title: {metadata.title}")
        print(f"Keywords: {metadata.keywords}")
    """

    BASE_URL = ""  # Not used - we fetch arbitrary URLs
    CACHE_PREFIX = "url_fetcher"

    def __init__(
        self,
        rate_limit: float = 1.0,  # 1 request per second - polite crawling
        timeout: float = 15.0,  # Shorter timeout for web pages
        max_redirects: int = 5,
        cache: Optional[InMemoryCache] = None,
    ):
        super().__init__(
            rate_limit=rate_limit,
            max_retries=2,  # Fewer retries for dead links
            timeout=timeout,
            cache=cache,
        )
        self.max_redirects = max_redirects

    def _get_headers(self) -> Dict[str, str]:
        """Return polite User-Agent headers."""
        return {
            "User-Agent": "PWG-BookmarkEnricher/0.1 (Personal preference analysis; respects robots.txt; contact: github.com/andybrandt)",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate",
            "Connection": "keep-alive",
        }

    async def fetch_metadata(self, url: str) -> URLMetadata:
        """
        Fetch and extract metadata from a URL.

        Args:
            url: The URL to fetch

        Returns:
            URLMetadata with extracted information, or with error set on failure
        """
        # Check cache first
        cached = self.cache.get(self.CACHE_PREFIX, url)
        if cached is not None:
            self._cache_hits += 1
            logger.debug(f"Cache hit for URL: {url[:50]}...")
            return cached

        self._cache_misses += 1

        metadata = URLMetadata(url=url)
        metadata.domain = extract_domain(url)

        # Validate URL
        if not url or not url.startswith(("http://", "https://")):
            metadata.error = "Invalid URL format"
            return metadata

        try:
            # Wait for rate limiter
            async with self.rate_limiter:
                async with httpx.AsyncClient(
                    timeout=self.timeout,
                    follow_redirects=True,
                    max_redirects=self.max_redirects,
                ) as client:
                    self._request_count += 1

                    # First, make a HEAD request to check content type
                    try:
                        head_response = await client.head(
                            url,
                            headers=self._get_headers(),
                        )

                        # Check content type
                        content_type = head_response.headers.get("content-type", "").lower()
                        for skip_type in SKIP_CONTENT_TYPES:
                            if skip_type in content_type:
                                metadata.error = f"Non-HTML content type: {content_type}"
                                metadata.http_status = head_response.status_code
                                return metadata

                        # Check content length
                        content_length = head_response.headers.get("content-length")
                        if content_length and int(content_length) > MAX_CONTENT_SIZE:
                            metadata.error = f"Content too large: {content_length} bytes"
                            return metadata

                    except httpx.HTTPError:
                        # HEAD failed, try GET anyway
                        pass

                    # Fetch the actual content
                    response = await client.get(
                        url,
                        headers=self._get_headers(),
                    )

                    metadata.http_status = response.status_code
                    metadata.final_url = str(response.url)

                    # Handle HTTP errors
                    if response.status_code == 404:
                        metadata.error = "Page not found (404)"
                        return metadata
                    elif response.status_code == 403:
                        metadata.error = "Access forbidden (403)"
                        return metadata
                    elif response.status_code == 401:
                        metadata.error = "Authentication required (401)"
                        return metadata
                    elif response.status_code >= 400:
                        metadata.error = f"HTTP error {response.status_code}"
                        return metadata

                    # Check content type again after GET
                    content_type = response.headers.get("content-type", "").lower()
                    if "text/html" not in content_type and "application/xhtml" not in content_type:
                        # Try to extract what we can from the URL itself
                        metadata.inferred_category = infer_category_from_domain(metadata.domain)
                        metadata.error = f"Non-HTML content: {content_type}"
                        return metadata

                    # Extract metadata from HTML
                    html = response.text[:MAX_CONTENT_SIZE]
                    extracted = HTMLMetadataExtractor.extract(html, url)

                    # Update metadata with extracted values
                    metadata.title = extracted.title
                    metadata.description = extracted.description
                    metadata.keywords = extracted.keywords
                    metadata.og_title = extracted.og_title
                    metadata.og_description = extracted.og_description
                    metadata.og_type = extracted.og_type
                    metadata.og_site_name = extracted.og_site_name
                    metadata.og_image = extracted.og_image
                    metadata.twitter_title = extracted.twitter_title
                    metadata.twitter_description = extracted.twitter_description
                    metadata.twitter_card = extracted.twitter_card
                    metadata.twitter_site = extracted.twitter_site
                    metadata.canonical_url = extracted.canonical_url
                    metadata.inferred_category = extracted.inferred_category

                    # Cache successful result
                    self.cache.set(self.CACHE_PREFIX, url, metadata)

                    logger.debug(
                        f"Fetched metadata for {url[:50]}...: "
                        f"title='{metadata.best_title()[:30] if metadata.best_title() else 'None'}...', "
                        f"keywords={len(metadata.keywords)}"
                    )

                    return metadata

        except httpx.TimeoutException:
            metadata.error = "Request timed out"
            self._errors += 1
            logger.debug(f"Timeout fetching {url[:50]}...")
            return metadata

        except httpx.TooManyRedirects:
            metadata.error = f"Too many redirects (>{self.max_redirects})"
            self._errors += 1
            return metadata

        except httpx.RequestError as e:
            metadata.error = f"Request failed: {str(e)[:100]}"
            self._errors += 1
            logger.debug(f"Request error for {url[:50]}...: {e}")
            return metadata

        except Exception as e:
            metadata.error = f"Unexpected error: {str(e)[:100]}"
            self._errors += 1
            logger.error(f"Unexpected error fetching {url}: {e}")
            return metadata

    async def batch_fetch(
        self,
        urls: List[str],
        skip_errors: bool = True
    ) -> Dict[str, URLMetadata]:
        """
        Fetch metadata for multiple URLs.

        Note: Due to rate limiting (1 req/sec), this will take approximately
        len(urls) seconds to complete.

        Args:
            urls: List of URLs to fetch
            skip_errors: If True, continue on errors (default: True)

        Returns:
            Dict mapping URL to URLMetadata
        """
        results = {}

        for url in urls:
            try:
                metadata = await self.fetch_metadata(url)
                results[url] = metadata
            except Exception as e:
                if not skip_errors:
                    raise
                logger.warning(f"Error fetching {url}: {e}")
                results[url] = URLMetadata(
                    url=url,
                    error=str(e),
                    domain=extract_domain(url),
                )

        # Log summary
        successful = sum(1 for m in results.values() if not m.error)
        logger.info(
            f"Batch fetched {len(urls)} URLs: "
            f"{successful} successful, {len(urls) - successful} failed"
        )

        return results

    async def enrich_url(
        self,
        preference_id: str,
        url: str,
        min_confidence: float = 0.5
    ) -> EnrichmentResult:
        """
        Enrich a bookmark/URL preference with extracted metadata.

        Args:
            preference_id: PWG preference ID
            url: The URL to enrich
            min_confidence: Minimum confidence threshold (not really used for URL fetching)

        Returns:
            EnrichmentResult with topics and entities extracted from the page
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=url,
            source=EnrichmentSource.UNKNOWN,  # No specific source enum for URL fetching
        )

        try:
            metadata = await self.fetch_metadata(url)

            if metadata.error:
                result.error = metadata.error
                result.confidence = 0.0
                result.match_type = MatchType.NONE
                return result

            # Direct fetch - we have the content
            result.confidence = 0.9
            result.match_type = MatchType.DIRECT_ID
            result.matched_title = metadata.best_title()
            result.exact_match = True

            # Add keywords as topics
            for keyword in metadata.all_keywords()[:20]:  # Limit to 20 keywords
                normalized = self._normalize_topic(keyword)
                result.topics.append(TopicResult(
                    name=keyword,
                    normalized=normalized,
                    confidence=0.8,
                    source_field="keywords"
                ))

            # Add OG type as topic if present
            if metadata.og_type and metadata.og_type not in ("website", "article"):
                normalized = self._normalize_topic(metadata.og_type)
                result.topics.append(TopicResult(
                    name=metadata.og_type,
                    normalized=normalized,
                    confidence=0.85,
                    source_field="og:type"
                ))

            # Add inferred category as topic
            if metadata.inferred_category:
                normalized = self._normalize_topic(metadata.inferred_category)
                result.topics.append(TopicResult(
                    name=metadata.inferred_category.replace("_", " "),
                    normalized=normalized,
                    confidence=0.7,
                    source_field="domain_heuristic"
                ))

            # Add domain/site as entity
            if metadata.domain:
                result.entities.append(EntityResult(
                    name=metadata.og_site_name or metadata.domain,
                    entity_type="website",
                    external_id=metadata.domain
                ))

            # Add Twitter site handle as entity if present
            if metadata.twitter_site:
                result.entities.append(EntityResult(
                    name=metadata.twitter_site,
                    entity_type="twitter_account"
                ))

            logger.info(
                f"Enriched URL '{url[:50]}...': "
                f"{len(result.topics)} topics, {len(result.entities)} entities"
            )

        except Exception as e:
            logger.error(f"Error enriching URL '{url}': {e}")
            result.error = str(e)

        return result

    def _normalize_topic(self, topic: str) -> str:
        """Normalize a topic string to a topic ID."""
        if not topic:
            return ""

        normalized = topic.lower().strip()

        # Check for custom mappings
        if normalized in settings.topic_mappings:
            return settings.topic_mappings[normalized]

        # Replace special chars and spaces
        normalized = re.sub(r"[^\w\s]", "", normalized)
        normalized = re.sub(r"\s+", "_", normalized)

        return normalized

    # Required abstract method implementations
    async def search(self, query: str) -> Optional[URLMetadata]:
        """
        Search is not implemented for URL Fetcher.

        Use fetch_metadata() with a known URL instead.
        """
        logger.warning(
            "URLFetcherClient.search() is not implemented. "
            "Use fetch_metadata() with a URL instead."
        )
        return None

    async def get_details(self, item_id: str) -> Optional[URLMetadata]:
        """Get URL metadata by URL (treated as item_id)."""
        metadata = await self.fetch_metadata(item_id)
        return metadata if not metadata.error else None
