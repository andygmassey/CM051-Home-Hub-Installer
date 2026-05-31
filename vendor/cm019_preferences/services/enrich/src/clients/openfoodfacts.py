"""Open Food Facts API client for grocery product analysis.

Enriches product preferences with nutrition info, ingredients, and labels
from barcodes (EAN/UPC codes).

Open Food Facts API: https://world.openfoodfacts.org/data
- No API key required (open data)
- Rate limit: Be polite (~2 req/sec)
"""

import logging
import re
from typing import Any, Dict, List, Optional

from .base import BaseClient, InMemoryCache
from ..config import settings
from ..models.enrichment import (
    EnrichmentResult,
    EnrichmentSource,
    MatchType,
    TopicResult,
    EntityResult,
    NutrientInfo,
    FoodProductMetadata,
)

logger = logging.getLogger(__name__)


def normalize_barcode(barcode: str) -> str:
    """
    Normalize a barcode to standard format.

    Args:
        barcode: Barcode string (may have leading zeros stripped)

    Returns:
        Normalized barcode (13 digits for EAN-13, 12 for UPC-A)
    """
    # Remove any non-digit characters
    barcode = re.sub(r'\D', '', barcode)

    # Pad to 13 digits if less (EAN-13 standard)
    if len(barcode) < 13:
        barcode = barcode.zfill(13)

    return barcode


def extract_barcode(text: str) -> Optional[str]:
    """
    Extract barcode from text.

    Args:
        text: Text that may contain a barcode

    Returns:
        Extracted barcode or None
    """
    if not text:
        return None

    # Find sequences of 8-14 digits (covers EAN-8, UPC-A, EAN-13, ITF-14)
    match = re.search(r'\b\d{8,14}\b', text)
    if match:
        return normalize_barcode(match.group(0))

    return None


# Nutri-Score grade descriptions
NUTRISCORE_DESCRIPTIONS = {
    "a": "Excellent nutritional quality",
    "b": "Good nutritional quality",
    "c": "Average nutritional quality",
    "d": "Poor nutritional quality",
    "e": "Bad nutritional quality",
}

# NOVA group descriptions (food processing level)
NOVA_DESCRIPTIONS = {
    1: "Unprocessed or minimally processed foods",
    2: "Processed culinary ingredients",
    3: "Processed foods",
    4: "Ultra-processed foods",
}


