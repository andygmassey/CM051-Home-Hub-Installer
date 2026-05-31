"""Geocoding client for location enrichment using Nominatim (OpenStreetMap).

Converts text location names to coordinates and structured address data.
Used for enriching Calendar venue preferences with geographic intelligence.

Nominatim usage policy (STRICTLY enforced):
- Rate limit: 1 request per second maximum
- User-Agent: REQUIRED - must identify the application
- No heavy usage or bulk geocoding without permission
- See: https://operations.osmfoundation.org/policies/nominatim/
"""

import logging
import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Dict, List, Optional

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


# User's default location for biasing search results (Hong Kong)
DEFAULT_VIEWBOX = {
    "min_lon": 113.8,
    "min_lat": 22.1,
    "max_lon": 114.4,
    "max_lat": 22.6,
}

# OSM place types mapped to our preference categories
PLACE_TYPE_CATEGORIES = {
    # Food & Drink
    "restaurant": "restaurant",
    "cafe": "cafe",
    "bar": "bar",
    "pub": "bar",
    "fast_food": "restaurant",
    "food_court": "restaurant",
    "biergarten": "bar",
    "wine_bar": "bar",
    "cocktail_bar": "bar",
    "bakery": "cafe",
    "ice_cream": "cafe",
    "coffee_shop": "cafe",
    # Entertainment & Leisure
    "cinema": "entertainment",
    "theatre": "entertainment",
    "museum": "museum",
    "gallery": "museum",
    "nightclub": "nightlife",
    "club": "nightlife",
    "arts_centre": "entertainment",
    "casino": "entertainment",
    "bowling_alley": "entertainment",
    "amusement_arcade": "entertainment",
    # Sports & Fitness
    "gym": "fitness",
    "fitness_centre": "fitness",
    "sports_centre": "sports",
    "stadium": "sports",
    "golf_course": "sports",
    "swimming_pool": "sports",
    # Shopping
    "supermarket": "shopping",
    "mall": "shopping",
    "shop": "shopping",
    "marketplace": "shopping",
    "department_store": "shopping",
    # Services
    "hotel": "accommodation",
    "hostel": "accommodation",
    "guest_house": "accommodation",
    "motel": "accommodation",
    "spa": "wellness",
    "beauty": "wellness",
    "hairdresser": "wellness",
    # Education
    "school": "education",
    "university": "education",
    "college": "education",
    "library": "education",
    # Healthcare
    "hospital": "healthcare",
    "clinic": "healthcare",
    "doctors": "healthcare",
    "dentist": "healthcare",
    "pharmacy": "healthcare",
    # Transportation
    "airport": "transportation",
    "train_station": "transportation",
    "bus_station": "transportation",
    "ferry_terminal": "transportation",
    # Religious
    "place_of_worship": "religious",
    "church": "religious",
    "temple": "religious",
    "mosque": "religious",
    "synagogue": "religious",
    # Office/Work
    "office": "office",
    "coworking_space": "office",
}


@dataclass
class GeocodingResult:
    """Result of a geocoding lookup."""
    query: str  # Original search text
    lat: Optional[float] = None
    lon: Optional[float] = None
    display_name: Optional[str] = None  # Full formatted address
    place_type: Optional[str] = None  # restaurant, cafe, bar, etc.
    place_category: Optional[str] = None  # Our internal category

    # Address components
    name: Optional[str] = None  # Venue/place name
    street: Optional[str] = None
    house_number: Optional[str] = None
    neighbourhood: Optional[str] = None
    suburb: Optional[str] = None
    district: Optional[str] = None
    city: Optional[str] = None
    state: Optional[str] = None
    country: Optional[str] = None
    country_code: Optional[str] = None
    postcode: Optional[str] = None

    # Metadata
    osm_id: Optional[int] = None
    osm_type: Optional[str] = None  # node, way, relation
    confidence: float = 0.0
    importance: Optional[float] = None  # OSM importance score

    # Error tracking
    error: Optional[str] = None
    geocoded_at: datetime = field(default_factory=datetime.utcnow)

    def has_coordinates(self) -> bool:
        """Check if valid coordinates were found."""
        return self.lat is not None and self.lon is not None

    def formatted_coordinates(self) -> Optional[str]:
        """Return coordinates as a formatted string."""
        if self.has_coordinates():
            return f"{self.lat:.6f}, {self.lon:.6f}"
        return None

    def area_name(self) -> Optional[str]:
        """Get the most specific area name available."""
        return (
            self.neighbourhood or
            self.suburb or
            self.district or
            self.city
        )


