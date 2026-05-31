"""Wikidata API client for topic normalization.

This is the CRITICAL component for cross-platform preference intelligence.
Normalizes free-text topics to Wikidata Q-IDs so topics can be correlated
across platforms (e.g., "psychology" from Open Library and "Psychological Drama"
from TMDB both map to Q9418 or related Q-IDs).
"""

import logging
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple, TYPE_CHECKING

from .base import BaseClient, InMemoryCache
from .validation import title_similarity

if TYPE_CHECKING:
    from ..hierarchy import TopicHierarchyService

logger = logging.getLogger(__name__)

# Type alias for hierarchy storage callback
HierarchyStorageCallback = Callable[[str], None]


@dataclass
class WikidataEntity:
    """A Wikidata entity (Q-ID) with metadata."""
    qid: str  # e.g., "Q9418"
    label: str  # e.g., "psychology"
    description: Optional[str] = None
    aliases: List[str] = field(default_factory=list)

    # For topic hierarchy
    instance_of: List[str] = field(default_factory=list)  # P31 values (Q-IDs)
    subclass_of: List[str] = field(default_factory=list)  # P279 values (Q-IDs)
    part_of: List[str] = field(default_factory=list)  # P361 values (Q-IDs)

    # External identifiers
    library_of_congress_id: Optional[str] = None  # P244
    gnd_id: Optional[str] = None  # P227 (German National Library)

    @property
    def url(self) -> str:
        """Get Wikidata URL for this entity."""
        return f"https://www.wikidata.org/wiki/{self.qid}"


@dataclass
class NormalizationResult:
    """Result of normalizing a free-text topic to Wikidata."""
    original: str  # Original topic string
    qid: Optional[str] = None  # Matched Q-ID
    label: Optional[str] = None  # Canonical label from Wikidata
    description: Optional[str] = None
    confidence: float = 0.0  # Match confidence
    match_type: str = "none"  # "exact", "fuzzy", "alias", "none"
    search_results: int = 0  # Number of results returned

    # Hierarchy (populated if requested)
    broader_concepts: List[str] = field(default_factory=list)  # Parent Q-IDs

    def is_match(self) -> bool:
        """Check if normalization found a match."""
        return self.qid is not None and self.confidence >= 0.5


@dataclass
class BroaderConceptsResult:
    """Result of broader concept resolution."""
    qid: str  # Starting Q-ID
    broader: List[WikidataEntity] = field(default_factory=list)  # Parent concepts
    depth: int = 0  # How many levels were traversed


