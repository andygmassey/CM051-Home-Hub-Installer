"""Enrichment orchestrator - coordinates preference enrichment."""

import asyncio
import logging
import os
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Set

import httpx

from .config import settings
from .eligibility import is_eligible
from .clients.base import InMemoryCache
from .clients.openlibrary import OpenLibraryClient
from .clients.tmdb import TMDBClient
from .clients.musicbrainz import MusicBrainzClient
from .clients.wikidata import WikidataClient
from .clients.podcast_index import PodcastIndexClient
from .clients.url_fetcher import URLFetcherClient
from .clients.brand import BrandClient
from .clients.foursquare import FoursquareClient
from .clients.events import EventClient
from .clients.domain_topics import DomainTopicMapper
from .clients.youtube import YouTubeClient
from .clients.places import PlacesClient
from .models.enrichment import EnrichmentResult, EnrichmentSource, TopicResult, EntityResult

logger = logging.getLogger(__name__)


@dataclass
class EnrichmentStats:
    """Statistics for enrichment run."""
    started_at: datetime = field(default_factory=datetime.utcnow)
    completed_at: Optional[datetime] = None

    total_processed: int = 0
    successful: int = 0
    failed: int = 0
    skipped_already_enriched: int = 0
    skipped_no_client: int = 0
    skipped_ineligible: int = 0

    # True when the pass stopped because it ran out of its wall-clock
    # allowance rather than because it ran out of work. The distinction
    # matters to every caller: an exhausted budget means there IS more to
    # do, and reporting it as completion would be a false absence.
    budget_exhausted: bool = False

    by_source: Dict[str, int] = field(default_factory=dict)
    by_category: Dict[str, int] = field(default_factory=dict)

    errors: List[str] = field(default_factory=list)

    def attempted(self) -> int:
        """
        Items that were actually DISPATCHED to a third party, successfully
        or not.

        This is the unit a `--limit` bounds, and it is deliberately not
        `total_processed`. Processing an item that turns out to be already
        enriched, or to have no client, or to be unsendable, costs one local
        SPARQL ASK and no egress. Counting those against an allowance is how
        a limited run ends up spending its whole budget re-reading work it
        finished last time.
        """
        return self.successful + self.failed

    def summary(self) -> str:
        """Generate summary string."""
        duration = (
            (self.completed_at or datetime.utcnow()) - self.started_at
        ).total_seconds()

        return (
            f"Enrichment Stats:\n"
            f"  Duration: {duration:.1f}s\n"
            f"  Total processed: {self.total_processed}\n"
            f"  Successful: {self.successful}\n"
            f"  Failed: {self.failed}\n"
            f"  Already enriched: {self.skipped_already_enriched}\n"
            f"  No client: {self.skipped_no_client}\n"
            f"  Not sendable: {self.skipped_ineligible}\n"
            f"  Budget exhausted: {self.budget_exhausted}\n"
            f"  By source: {self.by_source}\n"
            f"  By category: {self.by_category}"
        )


