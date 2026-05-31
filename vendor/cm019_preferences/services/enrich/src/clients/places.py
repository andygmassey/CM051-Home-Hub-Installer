"""Google Places API client for venue/restaurant enrichment.

Enriches venue preferences with rich metadata like cuisine types, price levels,
ratings, and business hours using the new Places API (v1).

Complements the Geocoder client:
- Geocoder: Coordinates + structured address (Nominatim/OSM)
- Places: Cuisine types, ratings, price level, hours, website (Google Places)

Google Places API (new v1):
- Text Search: https://places.googleapis.com/v1/places:searchText
- Place Details: https://places.googleapis.com/v1/places/{place_id}
- Field masks to limit billing (only request fields you need)
- API key passed as header: X-Goog-Api-Key
"""

import logging
import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

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


# Google Places type to cuisine/category mapping
# See: https://developers.google.com/maps/documentation/places/web-service/place-types
PLACE_TYPE_TO_CUISINE = {
    # Cuisine types
    "american_restaurant": "American",
    "asian_restaurant": "Asian",
    "bakery": "Bakery",
    "bar": "Bar",
    "barbecue_restaurant": "BBQ",
    "brazilian_restaurant": "Brazilian",
    "breakfast_restaurant": "Breakfast",
    "brunch_restaurant": "Brunch",
    "cafe": "Cafe",
    "chinese_restaurant": "Chinese",
    "coffee_shop": "Coffee",
    "fast_food_restaurant": "Fast Food",
    "french_restaurant": "French",
    "greek_restaurant": "Greek",
    "hamburger_restaurant": "Burgers",
    "ice_cream_shop": "Ice Cream",
    "indian_restaurant": "Indian",
    "indonesian_restaurant": "Indonesian",
    "italian_restaurant": "Italian",
    "japanese_restaurant": "Japanese",
    "korean_restaurant": "Korean",
    "lebanese_restaurant": "Lebanese",
    "mediterranean_restaurant": "Mediterranean",
    "mexican_restaurant": "Mexican",
    "middle_eastern_restaurant": "Middle Eastern",
    "pizza_restaurant": "Pizza",
    "ramen_restaurant": "Ramen",
    "restaurant": "Restaurant",
    "sandwich_shop": "Sandwiches",
    "seafood_restaurant": "Seafood",
    "spanish_restaurant": "Spanish",
    "steak_house": "Steakhouse",
    "sushi_restaurant": "Sushi",
    "thai_restaurant": "Thai",
    "turkish_restaurant": "Turkish",
    "vegan_restaurant": "Vegan",
    "vegetarian_restaurant": "Vegetarian",
    "vietnamese_restaurant": "Vietnamese",
    # Nightlife
    "night_club": "Nightclub",
    "wine_bar": "Wine Bar",
    # Other venue types
    "hotel": "Hotel",
    "spa": "Spa",
    "gym": "Gym",
    "museum": "Museum",
    "art_gallery": "Art Gallery",
    "movie_theater": "Cinema",
    "shopping_mall": "Mall",
}

# Price level descriptions
PRICE_LEVELS = {
    0: "Free",
    1: "Inexpensive",
    2: "Moderate",
    3: "Expensive",
    4: "Very Expensive",
}


@dataclass
class OpeningHours:
    """Business opening hours."""
    weekday_text: List[str] = field(default_factory=list)  # Human-readable hours
    open_now: Optional[bool] = None
    periods: List[Dict[str, Any]] = field(default_factory=list)  # Structured periods


