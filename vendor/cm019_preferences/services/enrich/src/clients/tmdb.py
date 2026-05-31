"""TMDB (The Movie Database) API client for movie/TV metadata."""

import logging
import re
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from .base import BaseClient, InMemoryCache
from .validation import calculate_confidence, should_accept_match, title_similarity
from ..config import settings
from ..models.enrichment import (
    MovieMetadata,
    WatchProvider,
    SimilarTitle,
    EnrichmentResult,
    EnrichmentSource,
    MatchType,
    TopicResult,
    GenreResult,
    EntityResult,
)

logger = logging.getLogger(__name__)


@dataclass
class SearchResult:
    """Wrapper for search results with metadata for confidence scoring."""
    metadata: MovieMetadata
    result_count: int


class TMDBClient(BaseClient[MovieMetadata]):
    """
    Client for TMDB (The Movie Database) API.

    API Documentation: https://developer.themoviedb.org/docs

    Features:
    - Search movies and TV shows by title
    - Get details including genres, keywords, cast, crew
    - Map genres to PWG topic ontology
    - Requires API key (env var TMDB_API_KEY)

    Rate limit: 40 requests per 10 seconds
    """

    BASE_URL = "https://api.themoviedb.org/3"
    CACHE_PREFIX = "tmdb"

    # TMDB genre ID to name mapping (for convenience)
    GENRE_MAP = {
        28: "Action",
        12: "Adventure",
        16: "Animation",
        35: "Comedy",
        80: "Crime",
        99: "Documentary",
        18: "Drama",
        10751: "Family",
        14: "Fantasy",
        36: "History",
        27: "Horror",
        10402: "Music",
        9648: "Mystery",
        10749: "Romance",
        878: "Science Fiction",
        10770: "TV Movie",
        53: "Thriller",
        10752: "War",
        37: "Western",
        # TV genres
        10759: "Action & Adventure",
        10762: "Kids",
        10763: "News",
        10764: "Reality",
        10765: "Sci-Fi & Fantasy",
        10766: "Soap",
        10767: "Talk",
        10768: "War & Politics",
    }

    def __init__(
        self,
        api_key: Optional[str] = None,
        cache: Optional[InMemoryCache] = None
    ):
        super().__init__(
            rate_limit=settings.tmdb_rate_limit,
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )
        self.api_key = api_key or settings.tmdb_api_key
        if not self.api_key:
            logger.warning(
                "TMDB API key not configured. Set TMDB_API_KEY environment variable."
            )

    def _get_headers(self):
        return {
            "Accept": "application/json",
            "User-Agent": "PWG-Enrichment/0.1.0",
        }

    async def _get(
        self,
        endpoint: str,
        params: Optional[Dict[str, Any]] = None,
        use_cache: bool = True,
        cache_key: Optional[str] = None,
    ) -> Optional[Dict[str, Any]]:
        """Override _get to add API key as query parameter (TMDB v3 API)."""
        if params is None:
            params = {}
        # Add API key to query params (TMDB v3 authentication)
        if self.api_key:
            params["api_key"] = self.api_key
        return await super()._get(endpoint, params, use_cache, cache_key)

    def _normalize_genre(self, genre: str) -> str:
        """Normalize a genre string to a topic ID."""
        # Convert to lowercase
        normalized = genre.lower().strip()

        # Check for custom mappings
        if normalized in settings.topic_mappings:
            return settings.topic_mappings[normalized]

        # Replace spaces and special characters
        normalized = re.sub(r"[^\w\s]", "", normalized)
        normalized = re.sub(r"\s+", "_", normalized)

        return normalized

    async def search(
        self,
        query: str,
        year: Optional[int] = None,
        media_type: Optional[str] = None
    ) -> Optional[SearchResult]:
        """
        Search for a movie or TV show by title.

        Args:
            query: Movie/TV title
            year: Optional release year for better matching
            media_type: "movie" or "tv" (if known)

        Returns:
            SearchResult with MovieMetadata and result count if found, None otherwise
        """
        if not self.api_key:
            logger.error("Cannot search TMDB: API key not configured")
            return None

        # Use multi-search to find both movies and TV
        params = {"query": query}
        if year:
            params["year"] = year

        result = await self._get("/search/multi", params=params)

        if not result or not result.get("results"):
            logger.debug(f"No TMDB results for: {query}")
            return None

        # Filter to movies and TV shows only
        valid_results = [
            r for r in result["results"]
            if r.get("media_type") in ("movie", "tv")
        ]

        if not valid_results:
            return None

        result_count = len(valid_results)

        # Score all results by title similarity and find best match
        scored_results = []
        for item in valid_results:
            item_title = item.get("title") or item.get("name", "")
            sim = title_similarity(query, item_title)

            # Bonus for matching media type
            if media_type and item.get("media_type") == media_type:
                sim += 0.1

            # Bonus for matching year
            item_year = None
            release_date = item.get("release_date") or item.get("first_air_date")
            if release_date and len(release_date) >= 4:
                try:
                    item_year = int(release_date[:4])
                    if year and item_year == year:
                        sim += 0.15
                except ValueError:
                    pass

            scored_results.append((item, sim))

        # Sort by score and pick best
        scored_results.sort(key=lambda x: x[1], reverse=True)
        best_match = scored_results[0][0]

        # Build metadata
        is_movie = best_match.get("media_type") == "movie"
        title = best_match.get("title") if is_movie else best_match.get("name", "")
        release_date = (
            best_match.get("release_date") if is_movie
            else best_match.get("first_air_date")
        )

        # Map genre IDs to names
        genres = [
            self.GENRE_MAP.get(gid, f"Unknown({gid})")
            for gid in best_match.get("genre_ids", [])
        ]

        metadata = MovieMetadata(
            title=title,
            media_type="movie" if is_movie else "tv",
            genres=genres,
            overview=best_match.get("overview"),
            release_date=release_date,
            tmdb_id=best_match.get("id"),
            poster_path=best_match.get("poster_path"),
            vote_average=best_match.get("vote_average"),
        )

        return SearchResult(metadata=metadata, result_count=result_count)

    async def get_details(
        self,
        tmdb_id: int,
        media_type: str = "movie",
        include_similar: bool = False,
        include_recommendations: bool = False,
        include_watch_providers: bool = False,
        watch_provider_region: str = "GB"
    ) -> Optional[MovieMetadata]:
        """
        Get detailed info for a movie or TV show by TMDB ID.

        Args:
            tmdb_id: TMDB ID
            media_type: "movie" or "tv"
            include_similar: Fetch similar titles (extra API call)
            include_recommendations: Fetch TMDB recommendations (extra API call)
            include_watch_providers: Fetch streaming availability (extra API call)
            watch_provider_region: ISO 3166-1 region code for watch providers

        Returns:
            MovieMetadata with full details including cast, keywords
        """
        if not self.api_key:
            return None

        # Build append_to_response for efficient fetching
        append_parts = ["credits", "keywords"]
        if media_type == "movie":
            append_parts.append("release_dates")  # For content ratings
        else:
            append_parts.append("content_ratings")  # For TV ratings

        # Get main details with credits, keywords, and ratings appended
        endpoint = f"/{media_type}/{tmdb_id}"
        params = {"append_to_response": ",".join(append_parts)}

        result = await self._get(endpoint, params=params)

        if not result:
            return None

        is_movie = media_type == "movie"
        title = result.get("title") if is_movie else result.get("name", "")
        release_date = (
            result.get("release_date") if is_movie
            else result.get("first_air_date")
        )

        # Extract genres
        genres = [g.get("name", "") for g in result.get("genres", [])]

        # Extract keywords
        keywords_data = result.get("keywords", {})
        keywords_list = (
            keywords_data.get("keywords", []) if is_movie
            else keywords_data.get("results", [])
        )
        keywords = [k.get("name", "") for k in keywords_list[:20]]

        # Extract cast (top 10)
        credits = result.get("credits", {})
        cast = [
            c.get("name", "")
            for c in credits.get("cast", [])[:10]
        ]

        # Find director (movies) or creators (TV)
        director = None
        if is_movie:
            for crew in credits.get("crew", []):
                if crew.get("job") == "Director":
                    director = crew.get("name")
                    break
        else:
            creators = result.get("created_by", [])
            if creators:
                director = creators[0].get("name")

        # Production companies
        companies = [
            c.get("name", "")
            for c in result.get("production_companies", [])[:5]
        ]

        # Extract runtime
        runtime = None
        if is_movie:
            runtime = result.get("runtime")
        else:
            # For TV, use average episode runtime
            episode_runtimes = result.get("episode_run_time", [])
            if episode_runtimes:
                runtime = sum(episode_runtimes) // len(episode_runtimes)

        # Extract content rating
        content_rating = None
        content_rating_desc = None
        if is_movie:
            # Movies: look in release_dates for certification
            release_dates = result.get("release_dates", {}).get("results", [])
            # Prioritize user's region, then US, then any
            for region_code in [watch_provider_region, "US", "GB"]:
                for country in release_dates:
                    if country.get("iso_3166_1") == region_code:
                        for rel in country.get("release_dates", []):
                            if rel.get("certification"):
                                content_rating = rel.get("certification")
                                content_rating_desc = rel.get("note", "")
                                break
                    if content_rating:
                        break
                if content_rating:
                    break
        else:
            # TV: look in content_ratings
            tv_ratings = result.get("content_ratings", {}).get("results", [])
            for region_code in [watch_provider_region, "US", "GB"]:
                for rating in tv_ratings:
                    if rating.get("iso_3166_1") == region_code:
                        content_rating = rating.get("rating")
                        break
                if content_rating:
                    break

        # Extract spoken languages
        spoken_languages = [
            lang.get("english_name", lang.get("name", ""))
            for lang in result.get("spoken_languages", [])
        ]

        # Build base metadata
        metadata = MovieMetadata(
            title=title,
            media_type=media_type,
            genres=genres,
            keywords=keywords,
            overview=result.get("overview"),
            release_date=release_date,
            tmdb_id=tmdb_id,
            poster_path=result.get("poster_path"),
            vote_average=result.get("vote_average"),
            vote_count=result.get("vote_count"),
            cast=cast,
            director=director,
            production_companies=companies,
            runtime=runtime,
            status=result.get("status"),
            tagline=result.get("tagline"),
            original_language=result.get("original_language"),
            spoken_languages=spoken_languages,
            imdb_id=result.get("imdb_id") if is_movie else result.get("external_ids", {}).get("imdb_id"),
            content_rating=content_rating,
            content_rating_description=content_rating_desc,
        )

        # TV-specific fields
        if not is_movie:
            metadata.episode_count = result.get("number_of_episodes")
            metadata.season_count = result.get("number_of_seasons")

        # Fetch optional data
        if include_watch_providers:
            providers = await self.get_watch_providers(tmdb_id, media_type, watch_provider_region)
            if providers:
                metadata.watch_providers_flatrate = providers.get("flatrate", [])
                metadata.watch_providers_rent = providers.get("rent", [])
                metadata.watch_providers_buy = providers.get("buy", [])

        if include_similar:
            metadata.similar_titles = await self.get_similar(tmdb_id, media_type)

        if include_recommendations:
            metadata.recommendations = await self.get_recommendations(tmdb_id, media_type)

        return metadata

    async def get_watch_providers(
        self,
        tmdb_id: int,
        media_type: str = "movie",
        region: str = "GB"
    ) -> Optional[Dict[str, List[WatchProvider]]]:
        """
        Get streaming/rental/purchase availability for a movie or TV show.

        Args:
            tmdb_id: TMDB ID
            media_type: "movie" or "tv"
            region: ISO 3166-1 region code (e.g., "GB", "US", "HK")

        Returns:
            Dict with keys 'flatrate' (subscription), 'rent', 'buy', each containing
            a list of WatchProvider objects
        """
        if not self.api_key:
            return None

        endpoint = f"/{media_type}/{tmdb_id}/watch/providers"
        result = await self._get(endpoint)

        if not result:
            return None

        # Get region-specific results
        region_data = result.get("results", {}).get(region, {})
        if not region_data:
            # Try common fallbacks
            for fallback in ["US", "GB"]:
                region_data = result.get("results", {}).get(fallback, {})
                if region_data:
                    break

        if not region_data:
            return None

        providers = {}
        for key in ["flatrate", "rent", "buy"]:
            providers[key] = [
                WatchProvider(
                    provider_id=p.get("provider_id"),
                    provider_name=p.get("provider_name", ""),
                    logo_path=p.get("logo_path"),
                    display_priority=p.get("display_priority", 0)
                )
                for p in region_data.get(key, [])
            ]

        return providers

    async def get_similar(
        self,
        tmdb_id: int,
        media_type: str = "movie",
        limit: int = 10
    ) -> List[SimilarTitle]:
        """
        Get similar movies/TV shows (based on keywords and genres).

        Args:
            tmdb_id: TMDB ID
            media_type: "movie" or "tv"
            limit: Max number of results

        Returns:
            List of SimilarTitle objects
        """
        if not self.api_key:
            return []

        endpoint = f"/{media_type}/{tmdb_id}/similar"
        result = await self._get(endpoint)

        if not result:
            return []

        similar = []
        is_movie = media_type == "movie"

        for item in result.get("results", [])[:limit]:
            title = item.get("title") if is_movie else item.get("name", "")
            release_date = (
                item.get("release_date") if is_movie
                else item.get("first_air_date")
            )
            genres = [
                self.GENRE_MAP.get(gid, f"Unknown({gid})")
                for gid in item.get("genre_ids", [])
            ]

            similar.append(SimilarTitle(
                tmdb_id=item.get("id"),
                title=title,
                media_type=media_type,
                overview=item.get("overview"),
                release_date=release_date,
                vote_average=item.get("vote_average"),
                poster_path=item.get("poster_path"),
                genres=genres
            ))

        return similar

    async def get_recommendations(
        self,
        tmdb_id: int,
        media_type: str = "movie",
        limit: int = 10
    ) -> List[SimilarTitle]:
        """
        Get TMDB recommendations (algorithmic, based on user behavior patterns).

        This is different from 'similar' - recommendations are based on what
        other users who liked this title also liked.

        Args:
            tmdb_id: TMDB ID
            media_type: "movie" or "tv"
            limit: Max number of results

        Returns:
            List of SimilarTitle objects
        """
        if not self.api_key:
            return []

        endpoint = f"/{media_type}/{tmdb_id}/recommendations"
        result = await self._get(endpoint)

        if not result:
            return []

        recommendations = []
        is_movie = media_type == "movie"

        for item in result.get("results", [])[:limit]:
            title = item.get("title") if is_movie else item.get("name", "")
            release_date = (
                item.get("release_date") if is_movie
                else item.get("first_air_date")
            )
            genres = [
                self.GENRE_MAP.get(gid, f"Unknown({gid})")
                for gid in item.get("genre_ids", [])
            ]

            recommendations.append(SimilarTitle(
                tmdb_id=item.get("id"),
                title=title,
                media_type=media_type,
                overview=item.get("overview"),
                release_date=release_date,
                vote_average=item.get("vote_average"),
                poster_path=item.get("poster_path"),
                genres=genres
            ))

        return recommendations

    async def enrich(
        self,
        preference_id: str,
        title: str,
        year: Optional[int] = None,
        media_type: Optional[str] = None,
        tmdb_id: Optional[int] = None,
        min_confidence: float = 0.5,
        include_similar: bool = True,
        include_recommendations: bool = True,
        include_watch_providers: bool = False,  # Disabled by default - fetch at query time for fresh data
        watch_provider_region: str = "GB"
    ) -> EnrichmentResult:
        """
        Enrich a movie/TV preference with genres, keywords, and cast.

        Args:
            preference_id: PWG preference ID
            title: Movie/TV title
            year: Optional release year for validation
            media_type: "movie" or "tv" if known
            tmdb_id: Optional TMDB ID for direct lookup (highest confidence)
            min_confidence: Minimum confidence to accept match

        Returns:
            EnrichmentResult with topics, genres, and entities
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=title,
            source=EnrichmentSource.TMDB,
        )

        if not self.api_key:
            result.error = "TMDB API key not configured"
            return result

        try:
            # Try direct ID lookup first (highest confidence)
            has_direct_id = False
            metadata = None
            result_count = 1

            if tmdb_id and media_type:
                metadata = await self.get_details(tmdb_id, media_type)
                if metadata:
                    has_direct_id = True
                    result_count = 1

            # Fall back to search
            if not metadata:
                search_result = await self.search(title, year, media_type)

                if not search_result:
                    result.error = f"Not found in TMDB: {title}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result

                metadata = search_result.metadata
                result_count = search_result.result_count

            # Extract year from release date for validation
            result_year = None
            if metadata.release_date and len(metadata.release_date) >= 4:
                try:
                    result_year = int(metadata.release_date[:4])
                except ValueError:
                    pass

            # Calculate confidence score
            confidence, match_type, breakdown = calculate_confidence(
                query=title,
                result_title=metadata.title,
                result_authors=None,  # Movies don't have authors
                query_author=None,
                result_year=result_year,
                preference_year=year,
                result_count=result_count,
                has_direct_id=has_direct_id
            )

            result.confidence = confidence
            result.match_type = match_type
            result.confidence_breakdown = breakdown
            result.matched_title = metadata.title
            result.exact_match = (match_type == MatchType.EXACT_TITLE)

            # Check if we should accept this match
            if not should_accept_match(confidence, match_type, min_confidence):
                result.error = f"Low confidence match ({confidence:.2f}): '{title}' -> '{metadata.title}'"
                logger.warning(
                    f"Rejecting low-confidence match for '{title}': "
                    f"matched '{metadata.title}' with confidence {confidence:.2f}"
                )
                return result

            # Get detailed info if we have an ID and didn't do direct lookup
            if metadata.tmdb_id and not has_direct_id:
                detailed = await self.get_details(
                    metadata.tmdb_id,
                    metadata.media_type,
                    include_similar=include_similar,
                    include_recommendations=include_recommendations,
                    include_watch_providers=include_watch_providers,
                    watch_provider_region=watch_provider_region
                )
                if detailed:
                    metadata = detailed
            elif has_direct_id:
                # For direct ID lookups, we already have details but may need similar/recommendations
                if include_similar:
                    metadata.similar_titles = await self.get_similar(metadata.tmdb_id, metadata.media_type)
                if include_recommendations:
                    metadata.recommendations = await self.get_recommendations(metadata.tmdb_id, metadata.media_type)
                if include_watch_providers:
                    providers = await self.get_watch_providers(metadata.tmdb_id, metadata.media_type, watch_provider_region)
                    if providers:
                        metadata.watch_providers_flatrate = providers.get("flatrate", [])
                        metadata.watch_providers_rent = providers.get("rent", [])
                        metadata.watch_providers_buy = providers.get("buy", [])

            result.movie_metadata = metadata

            # Topic confidence based on overall match confidence
            topic_confidence = min(0.95, confidence + 0.05)

            # Convert genres to both genres and topics
            for genre in metadata.genres:
                normalized = self._normalize_genre(genre)
                result.genres.append(GenreResult(
                    name=genre,
                    normalized=normalized,
                    confidence=topic_confidence
                ))
                # Genres are also topics
                result.topics.append(TopicResult(
                    name=genre,
                    normalized=normalized,
                    confidence=topic_confidence,
                    source_field="genres"
                ))

            # Convert keywords to topics
            for keyword in metadata.keywords:
                normalized = self._normalize_genre(keyword)  # Same normalization
                result.topics.append(TopicResult(
                    name=keyword,
                    normalized=normalized,
                    confidence=topic_confidence * 0.9,
                    source_field="keywords"
                ))

            # Add cast as entities
            for actor in metadata.cast[:5]:  # Top 5 cast
                result.entities.append(EntityResult(
                    name=actor,
                    entity_type="actor"
                ))

            # Add director as entity
            if metadata.director:
                result.entities.append(EntityResult(
                    name=metadata.director,
                    entity_type="director"
                ))

            # Add production companies as entities
            for company in metadata.production_companies[:3]:
                result.entities.append(EntityResult(
                    name=company,
                    entity_type="production_company"
                ))

            # Add content rating as a topic (useful for filtering)
            if metadata.content_rating:
                result.topics.append(TopicResult(
                    name=f"Rated {metadata.content_rating}",
                    normalized=f"rating_{metadata.content_rating.lower().replace('-', '_')}",
                    confidence=0.95,
                    source_field="content_rating"
                ))

            # Add runtime category as topic (helpful for "quick watch" vs "movie night")
            if metadata.runtime:
                if metadata.runtime <= 30:
                    runtime_cat = "Short (under 30 min)"
                elif metadata.runtime <= 60:
                    runtime_cat = "Medium (30-60 min)"
                elif metadata.runtime <= 120:
                    runtime_cat = "Feature length (1-2 hours)"
                else:
                    runtime_cat = "Long (over 2 hours)"
                result.topics.append(TopicResult(
                    name=runtime_cat,
                    normalized=f"runtime_{runtime_cat.split()[0].lower()}",
                    confidence=0.95,
                    source_field="runtime"
                ))

            # Add streaming availability as entities
            for provider in metadata.watch_providers_flatrate[:5]:
                result.entities.append(EntityResult(
                    name=provider.provider_name,
                    entity_type="streaming_service"
                ))

            # Log similar/recommendations count
            similar_count = len(metadata.similar_titles)
            recs_count = len(metadata.recommendations)
            streaming = ", ".join(metadata.available_on_streaming[:3]) or "none"

            logger.info(
                f"Enriched {metadata.media_type} '{title}' -> '{metadata.title}': "
                f"confidence={confidence:.2f}, match_type={match_type.value}, "
                f"{len(result.topics)} topics, {len(result.genres)} genres, "
                f"similar={similar_count}, recs={recs_count}, streaming=[{streaming}]"
            )

        except Exception as e:
            logger.error(f"Error enriching movie/TV '{title}': {e}")
            result.error = str(e)

        return result