class EnrichmentService:
    """
    Main enrichment orchestrator.

    Queries Qdrant for unenriched preferences, routes them to the
    appropriate API client based on category, and stores enrichment
    results back to Oxigraph as RDF triples.

    Usage:
        service = EnrichmentService()
        await service.enrich_all(user_id="user123", limit=1000)
    """

    # Category to client mapping
    CATEGORY_CLIENTS = {
        # Books - Open Library
        "book": "openlibrary",
        "books": "openlibrary",

        # Films and television - Wikidata, because we ship no TMDB key.
        #
        # These four categories were dispatched to TMDB, which warns at
        # construction that its key is missing and then fails every item
        # instantly. Measured: 24 films failed in 0.2 seconds on a real
        # install, and would have been retried on every run forever.
        # Wikidata gives genre, director and cast with no credential.
        "movie": "wikidata_film",
        "movies": "wikidata_film",
        "tv": "wikidata_film",
        "tv_show": "wikidata_film",
        "movie_tv": "wikidata_film",

        # YouTube Videos - YouTube Data API
        "video": "youtube",
        "youtube_video": "youtube",

        # Music - MusicBrainz
        "music": "musicbrainz",
        "artist": "musicbrainz",
        "track": "musicbrainz",

        # Podcasts - Podcast Index
        "podcast": "podcast_index",
        "podcasts": "podcast_index",

        # URLs/Bookmarks - URL Fetcher
        "bookmark": "url_fetcher",
        "bookmarks": "url_fetcher",
        "website": "url_fetcher",
        "page": "url_fetcher",

        # Brands - Wikidata Brand Lookup
        "brand": "wikidata_brand",

        # Topics/Interests - Wikidata
        "interest": "wikidata",
        "topic": "wikidata",
        "search_interest": "wikidata",
        "instagram_creator": "wikidata",  # Well-known creators may have Wikidata entries

        # Andy, 2026-08-17: education and food should be enriched;
        # `professional` explicitly EXCLUDED. That exclusion is a product
        # decision, not an oversight, so it is recorded here rather than
        # left as a category that merely happens to be absent.
        "education": "wikidata",
        "food": "wikidata",

        # Places/Venues - Wikidata, because we ship no Google Places key
        # either. Type, country and administrative area, keyless.
        "place": "wikidata_place",
        "venue": "wikidata_place",
        "restaurant": "wikidata_place",

        # Events - Ticketmaster
        "event": "events",
        "ticket": "events",
        "concert": "events",
    }

    # Clients that cannot do anything without a credential. We ship none of
    # these keys, so on a stock install every one of them is dead weight:
    # the category is dispatched, the client answers instantly, and the item
    # is recorded as a FAILURE that will be retried on every future run.
    #
    # Naming them here lets the caller skip those categories and SAY SO,
    # which is the difference between "your films got nothing" and 24 rows
    # of noise in an error list. The env var name is carried so the message
    # can tell an operator what to set if they have their own key.
    CLIENT_CREDENTIALS = {
        "tmdb": "TMDB_API_KEY",
        "google_places": "GOOGLE_PLACES_API_KEY",
        "youtube": "YOUTUBE_API_KEY",
        "foursquare": "FOURSQUARE_API_KEY",
        "podcast_index": "PODCAST_INDEX_API_KEY",
        "events": "TICKETMASTER_API_KEY",
    }

    @classmethod
    def _credential_present(cls, client_name: str) -> bool:
        """Is the credential this client needs actually configured?"""
        env_name = cls.CLIENT_CREDENTIALS.get(client_name)
        if env_name is None:
            return True  # keyless client, nothing to check
        # settings holds the parsed value; the env var is the operator-facing
        # name. Check settings first so a .env file counts, then the raw env.
        attr = env_name.lower()
        value = getattr(settings, attr, None) or os.environ.get(env_name)
        return bool(value)

    @classmethod
    def enrichable_categories(cls) -> List[str]:
        """
        Every category that has a client whose credential is present.

        Derived from CATEGORY_CLIENTS rather than listed separately, so a
        new category cannot be added to the dispatch table and then quietly
        left out of the sweep. That is exactly the defect this replaces:
        `--all` meant three hardcoded categories while the table held 27.
        """
        out = []
        for category, client_name in cls.CATEGORY_CLIENTS.items():
            if cls._credential_present(client_name):
                out.append(category)
        return out

    @classmethod
    def categories_missing_credentials(cls) -> Dict[str, str]:
        """Category -> env var name, for every category we must skip."""
        return {
            category: cls.CLIENT_CREDENTIALS[client_name]
            for category, client_name in cls.CATEGORY_CLIENTS.items()
            if not cls._credential_present(client_name)
        }

    def __init__(self):
        """Initialize the enrichment service."""
        # Shared cache across clients
        self._cache = InMemoryCache(ttl_days=settings.cache_ttl_days)

        # Domain topic mapper for bookmark enrichment (no API calls)
        self._domain_mapper = DomainTopicMapper()

        # Initialize core clients (always needed)
        self._openlibrary = OpenLibraryClient(cache=self._cache)
        self._tmdb = TMDBClient(cache=self._cache)
        self._musicbrainz = MusicBrainzClient(cache=self._cache)
        self._wikidata = WikidataClient(cache=self._cache)
        self._podcast_index = PodcastIndexClient(cache=self._cache)
        self._url_fetcher = URLFetcherClient(cache=self._cache)
        self._brand = BrandClient(cache=self._cache)

        # Lazy-initialized clients (only created when needed, may require API keys)
        self.__foursquare = None
        self.__events = None
        self.__youtube = None
        self.__google_places = None

        # Track already-enriched preferences (in memory for this run)
        self._enriched_ids: Set[str] = set()

    @property
    def _foursquare(self) -> FoursquareClient:
        """Lazy-initialize Foursquare client only when needed."""
        if self.__foursquare is None:
            self.__foursquare = FoursquareClient(cache=self._cache)
        return self.__foursquare

    @property
    def _events(self) -> EventClient:
        """Lazy-initialize Event client only when needed."""
        if self.__events is None:
            self.__events = EventClient()
        return self.__events

    @property
    def _youtube(self) -> YouTubeClient:
        """Lazy-initialize YouTube client only when needed."""
        if self.__youtube is None:
            self.__youtube = YouTubeClient(cache=self._cache)
        return self.__youtube

    @property
    def _google_places(self) -> PlacesClient:
        """Lazy-initialize Google Places client only when needed."""
        if self.__google_places is None:
            self.__google_places = PlacesClient(cache=self._cache)
        return self.__google_places

    async def _query_qdrant_preferences(
        self,
        user_id: Optional[str] = None,
        category: Optional[str] = None,
        limit: int = 100,
        offset: Optional[str] = None,
        min_strength: Optional[float] = None,
        order_by_strength: bool = False,
    ) -> tuple[List[dict], Optional[str]]:
        """
        Query Qdrant for preferences to enrich.

        Args:
            user_id: Filter by user ID
            category: Filter by category
            limit: Max results
            offset: Pagination offset (point ID to start after)
            min_strength: Minimum strength threshold (0-1)
            order_by_strength: Sort by strength descending (high-value first)

        Returns:
            Tuple of (list of preference payloads, next_page_offset)
        """
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                # Build filter
                must_conditions = []

                # USER_ID: MATCH IT, OR ACCEPT ITS ABSENCE.
                #
                # Measured on a real box, 2026-08-17, over 7,773 preferences:
                #
                #     user_id = "ostler"   2,963
                #     user_id = absent     4,810
                #
                # and among the categories enrichment can actually handle,
                # 4,791 of 6,240 carry NO user_id at all, including every one
                # of the 4,714 bookmarks and 77 of 84 places. A plain equality
                # filter silently excluded 77% of the corpus, and did it in a
                # way that reads as "there was nothing there".
                #
                # Ostler is single-machine by architectural directive: the Hub
                # Mac is THE machine and there is exactly one person. An
                # untagged preference is therefore THIS user's, not somebody
                # else's, and skipping it enriches nothing while looking like
                # a completed pass.
                #
                # `should` is OR in Qdrant, and must+should means must AND
                # at-least-one-should: the right category, and either the
                # right user or no user at all.
                should_conditions = []
                if user_id:
                    should_conditions = [
                        {"key": "user_id", "match": {"value": user_id}},
                        {"is_empty": {"key": "user_id"}},
                    ]

                if category:
                    must_conditions.append({
                        "key": "category",
                        "match": {"value": category}
                    })

                if min_strength is not None:
                    must_conditions.append({
                        "key": "strength",
                        "range": {"gte": min_strength}
                    })

                body = {
                    "limit": limit,
                    "with_payload": True,
                    "with_vector": False,
                }

                if offset:
                    body["offset"] = offset

                if must_conditions or should_conditions:
                    body["filter"] = {}
                    if must_conditions:
                        body["filter"]["must"] = must_conditions
                    if should_conditions:
                        body["filter"]["should"] = should_conditions

                # Order by strength descending for priority processing
                if order_by_strength:
                    body["order_by"] = {"key": "strength", "direction": "desc"}

                response = await client.post(
                    f"{settings.qdrant_url}/collections/{settings.qdrant_collection}/points/scroll",
                    json=body
                )

                if response.status_code == 200:
                    data = response.json()
                    result = data.get("result", {})
                    next_offset = result.get("next_page_offset")
                    preferences = [
                        {
                            "id": str(point.get("id")),
                            **point.get("payload", {})
                        }
                        for point in result.get("points", [])
                    ]
                    return preferences, next_offset
                else:
                    logger.error(f"Qdrant query failed: {response.text}")
                    return [], None

        except Exception as e:
            logger.error(f"Error querying Qdrant: {e}")
            return [], None

    async def _check_already_enriched(self, preference_id: str) -> bool:
        """
        Check if a preference has already been enriched in Oxigraph.

        Args:
            preference_id: Preference ID

        Returns:
            True if already enriched
        """
        # First check in-memory set
        if preference_id in self._enriched_ids:
            return True

        # Query Oxigraph for enrichment metadata (check default and named graphs)
        sparql = f"""
        PREFIX pwg: <https://schema.ostler.ai/ontology#>
        ASK WHERE {{
            {{
                <urn:ostler:preference:{preference_id}> pwg:enrichedAt ?date .
            }}
            UNION
            {{
                GRAPH ?g {{
                    <urn:ostler:preference:{preference_id}> pwg:enrichedAt ?date .
                }}
            }}
        }}
        """

        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.post(
                    f"{settings.oxigraph_url}/query",
                    content=sparql,
                    headers={
                        "Content-Type": "application/sparql-query",
                        "Accept": "application/sparql-results+json"
                    }
                )

                if response.status_code == 200:
                    result = response.json()
                    is_enriched = result.get("boolean", False)
                    if is_enriched:
                        self._enriched_ids.add(preference_id)
                    return is_enriched

        except Exception as e:
            logger.debug(f"Error checking enrichment status: {e}")

        return False

    async def _store_enrichment(self, result: EnrichmentResult) -> bool:
        """
        Store enrichment result as RDF triples in Oxigraph using SPARQL UPDATE.

        Args:
            result: EnrichmentResult to store

        Returns:
            True if successful
        """
        if not result.is_successful():
            return False

        preference_uri = f"urn:ostler:preference:{result.preference_id}"
        triples = result.to_turtle(preference_uri)

        # Convert Turtle to SPARQL UPDATE INSERT DATA format
        # Parse the Turtle lines and build SPARQL UPDATE
        lines = triples.strip().split('\n')
        data_lines = []
        for line in lines:
            stripped = line.strip()
            # Skip empty lines and comments
            if stripped and not stripped.startswith('#') and not stripped.startswith('@prefix'):
                data_lines.append(stripped)

        data_block = '\n'.join(data_lines)

        # Build SPARQL UPDATE query with prefixes
        update_query = f"""
PREFIX pwg: <https://schema.ostler.ai/ontology#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>

INSERT DATA {{
{data_block}
}}
"""

        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(
                    f"{settings.oxigraph_url}/update",
                    content=update_query,
                    headers={"Content-Type": "application/sparql-update"}
                )

                if response.status_code in (200, 201, 204):
                    self._enriched_ids.add(result.preference_id)
                    return True
                else:
                    logger.error(f"Failed to store enrichment: {response.text}")
                    return False

        except Exception as e:
            logger.error(f"Error storing enrichment: {e}")
            return False

    async def enrich_preference(
        self,
        preference: dict
    ) -> Optional[EnrichmentResult]:
        """
        Enrich a single preference.

        Args:
            preference: Preference dict from Qdrant

        Returns:
            EnrichmentResult or None
        """
        pref_id = preference.get("id", "")
        category = preference.get("category", "").lower() if preference.get("category") else ""
        subject = preference.get("subject", "")

        if not subject:
            logger.debug(f"Skipping preference {pref_id}: no subject")
            return None

        # Get appropriate client
        client_name = self.CATEGORY_CLIENTS.get(category)

        if client_name is None:
            logger.debug(f"No client for category: {category}")
            return None

        # Route to client
        if client_name == "openlibrary":
            author = preference.get("author")  # If available
            return await self._openlibrary.enrich(pref_id, subject, author)

        elif client_name == "tmdb":
            year = preference.get("year")  # If available

            # Determine media type from category
            if category in ("movie", "movies"):
                media_type = "movie"
            elif category in ("tv", "tv_show"):
                media_type = "tv"
            else:
                media_type = None

            # For TV shows, extract show name from "Show Name - Episode Title" format
            search_title = subject
            if media_type == "tv" and " - " in subject:
                # Split on " - " and take first part as show name
                parts = subject.split(" - ", 1)
                show_name = parts[0].strip()

                # Validate it looks like a show name (not a personal reminder)
                # Skip if it looks like a name or short phrase
                if len(show_name) > 2 and not show_name.lower() in ("me", "my", "we"):
                    search_title = show_name
                    logger.debug(f"TV: Extracted show name '{show_name}' from '{subject}'")

            # Use lower confidence threshold for movies (titles often have prefixes/suffixes)
            min_conf = 0.3 if media_type == "movie" else 0.5
            return await self._tmdb.enrich(pref_id, search_title, year, media_type, min_confidence=min_conf)

        elif client_name == "musicbrainz":
            # Extract metadata from extra if available (Apple Music provides this)
            extra = preference.get("extra", {}) or {}
            artist_name = extra.get("artist") or None
            song_name = extra.get("song") or None
            album_name = extra.get("album") or None

            # Determine enrichment approach based on available metadata
            if song_name:
                # Have explicit song name - use track enrichment directly
                # Artist may or may not be available
                return await self._musicbrainz.enrich_track(
                    pref_id, song_name, artist_name
                )
            elif artist_name and " - " not in subject:
                # Have artist but no song - subject might be the track name
                return await self._musicbrainz.enrich_track(
                    pref_id, subject, artist_name
                )
            elif " - " in subject and album_name:
                # Apple Music format: "Track - Album" (album name in extra)
                # Check if part2 matches the album name
                parts = subject.split(" - ", 1)
                part1, part2 = parts[0].strip(), parts[1].strip()

                # If album_name matches part2, it's "Track - Album" format
                if album_name.lower() in part2.lower() or part2.lower() in album_name.lower():
                    logger.debug(f"[APPLE-MUSIC] Detected Track-Album format: '{part1}' from album '{album_name}'")
                    # Search for track name only (no artist info available)
                    return await self._musicbrainz.enrich_track(pref_id, part1)
                else:
                    # Album doesn't match part2, might be "Artist - Track"
                    logger.debug(f"[APPLE-MUSIC] Standard Artist-Track format: artist='{part1}', track='{part2}'")
                    return await self._musicbrainz.enrich_track(pref_id, part2, part1)
            else:
                # Fall back to subject parsing (Artist - Track format)
                # For "music" category, use "track" type so the parser can split
                subject_type = "track" if category in ("track", "music") else "artist"
                return await self._musicbrainz.enrich(pref_id, subject, subject_type)

        elif client_name == "podcast_index":
            return await self._podcast_index.enrich_podcast(pref_id, subject)

        elif client_name == "url_fetcher":
            # For bookmarks, try domain-based topic mapping first (fast, works for dead URLs)
            # Fall back to URL fetch only if domain not mapped
            extra = preference.get("extra", {}) or {}
            domain = extra.get("domain")
            url = extra.get("url") or preference.get("url") or subject

            if domain:
                domain_info = self._domain_mapper.lookup(domain)
                if domain_info:
                    # Use domain-based enrichment (no API call needed)
                    result = EnrichmentResult(
                        preference_id=pref_id,
                        original_subject=subject,
                        source=EnrichmentSource.DOMAIN_MAPPING,
                        confidence=0.8,  # High confidence for known domains
                    )
                    result.topics = [
                        TopicResult(
                            name=topic.replace("_", " ").title(),  # Human-readable
                            normalized=topic,  # Machine-friendly (e.g., "business_strategy")
                            confidence=0.8,
                            source_field="domain_mapping",
                        )
                        for topic in domain_info.topics
                    ]
                    # If we have a Wikidata ID for the domain, add it as an entity
                    if domain_info.wikidata_id:
                        result.entities = [EntityResult(
                            name=domain,
                            entity_type="website",
                            external_id=domain_info.wikidata_id,
                        )]
                    result.matched_name = domain
                    result.category = domain_info.category
                    return result

            # For unmapped domains, log for future domain map expansion
            # We don't try URL fetching because:
            # 1. Most bookmarks are 5-10 years old (dead links, redirects, SSL issues)
            # 2. The domain itself IS the signal (someone bookmarking tech sites = tech interest)
            # 3. URL fetching is slow (~3-5 sec per URL with redirects)
            # 4. We can expand the domain map based on logged unmapped domains
            if domain:
                logger.debug(f"Unmapped domain: {domain}")
            return None

        elif client_name == "wikidata":
            # Normalize topic/interest to Wikidata Q-ID
            # Uses normalize_topic and converts to EnrichmentResult
            norm_result = await self._wikidata.normalize_topic(subject)
            if norm_result.qid:
                result = EnrichmentResult(
                    preference_id=pref_id,
                    original_subject=subject,
                    source=EnrichmentSource.WIKIDATA,
                    confidence=norm_result.confidence,
                )
                result.topics = [TopicResult(
                    name=norm_result.label,
                    normalized=norm_result.qid,  # Wikidata Q-ID as normalized ID
                    confidence=norm_result.confidence,
                    source_field="wikidata",
                )]
                result.matched_name = norm_result.label
                return result
            return None

        elif client_name == "wikidata_film":
            # For TV, "Show Name - Episode Title" is common; the show is the
            # thing with a genre and a cast, so search on that half.
            search_title = subject
            if " - " in subject:
                head = subject.split(" - ", 1)[0].strip()
                if len(head) > 2 and head.lower() not in ("me", "my", "we"):
                    search_title = head
            return await self._wikidata.enrich_film(
                pref_id, search_title, preference.get("year")
            )

        elif client_name == "wikidata_place":
            return await self._wikidata.enrich_place(pref_id, subject)

        elif client_name == "wikidata_brand":
            # Look up brand in Wikidata
            brand_result = await self._brand.lookup_brand(subject)
            if brand_result.brand:
                result = EnrichmentResult(
                    preference_id=pref_id,
                    original_subject=subject,
                    source=EnrichmentSource.WIKIDATA,
                    confidence=brand_result.confidence,
                )
                result.matched_name = brand_result.brand.name
                result.entities = [EntityResult(
                    name=brand_result.brand.name,
                    entity_type="brand",
                    external_id=brand_result.brand.qid,
                )]
                if brand_result.brand.industries:
                    result.topics = [
                        TopicResult(
                            name=ind.replace("_", " ").title(),
                            normalized=ind.lower().replace(" ", "_"),
                            confidence=0.9,
                            source_field="brand_industry"
                        )
                        for ind in brand_result.brand.industries
                    ]
                return result
            return None

        elif client_name == "foursquare":
            return await self._foursquare.enrich_venue(pref_id, subject)

        elif client_name == "google_places":
            return await self._google_places.enrich_venue(pref_id, subject)

        elif client_name == "events":
            return await self._events.enrich_event(pref_id, subject)

        elif client_name == "youtube":
            # Extract video_id from extra or parse from subject
            extra = preference.get("extra", {}) or {}
            video_id = extra.get("video_id") or extra.get("youtube_id")

            # If no video_id in extra, try to extract from subject (might be a URL)
            if not video_id and "youtube.com" in subject.lower():
                import re
                match = re.search(r'(?:v=|youtu\.be/)([a-zA-Z0-9_-]{11})', subject)
                if match:
                    video_id = match.group(1)

            if video_id:
                return await self._youtube.enrich_video(pref_id, video_id)
            else:
                logger.debug(f"No video_id found for YouTube video: {subject[:50]}")
                return None

        return None

    async def enrich_batch(
        self,
        preferences: List[dict],
        stats: EnrichmentStats,
        deadline: Optional[datetime] = None,
        work_allowance: Optional[int] = None,
    ) -> List[EnrichmentResult]:
        """
        Enrich a batch of preferences.

        Args:
            preferences: List of preference dicts
            stats: Stats object to update
            deadline: Stop before starting any further item once passed
            work_allowance: Stop once this many items have been ATTEMPTED
                            (dispatched to a client). Items that were skipped
                            cost nothing and do not count against it. None
                            means unbounded.

        Returns:
            List of successful EnrichmentResults
        """
        results = []
        work_at_entry = stats.attempted()

        for pref in preferences:
            # The allowance is checked BEFORE each item, never during one:
            # an item that has already left the machine gets to finish and
            # be recorded, so we never spend the egress and drop the result.
            if deadline is not None and datetime.utcnow() >= deadline:
                stats.budget_exhausted = True
                break

            if (
                work_allowance is not None
                and stats.attempted() - work_at_entry >= work_allowance
            ):
                break

            pref_id = pref.get("id", "")
            category = pref.get("category", "") or ""

            stats.total_processed += 1
            stats.by_category[category] = stats.by_category.get(category, 0) + 1

            # Check if already enriched
            if await self._check_already_enriched(pref_id):
                stats.skipped_already_enriched += 1
                continue

            # Check if we have a client for this category
            client_name = self.CATEGORY_CLIENTS.get(category.lower())
            if client_name is None:
                stats.skipped_no_client += 1
                continue

            # The classifier decided this subject is a book/film/artist. It
            # is sometimes wrong, and when it is wrong the subject still
            # goes out as a query. Refuse anything shaped like prose before
            # it reaches the network. See eligibility.py for what this does
            # and, just as importantly, what it does not.
            # `category_inferred` is set by the ingest parser when the routing
            # category was GUESSED from the subject rather than declared by the
            # source, and ParsedPreference.to_payload() now states it on EVERY
            # row it writes, True or False, so absence has exactly one meaning:
            # this row was stored before the field existed.
            #
            # PASSED THROUGH RAW, NOT COERCED WITH bool(). Absent must arrive as
            # None so eligibility can treat it as UNKNOWN provenance. Coercing
            # it here would turn "we never recorded this" into "the source
            # declared it", which is the false all-clear that would have left
            # the whole pre-existing corpus egressing while the gate read green.
            eligible, why_not = is_eligible(
                client_name,
                pref.get("subject", "") or "",
                category_inferred=(pref.get("extra") or {}).get("category_inferred"),
            )
            if not eligible:
                stats.skipped_ineligible += 1
                logger.info(
                    "Not sending %s preference %s to %s (%s)",
                    category, pref_id, client_name, why_not
                )
                continue

            # Enrich
            try:
                result = await self.enrich_preference(pref)

                if result and result.is_successful():
                    # Store to Oxigraph
                    if await self._store_enrichment(result):
                        results.append(result)
                        stats.successful += 1
                        stats.by_source[result.source.value] = (
                            stats.by_source.get(result.source.value, 0) + 1
                        )
                    else:
                        stats.failed += 1
                        stats.errors.append(f"Failed to store: {pref_id}")
                elif result and result.error:
                    stats.failed += 1
                    if len(stats.errors) < 100:  # Limit error storage
                        stats.errors.append(f"{pref_id}: {result.error}")

            except Exception as e:
                stats.failed += 1
                logger.error(f"Error enriching {pref_id}: {e}")
                if len(stats.errors) < 100:
                    stats.errors.append(f"{pref_id}: {str(e)}")

        return results

    async def enrich_all(
        self,
        user_id: Optional[str] = None,
        category: Optional[str] = None,
        limit: int = 10000,
        batch_size: int = 50,
        progress_callback: Optional[callable] = None,
        min_strength: Optional[float] = None,
        priority_order: bool = False,
        deadline: Optional[datetime] = None,
    ) -> EnrichmentStats:
        """
        Enrich all unenriched preferences.

        Args:
            user_id: Filter by user ID
            category: Filter by category
            limit: Maximum preferences to process
            batch_size: Batch size for processing
            progress_callback: Optional callback(processed, total, stats)
            min_strength: Minimum strength threshold (0-1), skip weaker items
            priority_order: If True, process high-strength items first

        Returns:
            EnrichmentStats with summary
        """
        stats = EnrichmentStats()
        next_offset: Optional[str] = None
        total_fetched = 0

        logger.info(
            f"Starting enrichment: user={user_id}, category={category}, limit={limit}, "
            f"min_strength={min_strength}, priority_order={priority_order}"
        )

        # THE LIMIT BOUNDS WORK, NOT READS, AND THAT IS THE WHOLE POINT.
        #
        # MEASURED ON THE BOX, 2026-08-17. It used to bound items FETCHED
        # from Qdrant, and Qdrant does not know which preferences are already
        # enriched -- that lives in Oxigraph, checked per item further down.
        # So a second `--limit 10 --category movie_tv` run read the same first
        # ten points, found nine of them already done, enriched ZERO, and
        # printed:
        #
        #     ENRICHMENT COMPLETE
        #     Total processed: 10   Successful: 0   Already enriched: 9
        #
        # with 165 unenriched films still sitting behind them. A recurring
        # invoker built on that would have spun on the same ten points for
        # ever while reporting completion every time. That is worse than not
        # running at all, because it looks like it is working.
        #
        # Bounding on ATTEMPTS makes a limited run mean "do N items of real
        # work", so successive runs walk forward through the backlog. Skips
        # are free: they cost one local SPARQL ASK and no egress, so they
        # must not consume the allowance. Termination is unchanged and comes
        # from `next_offset is None`, which is reached after a full pass of
        # the collection.
        while stats.attempted() < limit:
            # Fetch batch
            batch, next_offset = await self._query_qdrant_preferences(
                user_id=user_id,
                category=category,
                limit=batch_size,
                offset=next_offset,
                min_strength=min_strength,
                order_by_strength=priority_order,
            )

            if not batch:
                break

            total_fetched += len(batch)

            # Process batch, still bounded so a batch_size of 50 cannot
            # overshoot a --limit of 10 by forty items.
            await self.enrich_batch(
                batch,
                stats,
                deadline=deadline,
                work_allowance=limit - stats.attempted(),
            )

            if stats.budget_exhausted:
                logger.info(
                    "Enrichment allowance spent after %d processed. The rest "
                    "is still owed and the next run picks it up.",
                    stats.total_processed
                )
                break

            # Progress callback
            if progress_callback:
                progress_callback(stats.total_processed, limit, stats)

            # Log progress
            logger.info(
                f"Progress: {stats.total_processed} processed, "
                f"{stats.successful} enriched, "
                f"{stats.skipped_already_enriched} skipped"
            )

            # If no more pages, stop
            if next_offset is None:
                break

            # Small delay between batches to avoid overwhelming APIs
            await asyncio.sleep(0.1)

        stats.completed_at = datetime.utcnow()

        logger.info(stats.summary())

        return stats

    async def enrich_categories(
        self,
        categories: List[str],
        user_id: Optional[str] = None,
        limit_per_category: int = 1000,
        deadline: Optional[datetime] = None,
    ) -> EnrichmentStats:
        """
        Enrich specific categories.

        Args:
            categories: List of categories to enrich (book, movie, music)
            user_id: Filter by user ID
            limit_per_category: Max items per category
            deadline: Wall-clock stop for the WHOLE sweep, not per category

        Returns:
            Combined EnrichmentStats
        """
        combined_stats = EnrichmentStats()

        # ONE UNREACHABLE SOURCE MUST NOT STARVE EVERY OTHER CATEGORY.
        #
        # MEASURED ON .219, 2026-08-17, on the first real run of the recurring
        # invoker. The sweep handed the WHOLE remaining deadline to each
        # category in turn, and `book` is first. OpenLibrary was unreachable,
        # each lookup burned three retries with backoff, and the entire 180s
        # allowance went on THREE books:
        #
        #     Total processed: 3   Successful: 0   Failed: 2
        #     By category: {'book': 3}
        #     Allowance spent before reaching category books
        #
        # Films, music, places and the other twenty categories were never
        # reached. Not once, and not on the next tick either, because every
        # tick would start at `book` and hit the same dead host. A permanently
        # unreachable third party would have silently owned 100% of the
        # enrichment budget for ever.
        #
        # A FAIR SHARE RECOMPUTED EACH TIME, not a fixed slice up front. A
        # category with nothing to do returns in milliseconds and its unused
        # time flows to the categories after it, so the common case loses
        # nothing. A category that stalls is capped at its share of what was
        # left when it started. That makes the worst case "one dead source
        # costs one share per tick" instead of "one dead source costs
        # everything, permanently".
        remaining = list(categories)

        for category in categories:
            now = datetime.utcnow()
            if deadline is not None and now >= deadline:
                combined_stats.budget_exhausted = True
                logger.info(
                    "Allowance spent before reaching category %s. Not started, "
                    "not failed: still owed.", category
                )
                break

            category_deadline = deadline
            if deadline is not None and remaining:
                share = (deadline - now).total_seconds() / len(remaining)
                category_deadline = now + timedelta(seconds=share)
                logger.info(
                    "Enriching category: %s (share %.0fs of %.0fs left, "
                    "%d categories to go)",
                    category, share, (deadline - now).total_seconds(),
                    len(remaining),
                )
            else:
                logger.info(f"Enriching category: {category}")

            stats = await self.enrich_all(
                user_id=user_id,
                category=category,
                limit=limit_per_category,
                deadline=category_deadline,
            )

            # A CATEGORY THAT RAN OUT OF ITS SHARE STILL OWES WORK, AND THE
            # SWEEP MUST SAY SO.
            #
            # This block used to zero the flag here. The stated reason was that
            # the merge below would otherwise "mark the whole pass exhausted
            # after the first slow category and stop". MEASURED: nothing stops
            # on it. `combined_stats.budget_exhausted` is local to this method
            # and has exactly one consumer, `cli.py:685`, which uses it to
            # choose between
            #
            #     ENRICHMENT PAUSED (allowance spent, more still owed)
            #     ENRICHMENT COMPLETE
            #
            # The loop's own stopping condition is the `now >= deadline` check
            # at the top, which reads the clock, not this flag. So the
            # suppression bought no protection against starvation. What it
            # bought was a sweep that spent its ENTIRE allowance, left backlog
            # in every category, and printed COMPLETE, which is the same
            # defect the rest of this file is being hardened against: an
            # unfinished pass that reports success.
            #
            # The two events ARE different and the log says which. Both mean
            # work is owed, so both propagate.
            if stats.budget_exhausted and category_deadline is not deadline:
                logger.info(
                    "Category %s stopped on its own share rather than on the "
                    "sweep allowance. Work is still owed in this category and "
                    "the pass will be reported as PAUSED, not COMPLETE.",
                    category,
                )

            remaining.pop(0)

            # Merge stats
            combined_stats.total_processed += stats.total_processed
            combined_stats.successful += stats.successful
            combined_stats.failed += stats.failed
            combined_stats.skipped_already_enriched += stats.skipped_already_enriched
            combined_stats.skipped_no_client += stats.skipped_no_client
            combined_stats.skipped_ineligible += stats.skipped_ineligible
            combined_stats.budget_exhausted = (
                combined_stats.budget_exhausted or stats.budget_exhausted
            )
            combined_stats.errors.extend(stats.errors[:20])  # Limit errors

            for source, count in stats.by_source.items():
                combined_stats.by_source[source] = (
                    combined_stats.by_source.get(source, 0) + count
                )
            for cat, count in stats.by_category.items():
                combined_stats.by_category[cat] = (
                    combined_stats.by_category.get(cat, 0) + count
                )

        combined_stats.completed_at = datetime.utcnow()
        return combined_stats

    async def enrich_parallel(
        self,
        category_configs: List[Dict],
        user_id: Optional[str] = None,
        deadline: Optional[datetime] = None,
    ) -> Dict[str, EnrichmentStats]:
        """
        Enrich multiple categories IN PARALLEL using different API clients.

        Since each category uses a different external API (MusicBrainz, TMDB,
        OpenLibrary, etc.), we can run them all simultaneously without
        hitting rate limits!

        Args:
            category_configs: List of dicts with keys:
                - category: str (e.g., "music", "movie", "book")
                - limit: int (max items to process)
                - min_strength: Optional[float] (minimum strength threshold)
                - priority_order: bool (process high-value first)
            user_id: Filter by user ID

        Returns:
            Dict mapping category -> EnrichmentStats

        Example:
            stats = await service.enrich_parallel([
                {"category": "music", "limit": 5000, "min_strength": 0.7, "priority_order": True},
                {"category": "movie", "limit": 2000},
                {"category": "book", "limit": 500},
                {"category": "podcast", "limit": 200},
            ])
        """
        async def enrich_single_category(config: Dict) -> tuple[str, EnrichmentStats]:
            category = config["category"]
            limit = config.get("limit", 1000)
            min_strength = config.get("min_strength")
            priority_order = config.get("priority_order", False)

            logger.info(f"[PARALLEL] Starting {category} enrichment (limit={limit})")

            # ONE SHARED ABSOLUTE DEADLINE, not a fair share. These categories
            # run CONCURRENTLY under asyncio.gather, so they all spend the same
            # wall clock at the same time. Dividing the allowance between them
            # here, as the sequential enrich_categories has to, would cut each
            # one to a fraction of a budget it is not in fact competing for.
            stats = await self.enrich_all(
                user_id=user_id,
                category=category,
                limit=limit,
                min_strength=min_strength,
                priority_order=priority_order,
                deadline=deadline,
            )

            logger.info(f"[PARALLEL] Completed {category}: {stats.successful} enriched")
            return category, stats

        # Run all categories in parallel!
        logger.info(f"Starting PARALLEL enrichment for {len(category_configs)} categories")
        start_time = datetime.utcnow()

        tasks = [enrich_single_category(config) for config in category_configs]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        # Collect results
        stats_by_category = {}
        for result in results:
            if isinstance(result, Exception):
                logger.error(f"Parallel enrichment error: {result}")
            else:
                category, stats = result
                stats_by_category[category] = stats

        duration = (datetime.utcnow() - start_time).total_seconds()
        total_enriched = sum(s.successful for s in stats_by_category.values())
        logger.info(
            f"PARALLEL enrichment complete: {total_enriched} total enriched "
            f"across {len(stats_by_category)} categories in {duration:.1f}s"
        )

        return stats_by_category

    def get_client_stats(self) -> Dict[str, dict]:
        """Get statistics from all clients."""
        return {
            "openlibrary": self._openlibrary.get_stats(),
            "tmdb": self._tmdb.get_stats(),
            "musicbrainz": self._musicbrainz.get_stats(),
            "cache": self._cache.stats(),
        }

    async def normalize_topics_with_wikidata(
        self,
        progress_callback: Optional[callable] = None,
    ) -> Dict[str, any]:
        """
        Normalize all enriched topics to Wikidata Q-IDs.

        This is a second-pass enrichment that takes existing topic strings
        from enriched preferences and maps them to canonical Wikidata entities,
        enabling cross-platform topic correlation.

        Args:
            progress_callback: Optional callback(processed, total)

        Returns:
            Dict with normalization statistics
        """
        stats = {
            "total_topics": 0,
            "normalized": 0,
            "failed": 0,
            "already_normalized": 0,
            "topics": {},  # topic -> qid mapping
        }

        # Query Oxigraph for all unique topics from enriched preferences
        sparql_query = """
        PREFIX pwg: <https://schema.ostler.ai/ontology#>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

        SELECT DISTINCT ?topic ?label WHERE {
            GRAPH ?g {
                ?pref pwg:hasTopic ?topic .
                ?topic rdfs:label ?label .
            }
            # Exclude topics that already have a Wikidata Q-ID
            FILTER NOT EXISTS {
                GRAPH ?g2 {
                    ?topic pwg:wikidataId ?qid .
                }
            }
        }
        """

        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(
                    f"{settings.oxigraph_url}/query",
                    content=sparql_query,
                    headers={
                        "Content-Type": "application/sparql-query",
                        "Accept": "application/sparql-results+json"
                    }
                )

                if response.status_code != 200:
                    logger.error(f"Failed to query topics: {response.text}")
                    return stats

                data = response.json()
                bindings = data.get("results", {}).get("bindings", [])

                # Extract unique topic labels
                topics_to_normalize = {}
                for binding in bindings:
                    topic_uri = binding.get("topic", {}).get("value", "")
                    label = binding.get("label", {}).get("value", "")
                    if label and topic_uri:
                        topics_to_normalize[label] = topic_uri

                stats["total_topics"] = len(topics_to_normalize)
                logger.info(f"Found {len(topics_to_normalize)} unique topics to normalize")

                # Normalize each topic
                processed = 0
                for label, topic_uri in topics_to_normalize.items():
                    processed += 1

                    try:
                        # Call Wikidata normalization
                        norm_result = await self._wikidata.normalize_topic(label)

                        if norm_result.qid:
                            # Store the Q-ID back to Oxigraph
                            update_turtle = f"""
@prefix pwg: <https://schema.ostler.ai/ontology#> .
@prefix wd: <http://www.wikidata.org/entity/> .

<{topic_uri}> pwg:wikidataId "{norm_result.qid}" .
<{topic_uri}> pwg:wikidataLabel "{norm_result.label}" .
<{topic_uri}> pwg:normalizationConfidence "{norm_result.confidence}"^^<http://www.w3.org/2001/XMLSchema#decimal> .
"""
                            store_response = await client.post(
                                f"{settings.oxigraph_url}/store",
                                content=update_turtle,
                                headers={"Content-Type": "text/turtle"}
                            )

                            if store_response.status_code in (200, 201, 204):
                                stats["normalized"] += 1
                                stats["topics"][label] = norm_result.qid
                                logger.debug(f"Normalized '{label}' -> {norm_result.qid}")
                            else:
                                stats["failed"] += 1
                                logger.warning(f"Failed to store normalization for '{label}'")
                        else:
                            stats["failed"] += 1
                            logger.debug(f"Could not normalize '{label}'")

                    except Exception as e:
                        stats["failed"] += 1
                        logger.error(f"Error normalizing '{label}': {e}")

                    # Progress callback
                    if progress_callback:
                        progress_callback(processed, stats["total_topics"])

                    # Rate limiting (Wikidata is 1 req/sec)
                    await asyncio.sleep(1.0)

        except Exception as e:
            logger.error(f"Error in Wikidata normalization: {e}")

        logger.info(
            f"Wikidata normalization complete: "
            f"{stats['normalized']}/{stats['total_topics']} normalized, "
            f"{stats['failed']} failed"
        )

        return stats

    async def close(self) -> None:
        """Cleanup resources."""
        await self._openlibrary.close()
        await self._tmdb.close()
        await self._musicbrainz.close()
