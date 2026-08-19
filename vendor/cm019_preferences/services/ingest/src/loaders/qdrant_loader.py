"""Qdrant vector database loader."""

import logging
from typing import List, Optional, Dict, Any
import httpx
import uuid

from ..config import settings

logger = logging.getLogger(__name__)


class QdrantLoader:
    """Handles loading vectors into Qdrant."""

    def __init__(self, base_url: Optional[str] = None, collection: Optional[str] = None):
        """Initialize the loader."""
        self.base_url = base_url or settings.qdrant_url
        self.collection = collection or settings.qdrant_collection

    async def ensure_collection(self, dimension: int = 384) -> bool:
        """
        Create collection if it doesn't exist.

        Args:
            dimension: Vector dimension (384 for all-MiniLM-L6-v2)

        Returns:
            True if collection exists or was created
        """
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                # Check if collection exists
                response = await client.get(
                    f"{self.base_url}/collections/{self.collection}"
                )

                if response.status_code == 200:
                    logger.debug(f"Collection {self.collection} already exists")
                    return True

                # Create collection
                response = await client.put(
                    f"{self.base_url}/collections/{self.collection}",
                    json={
                        "vectors": {
                            "size": dimension,
                            "distance": "Cosine"
                        },
                        "optimizers_config": {
                            "memmap_threshold": 20000
                        },
                        "on_disk_payload": True
                    }
                )

                if response.status_code in (200, 201):
                    logger.info(f"Created collection {self.collection}")

                    # Create payload indices for filtering
                    await self._create_indices(client)
                    return True
                else:
                    logger.error(f"Failed to create collection: {response.text}")
                    return False

        except Exception as e:
            logger.error(f"Error ensuring collection: {e}")
            return False

    async def _create_indices(self, client: httpx.AsyncClient):
        """Create payload field indices for efficient filtering."""
        indices = [
            ("compartment_level", "integer"),
            ("user_id", "keyword"),
            ("preference_type", "keyword"),
            ("source", "keyword")
        ]

        for field, field_type in indices:
            try:
                await client.put(
                    f"{self.base_url}/collections/{self.collection}/index",
                    json={
                        "field_name": field,
                        "field_schema": field_type
                    }
                )
                logger.debug(f"Created index on {field}")
            except Exception as e:
                logger.warning(f"Failed to create index on {field}: {e}")

    async def upsert_vectors(
        self,
        vectors: List[List[float]],
        payloads: List[Dict[str, Any]],
        ids: Optional[List[str]] = None
    ) -> bool:
        """
        Upsert vectors with payloads.

        Args:
            vectors: List of embedding vectors
            payloads: List of payload dicts (must match vectors length)
            ids: Optional list of IDs (generated if not provided)

        Returns:
            True if successful
        """
        if len(vectors) != len(payloads):
            raise ValueError("Vectors and payloads must have same length")

        if not vectors:
            return True

        # Generate IDs if not provided
        if ids is None:
            ids = [str(uuid.uuid4()) for _ in vectors]

        # Build points
        points = []
        for i, (vector, payload, point_id) in enumerate(zip(vectors, payloads, ids)):
            points.append({
                "id": point_id,
                "vector": vector,
                "payload": payload
            })

        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                # Upsert in batches
                batch_size = settings.batch_size
                for i in range(0, len(points), batch_size):
                    batch = points[i:i + batch_size]

                    response = await client.put(
                        f"{self.base_url}/collections/{self.collection}/points",
                        json={"points": batch}
                    )

                    if response.status_code not in (200, 201):
                        logger.error(f"Failed to upsert batch: {response.text}")
                        return False

                logger.debug(f"Upserted {len(points)} vectors")
                return True

        except Exception as e:
            logger.error(f"Error upserting vectors: {e}")
            return False

    async def search(
        self,
        vector: List[float],
        limit: int = 10,
        compartment_level: Optional[int] = None,
        user_id: Optional[str] = None,
        filters: Optional[Dict[str, Any]] = None
    ) -> List[Dict[str, Any]]:
        """
        Search for similar vectors.

        Args:
            vector: Query vector
            limit: Max results to return
            compartment_level: Filter by max compartment level
            user_id: Filter by user ID
            filters: Additional Qdrant filters

        Returns:
            List of search results with scores
        """
        # Build filter
        must_conditions = []

        if compartment_level is not None:
            must_conditions.append({
                "key": "compartment_level",
                "range": {"gte": compartment_level}
            })

        if user_id:
            must_conditions.append({
                "key": "user_id",
                "match": {"value": user_id}
            })

        query_filter = None
        if must_conditions:
            query_filter = {"must": must_conditions}
        if filters:
            if query_filter:
                query_filter["must"].extend(filters.get("must", []))
            else:
                query_filter = filters

        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                body = {
                    "vector": vector,
                    "limit": limit,
                    "with_payload": True
                }
                if query_filter:
                    body["filter"] = query_filter

                response = await client.post(
                    f"{self.base_url}/collections/{self.collection}/points/search",
                    json=body
                )

                if response.status_code == 200:
                    data = response.json()
                    return data.get("result", [])
                else:
                    logger.error(f"Search failed: {response.text}")
                    return []

        except Exception as e:
            logger.error(f"Error searching vectors: {e}")
            return []

    async def delete_by_user(self, user_id: str) -> bool:
        """Delete all vectors for a user."""
        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(
                    f"{self.base_url}/collections/{self.collection}/points/delete",
                    json={
                        "filter": {
                            "must": [{
                                "key": "user_id",
                                "match": {"value": user_id}
                            }]
                        }
                    }
                )

                return response.status_code in (200, 201)

        except Exception as e:
            logger.error(f"Error deleting user vectors: {e}")
            return False

    async def count(self, user_id: Optional[str] = None) -> int:
        """Count vectors in collection."""
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                if user_id:
                    response = await client.post(
                        f"{self.base_url}/collections/{self.collection}/points/count",
                        json={
                            "filter": {
                                "must": [{
                                    "key": "user_id",
                                    "match": {"value": user_id}
                                }]
                            }
                        }
                    )
                else:
                    response = await client.post(
                        f"{self.base_url}/collections/{self.collection}/points/count",
                        json={}
                    )

                if response.status_code == 200:
                    return response.json().get("result", {}).get("count", 0)
                return 0

        except Exception as e:
            logger.error(f"Error counting vectors: {e}")
            return 0

    async def health_check(self) -> bool:
        """Check if Qdrant is healthy."""
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                response = await client.get(f"{self.base_url}/healthz")
                return response.status_code == 200
        except Exception:
            return False

    async def get_all_for_user(
        self,
        user_id: str,
        batch_size: int = 100,
        limit: Optional[int] = None
    ) -> List[Dict[str, Any]]:
        """
        Retrieve all preferences for a user.

        Used for warming the preference filter cache to enable
        cross-source preference reinforcement.

        Args:
            user_id: User ID to fetch preferences for
            batch_size: Number of points per scroll request
            limit: Maximum total points to retrieve (None = all)

        Returns:
            List of preference payloads with their current data
        """
        results = []
        offset = None

        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                while True:
                    body = {
                        "filter": {
                            "must": [{
                                "key": "user_id",
                                "match": {"value": user_id}
                            }]
                        },
                        "limit": batch_size,
                        "with_payload": True,
                        "with_vector": False  # Don't need vectors, just payloads
                    }

                    if offset is not None:
                        body["offset"] = offset

                    response = await client.post(
                        f"{self.base_url}/collections/{self.collection}/points/scroll",
                        json=body
                    )

                    if response.status_code != 200:
                        logger.error(f"Scroll failed: {response.text}")
                        break

                    data = response.json()
                    points = data.get("result", {}).get("points", [])
                    next_offset = data.get("result", {}).get("next_page_offset")

                    for point in points:
                        payload = point.get("payload", {})
                        payload["_id"] = point.get("id")  # Include point ID
                        results.append(payload)

                    # Check if we've hit the limit
                    if limit and len(results) >= limit:
                        results = results[:limit]
                        break

                    # Check if there are more pages
                    if not next_offset or not points:
                        break

                    offset = next_offset

                logger.info(f"Retrieved {len(results)} existing preferences for user {user_id}")
                return results

        except Exception as e:
            logger.error(f"Error retrieving user preferences: {e}")
            return results
