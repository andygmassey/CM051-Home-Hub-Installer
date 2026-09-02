"""
Qdrant Store - Vector storage and search for Evernote knowledge.

Handles collection management, vector upsert, and semantic search.

Usage:
    store = QdrantStore(collection="evernote_knowledge")
    await store.initialize()
    await store.upsert_vectors(vectors, metadata)
    results = await store.search("query text", limit=10)
"""

import logging
import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)


@dataclass
class SearchResult:
    """Result from a vector search."""

    id: str
    score: float
    note_id: str
    title: str
    content_preview: str
    chunk_index: int
    compartment_level: int
    tags: List[str]
    created_at: Optional[datetime]
    importance_score: float
    source_url: Optional[str]
    metadata: Dict[str, Any]


class QdrantStore:
    """
    Vector store using Qdrant for Evernote knowledge.

    Provides:
    - Collection management
    - Vector upsert with metadata
    - Semantic search with filtering
    - Privacy-aware retrieval
    """

    def __init__(
        self,
        host: str = "localhost",
        port: int = 6333,
        collection: str = "evernote_knowledge",
        vector_size: int = 768,
        distance: str = "Cosine",
    ):
        """
        Initialize Qdrant store.

        Args:
            host: Qdrant host
            port: Qdrant port
            collection: Collection name
            vector_size: Embedding dimensions
            distance: Distance metric (Cosine, Euclid, Dot)
        """
        self.host = host
        self.port = port
        self.collection = collection
        self.vector_size = vector_size
        self.distance = distance

        self._client = None
        self._initialized = False

        self._stats = {
            'vectors_upserted': 0,
            'searches_performed': 0,
        }

    async def initialize(self) -> bool:
        """
        Initialize connection and ensure collection exists.

        Returns:
            True if successful
        """
        try:
            from qdrant_client import QdrantClient
            from qdrant_client.models import Distance, VectorParams

            self._client = QdrantClient(host=self.host, port=self.port)

            # Check if collection exists
            collections = self._client.get_collections().collections
            exists = any(c.name == self.collection for c in collections)

            if not exists:
                # Create collection
                logger.info(f"Creating collection: {self.collection}")

                distance_map = {
                    "Cosine": Distance.COSINE,
                    "Euclid": Distance.EUCLID,
                    "Dot": Distance.DOT,
                }

                self._client.create_collection(
                    collection_name=self.collection,
                    vectors_config=VectorParams(
                        size=self.vector_size,
                        distance=distance_map.get(self.distance, Distance.COSINE),
                    )
                )

                # Create payload indexes
                self._client.create_payload_index(
                    collection_name=self.collection,
                    field_name="compartment_level",
                    field_schema="integer",
                )
                self._client.create_payload_index(
                    collection_name=self.collection,
                    field_name="note_id",
                    field_schema="keyword",
                )

                logger.info(f"Collection created with indexes")

            self._initialized = True
            return True

        except ImportError:
            logger.error("qdrant-client not installed")
            return False
        except Exception as e:
            logger.error(f"Failed to initialize Qdrant: {e}")
            return False

    async def upsert_vectors(
        self,
        vectors: List[List[float]],
        payloads: List[Dict[str, Any]],
        ids: Optional[List[str]] = None,
    ) -> int:
        """
        Upsert vectors with metadata.

        Args:
            vectors: List of embedding vectors
            payloads: List of metadata dicts
            ids: Optional list of IDs (generated if not provided)

        Returns:
            Number of vectors upserted
        """
        if not self._initialized:
            raise RuntimeError("Store not initialized. Call initialize() first.")

        if len(vectors) != len(payloads):
            raise ValueError("vectors and payloads must have same length")

        if not vectors:
            return 0

        from qdrant_client.models import PointStruct

        # Generate IDs if not provided
        if ids is None:
            ids = [str(uuid.uuid4()) for _ in vectors]

        # Build points
        points = []
        for i, (id_, vector, payload) in enumerate(zip(ids, vectors, payloads)):
            points.append(PointStruct(
                id=id_,
                vector=vector,
                payload=payload,
            ))

        # Upsert in batches
        batch_size = 100
        total_upserted = 0

        for i in range(0, len(points), batch_size):
            batch = points[i:i + batch_size]
            self._client.upsert(
                collection_name=self.collection,
                points=batch,
            )
            total_upserted += len(batch)

        self._stats['vectors_upserted'] += total_upserted
        logger.debug(f"Upserted {total_upserted} vectors")

        return total_upserted

    async def upsert(
        self,
        note_id: str,
        chunk_index: int,
        vector: List[float],
        content: str,
        title: str,
        tags: List[str],
        compartment_level: int,
        created_at: Optional[Any] = None,
        updated_at: Optional[Any] = None,
        importance_score: float = 0.0,
        source_url: Optional[str] = None,
        content_hash: Optional[str] = None,
        evernote_guid: Optional[str] = None,
    ) -> bool:
        """
        Upsert a single chunk.

        Convenience method for inserting one chunk at a time.

        Args:
            note_id: Note identifier
            chunk_index: Chunk index within note
            vector: Embedding vector
            content: Chunk text content
            title: Note title
            tags: Note tags
            compartment_level: Privacy level
            created_at: Creation timestamp
            importance_score: RAG importance score (0.0-1.0)
            source_url: Original source URL (for web clips)

        Returns:
            True if successful
        """
        # Generate deterministic UUID from note_id + chunk_index
        import hashlib
        hash_input = f"{note_id}_{chunk_index}".encode()
        point_id = str(uuid.UUID(hashlib.md5(hash_input).hexdigest()))
        payload = {
            "note_id": note_id,
            "evernote_guid": evernote_guid or note_id,
            "chunk_index": chunk_index,
            "title": title,
            "content": content,
            "tags": tags,
            "compartment_level": compartment_level,
            "importance_score": importance_score,
            "source_url": source_url,
            "created": created_at.isoformat() if created_at else None,
            "updated": updated_at.isoformat() if updated_at else None,
            "content_hash": content_hash,
        }

        try:
            count = await self.upsert_vectors(
                vectors=[vector],
                payloads=[payload],
                ids=[point_id],
            )
            return count > 0
        except Exception as e:
            logger.error(f"Failed to upsert chunk: {e}")
            return False

    async def search(
        self,
        query_vector: List[float],
        limit: int = 10,
        max_compartment_level: Optional[int] = None,
        tags: Optional[List[str]] = None,
        note_id: Optional[str] = None,
    ) -> List[SearchResult]:
        """
        Search for similar vectors.

        Args:
            query_vector: Query embedding
            limit: Maximum results
            max_compartment_level: Filter by privacy level (<=)
            tags: Filter by tags (any match)
            note_id: Filter by specific note

        Returns:
            List of SearchResult objects
        """
        if not self._initialized:
            raise RuntimeError("Store not initialized")

        from qdrant_client.models import Filter, FieldCondition, Range, MatchAny, MatchValue

        # Build filter
        conditions = []

        if max_compartment_level is not None:
            conditions.append(
                FieldCondition(
                    key="compartment_level",
                    range=Range(lte=max_compartment_level),
                )
            )

        if tags:
            conditions.append(
                FieldCondition(
                    key="tags",
                    match=MatchAny(any=tags),
                )
            )

        if note_id:
            conditions.append(
                FieldCondition(
                    key="note_id",
                    match=MatchValue(value=note_id),
                )
            )

        search_filter = Filter(must=conditions) if conditions else None

        # Execute search using query_points (qdrant-client >= 1.7)
        response = self._client.query_points(
            collection_name=self.collection,
            query=query_vector,
            query_filter=search_filter,
            limit=limit,
            with_payload=True,
        )

        self._stats['searches_performed'] += 1

        # Convert to SearchResult objects
        search_results = []
        for hit in response.points:
            payload = hit.payload or {}
            search_results.append(SearchResult(
                id=str(hit.id),
                score=hit.score,
                note_id=payload.get("note_id", ""),
                title=payload.get("title", ""),
                content_preview=payload.get("content", "")[:200],
                chunk_index=payload.get("chunk_index", 0),
                compartment_level=payload.get("compartment_level", 2),
                tags=payload.get("tags", []),
                created_at=self._parse_datetime(payload.get("created_at")),
                importance_score=payload.get("importance_score", 0.0),
                source_url=payload.get("source_url"),
                metadata=payload,
            ))

        return search_results

    def _parse_datetime(self, value: Optional[str]) -> Optional[datetime]:
        """Parse datetime string."""
        if not value:
            return None
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except (ValueError, AttributeError):
            return None

    async def delete_by_note_id(self, note_id: str) -> int:
        """
        Delete all vectors for a note.

        Args:
            note_id: Note ID to delete

        Returns:
            Number of vectors deleted (approximate)
        """
        if not self._initialized:
            raise RuntimeError("Store not initialized")

        from qdrant_client.models import Filter, FieldCondition, MatchValue

        # Get count first
        result = self._client.count(
            collection_name=self.collection,
            count_filter=Filter(
                must=[
                    FieldCondition(
                        key="note_id",
                        match=MatchValue(value=note_id),
                    )
                ]
            ),
        )
        count = result.count

        # Delete
        self._client.delete(
            collection_name=self.collection,
            points_selector=Filter(
                must=[
                    FieldCondition(
                        key="note_id",
                        match=MatchValue(value=note_id),
                    )
                ]
            ),
        )

        return count

    async def get_collection_info(self) -> Dict[str, Any]:
        """Get collection statistics."""
        if not self._initialized:
            return {}

        info = self._client.get_collection(self.collection)
        return {
            "name": self.collection,
            "vectors_count": info.vectors_count,
            "points_count": info.points_count,
            "status": str(info.status),
        }

    @property
    def stats(self) -> dict:
        """Get store statistics."""
        return self._stats.copy()


