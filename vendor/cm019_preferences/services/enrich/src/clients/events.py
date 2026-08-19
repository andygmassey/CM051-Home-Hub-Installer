"""Event and ticket enrichment client.

Enriches event attendance data from email receipts or ticket purchases.

Primary source: Ticketmaster Discovery API
- Full event search and discovery
- Free tier: 5,000 calls/day
- Register: https://developer.ticketmaster.com/

Secondary source: Eventbrite (limited)
- Public search was deprecated December 2019
- Only get_event(event_id) works - use for known Eventbrite URLs from emails/calendars
- Register: https://www.eventbrite.com/platform/api
"""

import logging
import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Dict, List, Optional
from enum import Enum

from .base import BaseClient, InMemoryCache
from ..models.enrichment import EnrichmentResult, EnrichmentSource, TopicResult, EntityResult

logger = logging.getLogger(__name__)


# Eventbrite URL patterns for ID extraction
EVENTBRITE_URL_PATTERNS = [
    # https://www.eventbrite.com/e/event-name-tickets-123456789
    r'eventbrite\.com/e/[^/]+-(\d+)',
    # https://www.eventbrite.com/e/123456789
    r'eventbrite\.com/e/(\d+)',
    # https://eventbrite.com/event/123456789
    r'eventbrite\.com/event/(\d+)',
    # Just the numeric ID
    r'^(\d{8,12})$',
]


def extract_eventbrite_id(url_or_id: str) -> Optional[str]:
    """
    Extract Eventbrite event ID from a URL or return the ID if already numeric.

    Supports various Eventbrite URL formats:
    - https://www.eventbrite.com/e/tech-conference-2026-tickets-123456789
    - https://www.eventbrite.com/e/123456789
    - https://eventbrite.com/event/123456789
    - Plain numeric ID: 123456789

    Args:
        url_or_id: Eventbrite URL or event ID

    Returns:
        Event ID string or None if not found

    Example:
        >>> extract_eventbrite_id("https://www.eventbrite.com/e/my-event-tickets-123456789")
        '123456789'
        >>> extract_eventbrite_id("123456789")
        '123456789'
    """
    if not url_or_id:
        return None

    url_or_id = url_or_id.strip()

    for pattern in EVENTBRITE_URL_PATTERNS:
        match = re.search(pattern, url_or_id, re.IGNORECASE)
        if match:
            return match.group(1)

    return None


class EventType(str, Enum):
    """Types of events."""
    CONCERT = "concert"
    SPORTS = "sports"
    THEATER = "theater"
    COMEDY = "comedy"
    CONFERENCE = "conference"
    MEETUP = "meetup"
    FESTIVAL = "festival"
    EXHIBITION = "exhibition"
    WORKSHOP = "workshop"
    OTHER = "other"


class EventSource(str, Enum):
    """Event data sources."""
    TICKETMASTER = "ticketmaster"
    EVENTBRITE = "eventbrite"
    SONGKICK = "songkick"
    UNKNOWN = "unknown"


@dataclass
class Performer:
    """Artist or performer at an event."""
    name: str
    id: Optional[str] = None  # Source-specific ID
    genre: Optional[str] = None
    image_url: Optional[str] = None
    url: Optional[str] = None


@dataclass
class Venue:
    """Event venue information."""
    name: str
    id: Optional[str] = None
    address: Optional[str] = None
    city: Optional[str] = None
    country: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    capacity: Optional[int] = None


@dataclass
class EventInfo:
    """Information about an event."""
    id: str  # Source-specific event ID
    name: str
    event_type: EventType = EventType.OTHER
    source: EventSource = EventSource.UNKNOWN

    # Timing
    start_date: Optional[datetime] = None
    end_date: Optional[datetime] = None
    timezone: Optional[str] = None

    # Location
    venue: Optional[Venue] = None

    # Performers
    performers: List[Performer] = field(default_factory=list)
    headliner: Optional[str] = None

    # Classification
    genres: List[str] = field(default_factory=list)
    segment: Optional[str] = None  # e.g., "Music", "Sports", "Arts"
    sub_genre: Optional[str] = None

    # Metadata
    description: Optional[str] = None
    image_url: Optional[str] = None
    url: Optional[str] = None
    price_range: Optional[str] = None
    status: Optional[str] = None  # "onsale", "cancelled", "postponed"

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "name": self.name,
            "event_type": self.event_type.value,
            "source": self.source.value,
            "start_date": self.start_date.isoformat() if self.start_date else None,
            "end_date": self.end_date.isoformat() if self.end_date else None,
            "venue": {
                "name": self.venue.name,
                "city": self.venue.city,
                "country": self.venue.country,
            } if self.venue else None,
            "performers": [p.name for p in self.performers],
            "headliner": self.headliner,
            "genres": self.genres,
            "segment": self.segment,
        }


