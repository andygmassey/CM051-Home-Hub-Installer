"""UPC/Barcode Lookup client for product categorization.

Resolves UPC/EAN/GTIN codes to product information using multiple fallback sources:
1. UPC Database API (https://www.upcdatabase.org)
2. Open EAN Database (https://opengtindb.org) - Limited access
3. Barcode Lookup API (https://www.barcodelookup.com)

For food products, consider using OpenFoodFactsClient instead which has better coverage.
"""

import logging
import re
from typing import Any, Dict, Optional

from .base import BaseClient, InMemoryCache
from ..config import settings
from ..models.enrichment import (
    EnrichmentResult,
    EnrichmentSource,
    MatchType,
    TopicResult,
    EntityResult,
    UPCProductMetadata,
)

logger = logging.getLogger(__name__)


def normalize_upc(barcode: str) -> str:
    """
    Normalize a UPC/EAN/GTIN code.

    Args:
        barcode: Barcode string

    Returns:
        Normalized barcode (digits only, zero-padded to standard length)
    """
    # Remove non-digits
    barcode = re.sub(r'\D', '', barcode)

    # Standard lengths: UPC-A (12), EAN-13 (13), GTIN-14 (14), EAN-8 (8)
    if len(barcode) <= 8:
        return barcode.zfill(8)
    elif len(barcode) <= 12:
        return barcode.zfill(12)
    elif len(barcode) <= 13:
        return barcode.zfill(13)
    else:
        return barcode.zfill(14)


def validate_upc_checksum(barcode: str) -> bool:
    """
    Validate UPC/EAN checksum.

    Args:
        barcode: Normalized barcode

    Returns:
        True if checksum is valid
    """
    if not barcode or len(barcode) < 8:
        return False

    digits = [int(d) for d in barcode]

    # Standard UPC/EAN checksum algorithm
    if len(barcode) in (12, 13, 14):
        # Alternate weighting: 1 and 3 for EAN-13, 3 and 1 for UPC-A
        odd_sum = sum(digits[::2])
        even_sum = sum(digits[1::2])

        if len(barcode) == 12:  # UPC-A
            checksum = (odd_sum * 3 + even_sum) % 10
        else:  # EAN-13/14
            checksum = (even_sum * 3 + odd_sum) % 10

        return checksum == 0

    return True  # Unknown format, assume valid


def extract_upc(text: str) -> Optional[str]:
    """
    Extract UPC/EAN code from text.

    Args:
        text: Text that may contain a barcode

    Returns:
        Extracted and normalized barcode, or None
    """
    if not text:
        return None

    # Find sequences of 8-14 digits
    match = re.search(r'\b\d{8,14}\b', text)
    if match:
        barcode = normalize_upc(match.group(0))
        return barcode

    return None


# GS1 Global Product Classification (GPC) top-level codes
GPC_CATEGORIES = {
    "10": "Food/Beverage/Tobacco",
    "21": "Healthcare",
    "42": "Personal Care",
    "47": "Cleaning/Hygiene",
    "50": "Beauty/Personal Care/Hygiene",
    "51": "Pet Care",
    "53": "Home Appliances",
    "54": "Luggage/Travel Goods",
    "58": "Music/Film",
    "60": "Information Technology",
    "61": "Audio Visual/Photography",
    "62": "Electrical Supplies",
    "63": "Stationery",
    "64": "Kitchen/Tabletop",
    "65": "Household/Office Furniture/Furnishings",
    "67": "Live Plants",
    "68": "Tools/Equipment – Hand",
    "70": "Sports Equipment",
    "71": "Toys/Games",
    "72": "Baby Care",
    "73": "Vehicles",
    "78": "Arts/Crafts/Needlework",
    "79": "Building Products",
    "82": "Safety/Security",
    "84": "Health/Wellness",
    "85": "Clothing",
    "86": "Footwear",
    "87": "Personal Accessories",
    "91": "Textiles",
    "92": "Hardware/Building Materials",
    "93": "Camping",
    "94": "Lawn/Garden",
}