def normalize_venue_name(name: str) -> str:
    """
    Normalize a venue name for better geocoding results.

    - Removes common suffixes that don't help geocoding
    - Cleans up extra whitespace
    - Preserves location hints
    """
    if not name:
        return name

    # Remove common uninformative suffixes
    remove_patterns = [
        r'\s*\(.*?\)\s*$',  # Parenthetical notes at end
        r'\s*-\s*reservation\s*$',
        r'\s*-\s*booking\s*$',
        r'\s*-\s*confirmed\s*$',
        r'\s*\[.*?\]\s*$',  # Square bracket notes at end
    ]

    result = name.strip()
    for pattern in remove_patterns:
        result = re.sub(pattern, '', result, flags=re.IGNORECASE)

    # Clean up whitespace
    result = re.sub(r'\s+', ' ', result).strip()

    return result


def calculate_match_confidence(
    query: str,
    result: Dict[str, Any],
    is_biased: bool = False
) -> float:
    """
    Calculate confidence score for a geocoding match.

    Factors considered:
    - OSM importance score
    - Name similarity to query
    - Whether we used location bias
    - Place type specificity
    """
    base_confidence = 0.5

    # OSM importance (0-1, usually 0.1-0.8)
    importance = result.get("importance", 0.3)
    base_confidence += importance * 0.3

    # Name match quality
    display_name = result.get("display_name", "").lower()
    query_lower = query.lower()

    # Check if query appears in display name
    if query_lower in display_name:
        base_confidence += 0.2
    elif any(word in display_name for word in query_lower.split()):
        base_confidence += 0.1

    # Penalty for ambiguous results (very low importance)
    if importance < 0.2:
        base_confidence -= 0.1

    # Bonus for having a specific place type
    place_class = result.get("class", "")
    if place_class in ("amenity", "shop", "tourism", "leisure"):
        base_confidence += 0.1

    # Small penalty if we had to bias the search
    if is_biased:
        base_confidence -= 0.05

    # Clamp to valid range
    return max(0.1, min(1.0, base_confidence))