@dataclass
class PlaceDetails:
    """Rich venue details from Google Places API."""
    place_id: str
    name: str

    # Location
    address: Optional[str] = None
    lat: Optional[float] = None
    lon: Optional[float] = None

    # Types and categories
    types: List[str] = field(default_factory=list)  # Google's place types
    primary_type: Optional[str] = None  # Main type (e.g., "japanese_restaurant")
    cuisine_types: List[str] = field(default_factory=list)  # Extracted cuisines

    # Ratings and pricing
    price_level: Optional[int] = None  # 0-4
    price_level_text: Optional[str] = None  # Human-readable (e.g., "Moderate")
    rating: Optional[float] = None  # 1.0-5.0
    user_ratings_total: Optional[int] = None

    # Business info
    opening_hours: Optional[OpeningHours] = None
    website: Optional[str] = None
    phone: Optional[str] = None
    google_maps_url: Optional[str] = None

    # Editorial content
    editorial_summary: Optional[str] = None

    # Metadata
    confidence: float = 0.0
    fetched_at: datetime = field(default_factory=datetime.utcnow)

    def has_coordinates(self) -> bool:
        """Check if valid coordinates are available."""
        return self.lat is not None and self.lon is not None

    def price_symbol(self) -> str:
        """Get price as $ symbols."""
        if self.price_level is None:
            return ""
        return "$" * (self.price_level + 1) if self.price_level > 0 else "Free"

    def formatted_rating(self) -> str:
        """Get formatted rating string."""
        if self.rating is None:
            return "No rating"
        count = f" ({self.user_ratings_total} reviews)" if self.user_ratings_total else ""
        return f"{self.rating:.1f}/5.0{count}"


@dataclass
class PlaceSearchResult:
    """Result from a place text search."""
    places: List[PlaceDetails]
    query: str
    total_results: int = 0


def extract_cuisines_from_types(types: List[str]) -> List[str]:
    """
    Extract cuisine types from Google Places types.

    Args:
        types: List of Google Places type strings

    Returns:
        List of human-readable cuisine names
    """
    cuisines = []
    for place_type in types:
        if place_type in PLACE_TYPE_TO_CUISINE:
            cuisine = PLACE_TYPE_TO_CUISINE[place_type]
            if cuisine not in cuisines:
                cuisines.append(cuisine)
    return cuisines


def normalize_venue_name(name: str) -> str:
    """
    Normalize a venue name for searching.

    - Removes common suffixes that don't help search
    - Cleans up extra whitespace
    """
    if not name:
        return name

    result = name.strip()

    # Remove common uninformative suffixes
    remove_patterns = [
        r'\s*\(.*?\)\s*$',  # Parenthetical notes at end
        r'\s*-\s*reservation\s*$',
        r'\s*-\s*booking\s*$',
        r'\s*\[.*?\]\s*$',  # Square bracket notes at end
    ]

    for pattern in remove_patterns:
        result = re.sub(pattern, '', result, flags=re.IGNORECASE)

    # Clean up whitespace
    result = re.sub(r'\s+', ' ', result).strip()

    return result