class OpenFoodFactsClient(BaseClient[FoodProductMetadata]):
    """
    Client for Open Food Facts API.

    API Documentation: https://world.openfoodfacts.org/data

    Features:
    - Get product by barcode (EAN/UPC)
    - Search products by name
    - Extract Nutri-Score, NOVA group, Eco-Score
    - Get ingredients, allergens, and labels

    Rate limits:
    - No official limit, but be polite (~2 req/sec)
    - Use User-Agent identifying your app
    """

    BASE_URL = "https://world.openfoodfacts.org/api/v2"
    CACHE_PREFIX = "openfoodfacts"

    def __init__(
        self,
        cache: Optional[InMemoryCache] = None
    ):
        """
        Initialize Open Food Facts client.

        Args:
            cache: Optional shared cache
        """
        super().__init__(
            rate_limit=settings.openfoodfacts_rate_limit,
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )

    def _get_headers(self) -> Dict[str, str]:
        return {
            "Accept": "application/json",
            "User-Agent": "PWG-Enrichment/0.1.0 (https://github.com/pwg)",
        }

    async def get_product(self, barcode: str) -> Optional[FoodProductMetadata]:
        """
        Get product information by barcode.

        Args:
            barcode: EAN-13, EAN-8, or UPC-A barcode

        Returns:
            FoodProductMetadata or None if not found
        """
        normalized = normalize_barcode(barcode)

        result = await self._get(
            f"/product/{normalized}",
            cache_key=f"product:{normalized}"
        )

        if not result or result.get("status") != 1:
            logger.debug(f"Product not found: {barcode}")
            return None

        product = result.get("product", {})
        return self._parse_product(product, normalized)

    async def search(
        self,
        query: str,
        page_size: int = 10,
        page: int = 1
    ) -> List[FoodProductMetadata]:
        """
        Search for products by name.

        Args:
            query: Search query
            page_size: Results per page (max 100)
            page: Page number

        Returns:
            List of matching products
        """
        # Use v1 search endpoint as v2 search has different parameters
        url = "https://world.openfoodfacts.org/cgi/search.pl"

        params = {
            "search_terms": query,
            "page_size": min(page_size, 100),
            "page": page,
            "json": 1,
        }

        result = await self._make_request("GET", url, params=params)

        if not result or "products" not in result:
            return []

        products = []
        for item in result["products"]:
            barcode = item.get("code", "")
            if barcode:
                products.append(self._parse_product(item, barcode))

        return products

    def _parse_product(self, item: Dict[str, Any], barcode: str) -> FoodProductMetadata:
        """Parse a product item from API response."""
        # Parse nutrients
        nutrients = None
        nutriments = item.get("nutriments", {})
        if nutriments:
            nutrients = NutrientInfo(
                energy_kcal=nutriments.get("energy-kcal_100g"),
                fat=nutriments.get("fat_100g"),
                saturated_fat=nutriments.get("saturated-fat_100g"),
                carbohydrates=nutriments.get("carbohydrates_100g"),
                sugars=nutriments.get("sugars_100g"),
                fiber=nutriments.get("fiber_100g"),
                proteins=nutriments.get("proteins_100g"),
                salt=nutriments.get("salt_100g"),
                sodium=nutriments.get("sodium_100g"),
            )

        # Parse categories (clean up the format)
        categories = []
        categories_raw = item.get("categories", "")
        if categories_raw:
            categories = [c.strip() for c in categories_raw.split(",")]

        # Parse labels
        labels = []
        labels_raw = item.get("labels", "")
        if labels_raw:
            labels = [l.strip() for l in labels_raw.split(",")]

        # Parse countries
        countries = []
        countries_raw = item.get("countries", "")
        if countries_raw:
            countries = [c.strip() for c in countries_raw.split(",")]

        return FoodProductMetadata(
            barcode=barcode,
            product_name=item.get("product_name", "") or item.get("product_name_en", ""),
            brand=item.get("brands", ""),
            brands_tags=item.get("brands_tags", []) or [],
            categories=categories,
            categories_hierarchy=item.get("categories_hierarchy", []) or [],
            ingredients_text=item.get("ingredients_text", "") or "",
            ingredients_tags=item.get("ingredients_tags", []) or [],
            allergens=item.get("allergens_tags", []) or [],
            traces=item.get("traces_tags", []) or [],
            nutriscore_grade=item.get("nutriscore_grade"),
            nutriscore_score=item.get("nutriscore_score"),
            nova_group=item.get("nova_group"),
            ecoscore_grade=item.get("ecoscore_grade"),
            labels=labels,
            labels_tags=item.get("labels_tags", []) or [],
            countries=countries,
            origins=item.get("origins_tags", []) or [],
            packaging=item.get("packaging_tags", []) or [],
            image_url=item.get("image_url"),
            image_front_url=item.get("image_front_url"),
            nutrients=nutrients,
            serving_size=item.get("serving_size"),
            quantity=item.get("quantity"),
        )

    def _normalize_topic(self, topic: str) -> str:
        """Normalize a topic string to a topic ID."""
        normalized = topic.lower().strip()

        # Remove language prefix (en:, fr:, etc.)
        normalized = re.sub(r'^[a-z]{2}:', '', normalized)

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
        barcode_or_name: str,
        min_confidence: float = 0.7
    ) -> EnrichmentResult:
        """
        Enrich a food product preference with Open Food Facts data.

        Args:
            preference_id: PWG preference ID
            barcode_or_name: Barcode or product name
            min_confidence: Minimum confidence for name search matches

        Returns:
            EnrichmentResult with topics, entities, and metadata
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=barcode_or_name,
            source=EnrichmentSource.OPENFOODFACTS,
        )

        try:
            # Check if input is a barcode
            extracted_barcode = extract_barcode(barcode_or_name)

            if extracted_barcode:
                # Direct barcode lookup
                metadata = await self.get_product(extracted_barcode)

                if metadata:
                    result.confidence = 0.95
                    result.match_type = MatchType.DIRECT_ID
                    result.exact_match = True
                else:
                    result.error = f"Product not found: {extracted_barcode}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result
            else:
                # Name search
                products = await self.search(barcode_or_name, page_size=5)

                if not products:
                    result.error = f"No products found for: {barcode_or_name}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result

                # Take first result
                metadata = products[0]

                # Calculate confidence based on name similarity
                from .validation import title_similarity
                similarity = title_similarity(barcode_or_name, metadata.product_name)

                if similarity >= 0.9:
                    result.confidence = 0.85
                    result.match_type = MatchType.EXACT_TITLE
                    result.exact_match = True
                elif similarity >= 0.7:
                    result.confidence = similarity * 0.8
                    result.match_type = MatchType.FUZZY_TITLE
                else:
                    result.confidence = similarity * 0.6
                    result.match_type = MatchType.BEST_GUESS

                if result.confidence < min_confidence:
                    result.error = f"Low confidence match ({result.confidence:.2f}): {metadata.product_name}"
                    return result

            # Store metadata
            result.matched_title = metadata.product_name
            result.openfoodfacts_metadata = metadata

            # Add categories as topics
            for category in metadata.categories[:10]:
                normalized = self._normalize_topic(category)
                result.topics.append(TopicResult(
                    name=category,
                    normalized=normalized,
                    confidence=0.9,
                    source_field="categories"
                ))

            # Add Nutri-Score as topic
            if metadata.nutriscore_grade:
                grade = metadata.nutriscore_grade.upper()
                # Description available via NUTRISCORE_DESCRIPTIONS if needed for display
                result.topics.append(TopicResult(
                    name=f"Nutri-Score {grade}",
                    normalized=f"nutriscore_{grade.lower()}",
                    confidence=0.95,
                    source_field="nutriscore_grade"
                ))

            # Add NOVA group as topic
            if metadata.nova_group:
                nova_desc = NOVA_DESCRIPTIONS.get(metadata.nova_group, "")
                result.topics.append(TopicResult(
                    name=f"NOVA {metadata.nova_group}: {nova_desc}",
                    normalized=f"nova_group_{metadata.nova_group}",
                    confidence=0.95,
                    source_field="nova_group"
                ))

            # Add labels as topics (organic, vegan, etc.)
            dietary_labels = []
            if metadata.is_organic:
                dietary_labels.append("Organic")
            if metadata.is_vegan:
                dietary_labels.append("Vegan")
            elif metadata.is_vegetarian:
                dietary_labels.append("Vegetarian")
            if metadata.is_gluten_free:
                dietary_labels.append("Gluten-Free")

            for label in dietary_labels:
                result.topics.append(TopicResult(
                    name=label,
                    normalized=self._normalize_topic(label),
                    confidence=0.95,
                    source_field="labels"
                ))

            # Add brand as entity
            if metadata.brand:
                result.entities.append(EntityResult(
                    name=metadata.brand,
                    entity_type="brand",
                ))

            # Add allergens as entities
            for allergen in metadata.allergens[:5]:
                clean_allergen = re.sub(r'^en:', '', allergen)
                result.entities.append(EntityResult(
                    name=clean_allergen,
                    entity_type="allergen",
                ))

            # Add origin countries as entities
            for country in metadata.countries[:3]:
                result.entities.append(EntityResult(
                    name=country,
                    entity_type="country",
                ))

            logger.info(
                f"Enriched product '{metadata.product_name}': "
                f"{len(result.topics)} topics, {len(result.entities)} entities, "
                f"Nutri-Score: {metadata.nutriscore_grade or 'N/A'}"
            )

        except Exception as e:
            logger.error(f"Error enriching product '{barcode_or_name}': {e}")
            result.error = str(e)

        return result

    # Required abstract method implementations
    async def get_details(self, item_id: str) -> Optional[FoodProductMetadata]:
        """Get product details by barcode."""
        return await self.get_product(item_id)
