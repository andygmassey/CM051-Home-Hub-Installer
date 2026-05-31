"""Oxigraph RDF triple store loader."""

import logging
from typing import Optional
import httpx

from ..config import settings

logger = logging.getLogger(__name__)


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
            # Extract prefixes and data from Turtle content
            lines = triples_ttl.strip().split('\n')
            prefixes = []
            data_lines = []

            for line in lines:
                stripped = line.strip()
                if stripped.startswith('@prefix') or stripped.startswith('PREFIX'):
                    # Convert @prefix to SPARQL PREFIX format
                    if stripped.startswith('@prefix'):
                        # @prefix pwg: <uri> . -> PREFIX pwg: <uri>
                        prefix_line = stripped.replace('@prefix ', 'PREFIX ').rstrip(' .')
                        prefixes.append(prefix_line)
                    else:
                        prefixes.append(stripped)
                elif stripped and not stripped.startswith('#'):
                    data_lines.append(line)

            # Build SPARQL UPDATE query
            prefix_block = '\n'.join(prefixes)
            data_block = '\n'.join(data_lines)

            if graph:
                update_query = f"{prefix_block}\nINSERT DATA {{ GRAPH <{graph}> {{ {data_block} }} }}"
            else:
                update_query = f"{prefix_block}\nINSERT DATA {{ {data_block} }}"

            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(
                    f"{self.base_url}/update",
                    content=update_query,
                    headers={"Content-Type": "application/sparql-update"}
                )

                if response.status_code in (200, 201, 204):
                    logger.debug("Inserted triples successfully via SPARQL UPDATE")
                    return True
                else:
                    logger.error(f"Failed to insert triples: {response.status_code} - {response.text}")
                    return False

        except Exception as e:
            logger.error(f"Error inserting triples: {e}")
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
