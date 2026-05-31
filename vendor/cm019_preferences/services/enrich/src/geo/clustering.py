"""Geographic clustering for location preferences."""

import math
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple
from collections import defaultdict


@dataclass
class Location:
    """A single location with coordinates."""
    id: str
    subject: str
    lat: float
    lng: float
    source: str
    category: str = "place"
    visit_count: int = 1
    extra: Dict = field(default_factory=dict)


@dataclass
class Cluster:
    """A geographic cluster of locations."""
    id: str
    name: str
    center_lat: float
    center_lng: float
    locations: List[Location] = field(default_factory=list)
    level: str = "city"  # city, district, neighborhood
    parent_id: Optional[str] = None

    @property
    def venue_count(self) -> int:
        return len(self.locations)

    @property
    def total_visits(self) -> int:
        return sum(loc.visit_count for loc in self.locations)

    def sources_breakdown(self) -> Dict[str, int]:
        breakdown = defaultdict(int)
        for loc in self.locations:
            breakdown[loc.source] += 1
        return dict(breakdown)


class GeoClustering:
    """
    Geographic clustering using distance-based grouping.

    Uses a simple hierarchical approach:
    1. City-level clusters (50km radius)
    2. District-level clusters (5km radius)
    3. Neighborhood-level clusters (1km radius)
    """

    # Known city definitions for better naming
    KNOWN_CITIES = {
        # Asia
        "hong_kong": {"lat_range": (22.15, 22.55), "lng_range": (113.8, 114.4), "name": "Hong Kong"},
        "shanghai": {"lat_range": (30.9, 31.5), "lng_range": (121.0, 122.0), "name": "Shanghai"},
        "beijing": {"lat_range": (39.7, 40.1), "lng_range": (116.1, 116.7), "name": "Beijing"},
        "tokyo": {"lat_range": (35.5, 35.9), "lng_range": (139.5, 140.0), "name": "Tokyo"},
        "singapore": {"lat_range": (1.2, 1.5), "lng_range": (103.6, 104.0), "name": "Singapore"},
        "hoi_an": {"lat_range": (15.8, 16.0), "lng_range": (108.2, 108.4), "name": "Hoi An"},
        "bangkok": {"lat_range": (13.6, 13.9), "lng_range": (100.4, 100.7), "name": "Bangkok"},
        "phuket": {"lat_range": (7.8, 8.0), "lng_range": (98.2, 98.4), "name": "Phuket"},
        # Europe
        "paris": {"lat_range": (48.7, 49.0), "lng_range": (2.1, 2.5), "name": "Paris"},
        "london": {"lat_range": (51.3, 51.7), "lng_range": (-0.5, 0.3), "name": "London"},
        "stockholm": {"lat_range": (59.2, 59.5), "lng_range": (17.8, 18.3), "name": "Stockholm"},
        "edinburgh": {"lat_range": (55.9, 56.0), "lng_range": (-3.3, -3.1), "name": "Edinburgh"},
        "glasgow": {"lat_range": (55.8, 55.95), "lng_range": (-4.4, -4.1), "name": "Glasgow"},
        "stirling": {"lat_range": (56.0, 56.15), "lng_range": (-4.0, -3.7), "name": "Stirling"},
        "loughborough": {"lat_range": (52.7, 52.85), "lng_range": (-1.3, -1.1), "name": "Loughborough"},
        "amsterdam": {"lat_range": (52.3, 52.45), "lng_range": (4.8, 5.0), "name": "Amsterdam"},
        "barcelona": {"lat_range": (41.3, 41.5), "lng_range": (2.1, 2.25), "name": "Barcelona"},
        # Americas
        "new_york": {"lat_range": (40.5, 41.0), "lng_range": (-74.3, -73.7), "name": "New York"},
        "san_francisco": {"lat_range": (37.7, 37.85), "lng_range": (-122.5, -122.35), "name": "San Francisco"},
        "los_angeles": {"lat_range": (33.9, 34.2), "lng_range": (-118.5, -118.1), "name": "Los Angeles"},
        # Oceania
        "sydney": {"lat_range": (-34.0, -33.7), "lng_range": (150.9, 151.4), "name": "Sydney"},
        "melbourne": {"lat_range": (-38.0, -37.6), "lng_range": (144.8, 145.2), "name": "Melbourne"},
        "brisbane": {"lat_range": (-27.8, -27.3), "lng_range": (152.9, 153.2), "name": "Brisbane"},
        "gold_coast": {"lat_range": (-28.2, -27.9), "lng_range": (153.3, 153.5), "name": "Gold Coast"},
    }

    # Hong Kong districts for detailed clustering
    HK_DISTRICTS = {
        "central": {"lat_range": (22.27, 22.29), "lng_range": (114.14, 114.165), "name": "Central"},
        "sheung_wan": {"lat_range": (22.285, 22.295), "lng_range": (114.13, 114.15), "name": "Sheung Wan"},
        "wan_chai": {"lat_range": (22.27, 22.285), "lng_range": (114.165, 114.185), "name": "Wan Chai"},
        "causeway_bay": {"lat_range": (22.275, 22.29), "lng_range": (114.18, 114.195), "name": "Causeway Bay"},
        "north_point": {"lat_range": (22.285, 22.305), "lng_range": (114.195, 114.215), "name": "North Point"},
        "quarry_bay": {"lat_range": (22.28, 22.295), "lng_range": (114.21, 114.23), "name": "Quarry Bay"},
        "happy_valley": {"lat_range": (22.26, 22.275), "lng_range": (114.175, 114.195), "name": "Happy Valley"},
        "tst": {"lat_range": (22.29, 22.31), "lng_range": (114.165, 114.185), "name": "Tsim Sha Tsui"},
        "jordan": {"lat_range": (22.3, 22.315), "lng_range": (114.165, 114.18), "name": "Jordan"},
        "mong_kok": {"lat_range": (22.315, 22.33), "lng_range": (114.165, 114.18), "name": "Mong Kok"},
        "kowloon_tong": {"lat_range": (22.33, 22.35), "lng_range": (114.175, 114.195), "name": "Kowloon Tong"},
        "tko": {"lat_range": (22.3, 22.33), "lng_range": (114.25, 114.28), "name": "Tseung Kwan O"},
        "sai_kung": {"lat_range": (22.37, 22.42), "lng_range": (114.25, 114.35), "name": "Sai Kung"},
        "lantau": {"lat_range": (22.2, 22.35), "lng_range": (113.85, 114.05), "name": "Lantau"},
        "aberdeen": {"lat_range": (22.24, 22.26), "lng_range": (114.14, 114.17), "name": "Aberdeen"},
        "stanley": {"lat_range": (22.21, 22.23), "lng_range": (114.2, 114.22), "name": "Stanley"},
    }

    def __init__(self):
        self.city_clusters: List[Cluster] = []
        self.district_clusters: List[Cluster] = []
        self.neighborhood_clusters: List[Cluster] = []

    @staticmethod
    def haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
        """Calculate distance in km between two points using Haversine formula."""
        R = 6371  # Earth radius in km
        lat1, lng1, lat2, lng2 = map(math.radians, [lat1, lng1, lat2, lng2])
        dlat = lat2 - lat1
        dlng = lng2 - lng1
        a = math.sin(dlat/2)**2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlng/2)**2
        return 2 * R * math.asin(math.sqrt(a))

    def _identify_city(self, lat: float, lng: float) -> Optional[str]:
        """Identify which known city a coordinate belongs to."""
        for city_id, city_def in self.KNOWN_CITIES.items():
            lat_min, lat_max = city_def["lat_range"]
            lng_min, lng_max = city_def["lng_range"]
            if lat_min <= lat <= lat_max and lng_min <= lng <= lng_max:
                return city_def["name"]
        return None

    def _identify_hk_district(self, lat: float, lng: float) -> Optional[str]:
        """Identify which Hong Kong district a coordinate belongs to."""
        for district_id, district_def in self.HK_DISTRICTS.items():
            lat_min, lat_max = district_def["lat_range"]
            lng_min, lng_max = district_def["lng_range"]
            if lat_min <= lat <= lat_max and lng_min <= lng <= lng_max:
                return district_def["name"]
        return None

    def cluster_cities(self, locations: List[Location], radius_km: float = 50) -> List[Cluster]:
        """
        Cluster locations into city-level groups.

        Args:
            locations: List of Location objects
            radius_km: Maximum distance to consider same city (default 50km)

        Returns:
            List of city-level Cluster objects
        """
        clusters = []

        for loc in locations:
            # Try to identify known city first
            city_name = self._identify_city(loc.lat, loc.lng)

            # Find existing cluster
            found = False
            for cluster in clusters:
                dist = self.haversine_km(loc.lat, loc.lng, cluster.center_lat, cluster.center_lng)
                if dist < radius_km:
                    cluster.locations.append(loc)
                    # Update center (running average)
                    n = len(cluster.locations)
                    cluster.center_lat = (cluster.center_lat * (n-1) + loc.lat) / n
                    cluster.center_lng = (cluster.center_lng * (n-1) + loc.lng) / n
                    found = True
                    break

            if not found:
                # Create new cluster
                cluster_id = f"city_{len(clusters)}"
                name = city_name or f"Location ({loc.lat:.1f}, {loc.lng:.1f})"
                clusters.append(Cluster(
                    id=cluster_id,
                    name=name,
                    center_lat=loc.lat,
                    center_lng=loc.lng,
                    locations=[loc],
                    level="city"
                ))

        # Update names for known cities
        for cluster in clusters:
            city_name = self._identify_city(cluster.center_lat, cluster.center_lng)
            if city_name:
                cluster.name = city_name

        self.city_clusters = sorted(clusters, key=lambda c: -len(c.locations))
        return self.city_clusters

    def cluster_districts(self, city_cluster: Cluster, radius_km: float = 5) -> List[Cluster]:
        """
        Cluster locations within a city into district-level groups.

        Args:
            city_cluster: A city-level Cluster
            radius_km: Maximum distance for same district (default 5km)

        Returns:
            List of district-level Cluster objects
        """
        clusters = []

        for loc in city_cluster.locations:
            # Try to identify known district (for Hong Kong)
            district_name = None
            if city_cluster.name == "Hong Kong":
                district_name = self._identify_hk_district(loc.lat, loc.lng)

            # Find existing cluster
            found = False
            for cluster in clusters:
                dist = self.haversine_km(loc.lat, loc.lng, cluster.center_lat, cluster.center_lng)
                if dist < radius_km:
                    cluster.locations.append(loc)
                    n = len(cluster.locations)
                    cluster.center_lat = (cluster.center_lat * (n-1) + loc.lat) / n
                    cluster.center_lng = (cluster.center_lng * (n-1) + loc.lng) / n
                    found = True
                    break

            if not found:
                cluster_id = f"{city_cluster.id}_district_{len(clusters)}"
                name = district_name or f"District ({loc.lat:.3f}, {loc.lng:.3f})"
                clusters.append(Cluster(
                    id=cluster_id,
                    name=name,
                    center_lat=loc.lat,
                    center_lng=loc.lng,
                    locations=[loc],
                    level="district",
                    parent_id=city_cluster.id
                ))

        # Update names for known districts
        for cluster in clusters:
            if city_cluster.name == "Hong Kong":
                district_name = self._identify_hk_district(cluster.center_lat, cluster.center_lng)
                if district_name:
                    cluster.name = district_name

        return sorted(clusters, key=lambda c: -len(c.locations))

    def cluster_neighborhoods(self, district_cluster: Cluster, radius_km: float = 0.5) -> List[Cluster]:
        """
        Cluster locations within a district into neighborhood-level groups.

        Args:
            district_cluster: A district-level Cluster
            radius_km: Maximum distance for same neighborhood (default 500m)

        Returns:
            List of neighborhood-level Cluster objects
        """
        clusters = []

        for loc in district_cluster.locations:
            found = False
            for cluster in clusters:
                dist = self.haversine_km(loc.lat, loc.lng, cluster.center_lat, cluster.center_lng)
                if dist < radius_km:
                    cluster.locations.append(loc)
                    n = len(cluster.locations)
                    cluster.center_lat = (cluster.center_lat * (n-1) + loc.lat) / n
                    cluster.center_lng = (cluster.center_lng * (n-1) + loc.lng) / n
                    found = True
                    break

            if not found:
                cluster_id = f"{district_cluster.id}_neighborhood_{len(clusters)}"
                # Use first venue name as neighborhood identifier
                name = f"Near {loc.subject[:30]}"
                clusters.append(Cluster(
                    id=cluster_id,
                    name=name,
                    center_lat=loc.lat,
                    center_lng=loc.lng,
                    locations=[loc],
                    level="neighborhood",
                    parent_id=district_cluster.id
                ))

        return sorted(clusters, key=lambda c: -len(c.locations))

    def full_hierarchy(self, locations: List[Location]) -> Dict:
        """
        Build full clustering hierarchy: cities → districts → neighborhoods.

        Returns:
            Dict with structure:
            {
                "cities": [
                    {
                        "cluster": Cluster,
                        "districts": [
                            {
                                "cluster": Cluster,
                                "neighborhoods": [Cluster, ...]
                            },
                            ...
                        ]
                    },
                    ...
                ]
            }
        """
        cities = self.cluster_cities(locations)

        result = {"cities": []}

        for city in cities:
            city_data = {"cluster": city, "districts": []}

            if len(city.locations) >= 5:  # Only subdivide if enough venues
                districts = self.cluster_districts(city)

                for district in districts:
                    district_data = {"cluster": district, "neighborhoods": []}

                    if len(district.locations) >= 3:  # Only subdivide if enough
                        neighborhoods = self.cluster_neighborhoods(district)
                        district_data["neighborhoods"] = neighborhoods

                    city_data["districts"].append(district_data)

            result["cities"].append(city_data)

        return result
