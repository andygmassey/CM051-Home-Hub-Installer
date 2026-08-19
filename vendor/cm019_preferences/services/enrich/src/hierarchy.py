"""Topic hierarchy storage service.

Persists Wikidata P279 (subclass of) and P31 (instance of) relationships
in Oxigraph to enable cross-platform topic queries like:
"Show me everything related to social sciences"

This transforms isolated topic strings into a connected knowledge graph.
"""

import asyncio
import logging
from dataclasses import dataclass, field
from datetime import datetime
from typing import List, Optional, Set

import httpx

from .config import settings
from .clients.wikidata import WikidataClient, WikidataEntity, BroaderConceptsResult

logger = logging.getLogger(__name__)


# RDF Prefixes for Turtle serialization
RDF_PREFIXES = """
@prefix wd: <http://www.wikidata.org/entity/> .
@prefix wdt: <http://www.wikidata.org/prop/direct/> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
@prefix pwg: <http://pwg.local/ontology#> .

"""


@dataclass
class HierarchyStorageResult:
    """Result of storing a topic hierarchy."""
    qid: str
    label: str
    stored_at: datetime = field(default_factory=datetime.utcnow)
    parent_count: int = 0
    triples_stored: int = 0
    success: bool = False
    error: Optional[str] = None

    def __str__(self) -> str:
        status = "OK" if self.success else f"FAILED: {self.error}"
        return f"{self.qid} ({self.label}): {self.parent_count} parents, {status}"


@dataclass
class BatchStorageStats:
    """Statistics for batch hierarchy storage."""
    started_at: datetime = field(default_factory=datetime.utcnow)
    completed_at: Optional[datetime] = None

    total_processed: int = 0
    successful: int = 0
    failed: int = 0
    skipped_already_stored: int = 0

    total_parents_discovered: int = 0
    total_triples_stored: int = 0

    errors: List[str] = field(default_factory=list)

    def summary(self) -> str:
        duration = (
            (self.completed_at or datetime.utcnow()) - self.started_at
        ).total_seconds()

        return (
            f"Hierarchy Storage Stats:\n"
            f"  Duration: {duration:.1f}s\n"
            f"  Total processed: {self.total_processed}\n"
            f"  Successful: {self.successful}\n"
            f"  Failed: {self.failed}\n"
            f"  Already stored: {self.skipped_already_stored}\n"
            f"  Parents discovered: {self.total_parents_discovered}\n"
            f"  Triples stored: {self.total_triples_stored}"
        )


@dataclass
class RelatedTopicsResult:
    """Result of querying related topics from stored hierarchy."""
    qid: str
    label: Optional[str] = None

    # Direct relationships
    subclass_of: List[WikidataEntity] = field(default_factory=list)  # P279
    instance_of: List[WikidataEntity] = field(default_factory=list)  # P31

    # Broader concepts (transitive P279*)
    broader_concepts: List[WikidataEntity] = field(default_factory=list)

    # Narrower concepts (things that have this as P279)
    narrower_concepts: List[WikidataEntity] = field(default_factory=list)

    # Siblings (same parent)
    siblings: List[WikidataEntity] = field(default_factory=list)

    def all_related_qids(self) -> Set[str]:
        """Get all related Q-IDs as a set."""
        qids = {self.qid}
        for entity in self.subclass_of + self.instance_of + self.broader_concepts + self.narrower_concepts + self.siblings:
            qids.add(entity.qid)
        return qids