class PlacesClient(BaseClient[PlaceDetails]):
    """
    Client for Google Places API (supports both new v1 and legacy APIs).

    Features:
    - Search for places by text query with location bias
    - Get detailed venue information (cuisine, rating, price, hours)
    - Extract cuisine types from Google's place types
    - Full enrichment for venue preferences

    API v1 uses:
    - POST requests for search
    - Field masks to control billing and response size
    - API key in X-Goog-Api-Key header

    Legacy API (fallback) uses:
    - GET requests for search
    - API key as query parameter
    - Different response format

    Usage:
        client = PlacesClient()

        # Search for a place
        results = await client.search_place("Yardbird Hong Kong")

        # Get place details
        details = await client.get_place_details("ChIJN1t...")
        print(f"Cuisine: {details.cuisine_types}")
        print(f"Price: {details.price_symbol()}")
        print(f"Rating: {details.formatted_rating()}")

        # Full enrichment
        result = await client.enrich_venue("pref_123", "Yardbird Hong Kong")
    """

    BASE_URL = "https://places.googleapis.com/v1"
    LEGACY_BASE_URL = "https://maps.googleapis.com/maps/api/place"
    CACHE_PREFIX = "places"

    # Field mask for search - minimal fields to reduce cost
    SEARCH_FIELD_MASK = ",".join([
        "places.id",
        "places.displayName",
        "places.formattedAddress",
        "places.location",
        "places.types",
        "places.primaryType",
        "places.rating",
        "places.userRatingCount",
        "places.priceLevel",
    ])

    # Field mask for details - more comprehensive
    DETAILS_FIELD_MASK = ",".join([
        "id",
        "displayName",
        "formattedAddress",
        "location",
        "types",
        "primaryType",
        "rating",
        "userRatingCount",
        "priceLevel",
        "regularOpeningHours",
        "websiteUri",
        "nationalPhoneNumber",
        "googleMapsUri",
        "editorialSummary",
    ])

    def __init__(
        self,
        api_key: Optional[str] = None,
        cache: Optional[InMemoryCache] = None,
        location_bias: Optional[Tuple[float, float]] = None,
    ):
        """
        Initialize the Places client.

        Args:
            api_key: Google Places API key (or GOOGLE_PLACES_API_KEY env var)
            cache: Optional shared cache instance
            location_bias: Optional (lat, lon) to bias search results
        """
        super().__init__(
            rate_limit=settings.google_places_rate_limit,
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )
        self.api_key = api_key or settings.google_places_api_key
        # Default location bias: Hong Kong
        self.location_bias = location_bias or (22.3, 114.17)

        if not self.api_key:
            logger.warning(
                "Google Places API key not configured. "
                "Set GOOGLE_PLACES_API_KEY environment variable."
            )

    def _get_headers(self) -> Dict[str, str]:
        """Return headers with API key for Google Places API v1."""
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "PWG-Enrichment/0.1.0",
        }
        if self.api_key:
            headers["X-Goog-Api-Key"] = self.api_key
        return headers

    async def _post(
        self,
        endpoint: str,
        json_data: Dict[str, Any],
        field_mask: str,
        use_cache: bool = True,
        cache_key: Optional[str] = None,
    ) -> Optional[Dict[str, Any]]:
        """
        Make a POST request with field mask header.

        Args:
            endpoint: API endpoint
            json_data: Request body
            field_mask: Fields to return (for billing optimization)
            use_cache: Whether to check/update cache
            cache_key: Custom cache key

        Returns:
            Response JSON or None
        """
        url = f"{self.BASE_URL}{endpoint}"

        # Check cache
        if use_cache and cache_key:
            cached = self.cache.get(self.CACHE_PREFIX, cache_key)
            if cached is not None:
                self._cache_hits += 1
                logger.debug(f"Cache hit for {self.CACHE_PREFIX}:{cache_key[:50]}")
                return cached

        self._cache_misses += 1

        # Add field mask to headers
        headers = self._get_headers()
        headers["X-Goog-FieldMask"] = field_mask

        # Make request
        result = await self._make_request(
            method="POST",
            url=url,
            json_data=json_data,
        )

        # Cache successful responses
        if result is not None and use_cache and cache_key:
            self.cache.set(self.CACHE_PREFIX, cache_key, result)

        return result

    async def _make_request(
        self,
        method: str,
        url: str,
        params: Optional[Dict[str, Any]] = None,
        json_data: Optional[Dict[str, Any]] = None,
    ) -> Optional[Dict[str, Any]]:
        """Override to add field mask header for POST requests."""
        import httpx
        import asyncio

        last_error = None

        for attempt in range(self.max_retries):
            try:
                async with self.rate_limiter:
                    async with httpx.AsyncClient(timeout=self.timeout) as client:
                        self._request_count += 1

                        response = await client.request(
                            method=method,
                            url=url,
                            params=params,
                            json=json_data,
                            headers=self._get_headers(),
                        )

                        # Handle rate limiting
                        if response.status_code == 429:
                            retry_after = int(response.headers.get("Retry-After", 5))
                            logger.warning(
                                f"Rate limited, waiting {retry_after}s "
                                f"(attempt {attempt + 1}/{self.max_retries})"
                            )
                            await asyncio.sleep(retry_after)
                            continue

                        # Handle server errors with retry
                        if response.status_code >= 500:
                            delay = min(
                                settings.retry_base_delay * (2 ** attempt),
                                settings.retry_max_delay
                            )
                            logger.warning(
                                f"Server error {response.status_code}, "
                                f"retrying in {delay}s"
                            )
                            await asyncio.sleep(delay)
                            continue

                        # Handle not found
                        if response.status_code == 404:
                            logger.debug(f"Not found: {url}")
                            return None

                        # Handle client errors
                        if response.status_code >= 400:
                            logger.error(
                                f"Client error {response.status_code}: {response.text}"
                            )
                            self._errors += 1
                            return None

                        return response.json()

            except httpx.TimeoutException:
                delay = min(
                    settings.retry_base_delay * (2 ** attempt),
                    settings.retry_max_delay
                )
                logger.warning(f"Request timeout, retrying in {delay}s")
                last_error = "timeout"
                await asyncio.sleep(delay)

            except httpx.RequestError as e:
                delay = min(
                    settings.retry_base_delay * (2 ** attempt),
                    settings.retry_max_delay
                )
                logger.warning(f"Request error: {e}, retrying in {delay}s")
                last_error = str(e)
                await asyncio.sleep(delay)

        logger.error(f"All {self.max_retries} retries exhausted. Last error: {last_error}")
        self._errors += 1
        return None

    async def search_place(
        self,
        query: str,
        location_bias: Optional[Tuple[float, float]] = None,
        radius_meters: int = 50000,
        max_results: int = 5,
    ) -> PlaceSearchResult:
        """
        Search for a place by text query.

        Uses the Text Search (New) API endpoint.

        Args:
            query: Search text (e.g., "Yardbird Hong Kong")
            location_bias: Optional (lat, lon) to bias results
            radius_meters: Radius for location bias (default 50km)
            max_results: Maximum results to return (default 5)

        Returns:
            PlaceSearchResult with list of matching places
        """
        result = PlaceSearchResult(places=[], query=query)

        if not self.api_key:
            logger.error("Cannot search: Google Places API key not configured")
            return result

        # Normalize query
        normalized_query = normalize_venue_name(query)
        if not normalized_query:
            logger.warning("Empty query after normalization")
            return result

        # Use provided location bias or default
        bias = location_bias or self.location_bias

        # Build request body
        request_body = {
            "textQuery": normalized_query,
            "maxResultCount": max_results,
        }

        if bias:
            request_body["locationBias"] = {
                "circle": {
                    "center": {
                        "latitude": bias[0],
                        "longitude": bias[1],
                    },
                    "radius": float(radius_meters),
                }
            }

        cache_key = f"search:{normalized_query}:{bias[0] if bias else 'none'}:{bias[1] if bias else 'none'}"

        try:
            # Make the search request with new API
            response = await self._post(
                "/places:searchText",
                json_data=request_body,
                field_mask=self.SEARCH_FIELD_MASK,
                cache_key=cache_key,
            )

            if not response:
                # New API failed, try legacy API
                logger.info(f"New API failed for '{query[:30]}...', trying legacy API")
                return await self._search_legacy(
                    normalized_query, bias, radius_meters, max_results
                )

            places_data = response.get("places", [])
            result.total_results = len(places_data)

            for place_data in places_data:
                place = self._parse_place(place_data)
                if place:
                    result.places.append(place)

            logger.info(
                f"Search '{query[:30]}...' found {len(result.places)} places"
            )

        except Exception as e:
            logger.error(f"Error searching '{query}': {e}")
            # Try legacy API as fallback
            logger.info(f"New API exception, trying legacy API for '{query[:30]}...'")
            return await self._search_legacy(
                normalized_query, bias, radius_meters, max_results
            )

        return result

    async def _search_legacy(
        self,
        query: str,
        location_bias: Optional[Tuple[float, float]] = None,
        radius_meters: int = 50000,
        max_results: int = 5,
    ) -> PlaceSearchResult:
        """
        Search using the legacy Places API (Text Search).

        Uses the older API at maps.googleapis.com which may have
        different permissions than the new places.googleapis.com API.
        """
        import httpx

        result = PlaceSearchResult(places=[], query=query)

        # Build legacy API URL
        url = f"{self.LEGACY_BASE_URL}/textsearch/json"

        params = {
            "query": query,
            "key": self.api_key,
        }

        if location_bias:
            params["location"] = f"{location_bias[0]},{location_bias[1]}"
            params["radius"] = str(radius_meters)

        cache_key = f"search_legacy:{query}:{location_bias[0] if location_bias else 'none'}:{location_bias[1] if location_bias else 'none'}"

        # Check cache
        cached = self.cache.get(self.CACHE_PREFIX, cache_key)
        if cached is not None:
            self._cache_hits += 1
            return cached

        self._cache_misses += 1

        try:
            async with self.rate_limiter:
                async with httpx.AsyncClient(timeout=self.timeout) as client:
                    self._request_count += 1
                    response = await client.get(url, params=params)

                    if response.status_code >= 400:
                        logger.error(
                            f"Legacy API error {response.status_code}: {response.text}"
                        )
                        return result

                    data = response.json()

            if data.get("status") not in ["OK", "ZERO_RESULTS"]:
                error_msg = data.get("error_message", data.get("status", "Unknown"))
                logger.error(f"Legacy API error: {error_msg}")
                return result

            places_data = data.get("results", [])[:max_results]
            result.total_results = len(places_data)

            for place_data in places_data:
                place = self._parse_legacy_place(place_data)
                if place:
                    result.places.append(place)

            if result.places:
                self.cache.set(self.CACHE_PREFIX, cache_key, result)

            logger.info(
                f"Legacy search '{query[:30]}...' found {len(result.places)} places"
            )

        except Exception as e:
            logger.error(f"Legacy API error searching '{query}': {e}")

        return result

    def _parse_legacy_place(self, data: Dict[str, Any]) -> Optional[PlaceDetails]:
        """Parse a place from legacy API response."""
        place_id = data.get("place_id", "")
        name = data.get("name", "")

        if not place_id or not name:
            return None

        place = PlaceDetails(
            place_id=place_id,
            name=name,
        )

        # Location
        geometry = data.get("geometry", {})
        location = geometry.get("location", {})
        if location:
            place.lat = location.get("lat")
            place.lon = location.get("lng")

        place.address = data.get("formatted_address")

        # Types
        place.types = data.get("types", [])
        if place.types:
            place.primary_type = place.types[0]
        place.cuisine_types = extract_cuisines_from_types(place.types)

        # Rating and price (legacy uses integer price_level directly)
        place.rating = data.get("rating")
        place.user_ratings_total = data.get("user_ratings_total")

        price_level = data.get("price_level")
        if price_level is not None:
            place.price_level = price_level
            place.price_level_text = PRICE_LEVELS.get(price_level)

        # Calculate confidence
        confidence = 0.7
        if place.rating is not None:
            confidence += 0.1
        if place.cuisine_types:
            confidence += 0.1
        if place.address:
            confidence += 0.05
        place.confidence = min(confidence, 1.0)

        return place

    async def get_place_details(
        self,
        place_id: str,
    ) -> Optional[PlaceDetails]:
        """
        Get detailed information for a place by its ID.

        Args:
            place_id: Google Places place ID

        Returns:
            PlaceDetails or None if not found
        """
        if not self.api_key:
            logger.error("Cannot get details: Google Places API key not configured")
            return None

        # Clean the place ID (might have "places/" prefix from API)
        if place_id.startswith("places/"):
            place_id = place_id[7:]

        cache_key = f"details:{place_id}"

        # Check cache
        cached = self.cache.get(self.CACHE_PREFIX, cache_key)
        if cached is not None:
            self._cache_hits += 1
            return cached

        self._cache_misses += 1

        try:
            # Build headers with field mask
            import httpx

            url = f"{self.BASE_URL}/places/{place_id}"
            headers = self._get_headers()
            headers["X-Goog-FieldMask"] = self.DETAILS_FIELD_MASK

            async with self.rate_limiter:
                async with httpx.AsyncClient(timeout=self.timeout) as client:
                    self._request_count += 1
                    response = await client.get(url, headers=headers)

                    if response.status_code == 404:
                        logger.debug(f"Place not found: {place_id}")
                        return None

                    if response.status_code >= 400:
                        # New API blocked, try legacy
                        logger.info(
                            f"New API blocked for details, trying legacy: {response.status_code}"
                        )
                        return await self._get_details_legacy(place_id)

                    data = response.json()

            place = self._parse_place(data, detailed=True)

            if place:
                # Cache the result
                self.cache.set(self.CACHE_PREFIX, cache_key, place)
                logger.info(
                    f"Got details for '{place.name}': "
                    f"rating={place.rating}, price={place.price_symbol()}"
                )

            return place

        except Exception as e:
            logger.error(f"Error getting details for '{place_id}': {e}")
            # Try legacy API as fallback
            return await self._get_details_legacy(place_id)

    async def _get_details_legacy(
        self,
        place_id: str,
    ) -> Optional[PlaceDetails]:
        """
        Get place details using the legacy Places API.
        """
        import httpx

        cache_key = f"details_legacy:{place_id}"

        # Check cache
        cached = self.cache.get(self.CACHE_PREFIX, cache_key)
        if cached is not None:
            self._cache_hits += 1
            return cached

        url = f"{self.LEGACY_BASE_URL}/details/json"
        params = {
            "place_id": place_id,
            "key": self.api_key,
            "fields": "name,formatted_address,geometry,types,price_level,rating,user_ratings_total,opening_hours,website,formatted_phone_number,url",
        }

        try:
            async with self.rate_limiter:
                async with httpx.AsyncClient(timeout=self.timeout) as client:
                    self._request_count += 1
                    response = await client.get(url, params=params)

                    if response.status_code >= 400:
                        logger.error(
                            f"Legacy details error {response.status_code}: {response.text}"
                        )
                        return None

                    data = response.json()

            if data.get("status") != "OK":
                error_msg = data.get("error_message", data.get("status", "Unknown"))
                logger.error(f"Legacy details error: {error_msg}")
                return None

            result_data = data.get("result", {})
            place = self._parse_legacy_place(result_data)

            if place:
                # Add extra details from legacy API
                place.website = result_data.get("website")
                place.phone = result_data.get("formatted_phone_number")
                place.google_maps_url = result_data.get("url")

                # Opening hours
                opening_hours_data = result_data.get("opening_hours", {})
                if opening_hours_data:
                    place.opening_hours = OpeningHours(
                        weekday_text=opening_hours_data.get("weekday_text", []),
                        open_now=opening_hours_data.get("open_now"),
                        periods=opening_hours_data.get("periods", []),
                    )

                self.cache.set(self.CACHE_PREFIX, cache_key, place)
                logger.info(
                    f"Got legacy details for '{place.name}': "
                    f"rating={place.rating}, price={place.price_symbol()}"
                )

            return place

        except Exception as e:
            logger.error(f"Legacy details error for '{place_id}': {e}")
            return None

    def _parse_place(
        self,
        data: Dict[str, Any],
        detailed: bool = False,
    ) -> Optional[PlaceDetails]:
        """Parse a place from API response."""
        place_id = data.get("id", "")
        if not place_id:
            return None

        # Remove "places/" prefix if present
        if place_id.startswith("places/"):
            place_id = place_id[7:]

        # Get name
        display_name = data.get("displayName", {})
        name = display_name.get("text", "") if isinstance(display_name, dict) else str(display_name)

        if not name:
            return None

        place = PlaceDetails(
            place_id=place_id,
            name=name,
        )

        # Location
        location = data.get("location", {})
        if location:
            place.lat = location.get("latitude")
            place.lon = location.get("longitude")

        place.address = data.get("formattedAddress")

        # Types
        place.types = data.get("types", [])
        place.primary_type = data.get("primaryType")
        place.cuisine_types = extract_cuisines_from_types(place.types)

        # Rating and price
        place.rating = data.get("rating")
        place.user_ratings_total = data.get("userRatingCount")

        price_level = data.get("priceLevel")
        if price_level:
            # API returns strings like "PRICE_LEVEL_MODERATE"
            price_map = {
                "PRICE_LEVEL_FREE": 0,
                "PRICE_LEVEL_INEXPENSIVE": 1,
                "PRICE_LEVEL_MODERATE": 2,
                "PRICE_LEVEL_EXPENSIVE": 3,
                "PRICE_LEVEL_VERY_EXPENSIVE": 4,
            }
            place.price_level = price_map.get(price_level)
            if place.price_level is not None:
                place.price_level_text = PRICE_LEVELS.get(place.price_level)

        # Detailed fields
        if detailed:
            # Opening hours
            opening_hours_data = data.get("regularOpeningHours", {})
            if opening_hours_data:
                place.opening_hours = OpeningHours(
                    weekday_text=opening_hours_data.get("weekdayDescriptions", []),
                    open_now=opening_hours_data.get("openNow"),
                    periods=opening_hours_data.get("periods", []),
                )

            # Contact info
            place.website = data.get("websiteUri")
            place.phone = data.get("nationalPhoneNumber")
            place.google_maps_url = data.get("googleMapsUri")

            # Editorial summary
            editorial = data.get("editorialSummary", {})
            if isinstance(editorial, dict):
                place.editorial_summary = editorial.get("text")

        # Calculate confidence based on available data
        confidence = 0.7  # Base confidence for Google match
        if place.rating is not None:
            confidence += 0.1
        if place.cuisine_types:
            confidence += 0.1
        if place.address:
            confidence += 0.05
        place.confidence = min(confidence, 1.0)

        return place

    async def enrich_venue(
        self,
        preference_id: str,
        venue_name: str,
        location_bias: Optional[Tuple[float, float]] = None,
        min_confidence: float = 0.5,
    ) -> EnrichmentResult:
        """
        Enrich a venue preference with Places API data.

        Searches for the venue, then fetches detailed information
        about the top match.

        Args:
            preference_id: PWG preference ID
            venue_name: The venue name to search for
            location_bias: Optional (lat, lon) to bias search
            min_confidence: Minimum confidence to accept match

        Returns:
            EnrichmentResult with cuisine topics, rating entities, etc.
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=venue_name,
            source=EnrichmentSource.PLACES,
        )

        if not self.api_key:
            result.error = "Google Places API key not configured"
            return result

        try:
            # Search for the venue
            search_result = await self.search_place(
                venue_name,
                location_bias=location_bias,
                max_results=3,
            )

            if not search_result.places:
                result.error = "No places found"
                result.confidence = 0.0
                result.match_type = MatchType.NONE
                return result

            # Get the top result
            top_place = search_result.places[0]

            # Fetch full details
            details = await self.get_place_details(top_place.place_id)
            if not details:
                details = top_place

            # Populate enrichment result
            result.confidence = details.confidence
            result.match_type = MatchType.FUZZY_TITLE
            result.matched_title = details.name
            result.exact_match = details.confidence >= 0.9

            if details.confidence < min_confidence:
                result.error = f"Low confidence match: {details.confidence:.2f}"

            # Add cuisine types as topics
            for cuisine in details.cuisine_types:
                result.topics.append(TopicResult(
                    name=cuisine,
                    normalized=cuisine.lower().replace(" ", "_"),
                    confidence=details.confidence,
                    source_field="cuisine_type"
                ))

            # Add primary type as topic if not already covered
            if details.primary_type:
                type_name = details.primary_type.replace("_", " ").title()
                if type_name not in [t.name for t in result.topics]:
                    result.topics.append(TopicResult(
                        name=type_name,
                        normalized=details.primary_type,
                        confidence=details.confidence * 0.9,
                        source_field="primary_type"
                    ))

            # Add price level as topic
            if details.price_level_text:
                result.topics.append(TopicResult(
                    name=f"Price: {details.price_symbol()}",
                    normalized=f"price_{details.price_level}",
                    confidence=details.confidence,
                    source_field="price_level"
                ))

            # Add rating as entity
            if details.rating is not None:
                rating_tier = (
                    "highly_rated" if details.rating >= 4.5 else
                    "well_rated" if details.rating >= 4.0 else
                    "average_rated" if details.rating >= 3.0 else
                    "low_rated"
                )
                result.entities.append(EntityResult(
                    name=details.formatted_rating(),
                    entity_type="rating",
                    external_id=rating_tier
                ))

            # Add venue as entity
            result.entities.append(EntityResult(
                name=details.name,
                entity_type="venue",
                external_id=f"google_places:{details.place_id}"
            ))

            # Add website if available
            if details.website:
                result.entities.append(EntityResult(
                    name=details.website,
                    entity_type="website",
                    external_id=details.website
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
    async def search(self, query: str) -> Optional[PlaceDetails]:
        """Search for a place and return the top result."""
        result = await self.search_place(query, max_results=1)
        if result.places:
            # Fetch full details for the top result
            return await self.get_place_details(result.places[0].place_id)
        return None

    async def get_details(self, item_id: str) -> Optional[PlaceDetails]:
        """Get place details by Google Places ID."""
        return await self.get_place_details(item_id)