class GeocoderClient(BaseClient[GeocodingResult]):
    """
    Client for Nominatim geocoding API (OpenStreetMap).

    Converts text venue names to geographic coordinates and address components.
    Strictly respects Nominatim usage policy:
    - 1 request per second maximum
    - User-Agent identifying the application

    Features:
    - Geocode venue names to lat/lon coordinates
    - Extract structured address components (city, country, etc.)
    - Identify place types (restaurant, cafe, bar, etc.)
    - Location bias toward user's region (Hong Kong by default)
    - Confidence scoring for match quality

    Usage:
        client = GeocoderClient()
        result = await client.geocode("Bonfire Cafe Hong Kong")
        print(f"Location: {result.lat}, {result.lon}")
        print(f"Area: {result.area_name()}")
        print(f"Type: {result.place_type}")
    """

    BASE_URL = "https://nominatim.openstreetmap.org"
    CACHE_PREFIX = "geocoder"

    def __init__(
        self,
        cache: Optional[InMemoryCache] = None,
        viewbox: Optional[Dict[str, float]] = None,
    ):
        """
        Initialize the geocoder client.

        Args:
            cache: Optional shared cache instance
            viewbox: Optional location bias bounding box
                     Dict with keys: min_lon, min_lat, max_lon, max_lat
        """
        # STRICT 1 request per second as per Nominatim policy
        super().__init__(
            rate_limit=1.0,  # Nominatim requires max 1 req/sec
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )
        self.viewbox = viewbox or DEFAULT_VIEWBOX

    def _get_headers(self) -> Dict[str, str]:
        """Return headers with required User-Agent for Nominatim."""
        return {
            "Accept": "application/json",
            # REQUIRED by Nominatim - identifies the application
            "User-Agent": "PWG-GeoEnricher/0.1 (Personal World Graph location enrichment; https://github.com/andybrandt)",
        }

    async def geocode(
        self,
        location_text: str,
        use_bias: bool = True,
    ) -> GeocodingResult:
        """
        Geocode a location text to coordinates and address components.

        Args:
            location_text: The venue/location name to geocode
            use_bias: Whether to bias results toward default viewbox

        Returns:
            GeocodingResult with coordinates and address data
        """
        # Normalize the venue name
        query = normalize_venue_name(location_text)

        if not query:
            return GeocodingResult(
                query=location_text,
                error="Empty location text",
                confidence=0.0
            )

        # Check cache
        cache_key = f"geo:{query}:{use_bias}"
        cached = self.cache.get(self.CACHE_PREFIX, cache_key)
        if cached is not None:
            self._cache_hits += 1
            logger.debug(f"Cache hit for geocode: {query[:30]}...")
            return cached

        self._cache_misses += 1

        # Build request parameters
        params: Dict[str, Any] = {
            "q": query,
            "format": "json",
            "addressdetails": 1,  # Get structured address
            "limit": 1,  # Only need top result
            "extratags": 1,  # Get extra OSM tags
            "namedetails": 1,  # Get name variants
        }

        # Add location bias if requested
        if use_bias and self.viewbox:
            params["viewbox"] = (
                f"{self.viewbox['min_lon']},{self.viewbox['max_lat']},"
                f"{self.viewbox['max_lon']},{self.viewbox['min_lat']}"
            )
            params["bounded"] = 0  # Prefer but don't require viewbox

        try:
            response = await self._get(
                "/search",
                params=params,
                use_cache=False,  # We handle caching ourselves
                cache_key=cache_key,
            )

            if not response or len(response) == 0:
                # Try again without bias if we used it
                if use_bias:
                    logger.debug(f"No results with bias, retrying without: {query[:30]}...")
                    return await self.geocode(location_text, use_bias=False)

                result = GeocodingResult(
                    query=location_text,
                    error="No results found",
                    confidence=0.0
                )
                return result

            # Parse the top result
            top = response[0]
            result = self._parse_result(location_text, top, use_bias)

            # Cache the result
            self.cache.set(self.CACHE_PREFIX, cache_key, result)

            logger.info(
                f"Geocoded '{query[:30]}...' -> "
                f"{result.formatted_coordinates() or 'no coords'} "
                f"({result.place_type or 'unknown type'}, conf={result.confidence:.2f})"
            )

            return result

        except Exception as e:
            logger.error(f"Error geocoding '{query[:30]}...': {e}")
            return GeocodingResult(
                query=location_text,
                error=str(e),
                confidence=0.0
            )

    def _parse_result(
        self,
        query: str,
        data: Dict[str, Any],
        is_biased: bool
    ) -> GeocodingResult:
        """Parse a Nominatim result into GeocodingResult."""
        result = GeocodingResult(query=query)

        # Coordinates
        try:
            result.lat = float(data.get("lat", 0))
            result.lon = float(data.get("lon", 0))
        except (ValueError, TypeError):
            pass

        # Display name
        result.display_name = data.get("display_name")

        # OSM identifiers
        result.osm_id = data.get("osm_id")
        result.osm_type = data.get("osm_type")
        result.importance = data.get("importance")

        # Place type from OSM class/type
        osm_class = data.get("class", "")
        osm_type = data.get("type", "")

        # Determine place type
        if osm_type in PLACE_TYPE_CATEGORIES:
            result.place_type = osm_type
            result.place_category = PLACE_TYPE_CATEGORIES[osm_type]
        elif osm_class == "amenity":
            result.place_type = osm_type
            result.place_category = PLACE_TYPE_CATEGORIES.get(osm_type, "amenity")
        elif osm_class == "shop":
            result.place_type = "shop"
            result.place_category = "shopping"
        elif osm_class == "tourism":
            result.place_type = osm_type
            result.place_category = "tourism"
        elif osm_class == "leisure":
            result.place_type = osm_type
            result.place_category = "leisure"
        elif osm_class == "building":
            # Check namedetails for hints
            namedetails = data.get("namedetails", {})
            if namedetails:
                result.name = namedetails.get("name")
            result.place_type = "building"
            result.place_category = "building"

        # Address components
        address = data.get("address", {})

        # Venue/place name
        result.name = (
            data.get("namedetails", {}).get("name") or
            address.get("name") or
            address.get(osm_type) or  # e.g., address.restaurant
            address.get("amenity") or
            address.get("shop") or
            address.get("tourism")
        )

        result.house_number = address.get("house_number")
        result.street = address.get("road") or address.get("street")
        result.neighbourhood = address.get("neighbourhood") or address.get("quarter")
        result.suburb = address.get("suburb")
        result.district = address.get("district") or address.get("city_district")
        result.city = (
            address.get("city") or
            address.get("town") or
            address.get("village") or
            address.get("municipality")
        )
        result.state = address.get("state") or address.get("province")
        result.country = address.get("country")
        result.country_code = address.get("country_code", "").upper()
        result.postcode = address.get("postcode")

        # Calculate confidence
        result.confidence = calculate_match_confidence(query, data, is_biased)

        return result

    async def batch_geocode(
        self,
        locations: List[str],
        use_bias: bool = True,
    ) -> Dict[str, GeocodingResult]:
        """
        Geocode multiple locations.

        Note: Due to Nominatim rate limit (1 req/sec), this will take
        approximately len(locations) seconds.

        Args:
            locations: List of location texts to geocode
            use_bias: Whether to use location bias

        Returns:
            Dict mapping location text to GeocodingResult
        """
        results = {}

        for location in locations:
            try:
                result = await self.geocode(location, use_bias)
                results[location] = result
            except Exception as e:
                logger.warning(f"Error geocoding '{location[:30]}...': {e}")
                results[location] = GeocodingResult(
                    query=location,
                    error=str(e),
                    confidence=0.0
                )

        # Log summary
        successful = sum(1 for r in results.values() if r.has_coordinates())
        logger.info(
            f"Batch geocoded {len(locations)} locations: "
            f"{successful} successful, {len(locations) - successful} failed"
        )

        return results

    async def enrich_venue(
        self,
        preference_id: str,
        venue_name: str,
        min_confidence: float = 0.3
    ) -> EnrichmentResult:
        """
        Enrich a venue preference with geocoding data.

        Args:
            preference_id: PWG preference ID
            venue_name: The venue name to geocode
            min_confidence: Minimum confidence to accept match

        Returns:
            EnrichmentResult with location topics and entities
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=venue_name,
            source=EnrichmentSource.GEOCODER,
        )

        try:
            geo = await self.geocode(venue_name)

            if geo.error:
                result.error = geo.error
                result.confidence = 0.0
                result.match_type = MatchType.NONE
                return result

            if not geo.has_coordinates():
                result.error = "No coordinates found"
                result.confidence = 0.0
                result.match_type = MatchType.NONE
                return result

            if geo.confidence < min_confidence:
                result.error = f"Low confidence match: {geo.confidence:.2f}"
                result.confidence = geo.confidence
                result.match_type = MatchType.BEST_GUESS
                # Still return partial data

            # Set match metadata
            result.confidence = geo.confidence
            result.match_type = MatchType.FUZZY_TITLE  # Text search is fuzzy
            result.matched_title = geo.name or geo.display_name
            result.exact_match = geo.confidence >= 0.8

            # Add place type as topic
            if geo.place_type:
                result.topics.append(TopicResult(
                    name=geo.place_type.replace("_", " "),
                    normalized=geo.place_type,
                    confidence=geo.confidence,
                    source_field="osm_type"
                ))

            # Add place category as topic
            if geo.place_category and geo.place_category != geo.place_type:
                result.topics.append(TopicResult(
                    name=geo.place_category.replace("_", " "),
                    normalized=geo.place_category,
                    confidence=geo.confidence,
                    source_field="place_category"
                ))

            # Add area as topic
            if geo.area_name():
                result.topics.append(TopicResult(
                    name=geo.area_name(),
                    normalized=geo.area_name().lower().replace(" ", "_"),
                    confidence=geo.confidence * 0.9,
                    source_field="area"
                ))

            # Add city as entity
            if geo.city:
                result.entities.append(EntityResult(
                    name=geo.city,
                    entity_type="city",
                    external_id=f"geo:city:{geo.city.lower().replace(' ', '_')}"
                ))

            # Add country as entity
            if geo.country:
                result.entities.append(EntityResult(
                    name=geo.country,
                    entity_type="country",
                    external_id=geo.country_code
                ))

            # Add venue as entity if we have a name
            if geo.name:
                result.entities.append(EntityResult(
                    name=geo.name,
                    entity_type="venue",
                    external_id=f"osm:{geo.osm_type}:{geo.osm_id}" if geo.osm_id else None
                ))

            logger.info(
                f"Enriched venue '{venue_name[:30]}...': "
                f"{len(result.topics)} topics, {len(result.entities)} entities, "
                f"confidence={result.confidence:.2f}"
            )

        except Exception as e:
            logger.error(f"Error enriching venue '{venue_name}': {e}")
            result.error = str(e)

        return result

    # Required abstract method implementations
    async def search(self, query: str) -> Optional[GeocodingResult]:
        """Search for a location. Alias for geocode()."""
        return await self.geocode(query)

    async def get_details(self, item_id: str) -> Optional[GeocodingResult]:
        """
        Get details by OSM ID is not implemented.
        Use geocode() with location text instead.
        """
        logger.warning(
            "GeocoderClient.get_details() is not implemented. "
            "Use geocode() with location text instead."
        )
        return None