async def create_store(
    host: str = "localhost",
    port: int = 6333,
    collection: str = "evernote_knowledge",
    vector_size: int = 768,
) -> QdrantStore:
    """
    Factory function to create and initialize a store.

    Args:
        host: Qdrant host
        port: Qdrant port
        collection: Collection name
        vector_size: Vector dimensions

    Returns:
        Initialized QdrantStore
    """
    store = QdrantStore(
        host=host,
        port=port,
        collection=collection,
        vector_size=vector_size,
    )
    await store.initialize()
    return store


if __name__ == "__main__":
    import asyncio

    async def test():
        print("Testing Qdrant store...")

        store = QdrantStore(collection="evernote_knowledge_test")

        if not await store.initialize():
            print("Failed to initialize store")
            return

        info = await store.get_collection_info()
        print(f"Collection info: {info}")

        # Test upsert
        vectors = [[0.1] * 768, [0.2] * 768]
        payloads = [
            {
                "note_id": "test-1",
                "title": "Test Note 1",
                "content": "This is test content.",
                "compartment_level": 2,
                "tags": ["test"],
            },
            {
                "note_id": "test-2",
                "title": "Test Note 2",
                "content": "Another test note.",
                "compartment_level": 1,
                "tags": ["test", "example"],
            },
        ]

        count = await store.upsert_vectors(vectors, payloads)
        print(f"Upserted {count} vectors")

        # Test search
        results = await store.search(
            query_vector=[0.15] * 768,
            limit=5,
            max_compartment_level=2,
        )

        print(f"Search results: {len(results)}")
        for r in results:
            print(f"  - {r.title} (score: {r.score:.3f}, level: {r.compartment_level})")

    asyncio.run(test())