@dataclass
class EventSearchResult:
    """Result of an event search."""
    query: str
    events: List[EventInfo] = field(default_factory=list)
    total_results: int = 0
    page: int = 1
    per_page: int = 20


# Genre mappings from Ticketmaster classification
TICKETMASTER_GENRES = {
    "KnvZfZ7vAv1": "alternative",
    "KnvZfZ7vAvv": "ballads_romantic",
    "KnvZfZ7vAvE": "blues",
    "KnvZfZ7vAvd": "children_family",
    "KnvZfZ7vAvA": "classical",
    "KnvZfZ7vAv6": "country",
    "KnvZfZ7vAvF": "dance_electronic",
    "KnvZfZ7vAve": "folk",
    "KnvZfZ7vAv7": "hip_hop_rap",
    "KnvZfZ7vAva": "holiday",
    "KnvZfZ7vAvt": "jazz",
    "KnvZfZ7vAvn": "latin",
    "KnvZfZ7vAvl": "metal",
    "KnvZfZ7vAvJ": "new_age",
    "KnvZfZ7vAv0": "other",
    "KnvZfZ7vAvk": "pop",
    "KnvZfZ7vAvI": "r_and_b",
    "KnvZfZ7vAeJ": "reggae",
    "KnvZfZ7vAeA": "religious",
    "KnvZfZ7vAv6": "rock",
    "KnvZfZ7vAeE": "world",
}

# Event type classification keywords
EVENT_TYPE_KEYWORDS = {
    EventType.CONCERT: ["concert", "live", "tour", "gig", "performance", "show"],
    EventType.SPORTS: ["game", "match", "championship", "tournament", "vs", "versus"],
    EventType.THEATER: ["theater", "theatre", "play", "musical", "opera", "ballet"],
    EventType.COMEDY: ["comedy", "stand-up", "standup", "comedian", "laughs"],
    EventType.CONFERENCE: ["conference", "summit", "symposium", "convention"],
    EventType.MEETUP: ["meetup", "networking", "mixer", "social"],
    EventType.FESTIVAL: ["festival", "fest", "fair"],
    EventType.EXHIBITION: ["exhibition", "exhibit", "gallery", "museum"],
    EventType.WORKSHOP: ["workshop", "class", "seminar", "training"],
}


