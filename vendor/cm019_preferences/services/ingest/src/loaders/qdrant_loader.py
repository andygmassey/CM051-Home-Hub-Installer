"""Qdrant vector database loader."""

import logging
from typing import List, Optional, Dict, Any
import httpx
import uuid

from ..config import settings

logger = logging.getLogger(__name__)


# What a record with NO compartment_level is read as. Declared by BOTH writers:
# parsers/base.py has `compartment_level: int = 2  # Default to L2 (Trusted)`,
# and ostler_fda/pwg_ingest.py stamps DEFAULT_PRIVACY = "L2". Named so the
# value is stated once and a change to it shows up in a diff.
ABSENT_COMPARTMENT_MEANS = 2


def compartment_should_clauses(compartment_level: int) -> list:
    """The one-of clauses selecting points at or above a compartment floor.

    Lifted out of ``search`` so the arm selection can be exercised directly. A
    filter reachable only through an async HTTP call is one whose behaviour is
    asserted by READING it, and reading is what missed the absent case for as
    long as it was missed.

    THE THIRD ARM: A POINT WITH NO compartment_level AT ALL. Two arms match a
    number and a string. A point carrying NEITHER matched neither and was
    silently dropped. Measured on a live box: 934 of 9,948 points, about one in
    eleven. So a customer with nearly ten thousand preferences was shown the
    subset that happened to carry the field, and nothing told them or us that
    the rest had been removed before the question was asked. Being shown less
    than you own, with no error, is worse than an error.

    THE DECISIVE CASE IS A FLOOR OF 0. There the caller is asking for
    EVERYTHING and unlabelled points were still dropped. That is not a privacy
    stance, it is a filter that does not do what it says.

    AN ABSENT LABEL IS READ AS THE DOCUMENTED DEFAULT, which is consistency
    rather than a new privacy decision: an unstamped record predates the
    stamping, so it is read as what the writer would have written.

    THE ARM IS CONDITIONAL. It is added only when that default satisfies the
    caller's floor. Admitting unlabelled points into a request STRICTER than
    the default would widen a privacy-scoped read, which is the direction this
    file must never move by accident.
    """
    level_tokens = [f"L{n}" for n in range(compartment_level, 7)]
    should_clauses = [
        {"key": "compartment_level", "range": {"gte": compartment_level}},
        {"key": "compartment_level", "match": {"any": level_tokens}},
    ]
    if compartment_level <= ABSENT_COMPARTMENT_MEANS:
        should_clauses.append({"is_empty": {"key": "compartment_level"}})
    return should_clauses


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
            # BOTH SHAPES, because the store holds both and a range alone
            # matches NEITHER of the records actually on disk.
            #
            # Measured on a live box 2026-09-16, preferences collection:
            #   compartment_level match "L2"      4804
            #   compartment_level range {gte: 0}     0
            #   CONTROL strength   range {gte: 0}  5733   <- the range
            #                                              operator works
            #
            # The control is the point: `range` is not broken and the field
            # is not missing. 4804 points carry compartment_level as the
            # STRING "L2", and Qdrant's range operator simply does not match
            # a string, so it returned zero for every query and the whole
            # compartment-scoped search path was dead.
            #
            # THE READER MOVES, NOT THE WRITER. The type the reader wants is
            # the documented one -- ParsedPreference.compartment_level is
            # `int` (parsers/base.py), ensure_indexes declares this key as
            # "integer", and all 23 parsers pass ints. But 4804 points on
            # this customer's disk already say "L2", written by
            # ostler_fda/pwg_ingest.py, and a writer-only fix leaves every
            # one of them unsearchable until a full re-ingest. Accepting the
            # stored vocabulary costs nothing and orphans nothing.
            #
            # THE COMPARISON DIRECTION IS PRESERVED EXACTLY. `gte` is kept
            # because this commit is about a type mismatch, not about what
            # the cap means. (Levels run L0 Personal ... L6 Broadcast, so
            # whether a "max compartment level" should be gte or lte is a
            # real question -- it is NOT this commit's question, and
            # answering it by accident while fixing the type would be a
            # silent privacy change.) The string arm enumerates exactly the
            # tokens that satisfy the same gte, so both arms agree.
            # Numeric payload OR string payload OR absent, the last only when
            # absent falls inside the caller's scope. See the function.
            must_conditions.append(
                {"should": compartment_should_clauses(compartment_level)})

        if user_id:
            # `should`, NOT `must`. The field is never written.
            #
            # Measured on a live box 2026-09-16, preferences collection:
            #   is_empty user_id   5733 of 5733
            #   CONTROL is_empty category   0 of 5733
            #
            # so this is a real absence and not a broken probe. The producer
            # for this collection is ostler_fda/pwg_ingest.py, whose payload
            # carries no user_id at all; CM019's own
            # ParsedPreference.to_payload does write one, but it is not what
            # populated this store. A `must` on an absent key excludes
            # everything, so every user-scoped read returned nothing.
            #
            # THE READER MOVES, NOT THE WRITER, and the reasoning is already
            # written down in this codebase -- enrich/src/enricher.py makes
            # exactly this call for exactly this reason: Ostler is
            # single-machine by architectural directive, the Hub Mac is THE
            # machine and there is exactly one person, so an untagged
            # preference is THIS user's rather than somebody else's. A
            # writer-side fix would mean back-filling 5733 points with an
            # identity the single-machine product does not otherwise have.
            #
            # Deliberately NOT applied to delete_by_user() below: widening a
            # DELETE to include untagged points would turn "erase this
            # user's data" into "erase the entire collection". A read that
            # is too narrow shows nothing; a delete that is too wide cannot
            # be undone.
            #
            # NESTED under must for the same reason as the clause above: two
            # independent one-of groups must BOTH hold. A flat top-level
            # `should` would make them alternatives, so a point matching only
            # the compartment arm would pass the user arm too.
            must_conditions.append({"should": [
                {"key": "user_id", "match": {"value": user_id}},
                {"is_empty": {"key": "user_id"}},
            ]})

        query_filter = None
        if must_conditions:
            query_filter = {"must": must_conditions}
        if filters:
            if query_filter:
                query_filter.setdefault("must", []).extend(
                    filters.get("must", [])
                )
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
        """Delete all vectors for a user.

        DELIBERATELY NOT WIDENED. The read paths in this class now also
        accept points with no ``user_id`` (see ``search``), because the
        field is absent on every point the live writer produces and a
        strict match therefore returned nothing. That same widening applied
        HERE would turn "delete this user's vectors" into "delete every
        vector in the collection", including the 5733 untagged points a
        live box was measured to hold on 2026-09-16.

        A read that is too narrow shows the customer nothing and is fixed
        by the next query. A delete that is too wide is not recoverable.
        So this stays strict, and the consequence is stated rather than
        hidden: on a store whose points carry no ``user_id``, this method
        deletes nothing. Making erasure actually work needs the writer to
        stamp an owner, which is tracked separately -- it must not be
        smuggled in by loosening a delete filter.
        """
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
                                # Same one-of clause as search(): the owner
                                # tag is absent on every point the live
                                # writer produces, so a strict match counted
                                # 0 and reported an empty store as fact.
                                "must": [{"should": [
                                    {"key": "user_id",
                                     "match": {"value": user_id}},
                                    {"is_empty": {"key": "user_id"}},
                                ]}]
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
                            # Same one-of clause as search(). This method
                            # warms the cross-source reinforcement cache, so
                            # a strict match here left the cache empty and
                            # silently disabled reinforcement entirely.
                            "must": [{"should": [
                                {"key": "user_id",
                                 "match": {"value": user_id}},
                                {"is_empty": {"key": "user_id"}},
                            ]}]
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
