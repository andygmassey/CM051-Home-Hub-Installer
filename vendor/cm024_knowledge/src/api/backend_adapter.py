"""
Backend Adapter - CM023 Synthesis Layer interface for Evernote knowledge.

Implements the standard backend adapter interface expected by the Synthesis Layer.
Provides semantic search over Evernote notes with privacy filtering.

Usage:
    adapter = EvernoteBackendAdapter()
    await adapter.initialize()
    response = await adapter.query(synthesis_query)
"""

import logging
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Dict, List, Optional

from ..storage.qdrant_store import QdrantStore
from ..storage.metadata_db import MetadataDB
from ..ingestion.embedder import Embedder

logger = logging.getLogger(__name__)


@dataclass
class SynthesisQuery:
    """
    Query from the Synthesis Layer.

    Matches the interface defined in CM023.
    """

    query_text: str
    intent: str  # knowledge_query, memory_recall, recommendation, decision_support
    user_id: str
    max_compartment_level: int = 2
    limit: int = 10
    filters: Dict[str, Any] = field(default_factory=dict)


@dataclass
class BackendResult:
    """Single result from the backend."""

    source_id: str
    content: str
    relevance_score: float
    timestamp: Optional[datetime]
    metadata: Dict[str, Any]
    provenance: Dict[str, Any]


@dataclass
class BackendResponse:
    """Response to a Synthesis Layer query."""

    backend: str
    query_id: str
    results: List[BackendResult]
    total_found: int
    latency_ms: float
    metadata: Dict[str, Any] = field(default_factory=dict)


class EvernoteBackendAdapter:
    """
    Backend adapter for Evernote knowledge.

    Implements the standard interface for CM023 Synthesis Layer:
    - supported_intents: List of intents this backend can handle
    - query(): Execute a query and return results
    - response_latency: Expected response time
    """

    # Intents this backend supports
    SUPPORTED_INTENTS = [
        "knowledge_query",      # "What do I know about X?"
        "memory_recall",        # "What notes do I have on X?"
        "recommendation",       # Provide context for recommendations
        "decision_support",     # Background knowledge for decisions
    ]

    def __init__(
        self,
        qdrant_host: str = "localhost",
        qdrant_port: int = 6333,
        qdrant_collection: str = "evernote_knowledge",
        db_path: str = "./data/metadata.db",
        embedding_provider: str = "ollama",
        embedding_model: str = "all-minilm",
        ollama_host: str = "http://localhost:11434",
    ):
        """
        Initialize the backend adapter.

        Args:
            qdrant_host: Qdrant server host
            qdrant_port: Qdrant server port
            qdrant_collection: Collection name
            db_path: Path to metadata SQLite database
            embedding_provider: Embedding provider
            embedding_model: Embedding model name
            ollama_host: Ollama server URL
        """
        self.qdrant_host = qdrant_host
        self.qdrant_port = qdrant_port
        self.qdrant_collection = qdrant_collection
        self.db_path = db_path
        self.embedding_provider = embedding_provider
        self.embedding_model = embedding_model
        self.ollama_host = ollama_host

        self._store: Optional[QdrantStore] = None
        self._db: Optional[MetadataDB] = None
        self._embedder: Optional[Embedder] = None
        self._initialized = False

    @property
    def supported_intents(self) -> List[str]:
        """List of intents this backend can handle."""
        return self.SUPPORTED_INTENTS

    @property
    def response_latency(self) -> float:
        """Expected response latency in seconds."""
        return 0.3  # ~300ms for vector search + embedding

    async def initialize(self) -> bool:
        """
        Initialize connections to Qdrant and metadata database.

        Returns:
            True if successful
        """
        try:
            # Initialize Qdrant store
            self._store = QdrantStore(
                host=self.qdrant_host,
                port=self.qdrant_port,
                collection=self.qdrant_collection,
            )
            if not await self._store.initialize():
                logger.error("Failed to initialize Qdrant store")
                return False

            # Initialize metadata database
            self._db = MetadataDB(self.db_path)
            self._db.initialize()

            # Initialize embedder
            self._embedder = Embedder(
                provider=self.embedding_provider,
                model=self.embedding_model,
                ollama_host=self.ollama_host,
            )

            self._initialized = True
            logger.info("EvernoteBackendAdapter initialized successfully")
            return True

        except Exception as e:
            logger.error(f"Failed to initialize adapter: {e}")
            return False

    async def query(self, query: SynthesisQuery) -> BackendResponse:
        """
        Execute a query from the Synthesis Layer.

        Args:
            query: SynthesisQuery with search parameters

        Returns:
            BackendResponse with results
        """
        if not self._initialized:
            raise RuntimeError("Adapter not initialized. Call initialize() first.")

        import time
        import uuid

        start_time = time.time()
        query_id = str(uuid.uuid4())

        try:
            # Generate embedding for query
            query_vector = await self._embedder.embed(query.query_text)
            if query_vector is None:
                logger.error("Failed to embed query")
                return self._empty_response(query_id, start_time)

            # Extract filters
            tags = query.filters.get("tags")
            note_id = query.filters.get("note_id")

            # Search Qdrant
            search_results = await self._store.search(
                query_vector=query_vector,
                limit=query.limit,
                max_compartment_level=query.max_compartment_level,
                tags=tags,
                note_id=note_id,
            )

            # Convert to BackendResults with importance-boosted ranking
            # Formula: adjusted_score = base_score * (1 + importance_score * 0.5)
            # This boosts high-quality notes (starred, "very good", etc.) by up to 50%
            results = []
            for hit in search_results:
                # Apply importance boost to relevance score
                importance_boost = 1 + (hit.importance_score * 0.5)
                adjusted_score = hit.score * importance_boost

                results.append(BackendResult(
                    source_id=hit.note_id,
                    content=hit.metadata.get("content", ""),
                    relevance_score=adjusted_score,
                    timestamp=hit.created_at,
                    metadata={
                        "title": hit.title,
                        "chunk_index": hit.chunk_index,
                        "compartment_level": hit.compartment_level,
                        "tags": hit.tags,
                        "importance_score": hit.importance_score,
                        "raw_similarity": hit.score,
                    },
                    provenance={
                        "source": "evernote",
                        "backend": "cm024",
                        "note_id": hit.note_id,
                        "vector_id": hit.id,
                    },
                ))

            # Re-sort by adjusted relevance score (importance-boosted)
            results.sort(key=lambda r: r.relevance_score, reverse=True)

            latency_ms = (time.time() - start_time) * 1000

            return BackendResponse(
                backend="evernote_knowledge",
                query_id=query_id,
                results=results,
                total_found=len(results),
                latency_ms=latency_ms,
                metadata={
                    "intent": query.intent,
                    "max_compartment_level": query.max_compartment_level,
                },
            )

        except Exception as e:
            logger.error(f"Query error: {e}")
            return self._empty_response(query_id, start_time)

    def _empty_response(self, query_id: str, start_time: float) -> BackendResponse:
        """Create an empty response for error cases."""
        import time

        return BackendResponse(
            backend="evernote_knowledge",
            query_id=query_id,
            results=[],
            total_found=0,
            latency_ms=(time.time() - start_time) * 1000,
            metadata={"error": True},
        )

    async def get_stats(self) -> Dict[str, Any]:
        """Get backend statistics."""
        stats = {
            "backend": "evernote_knowledge",
            "initialized": self._initialized,
        }

        if self._initialized:
            # Collection info
            collection_info = await self._store.get_collection_info()
            stats["collection"] = collection_info

            # Database stats
            db_stats = self._db.get_stats()
            stats["database"] = db_stats

        return stats

    async def health_check(self) -> Dict[str, Any]:
        """Check backend health."""
        health = {
            "backend": "evernote_knowledge",
            "status": "unknown",
            "components": {},
        }

        if not self._initialized:
            health["status"] = "not_initialized"
            return health

        try:
            # Check Qdrant
            collection_info = await self._store.get_collection_info()
            health["components"]["qdrant"] = {
                "status": "healthy",
                "vectors_count": collection_info.get("vectors_count", 0),
            }
        except Exception as e:
            health["components"]["qdrant"] = {
                "status": "unhealthy",
                "error": str(e),
            }

        try:
            # Check database
            db_stats = self._db.get_stats()
            health["components"]["database"] = {
                "status": "healthy",
                "notes_count": db_stats.get("total_notes", 0),
            }
        except Exception as e:
            health["components"]["database"] = {
                "status": "unhealthy",
                "error": str(e),
            }

        # Overall status
        all_healthy = all(
            c.get("status") == "healthy"
            for c in health["components"].values()
        )
        health["status"] = "healthy" if all_healthy else "degraded"

        return health


