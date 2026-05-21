"""
Incremental Updates - Enable "top-up" ingestion for new Evernote exports.

This module provides functionality for incremental ingestion without
re-processing the entire knowledge base. Key features:

1. Note-level deduplication using evernote_guid or content hash
2. Smart comparison to detect new/updated notes
3. Chunk replacement for updated notes

Usage:
    from src.ingestion.incremental import warm_existing_notes, should_update_note

    # Load existing notes from Qdrant
    existing = await warm_existing_notes(qdrant_client, collection)

    # Check if a note needs updating
    if should_update_note(existing.get(note.guid), note):
        await update_note(qdrant_client, collection, existing.get(note.guid), note, embedder)

Based on CM019's implementation in services/ingest/src/pipeline.py
"""

import hashlib
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Dict, List, Optional, Set

logger = logging.getLogger(__name__)


@dataclass
class NoteMetadata:
    """Metadata for an existing note in the database."""

    guid: str  # Evernote GUID or generated ID
    updated_at: Optional[datetime] = None
    content_hash: Optional[str] = None
    vector_ids: List[str] = field(default_factory=list)
    chunk_count: int = 0
    title: Optional[str] = None


@dataclass
class IncrementalStats:
    """Statistics from incremental ingestion."""

    existing_notes: int = 0
    new_notes: int = 0
    updated_notes: int = 0
    skipped_notes: int = 0
    deleted_chunks: int = 0
    inserted_chunks: int = 0


def compute_content_hash(content: str) -> str:
    """
    Compute a hash of note content for duplicate detection.

    Uses MD5 for speed - not cryptographic security.
    Normalizes whitespace before hashing for consistent comparison.
    """
    # Normalize: strip, collapse whitespace, lowercase
    normalized = ' '.join(content.lower().split())
    return hashlib.md5(normalized.encode('utf-8')).hexdigest()


async def warm_existing_notes(
    qdrant_client,
    collection: str,
    batch_size: int = 1000,
) -> Dict[str, NoteMetadata]:
    """
    Load existing note metadata from Qdrant for deduplication.

    Scrolls through all points in the collection and extracts note-level
    metadata including vector IDs for potential deletion during updates.

    Args:
        qdrant_client: Qdrant client instance
        collection: Collection name
        batch_size: Number of points to fetch per scroll

    Returns:
        Dict mapping note_id/evernote_guid -> NoteMetadata
    """
    from qdrant_client.models import Filter

    existing: Dict[str, NoteMetadata] = {}

    logger.info(f"Warming existing notes from {collection}...")

    try:
        # Check if collection exists
        collections = qdrant_client.get_collections().collections
        if not any(c.name == collection for c in collections):
            logger.info(f"Collection {collection} does not exist, nothing to warm")
            return existing

        # Scroll through all points
        offset = None
        total_points = 0

        while True:
            results = qdrant_client.scroll(
                collection_name=collection,
                scroll_filter=None,
                limit=batch_size,
                offset=offset,
                with_payload=["note_id", "evernote_guid", "updated", "created",
                             "chunk_index", "title", "content_hash"],
                with_vectors=False,
            )

            points, next_offset = results

            for point in points:
                total_points += 1
                payload = point.payload or {}

                # Use evernote_guid if available, otherwise note_id
                guid = payload.get("evernote_guid") or payload.get("note_id")
                if not guid:
                    continue

                # Parse updated_at timestamp
                updated_str = payload.get("updated") or payload.get("created")
                updated_at = None
                if updated_str:
                    try:
                        updated_at = datetime.fromisoformat(str(updated_str).replace('Z', '+00:00'))
                    except (ValueError, TypeError):
                        pass

                if guid not in existing:
                    existing[guid] = NoteMetadata(
                        guid=guid,
                        updated_at=updated_at,
                        content_hash=payload.get("content_hash"),
                        vector_ids=[str(point.id)],
                        chunk_count=1,
                        title=payload.get("title"),
                    )
                else:
                    existing[guid].vector_ids.append(str(point.id))
                    existing[guid].chunk_count += 1
                    # Keep the most recent updated_at
                    if updated_at and (existing[guid].updated_at is None or
                                       updated_at > existing[guid].updated_at):
                        existing[guid].updated_at = updated_at

            offset = next_offset
            if offset is None:
                break

            if total_points % 10000 == 0:
                logger.info(f"  Scanned {total_points:,} points, {len(existing):,} unique notes...")

        logger.info(f"Warmed {len(existing):,} existing notes from {total_points:,} vectors")
        return existing

    except Exception as e:
        logger.error(f"Error warming existing notes: {e}")
        return existing


