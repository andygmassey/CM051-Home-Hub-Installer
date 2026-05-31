"""MusicBrainz API client for music metadata."""

import logging
import re
from dataclasses import dataclass
from typing import List, Optional

from .base import BaseClient, InMemoryCache
from .validation import calculate_confidence, should_accept_match, title_similarity
from ..config import settings
from ..models.enrichment import (
    MusicMetadata,
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
    metadata: MusicMetadata
    result_count: int


class MusicBrainzClient(BaseClient[MusicMetadata]):
    """
    Client for MusicBrainz API.

    API Documentation: https://musicbrainz.org/doc/MusicBrainz_API

    Features:
    - Search by artist, track (recording), or album (release)
    - Get tags and genres
    - No API key required
    - STRICT rate limit: 1 request per second
    - MUST set User-Agent header

    Note: MusicBrainz uses community-contributed tags instead of
    formal genres. Tags are weighted by vote count.
    """

    BASE_URL = "https://musicbrainz.org/ws/2"
    CACHE_PREFIX = "musicbrainz"

    # Tag blocklist (low-value or technical tags)
    TAG_BLOCKLIST = {
        "seen live",
        "my favorite",
        "favourite",
        "favorites",
        "check out",
        "todo",
        "to check",
        "needs editing",
        "fix me",
        "stub",
        "under construction",
    }

    def __init__(self, cache: Optional[InMemoryCache] = None):
        super().__init__(
            rate_limit=settings.musicbrainz_rate_limit,  # 1 req/sec (strict)
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )

    def _get_headers(self):
        return {
            "Accept": "application/json",
            "User-Agent": settings.musicbrainz_user_agent,
        }

    def _normalize_tag(self, tag: str) -> str:
        """Normalize a tag string to a topic ID."""
        # Convert to lowercase
        normalized = tag.lower().strip()

        # Check for custom mappings
        if normalized in settings.topic_mappings:
            return settings.topic_mappings[normalized]

        # Replace spaces and special characters
        normalized = re.sub(r"[^\w\s]", "", normalized)
        normalized = re.sub(r"\s+", "_", normalized)

        return normalized

    def _normalize_track_title(self, title: str) -> str:
        """
        Normalize track title by removing common suffixes that MusicBrainz might not have.

        Examples:
            "Your Latest Trick (Remastered 1996)" -> "Your Latest Trick"
            "Bohemian Rhapsody - Remastered 2011" -> "Bohemian Rhapsody"
            "Highway to Hell (Live)" -> "Highway to Hell"
        """
        if not title:
            return title

        # Patterns to remove (in order of specificity)
        patterns = [
            r'\s*[\(\[]?\s*remaster(?:ed)?\s*\d{4}\s*[\)\]]?\s*$',  # (Remastered 1996)
            r'\s*-\s*remaster(?:ed)?\s*\d{4}\s*$',  # - Remastered 1996
            r'\s*[\(\[]\s*\d{4}\s+(?:mix|version|remaster)\s*[\)\]]\s*$',  # (2011 Mix)
            r'\s*[\(\[]\s*(?:live|single version|radio edit|extended|album version|bonus track|original|stereo)\s*[\)\]]\s*$',
            r'\s*[\(\[]\s*\d{4}\s*(?:digital\s*)?remaster\s*[\)\]]\s*$',
            r'\s*[\(\[]?\s*feat\.?\s+[^)\]]+[\)\]]?\s*$',  # (feat. Someone)
            r'\s*[\(\[]\s*from\s+[^)\]]+[\)\]]\s*$',  # (from Album Name)
        ]

        normalized = title.strip()
        for pattern in patterns:
            normalized = re.sub(pattern, '', normalized, flags=re.IGNORECASE).strip()

        return normalized

    def _filter_tags(self, tags: List[dict]) -> List[str]:
        """
        Filter and sort tags by vote count.

        Args:
            tags: List of tag dicts with 'name' and 'count' keys

        Returns:
            List of tag names, sorted by relevance
        """
        filtered = []
        seen = set()

        # Sort by count (descending)
        sorted_tags = sorted(tags, key=lambda t: t.get("count", 0), reverse=True)

        for tag in sorted_tags:
            name = tag.get("name", "").strip()
            lower = name.lower()

            # Skip blocklisted
            if lower in self.TAG_BLOCKLIST:
                continue

            # Skip duplicates
            if lower in seen:
                continue

            # Skip very short tags
            if len(lower) < 2:
                continue

            # Skip tags with very low votes (likely noise)
            if tag.get("count", 0) < 1:
                continue

            seen.add(lower)
            filtered.append(name)

        return filtered[:15]  # Limit to top 15 tags

    async def search_artist(self, name: str) -> Optional[SearchResult]:
        """
        Search for an artist by name.

        Args:
            name: Artist name

        Returns:
            SearchResult with MusicMetadata and result count if found, None otherwise
        """
        params = {
            "query": f'artist:"{name}"',
            "fmt": "json",
            "limit": 10,  # Get more results for confidence scoring
        }

        result = await self._get("/artist", params=params)

        if not result or not result.get("artists"):
            logger.debug(f"No MusicBrainz results for artist: {name}")
            return None

        artists = result["artists"]
        result_count = len(artists)

        # Score all results by name similarity and find best match
        scored_results = []
        for artist in artists:
            artist_name = artist.get("name", "")
            sim = title_similarity(name, artist_name)
            scored_results.append((artist, sim))

        # Sort by score and pick best
        scored_results.sort(key=lambda x: x[1], reverse=True)
        best_match = scored_results[0][0]

        metadata = MusicMetadata(
            name=best_match.get("name", name),
            entity_type="artist",
            tags=[],  # Tags require separate lookup with ?inc=tags
            country=best_match.get("country"),
            begin_date=best_match.get("life-span", {}).get("begin"),
            end_date=best_match.get("life-span", {}).get("end"),
            musicbrainz_id=best_match.get("id"),
            disambiguation=best_match.get("disambiguation"),
        )

        return SearchResult(metadata=metadata, result_count=result_count)

    async def search_recording(
        self,
        track: str,
        artist: Optional[str] = None
    ) -> Optional[SearchResult]:
        """
        Search for a recording (track) by title and optionally artist.

        Args:
            track: Track/song title
            artist: Optional artist name for better matching

        Returns:
            SearchResult with MusicMetadata and result count if found, None otherwise
        """
        # Build query
        query = f'recording:"{track}"'
        if artist:
            query += f' AND artist:"{artist}"'

        params = {
            "query": query,
            "fmt": "json",
            "limit": 10,  # Get more results for confidence scoring
        }

        result = await self._get("/recording", params=params)

        if not result or not result.get("recordings"):
            logger.debug(f"No MusicBrainz results for recording: {track}")
            return None

        recordings = result["recordings"]
        result_count = len(recordings)

        # Score all results by title similarity (and artist if provided)
        # Also use MusicBrainz's native score as a tiebreaker
        scored_results = []
        for recording in recordings:
            rec_title = recording.get("title", "")
            sim = title_similarity(track, rec_title)

            # Bonus for artist match
            if artist:
                artist_credits = recording.get("artist-credit", [])
                if artist_credits:
                    rec_artist = artist_credits[0].get("name", "")
                    artist_sim = title_similarity(artist, rec_artist)
                    sim = (sim * 0.6) + (artist_sim * 0.4)

            # Use MusicBrainz score as tiebreaker (normalized to 0-0.1 range)
            mb_score = recording.get("score", 0) / 1000.0
            combined_score = sim + mb_score

            scored_results.append((recording, combined_score))

        # Sort by score and pick best
        scored_results.sort(key=lambda x: x[1], reverse=True)
        best_match = scored_results[0][0]

        # Extract artist from first artist-credit
        recording_artist = None
        artist_credits = best_match.get("artist-credit", [])
        if artist_credits:
            recording_artist = artist_credits[0].get("name")

        metadata = MusicMetadata(
            name=best_match.get("title", track),
            entity_type="recording",
            tags=[],  # Tags require separate lookup
            musicbrainz_id=best_match.get("id"),
            disambiguation=best_match.get("disambiguation"),
            related_artists=[recording_artist] if recording_artist else [],
        )

        return SearchResult(metadata=metadata, result_count=result_count)

    def _extract_wikidata_id(self, relations: list) -> Optional[str]:
        """
        Extract Wikidata Q-ID from MusicBrainz url-rels.

        Args:
            relations: List of relation dicts from MusicBrainz API

        Returns:
            Wikidata Q-ID (e.g., "Q44190") or None if not found
        """
        for rel in relations:
            if rel.get("type") == "wikidata":
                url = rel.get("url", {}).get("resource", "")
                if "wikidata.org" in url:
                    # URL format: https://www.wikidata.org/wiki/Q44190
                    wikidata_id = url.split("/")[-1]
                    if wikidata_id.startswith("Q"):
                        return wikidata_id
        return None

    async def get_details(
        self,
        mbid: str,
        entity_type: str = "artist"
    ) -> Optional[MusicMetadata]:
        """
        Get detailed info for an entity by MusicBrainz ID.

        Args:
            mbid: MusicBrainz ID (UUID)
            entity_type: "artist", "recording", or "release"

        Returns:
            MusicMetadata with tags/genres and Wikidata ID if available
        """
        # Get entity with tags and URL relations (for Wikidata link)
        endpoint = f"/{entity_type}/{mbid}"
        params = {"inc": "tags+url-rels", "fmt": "json"}

        result = await self._get(endpoint, params=params)

        if not result:
            return None

        # Extract tags
        tags = self._filter_tags(result.get("tags", []))

        # Extract Wikidata ID from URL relations
        wikidata_id = self._extract_wikidata_id(result.get("relations", []))

        # Build metadata based on entity type
        if entity_type == "artist":
            return MusicMetadata(
                name=result.get("name", ""),
                entity_type="artist",
                tags=tags,
                genres=[t for t in tags if self._is_genre_tag(t)],
                country=result.get("country"),
                begin_date=result.get("life-span", {}).get("begin"),
                end_date=result.get("life-span", {}).get("end"),
                musicbrainz_id=mbid,
                disambiguation=result.get("disambiguation"),
                wikidata_id=wikidata_id,
            )
        elif entity_type == "recording":
            return MusicMetadata(
                name=result.get("title", ""),
                entity_type="recording",
                tags=tags,
                genres=[t for t in tags if self._is_genre_tag(t)],
                musicbrainz_id=mbid,
                disambiguation=result.get("disambiguation"),
                wikidata_id=wikidata_id,
            )
        else:  # release
            return MusicMetadata(
                name=result.get("title", ""),
                entity_type="release",
                tags=tags,
                genres=[t for t in tags if self._is_genre_tag(t)],
                musicbrainz_id=mbid,
                wikidata_id=wikidata_id,
            )

    def _is_genre_tag(self, tag: str) -> bool:
        """Check if a tag is likely a genre."""
        genre_keywords = {
            "rock", "pop", "jazz", "blues", "electronic", "classical",
            "hip hop", "rap", "country", "folk", "metal", "punk",
            "indie", "alternative", "soul", "r&b", "funk", "disco",
            "reggae", "ska", "house", "techno", "ambient", "experimental",
        }

        lower = tag.lower()

        # Check if tag contains any genre keyword
        for keyword in genre_keywords:
            if keyword in lower:
                return True

        return False

    async def search(self, query: str) -> Optional[MusicMetadata]:
        """
        Generic search - defaults to artist search.

        Args:
            query: Search query (typically artist name)

        Returns:
            MusicMetadata if found
        """
        return await self.search_artist(query)

    async def enrich_artist(
        self,
        preference_id: str,
        artist_name: str,
        musicbrainz_id: Optional[str] = None,
        min_confidence: float = 0.5
    ) -> EnrichmentResult:
        """
        Enrich an artist preference with genres and tags.

        Args:
            preference_id: PWG preference ID
            artist_name: Artist name
            musicbrainz_id: Optional MusicBrainz ID for direct lookup
            min_confidence: Minimum confidence to accept match

        Returns:
            EnrichmentResult with topics and genres
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=artist_name,
            source=EnrichmentSource.MUSICBRAINZ,
        )

        try:
            # Try direct ID lookup first
            has_direct_id = False
            metadata = None
            result_count = 1

            if musicbrainz_id:
                metadata = await self.get_details(musicbrainz_id, "artist")
                if metadata:
                    has_direct_id = True
                    result_count = 1

            # Fall back to search
            if not metadata:
                search_result = await self.search_artist(artist_name)

                if not search_result:
                    result.error = f"Artist not found: {artist_name}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result

                metadata = search_result.metadata
                result_count = search_result.result_count

            # Calculate confidence score
            confidence, match_type, breakdown = calculate_confidence(
                query=artist_name,
                result_title=metadata.name,
                result_authors=None,
                query_author=None,
                result_year=None,
                preference_year=None,
                result_count=result_count,
                has_direct_id=has_direct_id
            )

            result.confidence = confidence
            result.match_type = match_type
            result.confidence_breakdown = breakdown
            result.matched_title = metadata.name
            result.exact_match = (match_type == MatchType.EXACT_TITLE)

            # Check if we should accept this match
            if not should_accept_match(confidence, match_type, min_confidence):
                result.error = f"Low confidence match ({confidence:.2f}): '{artist_name}' -> '{metadata.name}'"
                logger.warning(
                    f"Rejecting low-confidence match for '{artist_name}': "
                    f"matched '{metadata.name}' with confidence {confidence:.2f}"
                )
                return result

            # Get detailed info with tags if we don't already have them
            if metadata.musicbrainz_id and not metadata.tags:
                detailed = await self.get_details(metadata.musicbrainz_id, "artist")
                if detailed:
                    metadata = detailed

            result.music_metadata = metadata

            # Topic confidence based on overall match confidence
            topic_confidence = min(0.95, confidence + 0.05)

            # Convert tags to topics
            for tag in metadata.tags:
                normalized = self._normalize_tag(tag)
                result.topics.append(TopicResult(
                    name=tag,
                    normalized=normalized,
                    confidence=topic_confidence * 0.9,
                    source_field="tags"
                ))

            # Extract genres from tags
            for tag in metadata.genres:
                normalized = self._normalize_tag(tag)
                result.genres.append(GenreResult(
                    name=tag,
                    normalized=normalized,
                    confidence=topic_confidence
                ))

            # Add artist as entity
            result.entities.append(EntityResult(
                name=metadata.name,
                entity_type="artist",
                external_id=metadata.musicbrainz_id
            ))

            # Add country as topic if present
            if metadata.country:
                result.topics.append(TopicResult(
                    name=f"{metadata.country} music",
                    normalized=f"{metadata.country.lower()}_music",
                    confidence=topic_confidence * 0.8,
                    source_field="country"
                ))

            wikidata_info = f", wikidata={metadata.wikidata_id}" if metadata.wikidata_id else ""
            logger.info(
                f"Enriched artist '{artist_name}' -> '{metadata.name}': "
                f"confidence={confidence:.2f}, match_type={match_type.value}, "
                f"{len(result.topics)} topics, {len(result.genres)} genres{wikidata_info}"
            )

        except Exception as e:
            logger.error(f"Error enriching artist '{artist_name}': {e}")
            result.error = str(e)

        return result

    async def enrich_track(
        self,
        preference_id: str,
        track_name: str,
        artist_name: Optional[str] = None,
        musicbrainz_id: Optional[str] = None,
        min_confidence: float = 0.5
    ) -> EnrichmentResult:
        """
        Enrich a track preference with genres and tags.

        Args:
            preference_id: PWG preference ID
            track_name: Track/song name
            artist_name: Optional artist name for validation
            musicbrainz_id: Optional MusicBrainz ID for direct lookup
            min_confidence: Minimum confidence to accept match

        Returns:
            EnrichmentResult with topics and genres
        """
        original_subject = f"{artist_name} - {track_name}" if artist_name else track_name
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=original_subject,
            source=EnrichmentSource.MUSICBRAINZ,
        )

        try:
            # Try direct ID lookup first
            has_direct_id = False
            metadata = None
            result_count = 1

            if musicbrainz_id:
                metadata = await self.get_details(musicbrainz_id, "recording")
                if metadata:
                    has_direct_id = True
                    result_count = 1

            # Fall back to search
            if not metadata:
                # Normalize track name by removing common suffixes
                normalized_track = self._normalize_track_title(track_name)
                search_result = await self.search_recording(normalized_track, artist_name)

                # If normalized search failed, try original (in case the parenthetical is part of the title)
                if not search_result and normalized_track != track_name:
                    logger.debug(f"Trying original track title: {track_name}")
                    search_result = await self.search_recording(track_name, artist_name)

                if not search_result:
                    # Fall back to artist enrichment if track not found
                    if artist_name:
                        logger.debug(f"Track not found, falling back to artist: {artist_name}")
                        return await self.enrich_artist(preference_id, artist_name)

                    result.error = f"Track not found: {track_name}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result

                metadata = search_result.metadata
                result_count = search_result.result_count

            # Calculate confidence score
            # For tracks, we also consider artist match
            confidence, match_type, breakdown = calculate_confidence(
                query=track_name,
                result_title=metadata.name,
                result_authors=metadata.related_artists if metadata.related_artists else None,
                query_author=artist_name,
                result_year=None,
                preference_year=None,
                result_count=result_count,
                has_direct_id=has_direct_id
            )

            result.confidence = confidence
            result.match_type = match_type
            result.confidence_breakdown = breakdown
            result.matched_title = metadata.name
            result.exact_match = (match_type == MatchType.EXACT_TITLE)

            # Check if we should accept this match
            if not should_accept_match(confidence, match_type, min_confidence):
                # Fall back to artist if track match is low confidence
                if artist_name:
                    logger.debug(
                        f"Low confidence track match ({confidence:.2f}), "
                        f"falling back to artist: {artist_name}"
                    )
                    return await self.enrich_artist(preference_id, artist_name)

                result.error = f"Low confidence match ({confidence:.2f}): '{track_name}' -> '{metadata.name}'"
                return result

            # Get detailed info with tags if not already present
            # Preserve related_artists from search since get_details doesn't return it
            original_related_artists = metadata.related_artists
            if metadata.musicbrainz_id and not metadata.tags:
                detailed = await self.get_details(metadata.musicbrainz_id, "recording")
                if detailed:
                    metadata = detailed
                    # Restore related_artists from original search result
                    metadata.related_artists = original_related_artists

            result.music_metadata = metadata

            # Topic confidence based on overall match confidence
            topic_confidence = min(0.95, confidence + 0.05)

            # Convert recording-level tags to topics
            recording_tags = set()
            for tag in metadata.tags:
                normalized = self._normalize_tag(tag)
                recording_tags.add(normalized)
                result.topics.append(TopicResult(
                    name=tag,
                    normalized=normalized,
                    confidence=topic_confidence * 0.85,
                    source_field="recording_tags"
                ))

            # Extract recording-level genres
            recording_genres = set()
            for tag in metadata.genres:
                normalized = self._normalize_tag(tag)
                recording_genres.add(normalized)
                result.genres.append(GenreResult(
                    name=tag,
                    normalized=normalized,
                    confidence=topic_confidence * 0.9
                ))

            # ENHANCEMENT: Also fetch artist-level tags (much more reliably populated)
            # This significantly improves genre/topic coverage for tracks
            artist_to_lookup = artist_name or (metadata.related_artists[0] if metadata.related_artists else None)
            logger.info(f"[ARTIST-LOOKUP] artist_name={artist_name}, related_artists={metadata.related_artists}, will_lookup={artist_to_lookup}")
            if artist_to_lookup:
                try:
                    artist_search = await self.search_artist(artist_to_lookup)
                    logger.debug(f"Artist search result: {artist_search.metadata.name if artist_search else 'None'}, mbid={artist_search.metadata.musicbrainz_id if artist_search else 'None'}")
                    if artist_search and artist_search.metadata.musicbrainz_id:
                        artist_details = await self.get_details(
                            artist_search.metadata.musicbrainz_id, "artist"
                        )
                        if artist_details:
                            # Add artist tags (with slightly lower confidence since they're artist-level)
                            logger.info(f"Artist '{artist_details.name}' has {len(artist_details.tags)} tags, {len(artist_details.genres)} genres")
                            for tag in artist_details.tags:
                                normalized = self._normalize_tag(tag)
                                # Skip if already have this tag from recording
                                if normalized not in recording_tags:
                                    recording_tags.add(normalized)
                                    result.topics.append(TopicResult(
                                        name=tag,
                                        normalized=normalized,
                                        confidence=topic_confidence * 0.75,  # Lower confidence for artist-level
                                        source_field="artist_tags"
                                    ))

                            # Add artist genres
                            for tag in artist_details.genres:
                                normalized = self._normalize_tag(tag)
                                if normalized not in recording_genres:
                                    recording_genres.add(normalized)
                                    result.genres.append(GenreResult(
                                        name=tag,
                                        normalized=normalized,
                                        confidence=topic_confidence * 0.8  # Lower confidence for artist-level
                                    ))

                            # Capture artist's Wikidata ID if available
                            if artist_details.wikidata_id and not metadata.wikidata_id:
                                metadata.wikidata_id = artist_details.wikidata_id
                except Exception as e:
                    logger.debug(f"Could not fetch artist tags for '{artist_to_lookup}': {e}")

            # Add related artists as entities
            for related in metadata.related_artists:
                result.entities.append(EntityResult(
                    name=related,
                    entity_type="artist"
                ))

            logger.info(
                f"Enriched track '{track_name}' -> '{metadata.name}': "
                f"confidence={confidence:.2f}, match_type={match_type.value}, "
                f"{len(result.topics)} topics, {len(result.genres)} genres"
            )

        except Exception as e:
            logger.error(f"Error enriching track '{track_name}': {e}")
            result.error = str(e)

        return result

    async def enrich(
        self,
        preference_id: str,
        subject: str,
        subject_type: str = "artist"
    ) -> EnrichmentResult:
        """
        Enrich a music preference.

        Args:
            preference_id: PWG preference ID
            subject: Artist or track name
            subject_type: "artist" or "track"

        Returns:
            EnrichmentResult
        """
        if subject_type == "track":
            # Try to parse "Artist - Track" format
            if " - " in subject:
                parts = subject.split(" - ", 1)
                part1, part2 = parts[0].strip(), parts[1].strip()

                # Detect if format is "Track - Album" instead of "Artist - Track"
                # Album indicators: full words/phrases that indicate an album name
                # Use word boundary matching to avoid false positives like "Remastered 1996"
                import re
                album_patterns = [
                    r'\balbum\b', r'\bedition\b', r'\bgreatest hits\b', r'\bhits\b',
                    r'\bcollection\b', r'\bcompilation\b', r'\bdeluxe\b',
                    r'\banniversary\b', r'\bsoundtrack\b', r'\bost\b',
                    r'\boriginal cast\b', r'\b\d+th anniversary\b',
                    r'\bbest of\b', r'\bthe very best\b', r'\bessential\b',
                    r'\bplatinum\b', r'\bgold\b', r'\blegacy\b', r'\bultimate\b',
                    r'\bcomplete\b', r'\bdefinitive\b', r'\banthology\b',
                    r'\bremaster', r'\b\d{4} remaster',  # Remastered albums
                    r'\bsingles\b', r'\brare\b', r'\blive at\b', r'\bunplugged\b',
                ]
                # Also check if it looks like "Album Name" (title case with multiple words)
                # e.g., "ABBA: The Album", "Gold: Greatest Hits"
                part2_lower = part2.lower()
                is_part2_album = any(re.search(pat, part2_lower) for pat in album_patterns)
                # Additional check: if part2 contains a colon followed by album-like text
                if not is_part2_album and ':' in part2:
                    after_colon = part2.split(':', 1)[1].strip().lower()
                    is_part2_album = any(re.search(pat, after_colon) for pat in album_patterns)

                if is_part2_album:
                    # Format is "Track - Album", so part1 is the track name
                    # No artist info available from subject
                    logger.debug(
                        f"Detected 'Track - Album' format: '{part1}' - '{part2}'"
                    )
                    return await self.enrich_track(preference_id, part1)

                # Check if part1 looks like a track title (has feat., remaster, remix, etc.)
                track_indicators = [
                    r'\(feat\.', r'\[feat\.', r'feat\.',
                    r'\(ft\.', r'\[ft\.', r'ft\.',
                    r'\(remaster', r'\[remaster', r'remaster',
                    r'\(remix', r'\[remix',
                    r'\(live', r'\[live',
                    r'\(radio', r'\[radio',
                    r'\(acoustic', r'\[acoustic',
                    r'\(extended', r'\[extended',
                    r'\(original', r'\[original',
                    r'\(club', r'\[club',
                    r'\(edit\)', r'\[edit\]',
                ]
                part1_lower = part1.lower()
                is_part1_track = any(re.search(pat, part1_lower) for pat in track_indicators)

                if is_part1_track:
                    # Format is "Track - Artist", so part1 is the track, part2 is the artist
                    logger.debug(
                        f"Detected 'Track - Artist' format: track='{part1}', artist='{part2}'"
                    )
                    return await self.enrich_track(preference_id, part1, part2)
                else:
                    # Standard "Artist - Track" format
                    return await self.enrich_track(preference_id, part2, part1)

            return await self.enrich_track(preference_id, subject)
        else:
            return await self.enrich_artist(preference_id, subject)
