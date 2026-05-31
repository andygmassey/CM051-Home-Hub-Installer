"""Address geocoding using Nominatim (OpenStreetMap)."""

import asyncio
import logging
import re
from dataclasses import dataclass
from typing import Optional, Dict, List, Tuple
import aiohttp
from urllib.parse import quote

logger = logging.getLogger(__name__)


@dataclass
class GeocodingResult:
    """Result from geocoding an address."""
    address: str
    lat: float
    lng: float
    display_name: str
    place_type: str
    confidence: float  # 0-1 based on match quality
    raw_response: Dict = None


class Geocoder:
    """
    Geocoder using Nominatim (OpenStreetMap).

    Free, no API key required, but has rate limits (1 req/sec).
    """

    NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
    USER_AGENT = "PWG-PersonalWorldGraph/1.0 (preference-analysis)"

    # Rate limiting
    MIN_REQUEST_INTERVAL = 1.1  # seconds between requests

    def __init__(self):
        self._last_request_time = 0
        self._cache: Dict[str, GeocodingResult] = {}
        self._session: Optional[aiohttp.ClientSession] = None

    async def _get_session(self) -> aiohttp.ClientSession:
        """Get or create aiohttp session."""
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(
                headers={"User-Agent": self.USER_AGENT}
            )
        return self._session

    async def close(self):
        """Close the aiohttp session."""
        if self._session and not self._session.closed:
            await self._session.close()

    def _clean_address(self, address: str) -> str:
        """Clean and normalize address for geocoding."""
        if not address:
            return ""

        # Remove common prefixes
        address = re.sub(r'^(Visited:|Favorite:|To:|From:)\s*', '', address, flags=re.IGNORECASE)

        # Remove floor/unit numbers that confuse geocoding
        address = re.sub(r'\d+/F\s*,?\s*', '', address)
        address = re.sub(r'Suite\s+\d+\s*,?\s*', '', address, flags=re.IGNORECASE)
        address = re.sub(r'Unit\s+\d+\s*,?\s*', '', address, flags=re.IGNORECASE)
        address = re.sub(r'Room\s+\d+\s*,?\s*', '', address, flags=re.IGNORECASE)

        # Remove parenthetical Chinese names (keep English for geocoding)
        address = re.sub(r'\([^)]*[\u4e00-\u9fff][^)]*\)', '', address)

        # Remove extra whitespace
        address = ' '.join(address.split())

        return address.strip()

    def _extract_city_hint(self, address: str) -> Optional[str]:
        """Extract city name from address for better geocoding."""
        address_lower = address.lower()

        city_patterns = [
            (r'hong\s*kong', 'Hong Kong'),
            (r'shanghai', 'Shanghai'),
            (r'beijing', 'Beijing'),
            (r'london', 'London'),
            (r'paris', 'Paris'),
            (r'new\s*york', 'New York'),
            (r'singapore', 'Singapore'),
            (r'tokyo', 'Tokyo'),
            (r'sydney', 'Sydney'),
            (r'melbourne', 'Melbourne'),
        ]

        for pattern, city in city_patterns:
            if re.search(pattern, address_lower):
                return city

        return None

    async def geocode(self, address: str, city_hint: str = None) -> Optional[GeocodingResult]:
        """
        Geocode an address to coordinates.

        Args:
            address: The address to geocode
            city_hint: Optional city name to improve accuracy

        Returns:
            GeocodingResult or None if not found
        """
        # Check cache
        cache_key = f"{address}|{city_hint}"
        if cache_key in self._cache:
            return self._cache[cache_key]

        # Clean address
        clean_addr = self._clean_address(address)
        if not clean_addr or len(clean_addr) < 5:
            return None

        # Extract city hint if not provided
        if not city_hint:
            city_hint = self._extract_city_hint(address)

        # Build query
        query = clean_addr
        if city_hint:
            query = f"{clean_addr}, {city_hint}"

        # Rate limiting
        now = asyncio.get_event_loop().time()
        wait_time = self.MIN_REQUEST_INTERVAL - (now - self._last_request_time)
        if wait_time > 0:
            await asyncio.sleep(wait_time)

        try:
            session = await self._get_session()

            params = {
                "q": query,
                "format": "json",
                "limit": 1,
                "addressdetails": 1
            }

            async with session.get(self.NOMINATIM_URL, params=params) as response:
                self._last_request_time = asyncio.get_event_loop().time()

                if response.status != 200:
                    logger.warning(f"Geocoding failed for '{address}': HTTP {response.status}")
                    return None

                data = await response.json()

                if not data:
                    logger.debug(f"No results for '{address}'")
                    self._cache[cache_key] = None
                    return None

                result = data[0]

                # Calculate confidence based on importance and type
                importance = float(result.get('importance', 0.5))
                place_type = result.get('type', 'unknown')

                # Higher confidence for specific place types
                type_bonus = {
                    'restaurant': 0.2,
                    'cafe': 0.2,
                    'bar': 0.2,
                    'hotel': 0.2,
                    'shop': 0.15,
                    'building': 0.1,
                    'house': 0.1,
                    'road': 0.05,
                    'suburb': 0.05,
                }.get(place_type, 0)

                confidence = min(1.0, importance + type_bonus)

                geocode_result = GeocodingResult(
                    address=address,
                    lat=float(result['lat']),
                    lng=float(result['lon']),
                    display_name=result.get('display_name', ''),
                    place_type=place_type,
                    confidence=confidence,
                    raw_response=result
                )

                self._cache[cache_key] = geocode_result
                return geocode_result

        except Exception as e:
            logger.error(f"Geocoding error for '{address}': {e}")
            return None

    async def geocode_batch(
        self,
        addresses: List[str],
        city_hints: Dict[str, str] = None,
        progress_callback=None
    ) -> Dict[str, Optional[GeocodingResult]]:
        """
        Geocode multiple addresses.

        Args:
            addresses: List of addresses to geocode
            city_hints: Optional dict mapping address to city hint
            progress_callback: Optional callback(current, total) for progress

        Returns:
            Dict mapping address to GeocodingResult (or None)
        """
        results = {}
        city_hints = city_hints or {}

        for i, address in enumerate(addresses):
            hint = city_hints.get(address)
            results[address] = await self.geocode(address, hint)

            if progress_callback:
                progress_callback(i + 1, len(addresses))

        return results

    def get_cache_stats(self) -> Dict:
        """Get cache statistics."""
        total = len(self._cache)
        hits = sum(1 for v in self._cache.values() if v is not None)
        return {
            "total_cached": total,
            "successful": hits,
            "failed": total - hits,
            "hit_rate": hits / total if total > 0 else 0
        }