def should_update_note(
    existing: Optional[NoteMetadata],
    new_updated_at: Optional[datetime] = None,
    new_content_hash: Optional[str] = None,
) -> bool:
    """
    Determine if a note should be re-processed.

    A note should be updated if:
    - It doesn't exist in the database (new note)
    - Its updated_at timestamp is newer than the DB version
    - Its content hash differs (content changed)

    Args:
        existing: Existing note metadata (None if new note)
        new_updated_at: Timestamp of the new note version
        new_content_hash: Content hash of the new note

    Returns:
        True if the note should be processed, False to skip
    """
    # New note - always process
    if existing is None:
        return True

    # Check timestamp if available
    if new_updated_at and existing.updated_at:
        if new_updated_at > existing.updated_at:
            return True

    # Check content hash if available
    if new_content_hash and existing.content_hash:
        if new_content_hash != existing.content_hash:
            return True

    # If we have neither timestamp nor hash comparison, and note exists, skip
    return False


async def delete_note_chunks(
    qdrant_client,
    collection: str,
    existing: NoteMetadata,
) -> int:
    """
    Delete all existing chunks for a note.

    Args:
        qdrant_client: Qdrant client instance
        collection: Collection name
        existing: NoteMetadata with vector_ids to delete

    Returns:
        Number of chunks deleted
    """
    if not existing or not existing.vector_ids:
        return 0

    from qdrant_client.models import PointIdsList

    try:
        # Convert string IDs to appropriate format
        # Qdrant accepts both int and string UUIDs
        point_ids = []
        for vid in existing.vector_ids:
            try:
                # Try as integer first (some old data might use int IDs)
                point_ids.append(int(vid))
            except ValueError:
                # Use as string UUID
                point_ids.append(vid)

        qdrant_client.delete(
            collection_name=collection,
            points_selector=PointIdsList(points=point_ids),
        )

        logger.debug(f"Deleted {len(point_ids)} chunks for note {existing.guid}")
        return len(point_ids)

    except Exception as e:
        logger.error(f"Error deleting chunks for note {existing.guid}: {e}")
        return 0


class IncrementalIngester:
    """
    Handles incremental ingestion with smart deduplication.

    Provides a high-level interface for:
    1. Warming the cache from existing Qdrant data
    2. Processing notes with automatic skip/update logic
    3. Tracking statistics
    """

    def __init__(
        self,
        qdrant_client,
        collection: str,
    ):
        """
        Initialize the incremental ingester.

        Args:
            qdrant_client: Qdrant client instance
            collection: Collection name
        """
        self.qdrant_client = qdrant_client
        self.collection = collection
        self.existing: Dict[str, NoteMetadata] = {}
        self.stats = IncrementalStats()
        self._warmed = False

    async def warm(self) -> int:
        """
        Warm the cache with existing notes.

        Returns:
            Number of existing notes loaded
        """
        self.existing = await warm_existing_notes(
            self.qdrant_client,
            self.collection,
        )
        self.stats.existing_notes = len(self.existing)
        self._warmed = True
        return len(self.existing)

    def should_process(
        self,
        note_id: str,
        updated_at: Optional[datetime] = None,
        content: Optional[str] = None,
    ) -> bool:
        """
        Check if a note should be processed.

        Args:
            note_id: Note ID (evernote_guid or generated)
            updated_at: Note's updated timestamp
            content: Note content (for hash computation)

        Returns:
            True if note should be processed
        """
        if not self._warmed:
            logger.warning("Cache not warmed, processing all notes")
            return True

        existing = self.existing.get(note_id)
        content_hash = compute_content_hash(content) if content else None

        should_update = should_update_note(existing, updated_at, content_hash)

        if should_update:
            if existing is None:
                self.stats.new_notes += 1
            else:
                self.stats.updated_notes += 1
        else:
            self.stats.skipped_notes += 1

        return should_update

    async def delete_existing_chunks(self, note_id: str) -> int:
        """
        Delete existing chunks for a note before re-inserting.

        Args:
            note_id: Note ID to delete chunks for

        Returns:
            Number of chunks deleted
        """
        existing = self.existing.get(note_id)
        if not existing:
            return 0

        deleted = await delete_note_chunks(
            self.qdrant_client,
            self.collection,
            existing,
        )
        self.stats.deleted_chunks += deleted
        return deleted

    def record_inserted_chunks(self, count: int):
        """Record number of chunks inserted."""
        self.stats.inserted_chunks += count

    def get_stats_summary(self) -> str:
        """Get a human-readable stats summary."""
        return (
            f"Existing: {self.stats.existing_notes:,}, "
            f"New: {self.stats.new_notes:,}, "
            f"Updated: {self.stats.updated_notes:,}, "
            f"Skipped: {self.stats.skipped_notes:,}, "
            f"Deleted chunks: {self.stats.deleted_chunks:,}, "
            f"Inserted chunks: {self.stats.inserted_chunks:,}"
        )


# Duplicate Detection

