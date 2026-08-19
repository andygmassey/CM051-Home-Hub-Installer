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
            "User-Agent": "Ostler/1.0 (+https://ostler.ai)",
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

    # ── Films, television and places, without an API key ────────────────
    #
    # WHY THESE LIVE HERE, measured 2026-08-17.
    #
    # `movie`, `movie_tv`, `tv`, `tv_show` dispatched to TMDB and `place`,
    # `venue`, `restaurant` to Google Places. We ship neither key, so on a
    # real install 24 films failed in 0.2 seconds and 84 places were never
    # attempted. 284 preferences that can never succeed, retried on every
    # future run.
    #
    # Wikidata answers the same questions with no credential: genre (P136),
    # director (P57), cast (P161) for a film; type, country and admin area
    # for a place. It is a smaller answer than TMDB gives, and it is an
    # answer, which is the whole of the difference.
    #
    # The transport/absence distinction from #805 is honoured throughout:
    # a source we could not REACH establishes nothing and must stay
    # eligible for a later run, so it returns UNAVAILABLE rather than NONE.

    FILM_TYPES = frozenset({
        "Q11424",     # film
        "Q5398426",   # television series
        "Q506240",    # television film
        "Q24856",     # film series
        "Q1259759",   # miniseries
        "Q29168811",  # animated feature film
        "Q93204",     # documentary film
        "Q21191270",  # television series episode
        "Q7725310",   # television series season
    })

    async def _fetch_types(self, qids: List[str]) -> Dict[str, set]:
        """
        What KIND of thing is each candidate? One cheap round trip.

        Types are fetched separately from details on purpose. The first
        version of this asked for types and genres and cast and directors
        in one query with OPTIONAL blocks, which returns their CROSS
        PRODUCT, then bounded it with LIMIT 400. On a candidate list headed
        by something well-connected the first entity alone can fill 400
        rows, and every later candidate then looks like it has no type at
        all. That is a silent truncation wearing the costume of an absence,
        and it is how "Hitchhiker's Guide" came back as "no film or
        programme named that" while Wikidata holds several.

        One property, no OPTIONALs, no cap needed.
        """
        if not qids:
            return {}
        values = " ".join("wd:%s" % q for q in qids)
        query = """
        SELECT ?item ?type WHERE {
          VALUES ?item { %s }
          ?item wdt:P31 ?type .
        }
        """ % values
        result = await self._sparql_query(query)
        if not result or "results" not in result:
            return {}
        out: Dict[str, set] = {}
        for b in result["results"].get("bindings", []):
            qid = b.get("item", {}).get("value", "").rsplit("/", 1)[-1]
            t = b.get("type", {}).get("value", "").rsplit("/", 1)[-1]
            if qid.startswith("Q") and t.startswith("Q"):
                out.setdefault(qid, set()).add(t)
        return out

    # property -> the bucket its values land in. One place, so adding a
    # property is one line and cannot drift from the parser.
    DETAIL_PROPS = {
        "P136": "genres",     "P57":  "directors", "P161": "cast",
        "P58":  "writers",    "P86":  "composers", "P162": "producers",
        "P144": "based_on",   "P495": "origin",
        "P17":  "country",    "P131": "admin",
    }

    async def _fetch_detail(self, qid: str) -> Dict[str, Any]:
        """
        Every property of interest for ONE entity, in ONE linear query.

        NOT a query with eleven OPTIONAL blocks. That returns their CROSS
        PRODUCT: for "Breaking Bad", with dozens of episode directors and
        an unbounded cast and five genres, the response reached 76 MB and
        failed to parse, so the show came back with NOTHING. Adding
        properties made the answer smaller, which is the signature of a
        combinatorial blow-up rather than a missing fact.

        Iterating a VALUES list of properties instead returns one row per
        (property, value) pair. Linear in the number of values, and it
        cannot explode however well-connected the entity is.
        """
        props = " ".join("wdt:%s" % p for p in self.DETAIL_PROPS)
        query = """
        SELECT ?p ?vLabel WHERE {
          VALUES ?p { %s }
          wd:%s ?p ?v .
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        }
        """ % (props, qid)

        rec: Dict[str, Any] = {k: set() for k in set(self.DETAIL_PROPS.values())}
        rec["year"] = None
        result = await self._sparql_query(query)

        # The label service does not always resolve every entity in one
        # query; when it cannot, it echoes the bare Q-ID back.
        #
        # DROPPING those was the previous behaviour and it was WRONG. For
        # "The Hitchhiker's Guide to the Galaxy" the screenwriters come back
        # as "Karey Kirkpatrick" and "Q42", and Q42 is DOUGLAS ADAMS. A
        # guard written to avoid showing "Q12345" on a page was quietly
        # deleting the person most associated with the work.
        #
        # So unresolved Q-IDs are COLLECTED and looked up, not discarded.
        # Showing a raw Q-ID is still never acceptable, and anything that
        # survives both passes unresolved is dropped at the end.
        unresolved = []   # (bucket, qid)
        for b in ((result or {}).get("results", {}) or {}).get("bindings", []):
            pid = b.get("p", {}).get("value", "").rsplit("/", 1)[-1]
            bucket = self.DETAIL_PROPS.get(pid)
            v = b.get("vLabel", {}).get("value")
            if not (bucket and v):
                continue
            if re.fullmatch(r"Q\d+", v):
                unresolved.append((bucket, v))
            else:
                rec[bucket].add(v)

        if unresolved:
            values = " ".join("wd:%s" % q for _, q in dict.fromkeys(
                (b, q) for b, q in unresolved))
            # LANGUAGE TAGS: "en" IS NOT ENOUGH, and this is why Douglas
            # Adams was missing.
            #
            # Wikidata has been migrating personal names to the `mul`
            # (multilingual) language code, because a name spelled the same
            # way in every Latin-script language does not need one label per
            # language. Q42's rdfs:label set contains "Douglas Adams", but
            # NOT tagged en: filtering LANG(?label) = "en" returns nothing
            # for him while returning fine for Karey Kirkpatrick.
            #
            # So an English-only filter silently drops exactly the people
            # whose names Wikidata has tidied up. Accept en, mul and en-gb,
            # and prefer them in that order.
            label_q = """
            SELECT ?item ?label WHERE {
              VALUES ?item { %s }
              ?item rdfs:label ?label .
              FILTER(LANG(?label) IN ("en", "mul", "en-gb"))
            }
            """ % values
            resolved = {}
            lr = await self._sparql_query(label_q)
            PREF = {"en": 0, "en-gb": 1, "mul": 2}
            best = {}
            for b in ((lr or {}).get("results", {}) or {}).get("bindings", []):
                q = b.get("item", {}).get("value", "").rsplit("/", 1)[-1]
                lab = b.get("label", {}).get("value")
                lang = b.get("label", {}).get("xml:lang", "")
                if not (q and lab):
                    continue
                rank = PREF.get(lang, 9)
                if q not in best or rank < best[q][0]:
                    best[q] = (rank, lab)
            resolved = {q: lab for q, (_, lab) in best.items()}
            for bucket, q in unresolved:
                if q in resolved:
                    rec[bucket].add(resolved[q])
                else:
                    logger.debug("Wikidata %s has no English label; dropped", q)

        # Publication date separately: it is single-valued in practice and
        # keeping it out of the loop above avoids re-deriving a year from
        # every one of a series' release dates.
        year_q = """
        SELECT (MIN(YEAR(?d)) AS ?year) WHERE { wd:%s wdt:P577 ?d . }
        """ % qid
        yr = await self._sparql_query(year_q)
        for b in ((yr or {}).get("results", {}) or {}).get("bindings", []):
            if b.get("year", {}).get("value"):
                rec["year"] = b["year"]["value"]

        # country/admin are single-valued downstream; collapse to a scalar.
        for k in ("country", "admin"):
            vals = sorted(rec[k])
            rec[k] = vals[0] if vals else None
        return rec

    def _unavailable(self, result, what: str):
        """Mark a result as 'could not reach', which is not an absence."""
        from ..models.enrichment import MatchType
        result.error = (
            "Could not reach Wikidata to look up %s. "
            "This is NOT a statement about it." % what
        )
        result.confidence = 0.0
        result.match_type = MatchType.UNAVAILABLE
        return result

    async def enrich_film(
        self,
        preference_id: str,
        title: str,
        year: Optional[int] = None,
    ):
        """Genre, director and cast for a film or television title."""
        from ..models.enrichment import (
            EnrichmentResult, EnrichmentSource, MatchType,
            GenreResult, EntityResult, TopicResult,
        )

        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=title,
            source=EnrichmentSource.WIKIDATA,
        )

        # limit=10, and the 5 it used to be was a defect I introduced.
        # For "The Hitchhiker's Guide to the Galaxy" Wikidata ranks the
        # novel, the radio series, the franchise, the video game and a
        # concept above the film; the film is SIXTH and the TV series
        # EIGHTH. At 5 this returned "no film or programme named that"
        # about a title with two. A cap that produces a false absence is
        # the same defect as the LIMIT in the query above, one layer up.
        candidates = await self.search_entity(title, limit=10)
        if not candidates:
            if getattr(self, "_last_transport_failure", None):
                return self._unavailable(result, "%r" % title)
            result.error = "No Wikidata entity for: %s" % title
            result.match_type = MatchType.NONE
            return result

        types = await self._fetch_types([c.qid for c in candidates])
        if not types and getattr(self, "_last_transport_failure", None):
            return self._unavailable(result, "%r" % title)

        # First candidate that is actually a film or programme. Search
        # ranking alone is not enough: "Chef" is a film AND an occupation,
        # and the occupation frequently ranks first.
        chosen = None
        for cand in candidates:
            if types.get(cand.qid, set()) & self.FILM_TYPES:
                chosen = (cand, await self._fetch_detail(cand.qid))
                break

        if chosen is None:
            result.error = "Wikidata has no film or programme named: %s" % title
            result.match_type = MatchType.NONE
            return result

        cand, rec = chosen
        sim = title_similarity(title, cand.label or "")
        if sim < 0.6:
            result.error = (
                "Best Wikidata film match for %r was %r, too far to trust"
                % (title, cand.label)
            )
            result.match_type = MatchType.NONE
            return result

        result.matched_title = cand.label
        result.confidence = round(sim, 3)
        result.match_type = (
            MatchType.EXACT_TITLE if sim >= 0.95 else MatchType.FUZZY_TITLE
        )
        result.genres = [
            GenreResult(name=g, normalized=g.lower().replace(" ", "_"), confidence=sim)
            for g in sorted(rec["genres"])
        ]
        # Bounded deliberately. A long-running series has dozens of episode
        # directors and an unbounded cast, and the value here is the SHAPE
        # of what someone watches, not a complete credit roll. Writers and
        # composers are few, so they are not capped: capping them is how
        # Douglas Adams would fall off a two-writer film.
        people = []
        for field_name, kind, cap in (("directors", "director", 8),
                                      ("writers", "writer", None),
                                      ("composers", "composer", None),
                                      ("producers", "producer", 6),
                                      ("cast", "actor", 12)):
            vals = sorted(rec[field_name])
            for v in (vals[:cap] if cap else vals):
                people.append(EntityResult(name=v, entity_type=kind))
        result.entities = people

        # The work it adapts, and where it was made. `year` was computed by
        # the previous version and then never attached to anything, which
        # is its own small defect: data fetched, paid for and discarded.
        result.topics = [
            TopicResult(name=v, normalized=v.lower().replace(" ", "_"),
                        confidence=sim, source_field=field_name)
            for field_name, values in (("based_on", sorted(rec["based_on"])),
                                       ("country_of_origin", sorted(rec["origin"])))
            for v in values
        ]
        if rec["year"]:
            result.topics.append(TopicResult(
                name=str(rec["year"]), normalized="year_%s" % rec["year"],
                confidence=sim, source_field="release_year",
            ))
        return result

    async def enrich_place(self, preference_id: str, name: str):
        """Type, country and administrative area for a place or venue."""
        from ..models.enrichment import (
            EnrichmentResult, EnrichmentSource, MatchType,
            TopicResult, EntityResult,
        )

        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=name,
            source=EnrichmentSource.WIKIDATA,
        )

        candidates = await self.search_entity(name, entity_type="place", limit=10)
        if not candidates:
            if getattr(self, "_last_transport_failure", None):
                return self._unavailable(result, "%r" % name)
            result.error = "No Wikidata entity for: %s" % name
            result.match_type = MatchType.NONE
            return result

        # A place is anything Wikidata situates: it has a country or an
        # administrative area. Enumerating place TYPES would be a losing
        # game (restaurant, cafe, hotel, park, borough, hamlet ...), and
        # "is it located somewhere" is the property that actually matters.
        chosen = None
        reached = False
        for cand in candidates:
            rec = await self._fetch_detail(cand.qid)
            reached = True
            if rec["country"] or rec["admin"]:
                chosen = (cand, rec)
                break

        if not reached and getattr(self, "_last_transport_failure", None):
            return self._unavailable(result, "%r" % name)

        if chosen is None:
            result.error = "Wikidata has no located entity named: %s" % name
            result.match_type = MatchType.NONE
            return result

        cand, rec = chosen
        sim = title_similarity(name, cand.label or "")
        if sim < 0.6:
            result.error = (
                "Best Wikidata place match for %r was %r, too far to trust"
                % (name, cand.label)
            )
            result.match_type = MatchType.NONE
            return result

        result.matched_title = cand.label
        result.confidence = round(sim, 3)
        result.match_type = (
            MatchType.EXACT_TITLE if sim >= 0.95 else MatchType.FUZZY_TITLE
        )
        result.topics = [
            TopicResult(
                name=v,
                normalized=v.lower().replace(" ", "_"),
                confidence=sim,
                source_field=field_name,
            )
            for field_name, v in (("country", rec["country"]), ("admin_area", rec["admin"]))
            if v
        ]
        result.entities = [EntityResult(
            name=cand.label, entity_type="place", external_id=cand.qid,
        )]
        return result

    # Required abstract method implementations
    async def search(self, query: str) -> Optional[WikidataEntity]:
        """Search for an entity by query string."""
        entities = await self.search_entity(query)
        return entities[0] if entities else None

    async def get_details(self, item_id: str) -> Optional[WikidataEntity]:
        """Get entity details by Q-ID."""
        return await self.get_entity(item_id)
