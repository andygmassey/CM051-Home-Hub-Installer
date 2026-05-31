"""ASIN Resolver client for Amazon product metadata.

Extracts product information from Amazon Standard Identification Numbers (ASINs).
Uses Amazon's public product pages with careful rate limiting.

Note: Amazon Product Advertising API requires an affiliate account.
This client uses public HTML pages as a fallback with graceful degradation.
"""

import logging
import re
from typing import Dict, Optional

from .base import BaseClient, InMemoryCache
from ..config import settings
from ..models.enrichment import (
    EnrichmentResult,
    EnrichmentSource,
    MatchType,
    TopicResult,
    EntityResult,
    AmazonProductMetadata,
)

logger = logging.getLogger(__name__)


def extract_asin(text: str) -> Optional[str]:
    """
    Extract ASIN from text or Amazon URL.

    ASINs are 10-character alphanumeric identifiers.
    For books, ASIN is usually the ISBN-10.

    Args:
        text: Text that may contain an ASIN

    Returns:
        Extracted ASIN or None
    """
    if not text:
        return None

    text = text.strip()

    # Bare ASIN (10 chars, alphanumeric, starts with B for products or digit for books)
    if re.match(r'^[A-Z0-9]{10}$', text, re.IGNORECASE):
        return text.upper()

    # Amazon product URL patterns
    patterns = [
        r'/dp/([A-Z0-9]{10})',
        r'/gp/product/([A-Z0-9]{10})',
        r'/exec/obidos/ASIN/([A-Z0-9]{10})',
        r'/o/ASIN/([A-Z0-9]{10})',
        r'ASIN[:\s]*([A-Z0-9]{10})',
    ]

    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return match.group(1).upper()

    return None


def get_amazon_url(asin: str, marketplace: str = "com") -> str:
    """
    Generate Amazon product URL from ASIN.

    Args:
        asin: Product ASIN
        marketplace: Amazon marketplace (com, co.uk, de, etc.)

    Returns:
        Amazon product URL
    """
    return f"https://www.amazon.{marketplace}/dp/{asin}"


# Common Amazon product category mappings
AMAZON_CATEGORY_MAPPINGS = {
    "electronics": ["Electronics", "Technology", "Gadgets"],
    "books": ["Books", "Reading", "Literature"],
    "kindle store": ["Books", "E-books", "Digital Reading"],
    "computers & accessories": ["Electronics", "Computing", "Technology"],
    "home & kitchen": ["Home", "Household", "Kitchen"],
    "toys & games": ["Toys", "Games", "Entertainment"],
    "clothing, shoes & jewelry": ["Fashion", "Apparel", "Clothing"],
    "sports & outdoors": ["Sports", "Fitness", "Outdoors"],
    "beauty & personal care": ["Beauty", "Personal Care", "Health"],
    "health & household": ["Health", "Wellness", "Personal Care"],
    "grocery & gourmet food": ["Food", "Grocery", "Gourmet"],
    "pet supplies": ["Pets", "Pet Care", "Animals"],
    "baby": ["Baby", "Parenting", "Children"],
    "movies & tv": ["Movies", "TV", "Entertainment", "Video"],
    "music": ["Music", "Audio", "Entertainment"],
    "video games": ["Gaming", "Video Games", "Entertainment"],
    "software": ["Software", "Computing", "Technology"],
    "tools & home improvement": ["Tools", "Home Improvement", "DIY"],
    "automotive": ["Automotive", "Vehicles", "Car"],
    "office products": ["Office", "Business", "Stationery"],
    "musical instruments": ["Music", "Instruments", "Audio"],
    "arts, crafts & sewing": ["Arts", "Crafts", "Creative"],
    "industrial & scientific": ["Industrial", "Scientific", "Professional"],
    "appliances": ["Appliances", "Home", "Kitchen"],
    "patio, lawn & garden": ["Garden", "Outdoor", "Home"],
}