class UPCClient(BaseClient[UPCProductMetadata]):
    """
    Client for UPC/Barcode lookups.

    Uses multiple sources for product information:
    - UPC Database (upcdatabase.org) - Community-driven, free tier available
    - Falls back to Open EAN if UPC Database unavailable

    Features:
    - Lookup product by UPC/EAN/GTIN code
    - Get product name, brand, category
    - Map to GS1 GPC categories where available

    Note: For food products, OpenFoodFactsClient has better coverage.
    """

    BASE_URL = "https://api.upcdatabase.org"
    CACHE_PREFIX = "upc"

    def __init__(
        self,
        api_key: Optional[str] = None,
        cache: Optional[InMemoryCache] = None
    ):
        """
        Initialize UPC client.

        Args:
            api_key: Optional UPC Database API key (free tier available)
            cache: Optional shared cache
        """
        super().__init__(
            rate_limit=2.0,  # Conservative rate limit
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )
        self.api_key = api_key or settings.upc_api_key if hasattr(settings, 'upc_api_key') else None

    def _get_headers(self) -> Dict[str, str]:
        headers = {
            "Accept": "application/json",
            "User-Agent": "PWG-Enrichment/0.1.0",
        }
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    async def get_product(self, barcode: str) -> Optional[UPCProductMetadata]:
        """
        Look up product by UPC/EAN/GTIN code.

        Args:
            barcode: Product barcode

        Returns:
            UPCProductMetadata or None if not found
        """
        normalized = normalize_upc(barcode)

        # Check cache first
        cached = self.cache.get(self.CACHE_PREFIX, f"product:{normalized}")
        if cached is not None:
            self._cache_hits += 1
            if isinstance(cached, dict):
                return UPCProductMetadata(**cached)
            return cached

        self._cache_misses += 1

        # Try UPC Database API if we have a key
        if self.api_key:
            result = await self._get(
                f"/product/{normalized}",
                cache_key=f"upcdatabase:{normalized}"
            )

            if result and result.get("success"):
                metadata = self._parse_upc_database_response(result, normalized)
                if metadata:
                    self._cache_product(normalized, metadata)
                    return metadata

        # Try UPC Items DB (free, no key required)
        # https://www.upcitemdb.com/upc/
        try:
            upcitemdb_url = f"https://api.upcitemdb.com/prod/trial/lookup?upc={normalized}"
            async with self.rate_limiter:
                import httpx
                async with httpx.AsyncClient(timeout=self.timeout) as client:
                    self._request_count += 1
                    response = await client.get(
                        upcitemdb_url,
                        headers={"Accept": "application/json"}
                    )

                    if response.status_code == 200:
                        data = response.json()
                        if data.get("items"):
                            metadata = self._parse_upcitemdb_response(data, normalized)
                            if metadata:
                                self._cache_product(normalized, metadata)
                                return metadata
        except Exception as e:
            logger.debug(f"UPC Item DB lookup failed: {e}")

        logger.debug(f"Product not found in any UPC database: {normalized}")
        return None

    def _cache_product(self, barcode: str, metadata: UPCProductMetadata) -> None:
        """Cache product metadata."""
        self.cache.set(self.CACHE_PREFIX, f"product:{barcode}", {
            "barcode": metadata.barcode,
            "title": metadata.title,
            "brand": metadata.brand,
            "manufacturer": metadata.manufacturer,
            "category": metadata.category,
            "description": metadata.description,
            "source": metadata.source,
        })

    def _parse_upc_database_response(
        self,
        data: Dict[str, Any],
        barcode: str
    ) -> Optional[UPCProductMetadata]:
        """Parse response from upcdatabase.org API."""
        try:
            return UPCProductMetadata(
                barcode=barcode,
                title=data.get("title", "") or data.get("description", ""),
                brand=data.get("brand", ""),
                manufacturer=data.get("manufacturer", ""),
                category=data.get("category", ""),
                description=data.get("description", ""),
                image_url=data.get("image"),
                source="upcdatabase.org",
            )
        except Exception as e:
            logger.warning(f"Error parsing UPC Database response: {e}")
            return None

    def _parse_upcitemdb_response(
        self,
        data: Dict[str, Any],
        barcode: str
    ) -> Optional[UPCProductMetadata]:
        """Parse response from upcitemdb.com API."""
        try:
            items = data.get("items", [])
            if not items:
                return None

            item = items[0]
            return UPCProductMetadata(
                barcode=barcode,
                title=item.get("title", ""),
                brand=item.get("brand", ""),
                manufacturer=item.get("manufacturer", ""),
                category=item.get("category", ""),
                description=item.get("description", ""),
                size=item.get("size", ""),
                weight=item.get("weight", ""),
                image_url=item.get("images", [None])[0] if item.get("images") else None,
                source="upcitemdb.com",
            )
        except Exception as e:
            logger.warning(f"Error parsing UPC Item DB response: {e}")
            return None

    def _normalize_topic(self, topic: str) -> str:
        """Normalize a topic string to a topic ID."""
        normalized = topic.lower().strip()

        if normalized in settings.topic_mappings:
            return settings.topic_mappings[normalized]

        normalized = re.sub(r"[^\w\s]", "", normalized)
        normalized = re.sub(r"\s+", "_", normalized)

        return normalized

    async def enrich_product(
        self,
        preference_id: str,
        barcode: str,
        min_confidence: float = 0.7
    ) -> EnrichmentResult:
        """
        Enrich a product preference with UPC lookup data.

        Args:
            preference_id: PWG preference ID
            barcode: UPC/EAN/GTIN code
            min_confidence: Minimum confidence threshold

        Returns:
            EnrichmentResult with topics and entities
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=barcode,
            source=EnrichmentSource.UNKNOWN,  # No UPC-specific source
        )

        try:
            # Extract and validate barcode
            extracted = extract_upc(barcode)
            if not extracted:
                result.error = f"Invalid barcode format: {barcode}"
                return result

            # Look up product
            metadata = await self.get_product(extracted)

            if not metadata:
                result.error = f"Product not found: {extracted}"
                result.confidence = 0.0
                result.match_type = MatchType.NONE
                return result

            # Direct barcode lookup - high confidence
            result.confidence = 0.90
            result.match_type = MatchType.DIRECT_ID
            result.matched_title = metadata.title
            result.exact_match = True
            result.upc_metadata = metadata

            # Add category as topic
            if metadata.category:
                result.topics.append(TopicResult(
                    name=metadata.category,
                    normalized=self._normalize_topic(metadata.category),
                    confidence=0.85,
                    source_field="category"
                ))

            # Add brand as entity
            if metadata.brand:
                result.entities.append(EntityResult(
                    name=metadata.brand,
                    entity_type="brand",
                ))

            # Add manufacturer as entity (if different from brand)
            if metadata.manufacturer and metadata.manufacturer != metadata.brand:
                result.entities.append(EntityResult(
                    name=metadata.manufacturer,
                    entity_type="manufacturer",
                ))

            # Try to infer GPC category from barcode prefix
            if len(extracted) >= 2:
                gpc_prefix = extracted[:2]
                if gpc_prefix in GPC_CATEGORIES:
                    result.topics.append(TopicResult(
                        name=GPC_CATEGORIES[gpc_prefix],
                        normalized=self._normalize_topic(GPC_CATEGORIES[gpc_prefix]),
                        confidence=0.6,  # Lower confidence for prefix-based inference
                        source_field="gpc_prefix"
                    ))

            logger.info(
                f"Enriched UPC product '{metadata.title}': "
                f"{len(result.topics)} topics, {len(result.entities)} entities"
            )

        except Exception as e:
            logger.error(f"Error enriching barcode '{barcode}': {e}")
            result.error = str(e)

        return result

    # Required abstract method implementations
    async def search(self, query: str) -> Optional[UPCProductMetadata]:
        """Search is not implemented for UPC client."""
        logger.warning("UPCClient.search() is not implemented. Use get_product() with a barcode.")
        return None

    async def get_details(self, item_id: str) -> Optional[UPCProductMetadata]:
        """Get product details by barcode."""
        return await self.get_product(item_id)