class TicketmasterClient(BaseClient[EventInfo]):
    """
    Client for Ticketmaster Discovery API.

    API Documentation: https://developer.ticketmaster.com/products-and-docs/apis/discovery-api/v2/

    Features:
    - Search events by keyword, location, date range
    - Get event details including performers, venue, genre
    - Attraction (artist) search and details

    Rate limit: 5 req/sec (5,000 calls/day on free tier)
    API key required: TICKETMASTER_API_KEY
    """

    BASE_URL = "https://app.ticketmaster.com/discovery/v2"
    CACHE_PREFIX = "ticketmaster"

    def __init__(
        self,
        api_key: Optional[str] = None,
        cache: Optional[InMemoryCache] = None,
    ):
        """
        Initialize Ticketmaster client.

        Args:
            api_key: Ticketmaster API key (or set TICKETMASTER_API_KEY env var)
            cache: Optional cache instance
        """
        super().__init__(
            rate_limit=5.0,  # 5 req/sec
            max_retries=3,
            timeout=30.0,
            cache=cache,
        )

        if api_key:
            self.api_key = api_key
        else:
            import os
            self.api_key = os.getenv("TICKETMASTER_API_KEY")

        if not self.api_key:
            logger.warning(
                "No Ticketmaster API key configured. "
                "Set TICKETMASTER_API_KEY environment variable or pass api_key parameter. "
                "Register at: https://developer.ticketmaster.com/"
            )

    def _get_headers(self) -> Dict[str, str]:
        return {
            "Accept": "application/json",
        }

    async def search_events(
        self,
        keyword: Optional[str] = None,
        city: Optional[str] = None,
        country_code: Optional[str] = None,
        start_date: Optional[datetime] = None,
        end_date: Optional[datetime] = None,
        classification_name: Optional[str] = None,  # "Music", "Sports", etc.
        size: int = 20,
        page: int = 0,
    ) -> EventSearchResult:
        """
        Search for events.

        Args:
            keyword: Search keyword
            city: City name
            country_code: ISO country code (e.g., "US", "GB")
            start_date: Events starting after this date
            end_date: Events starting before this date
            classification_name: Event category ("Music", "Sports", "Arts & Theatre")
            size: Results per page (max 200)
            page: Page number

        Returns:
            EventSearchResult with matching events
        """
        if not self.api_key:
            logger.error("Ticketmaster API key not configured")
            return EventSearchResult(query=keyword or "", events=[], total_results=0)

        params = {
            "apikey": self.api_key,
            "size": min(size, 200),
            "page": page,
        }

        if keyword:
            params["keyword"] = keyword
        if city:
            params["city"] = city
        if country_code:
            params["countryCode"] = country_code
        if classification_name:
            params["classificationName"] = classification_name
        if start_date:
            params["startDateTime"] = start_date.strftime("%Y-%m-%dT%H:%M:%SZ")
        if end_date:
            params["endDateTime"] = end_date.strftime("%Y-%m-%dT%H:%M:%SZ")

        result = await self._get("/events.json", params=params)

        if not result:
            return EventSearchResult(query=keyword or "", events=[], total_results=0)

        events = []
        embedded = result.get("_embedded", {})

        for event_data in embedded.get("events", []):
            event = self._parse_event(event_data)
            if event:
                events.append(event)

        page_info = result.get("page", {})

        return EventSearchResult(
            query=keyword or "",
            events=events,
            total_results=page_info.get("totalElements", len(events)),
            page=page_info.get("number", 0),
            per_page=page_info.get("size", size),
        )

    async def get_event(self, event_id: str) -> Optional[EventInfo]:
        """
        Get event details by Ticketmaster event ID.

        Args:
            event_id: Ticketmaster event ID

        Returns:
            EventInfo or None if not found
        """
        if not self.api_key:
            logger.error("Ticketmaster API key not configured")
            return None

        params = {"apikey": self.api_key}
        result = await self._get(f"/events/{event_id}.json", params=params)

        if not result:
            return None

        return self._parse_event(result)

    async def search(self, query: str) -> Optional[EventInfo]:
        """
        Search for an event by query string.

        Implementation of abstract method from BaseClient.

        Args:
            query: Search query (event name, artist, etc.)

        Returns:
            First matching EventInfo or None
        """
        result = await self.search_events(keyword=query, size=1)
        return result.events[0] if result.events else None

    async def get_details(self, item_id: str) -> Optional[EventInfo]:
        """
        Get event details by Ticketmaster event ID.

        Implementation of abstract method from BaseClient.

        Args:
            item_id: Ticketmaster event ID

        Returns:
            EventInfo or None if not found
        """
        return await self.get_event(item_id)

    async def search_attractions(
        self,
        keyword: str,
        size: int = 10,
    ) -> List[Performer]:
        """
        Search for attractions (artists/performers).

        Args:
            keyword: Artist/performer name
            size: Max results

        Returns:
            List of matching performers
        """
        if not self.api_key:
            logger.error("Ticketmaster API key not configured")
            return []

        params = {
            "apikey": self.api_key,
            "keyword": keyword,
            "size": size,
        }

        result = await self._get("/attractions.json", params=params)

        if not result:
            return []

        performers = []
        embedded = result.get("_embedded", {})

        for attraction in embedded.get("attractions", []):
            performer = Performer(
                name=attraction.get("name", ""),
                id=attraction.get("id"),
                genre=self._extract_genre(attraction),
                image_url=self._extract_image(attraction.get("images", [])),
                url=attraction.get("url"),
            )
            performers.append(performer)

        return performers

    async def enrich_event(
        self,
        preference_id: str,
        event_name: str,
        artist_name: Optional[str] = None,
        venue_city: Optional[str] = None,
    ) -> EnrichmentResult:
        """
        Enrich an event preference with Ticketmaster data.

        Args:
            preference_id: PWG preference ID
            event_name: Event name to search for
            artist_name: Optional artist name for better matching
            venue_city: Optional city for location filtering

        Returns:
            EnrichmentResult with topics and entities
        """
        # Search for the event
        search_result = await self.search_events(
            keyword=event_name,
            city=venue_city,
            size=5,
        )

        if not search_result.events:
            # Try searching by artist
            if artist_name:
                search_result = await self.search_events(keyword=artist_name, size=5)

        if not search_result.events:
            return EnrichmentResult(
                preference_id=preference_id,
                original_subject=event_name,
                source=EnrichmentSource.TICKETMASTER,
                confidence=0.0,
            )

        event = search_result.events[0]

        # Build topics
        topics = []
        if event.event_type:
            topics.append(TopicResult(
                name=event.event_type.value,
                normalized=event.event_type.value.lower().replace(" ", "_"),
                source_field="event_type",
            ))
        if event.segment:
            topics.append(TopicResult(
                name=event.segment,
                normalized=event.segment.lower().replace(" ", "_"),
                source_field="segment",
            ))
        for genre in event.genres[:3]:
            topics.append(TopicResult(
                name=genre,
                normalized=genre.lower().replace(" ", "_"),
                source_field="genre",
            ))

        # Build entities
        entities = []
        for performer in event.performers[:3]:
            entities.append(EntityResult(
                name=performer.name,
                entity_type="artist",
            ))
        if event.venue:
            entities.append(EntityResult(
                name=event.venue.name,
                entity_type="venue",
            ))

        return EnrichmentResult(
            preference_id=preference_id,
            original_subject=event_name,
            source=EnrichmentSource.TICKETMASTER,
            topics=topics,
            entities=entities,
            confidence=0.7,
            matched_title=event.name,
        )

    def _parse_event(self, data: Dict[str, Any]) -> Optional[EventInfo]:
        """Parse event data from API response."""
        try:
            # Basic info
            event_id = data.get("id", "")
            name = data.get("name", "")

            if not event_id or not name:
                return None

            # Dates
            dates = data.get("dates", {})
            start = dates.get("start", {})
            start_date = None
            if start.get("dateTime"):
                try:
                    start_date = datetime.fromisoformat(
                        start["dateTime"].replace("Z", "+00:00")
                    )
                except Exception:
                    pass

            # Venue
            venue = None
            embedded = data.get("_embedded", {})
            venues = embedded.get("venues", [])
            if venues:
                v = venues[0]
                venue = Venue(
                    name=v.get("name", ""),
                    id=v.get("id"),
                    city=v.get("city", {}).get("name"),
                    country=v.get("country", {}).get("name"),
                    address=v.get("address", {}).get("line1"),
                )
                location = v.get("location", {})
                if location:
                    try:
                        venue.latitude = float(location.get("latitude", 0))
                        venue.longitude = float(location.get("longitude", 0))
                    except Exception:
                        pass

            # Performers
            performers = []
            attractions = embedded.get("attractions", [])
            for attr in attractions:
                performers.append(Performer(
                    name=attr.get("name", ""),
                    id=attr.get("id"),
                    genre=self._extract_genre(attr),
                ))

            # Classification
            classifications = data.get("classifications", [])
            segment = None
            genres = []
            event_type = EventType.OTHER

            if classifications:
                c = classifications[0]
                segment_data = c.get("segment", {})
                segment = segment_data.get("name")

                genre_data = c.get("genre", {})
                if genre_data.get("name"):
                    genres.append(genre_data["name"].lower())

                subgenre_data = c.get("subGenre", {})
                if subgenre_data.get("name"):
                    genres.append(subgenre_data["name"].lower())

                # Determine event type
                if segment:
                    segment_lower = segment.lower()
                    if "music" in segment_lower:
                        event_type = EventType.CONCERT
                    elif "sport" in segment_lower:
                        event_type = EventType.SPORTS
                    elif "art" in segment_lower or "theatre" in segment_lower:
                        event_type = EventType.THEATER

            # Price range
            price_ranges = data.get("priceRanges", [])
            price_range = None
            if price_ranges:
                pr = price_ranges[0]
                currency = pr.get("currency", "USD")
                min_p = pr.get("min", 0)
                max_p = pr.get("max", 0)
                price_range = f"{currency} {min_p}-{max_p}"

            return EventInfo(
                id=event_id,
                name=name,
                event_type=event_type,
                source=EventSource.TICKETMASTER,
                start_date=start_date,
                venue=venue,
                performers=performers,
                headliner=performers[0].name if performers else None,
                genres=genres,
                segment=segment,
                description=data.get("info"),
                image_url=self._extract_image(data.get("images", [])),
                url=data.get("url"),
                price_range=price_range,
                status=dates.get("status", {}).get("code"),
            )
        except Exception as e:
            logger.error(f"Error parsing event: {e}")
            return None

    def _extract_genre(self, data: Dict) -> Optional[str]:
        """Extract genre from classifications."""
        classifications = data.get("classifications", [])
        if classifications:
            genre = classifications[0].get("genre", {})
            return genre.get("name")
        return None

    def _extract_image(self, images: List[Dict]) -> Optional[str]:
        """Extract best image URL."""
        if not images:
            return None
        # Prefer larger images
        for img in sorted(images, key=lambda x: x.get("width", 0), reverse=True):
            if img.get("url"):
                return img["url"]
        return images[0].get("url") if images else None


