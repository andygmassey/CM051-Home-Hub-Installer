"""Geographic analyzer - main orchestrator for location analysis."""

import asyncio
import logging
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple
from collections import defaultdict
from datetime import datetime
import json

from .clustering import GeoClustering, Location, Cluster
from .geocoder import Geocoder, GeocodingResult

logger = logging.getLogger(__name__)


@dataclass
class TravelPattern:
    """Analysis of travel patterns."""
    home_base: str
    home_venue_count: int
    home_percentage: float
    travel_destinations: List[Dict]  # [{city, venue_count, percentage}, ...]
    total_cities: int
    total_venues: int


@dataclass
class AreaPreference:
    """Preference pattern for a geographic area."""
    area_name: str
    area_level: str  # city, district, neighborhood
    center_lat: float
    center_lng: float
    venue_count: int
    total_visits: int
    top_venues: List[str]
    venue_types: Dict[str, int]  # category -> count
    sources: Dict[str, int]  # source -> count
    strength: float  # 0-1 based on visit frequency


@dataclass
class GeoInsights:
    """Complete geographic insights."""
    summary: str
    travel_pattern: TravelPattern
    city_clusters: List[Cluster]
    area_preferences: List[AreaPreference]
    geocoding_stats: Dict
    total_locations: int
    locations_with_coords: int
    locations_geocoded: int


