"""Oxigraph RDF triple store loader."""

import logging
from typing import Optional
import httpx

from ..config import settings

logger = logging.getLogger(__name__)


# The predicates a preference writer owns (ParsedPreference.to_turtle emits
# exactly these, plus rdf:type). A re-ingest of the same preference id must
# REPLACE them, not append a second value beside them. Enrichment triples on
# the same node (pwg:hasTopic, pwg:enrichedAt, ...) are not in this list and
# are left alone.
PREFERENCE_OWNED_PREDICATES = (
    "http://www.w3.org/1999/02/22-rdf-syntax-ns#type",
    "https://schema.ostler.ai/ontology#subject",
    "https://schema.ostler.ai/ontology#preferenceStrength",
    "https://schema.ostler.ai/ontology#belongsToCompartment",
    "https://schema.ostler.ai/ontology#hasSize",
    "https://schema.ostler.ai/ontology#createdAt",
    "https://schema.ostler.ai/ontology#belongsToUser",
    "https://schema.ostler.ai/ontology#dataSource",
    "https://schema.ostler.ai/ontology#category",
    "https://schema.ostler.ai/ontology#hasContext",
    "https://schema.ostler.ai/ontology#observedAt",
    "https://schema.ostler.ai/ontology#sourceId",
)


def _split_turtle(triples_ttl: str):
    """Split a Turtle block into (SPARQL PREFIX block, data block)."""
    prefixes = []
    data_lines = []
    for line in triples_ttl.strip().split('\n'):
        stripped = line.strip()
        if stripped.startswith('@prefix') or stripped.startswith('PREFIX'):
            # @prefix pwg: <uri> . -> PREFIX pwg: <uri>
            if stripped.startswith('@prefix'):
                prefixes.append(stripped.replace('@prefix ', 'PREFIX ').rstrip(' .'))
            else:
                prefixes.append(stripped)
        elif stripped and not stripped.startswith('#'):
            data_lines.append(line)
    return '\n'.join(prefixes), '\n'.join(data_lines)


class OxigraphLoader:
    """Handles loading RDF triples into Oxigraph."""

    def __init__(self, base_url: Optional[str] = None):
        """Initialize the loader."""
        self.base_url = base_url or settings.oxigraph_url
        self.client = httpx.Client(timeout=60.0)

    async def insert_triples(self, triples_ttl: str, graph: Optional[str] = None) -> bool:
        """
        Insert RDF triples in Turtle format using SPARQL UPDATE.

        Args:
            triples_ttl: RDF data in Turtle format
            graph: Optional named graph URI

        Returns:
            True if successful, False otherwise
        """
        try:
            prefix_block, data_block = _split_turtle(triples_ttl)

            if graph:
                update_query = f"{prefix_block}\nINSERT DATA {{ GRAPH <{graph}> {{ {data_block} }} }}"
            else:
                update_query = f"{prefix_block}\nINSERT DATA {{ {data_block} }}"

            return await self._post_update(update_query, "Inserted triples successfully via SPARQL UPDATE")

        except Exception as e:
            logger.error(f"Error inserting triples: {e}")
            return False

    async def replace_preference_triples(self, pref_ids: list, triples_ttl: str) -> bool:
        """Replace the owned triples of the given preference nodes, then insert.

        SPARQL INSERT DATA only ADDS. A preference re-ingested under the same
        stable id with a changed subject or createdAt therefore kept BOTH values
        in the graph while its Qdrant point (an upsert) held only the new one:
        six nodes on the v1.0.131 walk box carried two pwg:subject literals.
        This deletes the owned predicates of ``pref_ids`` and inserts the new
        block in ONE update request, so the node is replaced, never widened.
        """
        try:
            prefix_block, data_block = _split_turtle(triples_ttl)
            iris = " ".join("pwg:pref_%s" % pid for pid in pref_ids)
            preds = " ".join("<%s>" % p for p in PREFERENCE_OWNED_PREDICATES)
            if iris:
                delete = (
                    "DELETE { ?s ?p ?o } WHERE { VALUES ?s { %s } VALUES ?p { %s } ?s ?p ?o } ;\n"
                    % (iris, preds)
                )
            else:
                delete = ""
            update_query = f"{prefix_block}\n{delete}INSERT DATA {{ {data_block} }}"
            return await self._post_update(update_query, "Replaced preference triples via SPARQL UPDATE")
        except Exception as e:
            logger.error(f"Error replacing preference triples: {e}")
            return False

    async def _post_update(self, update_query: str, ok_message: str) -> bool:
        async with httpx.AsyncClient(timeout=60.0) as client:
            response = await client.post(
                f"{self.base_url}/update",
                content=update_query,
                headers={"Content-Type": "application/sparql-update"}
            )

            if response.status_code in (200, 201, 204):
                logger.debug(ok_message)
                return True
            logger.error(f"SPARQL update failed: {response.status_code} - {response.text}")
            return False

    async def execute_sparql_update(self, update: str) -> bool:
        """
        Execute a SPARQL UPDATE query.

        Args:
            update: SPARQL UPDATE query

        Returns:
            True if successful, False otherwise
        """
        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(
                    f"{self.base_url}/update",
                    content=update,
                    headers={"Content-Type": "application/sparql-update"}
                )

                if response.status_code in (200, 201, 204):
                    return True
                else:
                    logger.error(f"SPARQL update failed: {response.status_code} - {response.text}")
                    return False

        except Exception as e:
            logger.error(f"Error executing SPARQL update: {e}")
            return False

    async def query(self, sparql: str) -> Optional[dict]:
        """
        Execute a SPARQL SELECT query.

        Args:
            sparql: SPARQL SELECT query

        Returns:
            Query results as dict or None on error
        """
        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(
                    f"{self.base_url}/query",
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
            logger.error(f"Error executing SPARQL query: {e}")
            return None

    async def count_triples(self, graph: Optional[str] = None) -> int:
        """Count total triples in the store or a specific graph."""
        query = "SELECT (COUNT(*) as ?count) WHERE { ?s ?p ?o }"
        if graph:
            query = f"SELECT (COUNT(*) as ?count) WHERE {{ GRAPH <{graph}> {{ ?s ?p ?o }} }}"

        result = await self.query(query)
        if result and result.get("results", {}).get("bindings"):
            return int(result["results"]["bindings"][0]["count"]["value"])
        return 0

    async def health_check(self) -> bool:
        """Check if Oxigraph is healthy using a simple SPARQL query."""
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                # Use ASK query - minimal overhead, returns true/false
                response = await client.post(
                    f"{self.base_url}/query",
                    content="ASK { ?s ?p ?o }",
                    headers={
                        "Content-Type": "application/sparql-query",
                        "Accept": "application/sparql-results+json"
                    }
                )
                return response.status_code == 200
        except Exception:
            return False

    def close(self):
        """Close the HTTP client."""
        self.client.close()