class TopicHierarchyService:
    """
    Service for storing and querying Wikidata topic hierarchies in Oxigraph.

    This enables cross-platform preference queries like:
    - "Show me everything related to psychology" (includes books, movies, music)
    - "What are my interests in social sciences?" (aggregates across domains)

    RDF Structure stored:
    ```turtle
    wd:Q9418 rdfs:label "psychology" .
    wd:Q9418 wdt:P279 wd:Q34749 .  # subclass of: social science
    wd:Q9418 wdt:P31 wd:Q2465832 .  # instance of: academic discipline
    wd:Q34749 rdfs:label "social science" .
    ```

    Usage:
        service = TopicHierarchyService()

        # Store hierarchy for a single topic
        result = await service.store_topic_hierarchy("Q9418")

        # Store hierarchies in batch
        stats = await service.batch_store_hierarchies(["Q9418", "Q2539", "Q11660"])

        # Query stored hierarchy
        related = await service.get_related_topics("Q9418")
        print(f"Broader concepts: {[e.label for e in related.broader_concepts]}")
    """

    # Named graph for hierarchy data
    HIERARCHY_GRAPH = "http://pwg.local/graph/hierarchy"

    def __init__(
        self,
        wikidata_client: Optional[WikidataClient] = None,
        oxigraph_url: Optional[str] = None,
    ):
        """
        Initialize the hierarchy service.

        Args:
            wikidata_client: Optional WikidataClient instance (creates one if not provided)
            oxigraph_url: Optional Oxigraph URL (uses settings if not provided)
        """
        self._wikidata = wikidata_client or WikidataClient()
        self._oxigraph_url = oxigraph_url or settings.oxigraph_url

        # Track which Q-IDs we've already stored (in-memory for current session)
        self._stored_qids: Set[str] = set()

    async def store_topic_hierarchy(
        self,
        qid: str,
        depth: int = 2,
        skip_if_exists: bool = True,
    ) -> HierarchyStorageResult:
        """
        Fetch and store P279/P31 relationships for a topic.

        Args:
            qid: Wikidata Q-ID (e.g., "Q9418" for psychology)
            depth: How many levels up to traverse (1-5)
            skip_if_exists: If True, skip topics already stored

        Returns:
            HierarchyStorageResult with storage details
        """
        result = HierarchyStorageResult(qid=qid, label="")

        # Validate Q-ID format
        if not qid or not qid.startswith("Q"):
            result.error = f"Invalid Q-ID format: {qid}"
            return result

        # Check if already stored
        if skip_if_exists:
            if qid in self._stored_qids:
                result.success = True
                result.error = "already_stored_session"
                return result

            if await self._is_hierarchy_stored(qid):
                self._stored_qids.add(qid)
                result.success = True
                result.error = "already_stored_db"
                return result

        try:
            # Get entity details
            entity = await self._wikidata.get_entity(qid)
            if not entity:
                result.error = f"Entity not found: {qid}"
                return result

            result.label = entity.label

            # Get broader concepts via SPARQL
            hierarchy = await self._wikidata.get_broader_concepts(qid, depth=depth)

            # Build RDF triples
            triples = self._build_hierarchy_triples(entity, hierarchy)
            result.parent_count = len(hierarchy.broader)
            result.triples_stored = len(triples)

            if triples:
                # Store to Oxigraph
                turtle_doc = RDF_PREFIXES + "\n".join(triples)
                success = await self._store_triples(turtle_doc)

                if success:
                    self._stored_qids.add(qid)
                    result.success = True
                    logger.info(f"Stored hierarchy for {qid} ({entity.label}): {len(triples)} triples")
                else:
                    result.error = "Failed to store triples in Oxigraph"
            else:
                # No hierarchy to store (leaf node)
                result.success = True
                self._stored_qids.add(qid)
                logger.debug(f"No hierarchy to store for {qid} ({entity.label})")

        except Exception as e:
            result.error = str(e)
            logger.error(f"Error storing hierarchy for {qid}: {e}")

        return result

    def _build_hierarchy_triples(
        self,
        entity: WikidataEntity,
        hierarchy: BroaderConceptsResult,
    ) -> List[str]:
        """
        Build RDF triples for an entity and its hierarchy.

        Args:
            entity: The main WikidataEntity
            hierarchy: BroaderConceptsResult from get_broader_concepts

        Returns:
            List of Turtle triple strings (without prefixes)
        """
        triples = []

        # Add label for main entity
        if entity.label:
            escaped_label = entity.label.replace('"', '\\"')
            triples.append(f'wd:{entity.qid} rdfs:label "{escaped_label}" .')

        # Add description if available
        if entity.description:
            escaped_desc = entity.description.replace('"', '\\"')
            triples.append(f'wd:{entity.qid} rdfs:comment "{escaped_desc}" .')

        # Add direct P31 (instance of) relationships
        for instance_qid in entity.instance_of:
            triples.append(f'wd:{entity.qid} wdt:P31 wd:{instance_qid} .')

        # Add direct P279 (subclass of) relationships
        for subclass_qid in entity.subclass_of:
            triples.append(f'wd:{entity.qid} wdt:P279 wd:{subclass_qid} .')

        # Add broader concepts with their labels
        for broader in hierarchy.broader:
            if broader.label:
                escaped_label = broader.label.replace('"', '\\"')
                triples.append(f'wd:{broader.qid} rdfs:label "{escaped_label}" .')

            # Mark the transitive relationship for query optimization
            triples.append(f'wd:{entity.qid} pwg:broaderConcept wd:{broader.qid} .')

        # Add timestamp
        now = datetime.utcnow().isoformat()
        triples.append(f'wd:{entity.qid} pwg:hierarchyStoredAt "{now}"^^xsd:dateTime .')

        return triples

    async def _store_triples(self, turtle_doc: str) -> bool:
        """
        Store Turtle document to Oxigraph.

        Args:
            turtle_doc: Complete Turtle document with prefixes

        Returns:
            True if successful
        """
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                # Store to the hierarchy named graph
                url = f"{self._oxigraph_url}/store?graph={self.HIERARCHY_GRAPH}"

                response = await client.post(
                    url,
                    content=turtle_doc,
                    headers={"Content-Type": "text/turtle"}
                )

                if response.status_code in (200, 201, 204):
                    return True
                else:
                    logger.error(f"Oxigraph store failed: {response.status_code} - {response.text}")
                    return False

        except Exception as e:
            logger.error(f"Error storing triples: {e}")
            return False

    async def _is_hierarchy_stored(self, qid: str) -> bool:
        """
        Check if hierarchy for a Q-ID is already stored in Oxigraph.

        Args:
            qid: Wikidata Q-ID

        Returns:
            True if hierarchy exists
        """
        sparql = f"""
        ASK WHERE {{
            GRAPH <{self.HIERARCHY_GRAPH}> {{
                wd:{qid} pwg:hierarchyStoredAt ?date .
            }}
        }}
        """

        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.post(
                    f"{self._oxigraph_url}/query",
                    content=sparql,
                    headers={
                        "Content-Type": "application/sparql-query",
                        "Accept": "application/sparql-results+json"
                    }
                )

                if response.status_code == 200:
                    result = response.json()
                    return result.get("boolean", False)

        except Exception as e:
            logger.debug(f"Error checking hierarchy existence: {e}")

        return False

    async def get_related_topics(self, qid: str) -> RelatedTopicsResult:
        """
        Retrieve stored hierarchy relationships for a topic.

        Args:
            qid: Wikidata Q-ID

        Returns:
            RelatedTopicsResult with all related topics from stored hierarchy
        """
        result = RelatedTopicsResult(qid=qid)

        # Query for the label
        label_query = f"""
        PREFIX wd: <http://www.wikidata.org/entity/>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

        SELECT ?label WHERE {{
            GRAPH <{self.HIERARCHY_GRAPH}> {{
                wd:{qid} rdfs:label ?label .
            }}
        }}
        LIMIT 1
        """

        label_result = await self._execute_query(label_query)
        if label_result:
            bindings = label_result.get("results", {}).get("bindings", [])
            if bindings:
                result.label = bindings[0].get("label", {}).get("value")

        # Query for direct P279 (subclass of)
        subclass_query = f"""
        PREFIX wd: <http://www.wikidata.org/entity/>
        PREFIX wdt: <http://www.wikidata.org/prop/direct/>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

        SELECT ?parent ?parentLabel WHERE {{
            GRAPH <{self.HIERARCHY_GRAPH}> {{
                wd:{qid} wdt:P279 ?parent .
                OPTIONAL {{ ?parent rdfs:label ?parentLabel . }}
            }}
        }}
        """

        result.subclass_of = await self._parse_entity_results(subclass_query, "parent", "parentLabel")

        # Query for direct P31 (instance of)
        instance_query = f"""
        PREFIX wd: <http://www.wikidata.org/entity/>
        PREFIX wdt: <http://www.wikidata.org/prop/direct/>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

        SELECT ?type ?typeLabel WHERE {{
            GRAPH <{self.HIERARCHY_GRAPH}> {{
                wd:{qid} wdt:P31 ?type .
                OPTIONAL {{ ?type rdfs:label ?typeLabel . }}
            }}
        }}
        """

        result.instance_of = await self._parse_entity_results(instance_query, "type", "typeLabel")

        # Query for all broader concepts (transitive)
        broader_query = f"""
        PREFIX wd: <http://www.wikidata.org/entity/>
        PREFIX pwg: <http://pwg.local/ontology#>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

        SELECT DISTINCT ?broader ?broaderLabel WHERE {{
            GRAPH <{self.HIERARCHY_GRAPH}> {{
                wd:{qid} pwg:broaderConcept ?broader .
                OPTIONAL {{ ?broader rdfs:label ?broaderLabel . }}
            }}
        }}
        """

        result.broader_concepts = await self._parse_entity_results(broader_query, "broader", "broaderLabel")

        # Query for narrower concepts (things that are subclass of this)
        narrower_query = f"""
        PREFIX wd: <http://www.wikidata.org/entity/>
        PREFIX wdt: <http://www.wikidata.org/prop/direct/>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

        SELECT DISTINCT ?child ?childLabel WHERE {{
            GRAPH <{self.HIERARCHY_GRAPH}> {{
                ?child wdt:P279 wd:{qid} .
                OPTIONAL {{ ?child rdfs:label ?childLabel . }}
            }}
        }}
        LIMIT 50
        """

        result.narrower_concepts = await self._parse_entity_results(narrower_query, "child", "childLabel")

        # Query for siblings (same direct parent)
        siblings_query = f"""
        PREFIX wd: <http://www.wikidata.org/entity/>
        PREFIX wdt: <http://www.wikidata.org/prop/direct/>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

        SELECT DISTINCT ?sibling ?siblingLabel WHERE {{
            GRAPH <{self.HIERARCHY_GRAPH}> {{
                wd:{qid} wdt:P279 ?parent .
                ?sibling wdt:P279 ?parent .
                FILTER(?sibling != wd:{qid})
                OPTIONAL {{ ?sibling rdfs:label ?siblingLabel . }}
            }}
        }}
        LIMIT 20
        """

        result.siblings = await self._parse_entity_results(siblings_query, "sibling", "siblingLabel")

        return result

    async def _execute_query(self, sparql: str) -> Optional[dict]:
        """Execute a SPARQL query against Oxigraph."""
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(
                    f"{self._oxigraph_url}/query",
                    content=sparql,
                    headers={
                        "Content-Type": "application/sparql-query",
                        "Accept": "application/sparql-results+json"
                    }
                )

                if response.status_code == 200:
                    return response.json()
                else:
                    logger.error(f"SPARQL query failed: {response.status_code}")
                    return None

        except Exception as e:
            logger.error(f"Error executing query: {e}")
            return None

    async def _parse_entity_results(
        self,
        query: str,
        qid_var: str,
        label_var: str,
    ) -> List[WikidataEntity]:
        """
        Execute query and parse results into WikidataEntity list.

        Args:
            query: SPARQL query
            qid_var: Variable name for Q-ID URI
            label_var: Variable name for label

        Returns:
            List of WikidataEntity objects
        """
        entities = []

        result = await self._execute_query(query)
        if not result:
            return entities

        bindings = result.get("results", {}).get("bindings", [])

        for binding in bindings:
            uri = binding.get(qid_var, {}).get("value", "")
            label = binding.get(label_var, {}).get("value", "")

            # Extract Q-ID from URI
            if "entity/" in uri:
                entity_qid = uri.split("/")[-1]
                if entity_qid.startswith("Q"):
                    entities.append(WikidataEntity(
                        qid=entity_qid,
                        label=label or entity_qid,
                    ))

        return entities

    async def batch_store_hierarchies(
        self,
        qids: List[str],
        depth: int = 2,
        skip_if_exists: bool = True,
        progress_callback: Optional[callable] = None,
    ) -> BatchStorageStats:
        """
        Store hierarchies for multiple Q-IDs.

        Args:
            qids: List of Wikidata Q-IDs
            depth: How many levels up to traverse
            skip_if_exists: Skip topics already stored
            progress_callback: Optional callback(processed, total)

        Returns:
            BatchStorageStats with summary
        """
        stats = BatchStorageStats()

        logger.info(f"Batch storing hierarchies for {len(qids)} topics (depth={depth})")

        for i, qid in enumerate(qids):
            stats.total_processed += 1

            # Store hierarchy
            result = await self.store_topic_hierarchy(
                qid,
                depth=depth,
                skip_if_exists=skip_if_exists,
            )

            if result.success:
                if result.error in ("already_stored_session", "already_stored_db"):
                    stats.skipped_already_stored += 1
                else:
                    stats.successful += 1
                    stats.total_parents_discovered += result.parent_count
                    stats.total_triples_stored += result.triples_stored
            else:
                stats.failed += 1
                if len(stats.errors) < 100:
                    stats.errors.append(f"{qid}: {result.error}")

            # Progress callback
            if progress_callback:
                progress_callback(i + 1, len(qids))

            # Small delay between requests to be polite
            if i < len(qids) - 1:
                await asyncio.sleep(0.5)

        stats.completed_at = datetime.utcnow()
        logger.info(stats.summary())

        return stats

    async def find_preferences_by_broader_concept(
        self,
        qid: str,
        limit: int = 100,
    ) -> List[dict]:
        """
        Find all preferences related to a topic or its narrower concepts.

        This is the key query for cross-platform preference intelligence.

        Args:
            qid: Wikidata Q-ID of the broader concept (e.g., Q34749 for "social science")
            limit: Maximum results

        Returns:
            List of preference metadata dicts

        Example:
            # Find everything related to "social science"
            prefs = await service.find_preferences_by_broader_concept("Q34749")
            # Returns: psychology books, economics podcasts, sociology videos, etc.
        """
        # This query joins the hierarchy graph with the main preferences graph
        sparql = f"""
        PREFIX wd: <http://www.wikidata.org/entity/>
        PREFIX pwg: <http://pwg.local/ontology#>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

        SELECT DISTINCT ?pref ?name ?category ?platform ?topic ?topicLabel WHERE {{
            # Find topics that have the target as a broader concept
            GRAPH <{self.HIERARCHY_GRAPH}> {{
                ?topic pwg:broaderConcept wd:{qid} .
                OPTIONAL {{ ?topic rdfs:label ?topicLabel . }}
            }}

            # Find preferences linked to those topics
            ?pref pwg:hasWikidataTopic ?topic .
            ?pref pwg:name ?name .
            OPTIONAL {{ ?pref pwg:category ?category . }}
            OPTIONAL {{ ?pref pwg:platform ?platform . }}
        }}
        LIMIT {limit}
        """

        result = await self._execute_query(sparql)
        if not result:
            return []

        preferences = []
        bindings = result.get("results", {}).get("bindings", [])

        for binding in bindings:
            pref_uri = binding.get("pref", {}).get("value", "")
            pref_id = pref_uri.split(":")[-1] if ":" in pref_uri else pref_uri

            topic_uri = binding.get("topic", {}).get("value", "")
            topic_qid = topic_uri.split("/")[-1] if "/" in topic_uri else ""

            preferences.append({
                "id": pref_id,
                "name": binding.get("name", {}).get("value", ""),
                "category": binding.get("category", {}).get("value", ""),
                "platform": binding.get("platform", {}).get("value", ""),
                "topic_qid": topic_qid,
                "topic_label": binding.get("topicLabel", {}).get("value", ""),
            })

        return preferences

    async def get_hierarchy_stats(self) -> dict:
        """
        Get statistics about stored hierarchies.

        Returns:
            Dict with counts and metrics
        """
        stats = {
            "total_topics": 0,
            "total_relationships": 0,
            "topics_with_hierarchy": 0,
            "average_parents_per_topic": 0.0,
        }

        # Count topics with stored hierarchy
        count_query = f"""
        PREFIX pwg: <http://pwg.local/ontology#>

        SELECT (COUNT(DISTINCT ?topic) as ?count) WHERE {{
            GRAPH <{self.HIERARCHY_GRAPH}> {{
                ?topic pwg:hierarchyStoredAt ?date .
            }}
        }}
        """

        result = await self._execute_query(count_query)
        if result:
            bindings = result.get("results", {}).get("bindings", [])
            if bindings:
                stats["topics_with_hierarchy"] = int(bindings[0].get("count", {}).get("value", 0))

        # Count total broader concept relationships
        rel_query = f"""
        PREFIX pwg: <http://pwg.local/ontology#>

        SELECT (COUNT(*) as ?count) WHERE {{
            GRAPH <{self.HIERARCHY_GRAPH}> {{
                ?topic pwg:broaderConcept ?broader .
            }}
        }}
        """

        result = await self._execute_query(rel_query)
        if result:
            bindings = result.get("results", {}).get("bindings", [])
            if bindings:
                stats["total_relationships"] = int(bindings[0].get("count", {}).get("value", 0))

        # Calculate average
        if stats["topics_with_hierarchy"] > 0:
            stats["average_parents_per_topic"] = (
                stats["total_relationships"] / stats["topics_with_hierarchy"]
            )

        return stats

    async def close(self) -> None:
        """Cleanup resources."""
        await self._wikidata.close()