class ASINClient(BaseClient[AmazonProductMetadata]):
    """
    Client for resolving Amazon ASINs to product metadata.

    This client attempts to extract product information from Amazon.
    Due to Amazon's rate limiting and anti-bot measures, this may not
    always succeed. Results are cached aggressively.

    Features:
    - Extract title, brand, category from ASINs
    - Generate Amazon product URLs
    - Map categories to preference topics
    - Graceful degradation when blocked

    Rate limits:
    - Very conservative (0.5 req/sec) to avoid blocks
    - Results are heavily cached
    """

    BASE_URL = "https://www.amazon.com"
    CACHE_PREFIX = "asin"

    def __init__(
        self,
        marketplace: str = "com",
        cache: Optional[InMemoryCache] = None
    ):
        """
        Initialize ASIN client.

        Args:
            marketplace: Amazon marketplace (com, co.uk, de, etc.)
            cache: Optional shared cache
        """
        # Very conservative rate limit to avoid blocks
        super().__init__(
            rate_limit=0.5,  # 1 request per 2 seconds
            max_retries=2,
            timeout=settings.request_timeout,
            cache=cache,
        )
        self.marketplace = marketplace
        self.base_url = f"https://www.amazon.{marketplace}"

    def _get_headers(self) -> Dict[str, str]:
        """Get headers that look like a regular browser."""
        return {
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.5",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Cache-Control": "no-cache",
        }

    async def get_product(self, asin: str) -> Optional[AmazonProductMetadata]:
        """
        Get product metadata by ASIN.

        Note: This attempts to scrape Amazon product pages, which may fail
        due to rate limiting or anti-bot measures. Use sparingly.

        Args:
            asin: Amazon Standard Identification Number

        Returns:
            AmazonProductMetadata or None if not accessible
        """
        normalized_asin = extract_asin(asin) or asin.upper()

        # Check cache first
        cached = self.cache.get(self.CACHE_PREFIX, f"product:{normalized_asin}")
        if cached is not None:
            self._cache_hits += 1
            return AmazonProductMetadata(**cached) if isinstance(cached, dict) else cached

        self._cache_misses += 1

        # Try to fetch product page
        url = get_amazon_url(normalized_asin, self.marketplace)

        try:
            async with self.rate_limiter:
                import httpx
                async with httpx.AsyncClient(timeout=self.timeout, follow_redirects=True) as client:
                    self._request_count += 1
                    response = await client.get(url, headers=self._get_headers())

                    if response.status_code == 503:
                        logger.warning(f"Amazon returned 503 (service unavailable) for ASIN: {normalized_asin}")
                        return self._create_minimal_metadata(normalized_asin)

                    if response.status_code == 404:
                        logger.debug(f"Product not found: {normalized_asin}")
                        return None

                    if response.status_code != 200:
                        logger.warning(f"Amazon returned {response.status_code} for ASIN: {normalized_asin}")
                        return self._create_minimal_metadata(normalized_asin)

                    # Try to extract basic info from HTML
                    html = response.text
                    metadata = self._parse_product_html(html, normalized_asin)

                    if metadata:
                        # Cache the result
                        self.cache.set(self.CACHE_PREFIX, f"product:{normalized_asin}", {
                            "asin": metadata.asin,
                            "title": metadata.title,
                            "brand": metadata.brand,
                            "category": metadata.category,
                            "category_hierarchy": metadata.category_hierarchy,
                            "amazon_url": metadata.amazon_url,
                            "product_type": metadata.product_type,
                        })

                    return metadata

        except Exception as e:
            logger.warning(f"Error fetching ASIN {normalized_asin}: {e}")
            self._errors += 1
            return self._create_minimal_metadata(normalized_asin)

    def _create_minimal_metadata(self, asin: str) -> AmazonProductMetadata:
        """Create minimal metadata when we can't fetch the product."""
        return AmazonProductMetadata(
            asin=asin,
            title=f"Amazon Product {asin}",
            amazon_url=get_amazon_url(asin, self.marketplace),
            is_available=True,
        )

    def _parse_product_html(self, html: str, asin: str) -> Optional[AmazonProductMetadata]:
        """
        Extract product info from Amazon HTML.

        This is a best-effort extraction that may not work if Amazon
        changes their page structure.
        """
        try:
            # Extract title
            title_match = re.search(r'<span[^>]*id="productTitle"[^>]*>([^<]+)</span>', html)
            title = title_match.group(1).strip() if title_match else ""

            if not title:
                # Try alternate title location
                title_match = re.search(r'<title>([^<]+)</title>', html)
                if title_match:
                    title = title_match.group(1).split(':')[0].strip()
                    title = re.sub(r'\s*-\s*Amazon\.com.*$', '', title)

            # Extract brand
            brand = ""
            brand_match = re.search(r'<a[^>]*id="bylineInfo"[^>]*>([^<]+)</a>', html)
            if brand_match:
                brand = brand_match.group(1).strip()
                brand = re.sub(r'^Visit the\s*', '', brand)
                brand = re.sub(r'\s*Store$', '', brand)

            if not brand:
                brand_match = re.search(r'"brand"\s*:\s*"([^"]+)"', html)
                if brand_match:
                    brand = brand_match.group(1)

            # Extract category from breadcrumbs
            category = ""
            category_hierarchy = []
            breadcrumb_match = re.search(r'<div[^>]*id="wayfinding-breadcrumbs"[^>]*>(.*?)</div>', html, re.DOTALL)
            if breadcrumb_match:
                breadcrumb_html = breadcrumb_match.group(1)
                cats = re.findall(r'<a[^>]*>([^<]+)</a>', breadcrumb_html)
                category_hierarchy = [c.strip() for c in cats if c.strip()]
                if category_hierarchy:
                    category = category_hierarchy[-1]

            # Determine product type from category or ASIN pattern
            product_type = ""
            if category_hierarchy:
                first_cat = category_hierarchy[0].lower()
                if "book" in first_cat or "kindle" in first_cat:
                    product_type = "Book"
                elif "electronic" in first_cat or "computer" in first_cat:
                    product_type = "Electronics"
                elif "music" in first_cat:
                    product_type = "Music"
                elif "movie" in first_cat or "video" in first_cat:
                    product_type = "Video"

            # If ASIN starts with digit, likely a book (ISBN-10)
            if not product_type and asin[0].isdigit():
                product_type = "Book"

            return AmazonProductMetadata(
                asin=asin,
                title=title or f"Amazon Product {asin}",
                brand=brand,
                category=category,
                category_hierarchy=category_hierarchy,
                amazon_url=get_amazon_url(asin, self.marketplace),
                product_type=product_type,
            )

        except Exception as e:
            logger.warning(f"Error parsing Amazon HTML for {asin}: {e}")
            return self._create_minimal_metadata(asin)

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

    async def enrich_product(
        self,
        preference_id: str,
        asin: str,
        min_confidence: float = 0.5
    ) -> EnrichmentResult:
        """
        Enrich an Amazon product preference with metadata.

        Args:
            preference_id: PWG preference ID
            asin: Amazon ASIN or URL
            min_confidence: Minimum confidence (lower for ASIN since we have limited info)

        Returns:
            EnrichmentResult with topics and entities
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=asin,
            source=EnrichmentSource.UNKNOWN,  # No ASIN-specific source defined
        )

        try:
            # Extract ASIN
            extracted_asin = extract_asin(asin)
            if not extracted_asin:
                result.error = f"Invalid ASIN format: {asin}"
                return result

            # Fetch product metadata
            metadata = await self.get_product(extracted_asin)

            if not metadata:
                result.error = f"Product not found: {extracted_asin}"
                result.confidence = 0.0
                result.match_type = MatchType.NONE
                return result

            # ASIN lookup is a direct ID match
            result.confidence = 0.85 if metadata.title != f"Amazon Product {extracted_asin}" else 0.5
            result.match_type = MatchType.DIRECT_ID
            result.matched_title = metadata.title
            result.exact_match = True
            result.asin_metadata = metadata

            # Add categories as topics
            for cat in metadata.category_hierarchy:
                normalized = self._normalize_topic(cat)
                result.topics.append(TopicResult(
                    name=cat,
                    normalized=normalized,
                    confidence=0.8,
                    source_field="category_hierarchy"
                ))

            # Add mapped category topics
            if metadata.category:
                cat_lower = metadata.category.lower()
                if cat_lower in AMAZON_CATEGORY_MAPPINGS:
                    for topic in AMAZON_CATEGORY_MAPPINGS[cat_lower]:
                        result.topics.append(TopicResult(
                            name=topic,
                            normalized=self._normalize_topic(topic),
                            confidence=0.75,
                            source_field="category_mapping"
                        ))

            # Add product type as topic
            if metadata.product_type:
                result.topics.append(TopicResult(
                    name=metadata.product_type,
                    normalized=self._normalize_topic(metadata.product_type),
                    confidence=0.9,
                    source_field="product_type"
                ))

            # Add brand as entity
            if metadata.brand:
                result.entities.append(EntityResult(
                    name=metadata.brand,
                    entity_type="brand",
                    external_id=None
                ))

            # Add Amazon URL as entity
            result.entities.append(EntityResult(
                name=metadata.amazon_url,
                entity_type="amazon_url",
                external_id=extracted_asin
            ))

            logger.info(
                f"Enriched Amazon product '{metadata.title}': "
                f"{len(result.topics)} topics, {len(result.entities)} entities"
            )

        except Exception as e:
            logger.error(f"Error enriching ASIN '{asin}': {e}")
            result.error = str(e)

        return result

    # Required abstract method implementations
    async def search(self, query: str) -> Optional[AmazonProductMetadata]:
        """Search is not implemented for ASIN client."""
        logger.warning("ASINClient.search() is not implemented. Use get_product() with an ASIN.")
        return None

    async def get_details(self, item_id: str) -> Optional[AmazonProductMetadata]:
        """Get product details by ASIN."""
        return await self.get_product(item_id)