class EventbriteClient(BaseClient[EventInfo]):
    """
    Client for Eventbrite API.

    API Documentation: https://www.eventbrite.com/platform/api

    IMPORTANT: Public event search was deprecated in December 2019.
    The search endpoint (GET /v3/events/search/) no longer works.

    Available endpoints (require known IDs):
    - GET /v3/events/:event_id/ - Get event by ID
    - GET /v3/organizations/:org_id/events/ - List events by organization
    - GET /v3/venues/:venue_id/events/ - List events by venue

    Use this client when you have specific event/organization/venue IDs
    (e.g., from email confirmations, calendar invites, or known organizers).

    For general event discovery, use TicketmasterClient instead.

    Rate limit: Varies by plan (be conservative)
    API key required: EVENTBRITE_API_KEY (OAuth token)
    """

    BASE_URL = "https://www.eventbriteapi.com/v3"
    CACHE_PREFIX = "eventbrite"

    def __init__(
        self,
        api_key: Optional[str] = None,
        cache: Optional[InMemoryCache] = None,
    ):
        """
        Initialize Eventbrite client.

        Args:
            api_key: Eventbrite private OAuth token (or set EVENTBRITE_API_KEY env var)
            cache: Optional cache instance
        """
        super().__init__(
            rate_limit=2.0,  # 2 req/sec (conservative)
            max_retries=3,
            timeout=30.0,
            cache=cache,
        )

        if api_key:
            self.api_key = api_key
        else:
            import os
            self.api_key = os.getenv("EVENTBRITE_API_KEY")

        if not self.api_key:
            logger.warning(
                "No Eventbrite API key configured. "
                "Set EVENTBRITE_API_KEY environment variable or pass api_key parameter. "
                "Register at: https://www.eventbrite.com/platform/api"
            )

    def _get_headers(self) -> Dict[str, str]:
        headers = {"Accept": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    async def get_event(self, event_id_or_url: str) -> Optional[EventInfo]:
        """
        Get event details by Eventbrite event ID or URL.

        Args:
            event_id_or_url: Eventbrite event ID or URL containing the ID
                Examples:
                - "123456789"
                - "https://www.eventbrite.com/e/my-event-tickets-123456789"

        Returns:
            EventInfo or None if not found
        """
        if not self.api_key:
            logger.error("Eventbrite API key not configured")
            return None

        # Extract ID from URL if needed
        event_id = extract_eventbrite_id(event_id_or_url)
        if not event_id:
            logger.error(f"Could not extract Eventbrite event ID from: {event_id_or_url}")
            return None

        params = {"expand": "venue,organizer,category"}
        result = await self._get(f"/events/{event_id}/", params=params)

        if not result:
            return None

        return self._parse_event(result)

    async def search(self, query: str) -> Optional[EventInfo]:
        """
        Search for an event by query string.

        NOTE: Eventbrite public search was deprecated in December 2019.
        This method returns None. Use TicketmasterClient for event discovery,
        or use get_event() with a known Eventbrite event ID/URL.

        Args:
            query: Search query (ignored - API deprecated)

        Returns:
            Always None (search API deprecated)
        """
        logger.debug(
            "Eventbrite search not available (deprecated Dec 2019). "
            "Use get_event() with a known event ID or URL."
        )
        return None

    async def get_details(self, item_id: str) -> Optional[EventInfo]:
        """
        Get event details by Eventbrite event ID.

        Implementation of abstract method from BaseClient.

        Args:
            item_id: Eventbrite event ID

        Returns:
            EventInfo or None if not found
        """
        return await self.get_event(item_id)

    async def enrich_event_by_id(
        self,
        preference_id: str,
        event_id_or_url: str,
    ) -> EnrichmentResult:
        """
        Enrich an event preference with Eventbrite data using a known event ID or URL.

        Use this when you have an Eventbrite URL from an email confirmation or calendar.
        For event discovery by name, use TicketmasterClient instead.

        Args:
            preference_id: PWG preference ID
            event_id_or_url: Eventbrite event ID or URL
                Examples:
                - "123456789"
                - "https://www.eventbrite.com/e/my-event-tickets-123456789"

        Returns:
            EnrichmentResult with topics and entities
        """
        event = await self.get_event(event_id_or_url)

        if not event:
            return EnrichmentResult(
                preference_id=preference_id,
                original_subject=event_id_or_url,
                source=EnrichmentSource.EVENTBRITE,
                confidence=0.0,
            )

        # Build topics
        topics = []
        if event.event_type:
            topics.append(TopicResult(
                name=event.event_type.value,
                normalized=event.event_type.value.lower().replace(" ", "_"),
                source_field="event_type",
            ))
        if event.segment:
            topics.append(TopicResult(
                name=event.segment,
                normalized=event.segment.lower().replace(" ", "_"),
                source_field="segment",
            ))
        for genre in event.genres[:3]:
            topics.append(TopicResult(
                name=genre,
                normalized=genre.lower().replace(" ", "_"),
                source_field="genres",
            ))

        # Build entities
        entities = []
        if event.venue:
            entities.append(EntityResult(
                name=event.venue.name,
                entity_type="venue",
            ))

        return EnrichmentResult(
            preference_id=preference_id,
            original_subject=event_id_or_url,
            source=EnrichmentSource.EVENTBRITE,
            topics=topics,
            entities=entities,
            confidence=0.8,  # Higher confidence since we have exact ID
            matched_title=event.name,
        )

    def _parse_event(self, data: Dict[str, Any]) -> Optional[EventInfo]:
        """Parse event data from API response."""
        try:
            event_id = data.get("id", "")
            name_data = data.get("name", {})
            name = name_data.get("text", "") if isinstance(name_data, dict) else str(name_data)

            if not event_id or not name:
                return None

            # Dates
            start_data = data.get("start", {})
            start_date = None
            if start_data.get("utc"):
                try:
                    start_date = datetime.fromisoformat(
                        start_data["utc"].replace("Z", "+00:00")
                    )
                except Exception:
                    pass

            end_data = data.get("end", {})
            end_date = None
            if end_data.get("utc"):
                try:
                    end_date = datetime.fromisoformat(
                        end_data["utc"].replace("Z", "+00:00")
                    )
                except Exception:
                    pass

            # Venue (if expanded)
            venue = None
            venue_data = data.get("venue")
            if venue_data and isinstance(venue_data, dict):
                address = venue_data.get("address", {})
                venue = Venue(
                    name=venue_data.get("name", ""),
                    id=venue_data.get("id"),
                    city=address.get("city"),
                    country=address.get("country"),
                    address=address.get("localized_address_display"),
                    latitude=float(address.get("latitude", 0)) if address.get("latitude") else None,
                    longitude=float(address.get("longitude", 0)) if address.get("longitude") else None,
                )

            # Category
            category = data.get("category")
            segment = None
            genres = []
            if category and isinstance(category, dict):
                segment = category.get("name")
                if segment:
                    genres.append(segment.lower())

            # Determine event type from name/category
            event_type = self._classify_event_type(name, segment)

            # Description
            description_data = data.get("description", {})
            description = description_data.get("text", "") if isinstance(description_data, dict) else None

            return EventInfo(
                id=event_id,
                name=name,
                event_type=event_type,
                source=EventSource.EVENTBRITE,
                start_date=start_date,
                end_date=end_date,
                timezone=start_data.get("timezone"),
                venue=venue,
                genres=genres,
                segment=segment,
                description=description,
                image_url=data.get("logo", {}).get("url") if data.get("logo") else None,
                url=data.get("url"),
                status=data.get("status"),
            )
        except Exception as e:
            logger.error(f"Error parsing Eventbrite event: {e}")
            return None

    def _classify_event_type(self, name: str, category: Optional[str]) -> EventType:
        """Classify event type from name and category."""
        text = f"{name} {category or ''}".lower()

        for event_type, keywords in EVENT_TYPE_KEYWORDS.items():
            if any(kw in text for kw in keywords):
                return event_type

        return EventType.OTHER


class EventClient:
    """
    Unified client for event enrichment.

    Primary source: Ticketmaster Discovery API (5,000 calls/day free tier)
    - Full event search and discovery
    - Concerts, sports, theater, comedy, family events
    - Global coverage with venue and performer data

    Secondary source: Eventbrite (ID lookup only - search deprecated Dec 2019)
    - Use get_eventbrite_event() with known event IDs/URLs from emails/calendars
    - Cannot discover new events via search
    """

    def __init__(
        self,
        ticketmaster_key: Optional[str] = None,
        eventbrite_key: Optional[str] = None,
        cache: Optional[InMemoryCache] = None,
    ):
        """
        Initialize the unified event client.

        Args:
            ticketmaster_key: Ticketmaster API key
            eventbrite_key: Eventbrite API key (optional - only for ID lookups)
            cache: Shared cache instance
        """
        self.ticketmaster = TicketmasterClient(api_key=ticketmaster_key, cache=cache)
        self.eventbrite = EventbriteClient(api_key=eventbrite_key, cache=cache)

    async def search_events(
        self,
        keyword: str,
        city: Optional[str] = None,
    ) -> List[EventInfo]:
        """
        Search for events using Ticketmaster.

        Args:
            keyword: Search keyword
            city: City for location filtering

        Returns:
            List of events from Ticketmaster
        """
        if not self.ticketmaster.api_key:
            logger.warning("Ticketmaster API key not configured")
            return []

        result = await self.ticketmaster.search_events(keyword=keyword, city=city)
        return result.events

    async def get_eventbrite_event(self, event_id_or_url: str) -> Optional[EventInfo]:
        """
        Get an Eventbrite event by ID or URL.

        Use this when you have an Eventbrite URL from an email or calendar.

        Args:
            event_id_or_url: Eventbrite event ID or URL
                Examples:
                - "123456789"
                - "https://www.eventbrite.com/e/my-event-tickets-123456789"

        Returns:
            EventInfo or None if not found
        """
        return await self.eventbrite.get_event(event_id_or_url)

    async def enrich_event(
        self,
        preference_id: str,
        event_name: str,
        artist_name: Optional[str] = None,
        location: Optional[str] = None,
    ) -> EnrichmentResult:
        """
        Enrich an event preference using Ticketmaster search.

        For Eventbrite events, use enrich_eventbrite_by_id() with the event URL.

        Args:
            preference_id: PWG preference ID
            event_name: Event name to search for
            artist_name: Optional artist name
            location: Optional location

        Returns:
            EnrichmentResult from Ticketmaster search
        """
        if self.ticketmaster.api_key:
            result = await self.ticketmaster.enrich_event(
                preference_id, event_name, artist_name, location
            )
            if result.is_successful():
                return result

        # No successful enrichment
        return EnrichmentResult(
            preference_id=preference_id,
            original_subject=event_name,
            source=EnrichmentSource.TICKETMASTER,
            confidence=0.0,
        )

    async def enrich_eventbrite_by_id(
        self,
        preference_id: str,
        event_id_or_url: str,
    ) -> EnrichmentResult:
        """
        Enrich an Eventbrite event using a known event ID or URL.

        Use this when you have an Eventbrite URL from an email confirmation
        or calendar invite.

        Args:
            preference_id: PWG preference ID
            event_id_or_url: Eventbrite event ID or URL

        Returns:
            EnrichmentResult from Eventbrite lookup
        """
        return await self.eventbrite.enrich_event_by_id(preference_id, event_id_or_url)


# Add to enrichment source enum if not already present
# This is a stub - the actual enum is in models/enrichment.py
def _ensure_event_sources():
    """Ensure event sources are in EnrichmentSource enum."""
    # Check if already present
    if not hasattr(EnrichmentSource, "TICKETMASTER"):
        logger.warning(
            "EnrichmentSource.TICKETMASTER not defined. "
            "Add to models/enrichment.py: TICKETMASTER = 'ticketmaster'"
        )
    if not hasattr(EnrichmentSource, "EVENTBRITE"):
        logger.warning(
            "EnrichmentSource.EVENTBRITE not defined. "
            "Add to models/enrichment.py: EVENTBRITE = 'eventbrite'"
        )