class WikidataClient(BaseClient[WikidataEntity]):
    """
    Client for Wikidata API and SPARQL endpoint.

    Normalizes topics to Wikidata Q-IDs for cross-platform correlation.

    API Documentation:
    - MediaWiki API: https://www.wikidata.org/w/api.php
    - SPARQL: https://query.wikidata.org/

    Features:
    - Search entities by label
    - Get broader/narrower concepts via P279/P31
    - Resolve topic strings to Q-IDs with confidence scoring
    - Cache mappings for performance

    Rate limit: Generous (be polite - use ~1 req/sec for batch operations)
    """

    BASE_URL = "https://www.wikidata.org/w/api.php"
    SPARQL_URL = "https://query.wikidata.org/sparql"
    CACHE_PREFIX = "wikidata"

    # Entity types for filtering (maps to Wikidata Q-IDs)
    ENTITY_TYPE_FILTERS = {
        "topic": [],  # No filter - general search
        "genre": ["Q483394", "Q188451", "Q17537576"],  # genre, music genre, film genre
        "person": ["Q5"],  # human
        "place": ["Q17334923", "Q486972"],  # location, human settlement
        "work": ["Q386724", "Q11424", "Q5398426"],  # work, film, tv series
        "organization": ["Q43229", "Q4830453"],  # organization, business
    }

    def __init__(
        self,
        cache: Optional[InMemoryCache] = None,
        hierarchy_service: Optional["TopicHierarchyService"] = None,
    ):
        """
        Initialize the Wikidata client.

        Args:
            cache: Optional cache instance
            hierarchy_service: Optional TopicHierarchyService for storing hierarchies.
                              If provided, normalize_topic() can store hierarchies automatically.
        """
        super().__init__(
            rate_limit=1.0,  # 1 req/sec (be polite)
            max_retries=3,
            timeout=30.0,
            cache=cache,
        )
        self._hierarchy_service = hierarchy_service

    def set_hierarchy_service(self, service: "TopicHierarchyService") -> None:
        """
        Set the hierarchy service for automatic storage.

        This allows the Wikidata client to automatically store topic hierarchies
        when normalize_topic() is called with store_hierarchy=True.

        Args:
            service: TopicHierarchyService instance
        """
        self._hierarchy_service = service

    def _get_headers(self) -> Dict[str, str]:
        return {
            "Accept": "application/json",
            "User-Agent": "PWG-Enrichment/0.1.0 (Personal World Graph project; topic normalization)",
        }

    async def search_entity(
        self,
        label: str,
        entity_type: Optional[str] = None,
        language: str = "en",
        limit: int = 10
    ) -> List[WikidataEntity]:
        """
        Search for a Wikidata entity by label.

        Args:
            label: Text to search for (e.g., "psychology")
            entity_type: Optional type filter ("topic", "genre", "person", "place")
            language: Language code for search (default: "en")
            limit: Maximum results to return

        Returns:
            List of WikidataEntity matches, ordered by relevance
        """
        params = {
            "action": "wbsearchentities",
            "search": label,
            "language": language,
            "format": "json",
            "limit": limit,
            "type": "item",  # Only search for items (Q-IDs), not properties (P-IDs)
        }

        result = await self._get("", params=params)

        if not result or "search" not in result:
            logger.debug(f"No Wikidata results for: {label}")
            return []

        entities = []
        for item in result["search"]:
            entity = WikidataEntity(
                qid=item.get("id", ""),
                label=item.get("label", ""),
                description=item.get("description"),
                aliases=item.get("aliases", []),
            )
            entities.append(entity)

        logger.debug(f"Wikidata search '{label}': {len(entities)} results")
        return entities

    async def get_entity(
        self,
        qid: str,
        language: str = "en"
    ) -> Optional[WikidataEntity]:
        """
        Get detailed information about a Wikidata entity.

        Args:
            qid: Wikidata Q-ID (e.g., "Q9418")
            language: Language for labels/descriptions

        Returns:
            WikidataEntity with full details, or None if not found
        """
        params = {
            "action": "wbgetentities",
            "ids": qid,
            "props": "labels|descriptions|aliases|claims",
            "languages": language,
            "format": "json",
        }

        result = await self._get("", params=params, cache_key=f"entity:{qid}")

        if not result or "entities" not in result:
            return None

        entity_data = result["entities"].get(qid)
        if not entity_data or entity_data.get("missing"):
            return None

        # Extract labels and descriptions
        labels = entity_data.get("labels", {})
        descriptions = entity_data.get("descriptions", {})
        aliases_data = entity_data.get("aliases", {})

        label = labels.get(language, {}).get("value", "")
        description = descriptions.get(language, {}).get("value")
        aliases = [a["value"] for a in aliases_data.get(language, [])]

        # Extract claims (properties)
        claims = entity_data.get("claims", {})

        # P31 - instance of
        instance_of = self._extract_qid_claims(claims.get("P31", []))

        # P279 - subclass of
        subclass_of = self._extract_qid_claims(claims.get("P279", []))

        # P361 - part of
        part_of = self._extract_qid_claims(claims.get("P361", []))

        # P244 - Library of Congress authority ID
        loc_id = self._extract_string_claim(claims.get("P244", []))

        # P227 - GND ID
        gnd_id = self._extract_string_claim(claims.get("P227", []))

        return WikidataEntity(
            qid=qid,
            label=label,
            description=description,
            aliases=aliases,
            instance_of=instance_of,
            subclass_of=subclass_of,
            part_of=part_of,
            library_of_congress_id=loc_id,
            gnd_id=gnd_id,
        )

    def _extract_qid_claims(self, claims: List[Dict]) -> List[str]:
        """Extract Q-IDs from claim values."""
        qids = []
        for claim in claims:
            mainsnak = claim.get("mainsnak", {})
            datavalue = mainsnak.get("datavalue", {})
            if datavalue.get("type") == "wikibase-entityid":
                value = datavalue.get("value", {})
                if "id" in value:
                    qids.append(value["id"])
        return qids

    def _extract_string_claim(self, claims: List[Dict]) -> Optional[str]:
        """Extract first string value from claims."""
        for claim in claims:
            mainsnak = claim.get("mainsnak", {})
            datavalue = mainsnak.get("datavalue", {})
            if datavalue.get("type") == "string":
                return datavalue.get("value")
        return None

    async def get_broader_concepts(
        self,
        qid: str,
        depth: int = 2,
        language: str = "en"
    ) -> BroaderConceptsResult:
        """
        Get parent concepts via P279 (subclass of) and P31 (instance of).

        Uses SPARQL for efficient hierarchy traversal.

        Args:
            qid: Starting Q-ID
            depth: How many levels up to traverse (1-5)
            language: Language for labels

        Returns:
            BroaderConceptsResult with parent concepts
        """
        depth = min(max(depth, 1), 5)  # Clamp to 1-5

        # SPARQL query to get broader concepts
        # Using property path with * for variable depth traversal
        query = f"""
        SELECT DISTINCT ?broader ?broaderLabel WHERE {{
          wd:{qid} wdt:P279* ?mid .
          ?mid (wdt:P279|wdt:P31) ?broader .
          SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{language},en" . }}
        }}
        LIMIT 50
        """

        result = await self._sparql_query(query)

        broader_entities = []
        if result and "results" in result:
            bindings = result["results"].get("bindings", [])
            for binding in bindings:
                broader_uri = binding.get("broader", {}).get("value", "")
                label = binding.get("broaderLabel", {}).get("value", "")

                # Extract Q-ID from URI
                if "entity/" in broader_uri:
                    broader_qid = broader_uri.split("/")[-1]
                    if broader_qid.startswith("Q"):
                        broader_entities.append(WikidataEntity(
                            qid=broader_qid,
                            label=label,
                        ))

        return BroaderConceptsResult(
            qid=qid,
            broader=broader_entities,
            depth=depth,
        )

    async def _sparql_query(self, query: str) -> Optional[Dict[str, Any]]:
        """
        Execute a SPARQL query against the Wikidata endpoint.

        Args:
            query: SPARQL query string

        Returns:
            JSON response or None on error
        """
        import httpx

        # Wait for rate limiter
        async with self.rate_limiter:
            try:
                async with httpx.AsyncClient(timeout=self.timeout) as client:
                    self._request_count += 1

                    response = await client.get(
                        self.SPARQL_URL,
                        params={"query": query, "format": "json"},
                        headers={
                            "Accept": "application/sparql-results+json",
                            "User-Agent": self._get_headers()["User-Agent"],
                        },
                    )

                    if response.status_code == 429:
                        # Rate limited - wait and indicate failure
                        logger.warning("SPARQL endpoint rate limited")
                        return None

                    if response.status_code >= 400:
                        logger.error(f"SPARQL error {response.status_code}: {response.text[:200]}")
                        self._errors += 1
                        return None

                    return response.json()

            except Exception as e:
                logger.error(f"SPARQL query error: {e}")
                self._errors += 1
                return None

    async def normalize_topic(
        self,
        topic: str,
        entity_type: Optional[str] = None,
        include_hierarchy: bool = False,
        store_hierarchy: bool = False,
        hierarchy_depth: int = 2,
        min_confidence: float = 0.5
    ) -> NormalizationResult:
        """
        Map a free-text topic to a Wikidata Q-ID with confidence scoring.

        This is the main entry point for topic normalization.

        Args:
            topic: Free-text topic string (e.g., "psychology", "machine learning")
            entity_type: Optional type filter ("topic", "genre", "person", "place")
            include_hierarchy: If True, also fetch broader concepts in result
            store_hierarchy: If True and hierarchy_service is set, store the topic
                            hierarchy to Oxigraph for cross-platform queries
            hierarchy_depth: How many levels to traverse when storing (1-5)
            min_confidence: Minimum confidence to accept match

        Returns:
            NormalizationResult with Q-ID and confidence
        """
        result = NormalizationResult(original=topic)

        # Normalize the input
        normalized_topic = self._normalize_for_search(topic)

        if not normalized_topic:
            logger.debug(f"Empty topic after normalization: {topic}")
            return result

        # Search for entities
        entities = await self.search_entity(
            normalized_topic,
            entity_type=entity_type,
            limit=10
        )

        result.search_results = len(entities)

        if not entities:
            logger.debug(f"No Wikidata results for topic: {topic}")
            return result

        # Score each result
        best_match = None
        best_score = 0.0
        best_match_type = "none"

        for entity in entities:
            score, match_type = self._calculate_match_score(
                normalized_topic, entity
            )

            if score > best_score:
                best_score = score
                best_match = entity
                best_match_type = match_type

        if best_match and best_score >= min_confidence:
            result.qid = best_match.qid
            result.label = best_match.label
            result.description = best_match.description
            result.confidence = best_score
            result.match_type = best_match_type

            # Optionally fetch hierarchy for result
            if include_hierarchy:
                hierarchy = await self.get_broader_concepts(best_match.qid, depth=hierarchy_depth)
                result.broader_concepts = [e.qid for e in hierarchy.broader]

            # Optionally store hierarchy to Oxigraph
            if store_hierarchy and self._hierarchy_service:
                try:
                    storage_result = await self._hierarchy_service.store_topic_hierarchy(
                        best_match.qid,
                        depth=hierarchy_depth,
                        skip_if_exists=True,
                    )
                    if storage_result.success:
                        logger.debug(
                            f"Stored hierarchy for {best_match.qid}: "
                            f"{storage_result.parent_count} parents"
                        )
                    elif storage_result.error not in ("already_stored_session", "already_stored_db"):
                        logger.warning(
                            f"Failed to store hierarchy for {best_match.qid}: "
                            f"{storage_result.error}"
                        )
                except Exception as e:
                    logger.warning(f"Error storing hierarchy for {best_match.qid}: {e}")
            elif store_hierarchy and not self._hierarchy_service:
                logger.warning(
                    "store_hierarchy=True but no hierarchy_service configured. "
                    "Use set_hierarchy_service() or pass hierarchy_service to __init__"
                )

            logger.info(
                f"Normalized '{topic}' -> {best_match.qid} ({best_match.label}) "
                f"confidence={best_score:.2f}, match_type={best_match_type}"
            )
        else:
            logger.debug(
                f"No confident match for '{topic}': "
                f"best score {best_score:.2f} < threshold {min_confidence}"
            )

        return result

    def _normalize_for_search(self, text: str) -> str:
        """Normalize text for Wikidata search."""
        if not text:
            return ""

        # Lowercase
        normalized = text.lower().strip()

        # Remove common prefixes
        prefixes = ["the ", "a ", "an "]
        for prefix in prefixes:
            if normalized.startswith(prefix):
                normalized = normalized[len(prefix):]

        # Remove extra whitespace
        normalized = re.sub(r"\s+", " ", normalized).strip()

        return normalized

    def _calculate_match_score(
        self,
        query: str,
        entity: WikidataEntity
    ) -> Tuple[float, str]:
        """
        Calculate match score between query and entity.

        Returns:
            Tuple of (score, match_type)
        """
        query_norm = self._normalize_for_search(query)
        label_norm = self._normalize_for_search(entity.label)

        # Exact match
        if query_norm == label_norm:
            return 0.95, "exact"

        # Check aliases
        for alias in entity.aliases:
            alias_norm = self._normalize_for_search(alias)
            if query_norm == alias_norm:
                return 0.90, "alias"

        # Fuzzy match on label
        label_sim = title_similarity(query, entity.label)

        if label_sim >= 0.85:
            return min(0.88, label_sim * 0.95), "fuzzy"

        # Check fuzzy on aliases
        best_alias_sim = 0.0
        for alias in entity.aliases:
            alias_sim = title_similarity(query, alias)
            best_alias_sim = max(best_alias_sim, alias_sim)

        if best_alias_sim >= 0.85:
            return min(0.85, best_alias_sim * 0.9), "fuzzy_alias"

        # Lower confidence for weaker matches
        combined = max(label_sim, best_alias_sim)
        if combined >= 0.6:
            return combined * 0.75, "weak"

        return combined * 0.5, "guess"

    async def batch_normalize(
        self,
        topics: List[str],
        min_confidence: float = 0.5
    ) -> Dict[str, NormalizationResult]:
        """
        Normalize a batch of topics to Wikidata Q-IDs.

        Args:
            topics: List of topic strings
            min_confidence: Minimum confidence threshold

        Returns:
            Dict mapping original topic to NormalizationResult
        """
        results = {}

        for topic in topics:
            result = await self.normalize_topic(
                topic,
                min_confidence=min_confidence
            )
            results[topic] = result

        # Log summary
        matched = sum(1 for r in results.values() if r.is_match())
        logger.info(
            f"Batch normalized {len(topics)} topics: "
            f"{matched} matched ({matched/max(1, len(topics))*100:.1f}%)"
        )

        return results

    async def get_related_topics(
        self,
        qid: str,
        language: str = "en"
    ) -> List[WikidataEntity]:
        """
        Get related topics for cross-domain linking.

        Uses SPARQL to find entities that are:
        - In the same class hierarchy
        - Share common broader concepts

        Args:
            qid: Starting Q-ID
            language: Language for labels

        Returns:
            List of related WikidataEntity objects
        """
        # SPARQL to find related entities via shared parents or siblings
        query = f"""
        SELECT DISTINCT ?related ?relatedLabel WHERE {{
          # Get siblings (same parent class)
          {{
            wd:{qid} wdt:P279 ?parent .
            ?related wdt:P279 ?parent .
            FILTER(?related != wd:{qid})
          }}
          UNION
          # Get siblings (same instance type)
          {{
            wd:{qid} wdt:P31 ?type .
            ?related wdt:P31 ?type .
            FILTER(?related != wd:{qid})
          }}
          SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{language},en" . }}
        }}
        LIMIT 20
        """

        result = await self._sparql_query(query)

        related = []
        if result and "results" in result:
            bindings = result["results"].get("bindings", [])
            for binding in bindings:
                uri = binding.get("related", {}).get("value", "")
                label = binding.get("relatedLabel", {}).get("value", "")

                if "entity/" in uri:
                    related_qid = uri.split("/")[-1]
                    if related_qid.startswith("Q"):
                        related.append(WikidataEntity(
                            qid=related_qid,
                            label=label,
                        ))

        return related

    # Required abstract method implementations
    async def search(self, query: str) -> Optional[WikidataEntity]:
        """Search for an entity by query string."""
        entities = await self.search_entity(query)
        return entities[0] if entities else None

    async def get_details(self, item_id: str) -> Optional[WikidataEntity]:
        """Get entity details by Q-ID."""
        return await self.get_entity(item_id)