@dataclass
class DuplicateGroup:
    """A group of duplicate notes."""

    content_hash: str
    note_ids: List[str]
    titles: List[str]
    chunk_counts: List[int]

    @property
    def count(self) -> int:
        return len(self.note_ids)

    def get_primary(self) -> str:
        """Get the primary note (most chunks = most complete)."""
        max_chunks = max(self.chunk_counts)
        idx = self.chunk_counts.index(max_chunks)
        return self.note_ids[idx]

    def get_duplicates(self) -> List[str]:
        """Get duplicate note IDs (excluding primary)."""
        primary = self.get_primary()
        return [nid for nid in self.note_ids if nid != primary]


async def find_duplicates(
    qdrant_client,
    collection: str,
    batch_size: int = 1000,
) -> List[DuplicateGroup]:
    """
    Find duplicate notes in the collection.

    Groups notes by content hash to identify duplicates.

    Args:
        qdrant_client: Qdrant client instance
        collection: Collection name
        batch_size: Scroll batch size

    Returns:
        List of DuplicateGroup objects (groups with >1 note)
    """
    from collections import defaultdict

    logger.info(f"Scanning {collection} for duplicates...")

    # Group by content hash
    hash_to_notes: Dict[str, List[Dict[str, Any]]] = defaultdict(list)

    try:
        # Scroll through all points, only need chunk_index=0 for dedup
        offset = None
        total_scanned = 0

        while True:
            results = qdrant_client.scroll(
                collection_name=collection,
                scroll_filter=None,
                limit=batch_size,
                offset=offset,
                with_payload=["note_id", "evernote_guid", "title",
                             "chunk_index", "content", "content_hash"],
                with_vectors=False,
            )

            points, next_offset = results

            for point in points:
                total_scanned += 1
                payload = point.payload or {}

                # Only consider first chunk for deduplication
                chunk_idx = payload.get("chunk_index", 0)
                if chunk_idx != 0:
                    continue

                note_id = payload.get("evernote_guid") or payload.get("note_id")
                if not note_id:
                    continue

                # Get or compute content hash
                content_hash = payload.get("content_hash")
                if not content_hash and payload.get("content"):
                    content_hash = compute_content_hash(payload["content"])

                if content_hash:
                    hash_to_notes[content_hash].append({
                        'note_id': note_id,
                        'title': payload.get("title", "Untitled"),
                        'point_id': str(point.id),
                    })

            offset = next_offset
            if offset is None:
                break

        logger.info(f"Scanned {total_scanned:,} vectors, found {len(hash_to_notes):,} unique content hashes")

        # Build duplicate groups
        duplicates = []
        for content_hash, notes in hash_to_notes.items():
            if len(notes) > 1:
                # Count chunks per note
                chunk_counts = []
                for note in notes:
                    # Count total chunks for this note
                    count_result = qdrant_client.count(
                        collection_name=collection,
                        count_filter={
                            "must": [
                                {"key": "note_id", "match": {"value": note['note_id']}}
                            ]
                        },
                    )
                    chunk_counts.append(count_result.count)

                duplicates.append(DuplicateGroup(
                    content_hash=content_hash,
                    note_ids=[n['note_id'] for n in notes],
                    titles=[n['title'] for n in notes],
                    chunk_counts=chunk_counts,
                ))

        logger.info(f"Found {len(duplicates):,} duplicate groups")
        return duplicates

    except Exception as e:
        logger.error(f"Error finding duplicates: {e}")
        return []


async def remove_duplicates(
    qdrant_client,
    collection: str,
    duplicates: List[DuplicateGroup],
    dry_run: bool = True,
) -> int:
    """
    Remove duplicate notes, keeping the most complete version.

    Args:
        qdrant_client: Qdrant client instance
        collection: Collection name
        duplicates: List of duplicate groups from find_duplicates()
        dry_run: If True, only report what would be deleted

    Returns:
        Number of notes removed (or would be removed if dry_run)
    """
    from qdrant_client.models import Filter, FieldCondition, MatchValue

    total_removed = 0

    for group in duplicates:
        primary = group.get_primary()
        to_remove = group.get_duplicates()

        if dry_run:
            logger.info(f"Would keep: {primary} ({group.titles[group.note_ids.index(primary)]})")
            for dup_id in to_remove:
                idx = group.note_ids.index(dup_id)
                logger.info(f"  Would remove: {dup_id} ({group.titles[idx]})")
            total_removed += len(to_remove)
        else:
            for dup_id in to_remove:
                try:
                    qdrant_client.delete(
                        collection_name=collection,
                        points_selector=Filter(
                            must=[
                                FieldCondition(
                                    key="note_id",
                                    match=MatchValue(value=dup_id),
                                )
                            ]
                        ),
                    )
                    total_removed += 1
                    logger.info(f"Removed duplicate: {dup_id}")
                except Exception as e:
                    logger.error(f"Failed to remove {dup_id}: {e}")

    action = "Would remove" if dry_run else "Removed"
    logger.info(f"{action} {total_removed:,} duplicate notes")
    return total_removed
