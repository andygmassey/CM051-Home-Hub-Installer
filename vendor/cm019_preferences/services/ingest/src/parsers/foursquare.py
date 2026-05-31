"""FourSquare/Swarm data parser - comprehensive extraction."""

import json
import logging
import zipfile
from pathlib import Path
from typing import AsyncIterator, Optional, Dict, Any
from datetime import datetime
from collections import defaultdict
import aiofiles

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)

# FourSquare category ID to readable name mapping
# These are the common category group IDs from FourSquare's taxonomy
FOURSQUARE_CATEGORIES = {
    "4bf58dd8d48988d143941735": "Breakfast Spot",
    "4bf58dd8d48988d10c941735": "French Restaurant",
    "4bf58dd8d48988d14a941735": "Vietnamese Restaurant",
    "4bf58dd8d48988d116941735": "Bar",
    "4bf58dd8d48988d149941735": "Thai Restaurant",
    "4bf58dd8d48988d1cc941735": "Steakhouse",
    "4bf58dd8d48988d15e941735": "Coffee Shop",
    "4bf58dd8d48988d1f8931735": "Bed & Breakfast",
    "4bf58dd8d48988d118951735": "Grocery Store",
    "4bf58dd8d48988d16d941735": "Cafe",
    "4bf58dd8d48988d1c4941735": "Restaurant",
    "4bf58dd8d48988d110941735": "Italian Restaurant",
    "4bf58dd8d48988d145941735": "Chinese Restaurant",
    "4bf58dd8d48988d142941735": "Asian Restaurant",
    "4bf58dd8d48988d1ce941735": "Seafood Restaurant",
    "4bf58dd8d48988d1d0941735": "Dessert Shop",
    "4bf58dd8d48988d17a941735": "Fast Food Restaurant",
    "4bf58dd8d48988d1ca941735": "Pizza Place",
    "4bf58dd8d48988d1cb941735": "Food Truck",
    "4bf58dd8d48988d147941735": "Diner",
    "4bf58dd8d48988d151941735": "Taco Place",
    "4bf58dd8d48988d1db931735": "Tapas Restaurant",
    "4bf58dd8d48988d1df931735": "BBQ Joint",
    "4bf58dd8d48988d1bc941735": "Sports Bar",
    "4bf58dd8d48988d11e941735": "Cocktail Bar",
    "4bf58dd8d48988d11b941735": "Pub",
    "4bf58dd8d48988d1d5941735": "Hotel",
    "4bf58dd8d48988d1fa931735": "Hostel",
    "4bf58dd8d48988d130941735": "Building",
    "4bf58dd8d48988d163941735": "Park",
    "4bf58dd8d48988d165941735": "Scenic Lookout",
    "4bf58dd8d48988d1e2931735": "Beach",
    "4bf58dd8d48988d1e0931735": "Swimming Pool",
    "4bf58dd8d48988d175941735": "Gym / Fitness Center",
    "4bf58dd8d48988d104941735": "Museum",
    "4bf58dd8d48988d181941735": "Movie Theater",
    "4bf58dd8d48988d1e5931735": "Music Venue",
    "4bf58dd8d48988d1f1931735": "Art Gallery",
}