# Convenience function for creating adapter
async def create_adapter(
    qdrant_host: str = "localhost",
    qdrant_port: int = 6333,
    **kwargs
) -> EvernoteBackendAdapter:
    """
    Factory function to create and initialize an adapter.

    Args:
        qdrant_host: Qdrant server host
        qdrant_port: Qdrant server port
        **kwargs: Additional arguments

    Returns:
        Initialized EvernoteBackendAdapter
    """
    adapter = EvernoteBackendAdapter(
        qdrant_host=qdrant_host,
        qdrant_port=qdrant_port,
        **kwargs
    )
    await adapter.initialize()
    return adapter


if __name__ == "__main__":
    import asyncio

    async def test():
        print("Testing EvernoteBackendAdapter...")

        adapter = EvernoteBackendAdapter()

        if not await adapter.initialize():
            print("Failed to initialize adapter")
            return

        print(f"Supported intents: {adapter.supported_intents}")
        print(f"Expected latency: {adapter.response_latency}s")

        # Test query
        query = SynthesisQuery(
            query_text="What do I know about machine learning?",
            intent="knowledge_query",
            user_id="operator",
            max_compartment_level=2,
            limit=5,
        )

        response = await adapter.query(query)

        print(f"\nQuery results: {response.total_found}")
        print(f"Latency: {response.latency_ms:.1f}ms")

        for result in response.results:
            print(f"\n- {result.metadata.get('title', 'Untitled')}")
            print(f"  Score: {result.relevance_score:.3f}")
            print(f"  Preview: {result.content[:100]}...")

        # Health check
        health = await adapter.health_check()
        print(f"\nHealth: {health['status']}")

    asyncio.run(test())