class GeoAnalyzer:
    """
    Main geographic analyzer for PWG.

    Orchestrates:
    1. Data extraction from Qdrant
    2. Geocoding of addresses
    3. Hierarchical clustering
    4. Travel pattern analysis
    5. Area preference generation
    """

    def __init__(self, qdrant_host: str = "localhost", qdrant_port: int = 6333):
        self.qdrant_url = f"http://{qdrant_host}:{qdrant_port}"
        self.clustering = GeoClustering()
        self.geocoder = Geocoder()

    async def _fetch_from_qdrant(self, filter_dict: Dict, limit: int = 500) -> List[Dict]:
        """Fetch preferences from Qdrant."""
        import aiohttp

        url = f"{self.qdrant_url}/collections/pwg_preferences/points/scroll"
        payload = {
            "filter": filter_dict,
            "limit": limit,
            "with_payload": True
        }

        async with aiohttp.ClientSession() as session:
            async with session.post(url, json=payload) as response:
                if response.status != 200:
                    logger.error(f"Qdrant query failed: {response.status}")
                    return []
                data = await response.json()
                return data.get("result", {}).get("points", [])

    async def extract_locations(self) -> Tuple[List[Location], List[Dict]]:
        """
        Extract all location data from Qdrant.

        Returns:
            Tuple of (locations_with_coords, items_needing_geocoding)
        """
        locations = []
        needs_geocoding = []

        # FourSquare - has coordinates
        foursquare_points = await self._fetch_from_qdrant({
            "must": [{"key": "source", "match": {"value": "foursquare"}}]
        })

        for p in foursquare_points:
            extra = p["payload"].get("extra", {})
            if extra.get("lat") and extra.get("lng"):
                locations.append(Location(
                    id=p["id"],
                    subject=p["payload"]["subject"],
                    lat=float(extra["lat"]),
                    lng=float(extra["lng"]),
                    source="foursquare",
                    category=p["payload"].get("category", "place"),
                    visit_count=extra.get("visit_count", 1),
                    extra=extra
                ))

        # Google Takeout places
        google_points = await self._fetch_from_qdrant({
            "must": [
                {"key": "source", "match": {"value": "google_takeout"}},
                {"key": "category", "match": {"value": "place"}}
            ]
        })

        for p in google_points:
            extra = p["payload"].get("extra", {})
            coords = extra.get("coordinates")

            if isinstance(coords, dict) and coords.get("lat") and coords.get("lng"):
                locations.append(Location(
                    id=p["id"],
                    subject=p["payload"]["subject"],
                    lat=float(coords["lat"]),
                    lng=float(coords["lng"]),
                    source="google_takeout",
                    category=p["payload"].get("category", "place"),
                    visit_count=extra.get("visit_count", 1),
                    extra=extra
                ))
            elif extra.get("sample_location"):
                needs_geocoding.append({
                    "id": p["id"],
                    "subject": p["payload"]["subject"],
                    "address": extra["sample_location"],
                    "source": "google_takeout",
                    "category": p["payload"].get("category", "place"),
                    "extra": extra
                })

        # Uber - addresses only
        uber_points = await self._fetch_from_qdrant({
            "must": [{"key": "source", "match": {"value": "uber"}}]
        })

        for p in uber_points:
            extra = p["payload"].get("extra", {})
            address = extra.get("dropoff_address") or extra.get("pickup_address")

            if address and len(address) > 10:
                needs_geocoding.append({
                    "id": p["id"],
                    "subject": p["payload"]["subject"],
                    "address": address,
                    "source": "uber",
                    "category": p["payload"].get("category", "transportation"),
                    "extra": extra
                })

        logger.info(f"Extracted {len(locations)} locations with coords, {len(needs_geocoding)} need geocoding")
        return locations, needs_geocoding

    async def geocode_addresses(
        self,
        items: List[Dict],
        max_items: int = 100,
        progress_callback=None
    ) -> List[Location]:
        """
        Geocode addresses and convert to Location objects.

        Args:
            items: List of dicts with 'address', 'id', 'subject', etc.
            max_items: Maximum items to geocode (rate limiting)
            progress_callback: Optional callback(current, total, address)

        Returns:
            List of successfully geocoded Location objects
        """
        locations = []
        items_to_process = items[:max_items]

        for i, item in enumerate(items_to_process):
            if progress_callback:
                progress_callback(i + 1, len(items_to_process), item["address"][:50])

            result = await self.geocoder.geocode(
                item["address"],
                city_hint=item["extra"].get("city")
            )

            if result and result.confidence > 0.3:
                locations.append(Location(
                    id=item["id"],
                    subject=item["subject"],
                    lat=result.lat,
                    lng=result.lng,
                    source=item["source"],
                    category=item["category"],
                    visit_count=item["extra"].get("visit_count", 1),
                    extra={**item["extra"], "geocoded": True, "geocode_confidence": result.confidence}
                ))

        await self.geocoder.close()
        return locations

    def analyze_travel_patterns(self, clusters: List[Cluster]) -> TravelPattern:
        """Analyze travel patterns from city clusters."""
        if not clusters:
            return TravelPattern(
                home_base="Unknown",
                home_venue_count=0,
                home_percentage=0,
                travel_destinations=[],
                total_cities=0,
                total_venues=0
            )

        total_venues = sum(c.venue_count for c in clusters)

        # Home base is the city with most venues
        home = clusters[0]
        home_pct = (home.venue_count / total_venues * 100) if total_venues > 0 else 0

        # Travel destinations (excluding home)
        destinations = []
        for cluster in clusters[1:]:
            if cluster.venue_count >= 1:
                destinations.append({
                    "city": cluster.name,
                    "venue_count": cluster.venue_count,
                    "percentage": round(cluster.venue_count / total_venues * 100, 1)
                })

        return TravelPattern(
            home_base=home.name,
            home_venue_count=home.venue_count,
            home_percentage=round(home_pct, 1),
            travel_destinations=destinations,
            total_cities=len(clusters),
            total_venues=total_venues
        )

    def generate_area_preferences(
        self,
        hierarchy: Dict,
        min_venues: int = 2
    ) -> List[AreaPreference]:
        """Generate area preferences from clustering hierarchy."""
        preferences = []

        for city_data in hierarchy.get("cities", []):
            city = city_data["cluster"]

            # City-level preference
            if city.venue_count >= min_venues:
                sources = city.sources_breakdown()
                top_venues = [loc.subject for loc in city.locations[:5]]

                # Calculate strength based on venue count and visits
                strength = min(1.0, 0.3 + (city.venue_count / 50) * 0.4 + (city.total_visits / 100) * 0.3)

                preferences.append(AreaPreference(
                    area_name=city.name,
                    area_level="city",
                    center_lat=city.center_lat,
                    center_lng=city.center_lng,
                    venue_count=city.venue_count,
                    total_visits=city.total_visits,
                    top_venues=top_venues,
                    venue_types={},  # Could categorize venues
                    sources=sources,
                    strength=round(strength, 2)
                ))

            # District-level preferences
            for district_data in city_data.get("districts", []):
                district = district_data["cluster"]

                if district.venue_count >= min_venues:
                    sources = district.sources_breakdown()
                    top_venues = [loc.subject for loc in district.locations[:3]]

                    strength = min(1.0, 0.2 + (district.venue_count / 20) * 0.5 + (district.total_visits / 50) * 0.3)

                    preferences.append(AreaPreference(
                        area_name=f"{district.name}, {city.name}",
                        area_level="district",
                        center_lat=district.center_lat,
                        center_lng=district.center_lng,
                        venue_count=district.venue_count,
                        total_visits=district.total_visits,
                        top_venues=top_venues,
                        venue_types={},
                        sources=sources,
                        strength=round(strength, 2)
                    ))

        return sorted(preferences, key=lambda p: -p.strength)

    def generate_summary(self, travel: TravelPattern, preferences: List[AreaPreference]) -> str:
        """Generate human-readable summary of geographic insights."""
        lines = []

        # Home base
        lines.append(f"Your home base is **{travel.home_base}** with {travel.home_venue_count} venues ({travel.home_percentage}% of all locations).")

        # Travel
        if travel.travel_destinations:
            top_travel = travel.travel_destinations[:5]
            dest_str = ", ".join(f"{d['city']} ({d['venue_count']})" for d in top_travel)
            lines.append(f"\nYou've visited **{travel.total_cities} cities**. Top travel destinations: {dest_str}.")

        # Favorite areas
        if preferences:
            district_prefs = [p for p in preferences if p.area_level == "district"][:3]
            if district_prefs:
                areas = ", ".join(p.area_name for p in district_prefs)
                lines.append(f"\nYour favorite areas: {areas}.")

        return "\n".join(lines)

    async def analyze(
        self,
        geocode_addresses: bool = True,
        max_geocode: int = 100,
        progress_callback=None
    ) -> GeoInsights:
        """
        Run full geographic analysis.

        Args:
            geocode_addresses: Whether to geocode addresses without coords
            max_geocode: Maximum addresses to geocode
            progress_callback: Optional progress callback

        Returns:
            GeoInsights with complete analysis
        """
        # Extract locations
        locations_with_coords, needs_geocoding = await self.extract_locations()

        # Optionally geocode addresses
        geocoded_locations = []
        if geocode_addresses and needs_geocoding:
            logger.info(f"Geocoding up to {max_geocode} addresses...")
            geocoded_locations = await self.geocode_addresses(
                needs_geocoding,
                max_items=max_geocode,
                progress_callback=progress_callback
            )

        # Combine all locations
        all_locations = locations_with_coords + geocoded_locations

        # Cluster
        logger.info(f"Clustering {len(all_locations)} locations...")
        hierarchy = self.clustering.full_hierarchy(all_locations)
        city_clusters = self.clustering.city_clusters

        # Analyze
        travel_pattern = self.analyze_travel_patterns(city_clusters)
        area_preferences = self.generate_area_preferences(hierarchy)
        summary = self.generate_summary(travel_pattern, area_preferences)

        return GeoInsights(
            summary=summary,
            travel_pattern=travel_pattern,
            city_clusters=city_clusters,
            area_preferences=area_preferences,
            geocoding_stats=self.geocoder.get_cache_stats(),
            total_locations=len(locations_with_coords) + len(needs_geocoding),
            locations_with_coords=len(locations_with_coords),
            locations_geocoded=len(geocoded_locations)
        )

    def insights_to_dict(self, insights: GeoInsights) -> Dict:
        """Convert GeoInsights to JSON-serializable dict."""
        return {
            "summary": insights.summary,
            "travel_pattern": {
                "home_base": insights.travel_pattern.home_base,
                "home_venue_count": insights.travel_pattern.home_venue_count,
                "home_percentage": insights.travel_pattern.home_percentage,
                "travel_destinations": insights.travel_pattern.travel_destinations,
                "total_cities": insights.travel_pattern.total_cities,
                "total_venues": insights.travel_pattern.total_venues
            },
            "city_clusters": [
                {
                    "name": c.name,
                    "venue_count": c.venue_count,
                    "total_visits": c.total_visits,
                    "center": {"lat": c.center_lat, "lng": c.center_lng},
                    "sources": c.sources_breakdown()
                }
                for c in insights.city_clusters
            ],
            "area_preferences": [
                {
                    "area_name": p.area_name,
                    "area_level": p.area_level,
                    "venue_count": p.venue_count,
                    "strength": p.strength,
                    "top_venues": p.top_venues
                }
                for p in insights.area_preferences
            ],
            "stats": {
                "total_locations": insights.total_locations,
                "with_coordinates": insights.locations_with_coords,
                "geocoded": insights.locations_geocoded,
                "geocoding": insights.geocoding_stats
            }
        }