class FoursquareParser(BaseParser):
    """
    Parser for FourSquare/Swarm data exports.

    Extracts comprehensive data from:
    - checkins1.json (confirmed check-ins with timestamps, lat/lng)
    - venueRatings.json (explicit likes, okays, dislikes)
    - tips.json (user-written reviews)
    - expertise.json (category expertise)
    - lists.json (curated venue lists)
    """

    source_name = "foursquare"

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a FourSquare data export."""
        name = file_path.name.lower()
        full_path = str(file_path).lower()

        # Require 'foursquare' in path to avoid false matches
        if 'foursquare' not in full_path:
            return False

        # Check for ZIP file
        if file_path.suffix.lower() == '.zip':
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = [n.lower() for n in zf.namelist()]
                    return any('checkins' in n or 'venueratings' in n for n in names)
            except:
                return False

        # Also handle individual JSON files
        if file_path.suffix.lower() == '.json':
            return name in (
                'checkins1.json', 'venueratings.json', 'tips.json',
                'expertise.json', 'lists.json'
            )

        return False

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse FourSquare data export."""
        if default_compartment is None:
            default_compartment = 2  # L2 Trusted

        logger.info(f"Parsing FourSquare data from {file_path}")

        if file_path.suffix.lower() == '.zip':
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == '.json':
            async for pref in self._parse_json_file(file_path, default_compartment):
                yield pref

    async def _parse_zip(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse FourSquare ZIP archive."""
        with zipfile.ZipFile(file_path, 'r') as zf:
            for name in zf.namelist():
                name_lower = name.lower()

                if name_lower.endswith('.json'):
                    content = zf.read(name).decode('utf-8')

                    if 'checkins' in name_lower:
                        async for pref in self._parse_checkins(content, default_compartment):
                            yield pref

                    elif 'venueratings' in name_lower:
                        async for pref in self._parse_venue_ratings(content, default_compartment):
                            yield pref

                    elif 'tips' in name_lower and 'tips.json' in name_lower:
                        async for pref in self._parse_tips(content, default_compartment):
                            yield pref

                    elif 'expertise' in name_lower:
                        async for pref in self._parse_expertise(content, default_compartment):
                            yield pref

                    elif 'lists' in name_lower and 'lists.json' in name_lower:
                        async for pref in self._parse_lists(content, default_compartment):
                            yield pref

    async def _parse_json_file(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse individual JSON file."""
        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        name = file_path.name.lower()

        if 'checkins' in name:
            async for pref in self._parse_checkins(content, default_compartment):
                yield pref
        elif 'venueratings' in name:
            async for pref in self._parse_venue_ratings(content, default_compartment):
                yield pref
        elif 'tips' in name:
            async for pref in self._parse_tips(content, default_compartment):
                yield pref
        elif 'expertise' in name:
            async for pref in self._parse_expertise(content, default_compartment):
                yield pref
        elif 'lists' in name:
            async for pref in self._parse_lists(content, default_compartment):
                yield pref

    def _parse_timestamp(self, ts_str: str) -> Optional[datetime]:
        """Parse FourSquare timestamp formats."""
        if not ts_str:
            return None

        formats = [
            "%Y-%m-%d %H:%M:%S.%f",
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%dT%H:%M:%S.%fZ",
            "%Y-%m-%dT%H:%M:%SZ",
        ]

        for fmt in formats:
            try:
                return datetime.strptime(ts_str, fmt)
            except ValueError:
                continue
        return None

    async def _parse_checkins(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse check-ins - individual records + venue/city aggregates."""
        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse checkins JSON: {e}")
            return

        items = data.get('items', [])
        logger.info(f"Processing {len(items)} FourSquare check-ins")

        # Aggregation tracking
        venue_visits: Dict[str, Dict[str, Any]] = defaultdict(lambda: {
            'count': 0,
            'first_visit': None,
            'last_visit': None,
            'venue_id': None,
            'lat': None,
            'lng': None
        })
        city_checkins: Dict[str, int] = defaultdict(int)
        checkins = []

        for item in items:
            try:
                venue = item.get('venue', {})
                venue_name = venue.get('name', '').strip()
                venue_id = venue.get('id', '')

                if not venue_name:
                    continue

                created_at = item.get('createdAt', '')
                timestamp = self._parse_timestamp(created_at)
                lat = item.get('lat')
                lng = item.get('lng')

                # Store for individual record
                checkins.append({
                    'venue_name': venue_name,
                    'venue_id': venue_id,
                    'timestamp': timestamp,
                    'lat': lat,
                    'lng': lng,
                    'is_private': item.get('private', False)
                })

                # Aggregate by venue
                venue_data = venue_visits[venue_name]
                venue_data['count'] += 1
                venue_data['venue_id'] = venue_id
                if lat:
                    venue_data['lat'] = lat
                if lng:
                    venue_data['lng'] = lng
                if timestamp:
                    if venue_data['first_visit'] is None or timestamp < venue_data['first_visit']:
                        venue_data['first_visit'] = timestamp
                    if venue_data['last_visit'] is None or timestamp > venue_data['last_visit']:
                        venue_data['last_visit'] = timestamp

                # Extract city from coordinates or timezone (approximate)
                # For now, we'll track by timezone offset or mark as unknown
                timezone_offset = item.get('timeZoneOffset')
                if timezone_offset == 480:
                    city_checkins['Hong Kong'] += 1
                elif timezone_offset == 120:
                    city_checkins['Europe'] += 1
                elif timezone_offset == 420:
                    city_checkins['Southeast Asia'] += 1
                elif timezone_offset == 0:
                    city_checkins['UK/Portugal'] += 1
                else:
                    city_checkins['Other'] += 1

            except Exception as e:
                logger.warning(f"Error parsing check-in: {e}")
                continue

        # ============================================
        # INDIVIDUAL CHECK-IN RECORDS
        # ============================================
        for checkin in checkins:
            extra = {
                "type": "checkin",
                "venue_id": checkin['venue_id']
            }

            if checkin['lat'] and checkin['lng']:
                extra["lat"] = checkin['lat']
                extra["lng"] = checkin['lng']

            if checkin['timestamp']:
                extra["timestamp"] = checkin['timestamp'].strftime("%Y-%m-%d %H:%M")

            yield ParsedPreference(
                subject=checkin['venue_name'],
                preference_type="Experience",
                category="place",
                strength=0.25,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                observed_at=checkin['timestamp'],
                extra=extra
            )

        # ============================================
        # AGGREGATE - Repeat Venues (2+ visits)
        # ============================================
        for venue_name, data in sorted(venue_visits.items(), key=lambda x: -x[1]['count']):
            count = data['count']
            if count >= 2:
                # Higher strength for repeat visits: 0.5 base + 0.05 per visit, max 0.85
                strength = min(0.5 + (count * 0.05), 0.85)

                extra = {
                    "type": "repeat_venue",
                    "visit_count": count,
                    "venue_id": data['venue_id']
                }

                if data['first_visit']:
                    extra["first_visit"] = data['first_visit'].strftime("%Y-%m-%d")
                if data['last_visit']:
                    extra["last_visit"] = data['last_visit'].strftime("%Y-%m-%d")
                if data['lat']:
                    extra["lat"] = data['lat']
                if data['lng']:
                    extra["lng"] = data['lng']

                yield ParsedPreference(
                    subject=venue_name,
                    preference_type="Like",
                    category="place",
                    strength=strength,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra=extra
                )

        # ============================================
        # AGGREGATE - City Patterns
        # ============================================
        total_checkins = len(checkins)
        for city, count in sorted(city_checkins.items(), key=lambda x: -x[1]):
            if count >= 5 and city != 'Other':
                percentage = round(count / total_checkins * 100, 1) if total_checkins > 0 else 0

                yield ParsedPreference(
                    subject=city,
                    preference_type="Pattern",
                    category="travel",
                    strength=0.35,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "type": "city_pattern",
                        "checkin_count": count,
                        "percentage": percentage
                    }
                )

        logger.info(f"Parsed {len(checkins)} check-ins, {len([v for v in venue_visits.values() if v['count'] >= 2])} repeat venues")

    async def _parse_venue_ratings(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse explicit venue ratings (likes, okays, dislikes)."""
        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse venue ratings JSON: {e}")
            return

        # Likes - strong positive signal
        likes = data.get('venueLikes', [])
        for venue in likes:
            venue_name = venue.get('name', '').strip()
            venue_id = venue.get('id', '')

            if not venue_name:
                continue

            yield ParsedPreference(
                subject=venue_name,
                preference_type="Like",
                category="place",
                strength=0.7,  # Explicit positive rating
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "explicit_like",
                    "venue_id": venue_id
                }
            )

        # Okays - neutral-positive signal
        okays = data.get('venueOkays', [])
        for venue in okays:
            venue_name = venue.get('name', '').strip()
            venue_id = venue.get('id', '')

            if not venue_name:
                continue

            yield ParsedPreference(
                subject=venue_name,
                preference_type="Neutral",
                category="place",
                strength=0.4,  # Neutral-positive
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "explicit_okay",
                    "venue_id": venue_id
                }
            )

        # Dislikes - negative signal
        dislikes = data.get('venueDislikes', [])
        for venue in dislikes:
            venue_name = venue.get('name', '').strip()
            venue_id = venue.get('id', '')

            if not venue_name:
                continue

            yield ParsedPreference(
                subject=venue_name,
                preference_type="Dislike",
                category="place",
                strength=-0.3,  # Explicit negative
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "explicit_dislike",
                    "venue_id": venue_id
                }
            )

        logger.info(f"Parsed {len(likes)} likes, {len(okays)} okays, {len(dislikes)} dislikes")

    async def _parse_tips(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse user tips/reviews - high-value signal."""
        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse tips JSON: {e}")
            return

        items = data.get('items', [])
        logger.info(f"Processing {len(items)} FourSquare tips")

        for item in items:
            try:
                venue = item.get('venue', {})
                venue_name = venue.get('name', '').strip()
                venue_id = venue.get('id', '')
                tip_text = item.get('text', '').strip()

                if not venue_name:
                    continue

                created_at = item.get('createdAt', '')
                timestamp = self._parse_timestamp(created_at)
                view_count = item.get('viewCount', 0)
                agree_count = item.get('agreeCount', 0)

                # Writing a tip indicates strong engagement
                extra = {
                    "type": "tip",
                    "venue_id": venue_id,
                    "view_count": view_count
                }

                if tip_text:
                    extra["text"] = tip_text[:500]  # Truncate long tips
                if agree_count > 0:
                    extra["agree_count"] = agree_count

                yield ParsedPreference(
                    subject=f"reviewed {venue_name}",
                    preference_type="Like",
                    category="place",
                    strength=0.65,  # Effort to write = strong signal
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    observed_at=timestamp,
                    extra=extra
                )

            except Exception as e:
                logger.warning(f"Error parsing tip: {e}")
                continue

        logger.info(f"Parsed {len(items)} tips")

    async def _parse_expertise(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse category expertise."""
        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse expertise JSON: {e}")
            return

        items = data.get('items', [])
        logger.info(f"Processing {len(items)} expertise entries")

        for item in items:
            try:
                category_id = item.get('id', '')
                category_type = item.get('type', '')
                last_modified = item.get('lastModified', '')
                timestamp = self._parse_timestamp(last_modified)

                # Skip neighborhoods and cities (not very meaningful without names)
                if category_type in ('Neighborhood', 'City'):
                    continue

                # Look up category name
                category_name = FOURSQUARE_CATEGORIES.get(category_id)

                if not category_name:
                    # Unknown category - skip
                    continue

                yield ParsedPreference(
                    subject=f"expertise in {category_name}",
                    preference_type="Pattern",
                    category="interest",
                    strength=0.45,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    observed_at=timestamp,
                    extra={
                        "type": "category_expertise",
                        "foursquare_category_id": category_id,
                        "category_name": category_name
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing expertise: {e}")
                continue

    async def _parse_lists(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse curated venue lists."""
        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse lists JSON: {e}")
            return

        items = data.get('items', [])
        logger.info(f"Processing {len(items)} lists")

        for list_item in items:
            try:
                list_name = list_item.get('name', '').strip()
                list_id = list_item.get('id', '')
                created_at = list_item.get('createdAt', '')
                timestamp = self._parse_timestamp(created_at)

                list_items = list_item.get('listItems', {}).get('items', [])

                # Extract venues from list
                for venue_entry in list_items:
                    venue = venue_entry.get('venue', {})
                    venue_name = venue.get('name', '').strip()
                    venue_id = venue.get('id', '')

                    if not venue_name:
                        continue

                    yield ParsedPreference(
                        subject=venue_name,
                        preference_type="Like",
                        category="place",
                        strength=0.6,  # Curation is a strong signal
                        source=self.source_name,
                        compartment_level=default_compartment,
                        size="Small",
                        observed_at=timestamp,
                        extra={
                            "type": "list_venue",
                            "list_name": list_name,
                            "list_id": list_id,
                            "venue_id": venue_id
                        }
                    )

                # Also yield the list itself as a curation pattern
                if list_name and len(list_items) > 0:
                    yield ParsedPreference(
                        subject=f"curated list: {list_name}",
                        preference_type="Pattern",
                        category="interest",
                        strength=0.4,
                        source=self.source_name,
                        compartment_level=default_compartment,
                        size="Small",
                        observed_at=timestamp,
                        extra={
                            "type": "curated_list",
                            "list_id": list_id,
                            "venue_count": len(list_items)
                        }
                    )

            except Exception as e:
                logger.warning(f"Error parsing list: {e}")
                continue
