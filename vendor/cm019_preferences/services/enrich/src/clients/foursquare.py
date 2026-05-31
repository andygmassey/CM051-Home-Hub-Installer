"""Foursquare Places API client for venue enrichment.

Alternative to Google Places with different coverage and venue categories.
Particularly good for nightlife, bars, and restaurants.

Foursquare Places API: https://docs.foursquare.com/developer/reference/place-search
- API key required (free tier: 950 calls/day)
- Rate limit: ~2 req/sec
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
    FoursquareCategory,
    FoursquareLocation,
    FoursquareVenueMetadata,
)

logger = logging.getLogger(__name__)


# Map Foursquare top-level category IDs to human-readable names
# https://docs.foursquare.com/developer/reference/place-categories
FOURSQUARE_TOP_CATEGORIES = {
    # Food & Drink
    13000: "Dining and Drinking",
    13001: "Bar",
    13002: "Brewery",
    13003: "Bubble Tea Shop",
    13004: "Cafe",
    13005: "Cocktail Bar",
    13006: "Coffee Shop",
    13007: "Restaurant",
    13009: "Wine Bar",

    # Nightlife
    10032: "Nightclub",

    # Arts & Entertainment
    10000: "Arts and Entertainment",
    10001: "Aquarium",
    10002: "Arcade",
    10004: "Casino",
    10005: "Cinema",
    10006: "Comedy Club",
    10007: "Concert Hall",
    10008: "Exhibit",
    10024: "Museum",
    10025: "Music Venue",
    10027: "Performing Arts Venue",
    10029: "Stadium",
    10030: "Theater",

    # Outdoors & Recreation
    16000: "Landmarks and Outdoors",
    16003: "Beach",
    16020: "Lake",
    16023: "Mountain",
    16032: "Park",
    16035: "Playground",

    # Travel & Transport
    19000: "Travel and Transportation",
    19009: "Airport",
    19034: "Train Station",

    # Shopping
    17000: "Retail",
    17003: "Bookstore",
    17018: "Electronics Store",
    17030: "Grocery Store",
    17069: "Shopping Mall",

    # Services
    11000: "Business and Professional Services",
    12000: "Community and Government",
    15000: "Health and Medicine",
}


def extract_foursquare_id(text: str) -> Optional[str]:
    """
    Extract Foursquare venue ID from URL or text.

    Args:
        text: Text that may contain a Foursquare ID

    Returns:
        Extracted FSQ ID or None
    """
    if not text:
        return None

    text = text.strip()

    # Foursquare v3 ID format (24 char hex)
    if re.match(r'^[a-f0-9]{24}$', text, re.IGNORECASE):
        return text

    # URL patterns
    url_match = re.search(r'foursquare\.com/v/[^/]+/([a-f0-9]{24})', text, re.IGNORECASE)
    if url_match:
        return url_match.group(1)

    # fsq: prefix
    prefix_match = re.match(r'^fsq[:\s]*([a-f0-9]{24})$', text, re.IGNORECASE)
    if prefix_match:
        return prefix_match.group(1)

    return None


class FoursquareClient(BaseClient[FoursquareVenueMetadata]):
    """
    Client for Foursquare Places API v3.

    API Documentation: https://docs.foursquare.com/developer/reference

    Features:
    - Search venues by name and location
    - Get venue details including categories, price, rating
    - Hierarchical category system
    - Tips and photos counts

    Rate limits:
    - Free tier: 950 calls/day
    - ~2 req/sec recommended
    """

    BASE_URL = "https://api.foursquare.com/v3"
    CACHE_PREFIX = "foursquare"

    def __init__(
        self,
        api_key: Optional[str] = None,
        cache: Optional[InMemoryCache] = None
    ):
        """
        Initialize Foursquare client.

        Args:
            api_key: Foursquare API key (FOURSQUARE_API_KEY env var)
            cache: Optional shared cache
        """
        super().__init__(
            rate_limit=settings.foursquare_rate_limit,
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )
        self.api_key = api_key or settings.foursquare_api_key
        if not self.api_key:
            logger.warning(
                "Foursquare API key not configured. Set FOURSQUARE_API_KEY environment variable."
            )

    def _get_headers(self) -> Dict[str, str]:
        headers = {
            "Accept": "application/json",
            "User-Agent": "PWG-Enrichment/0.1.0",
        }
        if self.api_key:
            headers["Authorization"] = self.api_key
        return headers

    async def search_venues(
        self,
        query: str,
        near: Optional[str] = None,
        ll: Optional[str] = None,
        radius: int = 2000,
        limit: int = 10,
        categories: Optional[List[int]] = None
    ) -> List[FoursquareVenueMetadata]:
        """
        Search for venues.

        Args:
            query: Search query (venue name)
            near: Location query (e.g., "Hong Kong")
            ll: Latitude,longitude (e.g., "22.3193,114.1694")
            radius: Search radius in meters
            limit: Maximum results
            categories: Filter by category IDs

        Returns:
            List of matching venues
        """
        if not self.api_key:
            logger.error("Cannot search: Foursquare API key not configured")
            return []

        params = {
            "query": query,
            "limit": min(limit, 50),
        }

        if near:
            params["near"] = near
        if ll:
            params["ll"] = ll
        if radius:
            params["radius"] = radius
        if categories:
            params["categories"] = ",".join(str(c) for c in categories)

        cache_key = f"search:{query}:{near or ll}:{limit}"
        result = await self._get("/places/search", params=params, cache_key=cache_key)

        if not result or "results" not in result:
            return []

        return [self._parse_venue(item) for item in result["results"]]

    async def get_venue(self, fsq_id: str) -> Optional[FoursquareVenueMetadata]:
        """
        Get detailed venue information.

        Args:
            fsq_id: Foursquare venue ID

        Returns:
            FoursquareVenueMetadata or None
        """
        if not self.api_key:
            logger.error("Cannot fetch venue: Foursquare API key not configured")
            return None

        # Extract ID if URL was passed
        extracted = extract_foursquare_id(fsq_id) or fsq_id

        params = {
            "fields": "fsq_id,name,categories,location,description,tel,website,"
                      "email,hours_display,rating,price,popularity,tips_count,"
                      "photos_count,verified,closed_bucket,menu,link"
        }

        result = await self._get(
            f"/places/{extracted}",
            params=params,
            cache_key=f"venue:{extracted}"
        )

        if not result:
            logger.debug(f"Venue not found: {fsq_id}")
            return None

        return self._parse_venue(result)

    def _parse_venue(self, item: Dict[str, Any]) -> FoursquareVenueMetadata:
        """Parse a venue from API response."""
        # Parse categories
        categories = []
        for cat in item.get("categories", []):
            categories.append(FoursquareCategory(
                id=cat.get("id", 0),
                name=cat.get("name", ""),
                short_name=cat.get("short_name", ""),
                plural_name=cat.get("plural_name", ""),
                icon_prefix=cat.get("icon", {}).get("prefix", ""),
                icon_suffix=cat.get("icon", {}).get("suffix", ""),
            ))

        # Parse location
        location = None
        loc_data = item.get("location", {})
        if loc_data:
            location = FoursquareLocation(
                address=loc_data.get("address", ""),
                address_extended=loc_data.get("address_extended", ""),
                locality=loc_data.get("locality", ""),
                region=loc_data.get("region", ""),
                postcode=loc_data.get("postcode", ""),
                country=loc_data.get("country", ""),
                cross_street=loc_data.get("cross_street", ""),
                latitude=loc_data.get("latitude") or (item.get("geocodes", {}).get("main", {}).get("latitude")),
                longitude=loc_data.get("longitude") or (item.get("geocodes", {}).get("main", {}).get("longitude")),
                formatted_address=loc_data.get("formatted_address", ""),
            )

        # Parse menu URL
        menu_url = ""
        menu_data = item.get("menu")
        if menu_data:
            menu_url = menu_data.get("url", "") if isinstance(menu_data, dict) else str(menu_data)

        return FoursquareVenueMetadata(
            fsq_id=item.get("fsq_id", ""),
            name=item.get("name", ""),
            categories=categories,
            location=location,
            description=item.get("description", ""),
            tel=item.get("tel", ""),
            website=item.get("website", ""),
            email=item.get("email", ""),
            hours_display=item.get("hours_display", ""),
            rating=item.get("rating"),
            price=item.get("price"),
            popularity=item.get("popularity"),
            tips_count=item.get("tips_count", 0),
            photos_count=item.get("photos_count", 0),
            verified=item.get("verified", False),
            closed_bucket=item.get("closed_bucket", ""),
            menu_url=menu_url,
        )

    def _normalize_topic(self, topic: str) -> str:
        """Normalize a topic string to a topic ID."""
        normalized = topic.lower().strip()

        if normalized in settings.topic_mappings:
            return settings.topic_mappings[normalized]

        normalized = re.sub(r"[^\w\s]", "", normalized)
        normalized = re.sub(r"\s+", "_", normalized)

        return normalized

    async def enrich_venue(
        self,
        preference_id: str,
        venue_name: str,
        location: Optional[str] = None,
        min_confidence: float = 0.7
    ) -> EnrichmentResult:
        """
        Enrich a venue preference with Foursquare data.

        Args:
            preference_id: PWG preference ID
            venue_name: Venue name or Foursquare ID
            location: Optional location hint (e.g., "Hong Kong")
            min_confidence: Minimum confidence threshold

        Returns:
            EnrichmentResult with topics and entities
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=venue_name,
            source=EnrichmentSource.FOURSQUARE,
        )

        if not self.api_key:
            result.error = "Foursquare API key not configured"
            return result

        try:
            # Check if input is a Foursquare ID
            extracted_id = extract_foursquare_id(venue_name)

            if extracted_id:
                # Direct ID lookup
                metadata = await self.get_venue(extracted_id)

                if metadata:
                    result.confidence = 0.95
                    result.match_type = MatchType.DIRECT_ID
                    result.exact_match = True
                else:
                    result.error = f"Venue not found: {extracted_id}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result
            else:
                # Search by name
                venues = await self.search_venues(
                    query=venue_name,
                    near=location or "Hong Kong",  # Default location bias
                    limit=5
                )

                if not venues:
                    result.error = f"No venues found for: {venue_name}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result

                # Take first result
                metadata = venues[0]

                # Calculate confidence based on name similarity
                from .validation import title_similarity
                similarity = title_similarity(venue_name, metadata.name)

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
                    result.error = f"Low confidence match ({result.confidence:.2f}): {metadata.name}"
                    return result

            # Store metadata
            result.matched_title = metadata.name
            result.foursquare_metadata = metadata

            # Add categories as topics
            for cat in metadata.categories:
                result.topics.append(TopicResult(
                    name=cat.name,
                    normalized=self._normalize_topic(cat.name),
                    confidence=0.9,
                    source_field="categories"
                ))

                # Also add short name if different
                if cat.short_name and cat.short_name != cat.name:
                    result.topics.append(TopicResult(
                        name=cat.short_name,
                        normalized=self._normalize_topic(cat.short_name),
                        confidence=0.85,
                        source_field="categories.short_name"
                    ))

            # Add price level as topic
            if metadata.price:
                price_label = f"Price: {metadata.price_symbol}"
                result.topics.append(TopicResult(
                    name=price_label,
                    normalized=f"price_{metadata.price}",
                    confidence=0.95,
                    source_field="price"
                ))

            # Add rating as entity
            if metadata.rating:
                result.entities.append(EntityResult(
                    name=metadata.formatted_rating,
                    entity_type="rating",
                ))

            # Add location as entities
            if metadata.location:
                if metadata.location.locality:
                    result.entities.append(EntityResult(
                        name=metadata.location.locality,
                        entity_type="city",
                    ))
                if metadata.location.country:
                    result.entities.append(EntityResult(
                        name=metadata.location.country,
                        entity_type="country",
                    ))

            # Add venue name as entity
            result.entities.append(EntityResult(
                name=metadata.name,
                entity_type="venue",
                external_id=metadata.fsq_id
            ))

            # Add website if available
            if metadata.website:
                result.entities.append(EntityResult(
                    name=metadata.website,
                    entity_type="website",
                ))

            logger.info(
                f"Enriched Foursquare venue '{metadata.name}': "
                f"{len(result.topics)} topics, {len(result.entities)} entities, "
                f"rating: {metadata.formatted_rating or 'N/A'}"
            )

        except Exception as e:
            logger.error(f"Error enriching venue '{venue_name}': {e}")
            result.error = str(e)

        return result

    # Required abstract method implementations
    async def search(self, query: str) -> Optional[FoursquareVenueMetadata]:
        """Search for a venue by name."""
        venues = await self.search_venues(query, limit=1)
        return venues[0] if venues else None

    async def get_details(self, item_id: str) -> Optional[FoursquareVenueMetadata]:
        """Get venue details by Foursquare ID."""
        return await self.get_venue(item_id)
