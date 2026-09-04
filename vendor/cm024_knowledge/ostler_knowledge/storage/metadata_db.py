"""
Metadata DB - SQLite storage for note metadata.

Tracks notes, chunks, and processing status without storing vectors.

Usage:
    db = MetadataDB("./data/metadata.db")
    db.initialize()
    db.insert_note(note_record)
"""

import json
import logging
import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional

logger = logging.getLogger(__name__)


@dataclass
class NoteRecord:
    """Record for a processed note."""

    id: str
    title: str
    created_at: Optional[datetime]
    updated_at: Optional[datetime]
    compartment_level: int
    tags: List[str]
    source_url: Optional[str]
    word_count: int
    chunk_count: int
    file_path: str
    processed_at: datetime
    evernote_guid: Optional[str] = None


@dataclass
class ChunkRecord:
    """Record for a note chunk."""

    id: str
    note_id: str
    chunk_index: int
    content: str
    token_count: int
    embedded_at: Optional[datetime] = None


class MetadataDB:
    """
    SQLite database for note metadata.

    Stores note and chunk information for:
    - Tracking processing status
    - Enabling incremental updates
    - Providing metadata for searches
    - Generating statistics
    """

    SCHEMA = """
    CREATE TABLE IF NOT EXISTS notes (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at DATETIME,
        updated_at DATETIME,
        compartment_level INTEGER DEFAULT 2,
        tags TEXT,  -- JSON array
        source_url TEXT,
        word_count INTEGER DEFAULT 0,
        chunk_count INTEGER DEFAULT 0,
        file_path TEXT,
        processed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        evernote_guid TEXT
    );

    CREATE TABLE IF NOT EXISTS chunks (
        id TEXT PRIMARY KEY,
        note_id TEXT NOT NULL,
        chunk_index INTEGER NOT NULL,
        content TEXT NOT NULL,
        token_count INTEGER DEFAULT 0,
        embedded_at DATETIME,
        FOREIGN KEY (note_id) REFERENCES notes(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_notes_compartment ON notes(compartment_level);
    CREATE INDEX IF NOT EXISTS idx_notes_created ON notes(created_at);
    CREATE INDEX IF NOT EXISTS idx_chunks_note ON chunks(note_id);
    CREATE INDEX IF NOT EXISTS idx_chunks_embedded ON chunks(embedded_at);
    """

    def __init__(self, db_path: str = "./data/metadata.db"):
        """
        Initialize the metadata database.

        Args:
            db_path: Path to SQLite database file
        """
        self.db_path = Path(db_path)
        self._connection = None

    def initialize(self):
        """Create database and tables."""
        self.db_path.parent.mkdir(parents=True, exist_ok=True)

        with self._get_connection() as conn:
            conn.executescript(self.SCHEMA)

        logger.info(f"Database initialized: {self.db_path}")

    @contextmanager
    def _get_connection(self) -> Iterator[sqlite3.Connection]:
        """Get database connection."""
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def insert_note(self, note: NoteRecord) -> bool:
        """
        Insert or update a note record.

        Args:
            note: NoteRecord to insert

        Returns:
            True if successful
        """
        with self._get_connection() as conn:
            conn.execute("""
                INSERT OR REPLACE INTO notes
                (id, title, created_at, updated_at, compartment_level, tags,
                 source_url, word_count, chunk_count, file_path, processed_at, evernote_guid)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                note.id,
                note.title,
                note.created_at.isoformat() if note.created_at else None,
                note.updated_at.isoformat() if note.updated_at else None,
                note.compartment_level,
                json.dumps(note.tags),
                note.source_url,
                note.word_count,
                note.chunk_count,
                note.file_path,
                note.processed_at.isoformat(),
                note.evernote_guid,
            ))

        return True

    def insert_chunks(self, chunks: List[ChunkRecord]) -> int:
        """
        Insert chunk records.

        Args:
            chunks: List of ChunkRecord objects

        Returns:
            Number inserted
        """
        if not chunks:
            return 0

        with self._get_connection() as conn:
            conn.executemany("""
                INSERT OR REPLACE INTO chunks
                (id, note_id, chunk_index, content, token_count, embedded_at)
                VALUES (?, ?, ?, ?, ?, ?)
            """, [
                (
                    c.id,
                    c.note_id,
                    c.chunk_index,
                    c.content,
                    c.token_count,
                    c.embedded_at.isoformat() if c.embedded_at else None,
                )
                for c in chunks
            ])

        return len(chunks)

    def get_note(self, note_id: str) -> Optional[NoteRecord]:
        """Get a note by ID."""
        with self._get_connection() as conn:
            row = conn.execute(
                "SELECT * FROM notes WHERE id = ?",
                (note_id,)
            ).fetchone()

        if not row:
            return None

        return self._row_to_note(row)

    def get_notes(
        self,
        compartment_level: Optional[int] = None,
        limit: int = 100,
        offset: int = 0,
    ) -> List[NoteRecord]:
        """Get notes with optional filtering."""
        query = "SELECT * FROM notes"
        params = []

        if compartment_level is not None:
            query += " WHERE compartment_level <= ?"
            params.append(compartment_level)

        query += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
        params.extend([limit, offset])

        with self._get_connection() as conn:
            rows = conn.execute(query, params).fetchall()

        return [self._row_to_note(row) for row in rows]

    def get_chunks_for_note(self, note_id: str) -> List[ChunkRecord]:
        """Get all chunks for a note."""
        with self._get_connection() as conn:
            rows = conn.execute(
                "SELECT * FROM chunks WHERE note_id = ? ORDER BY chunk_index",
                (note_id,)
            ).fetchall()

        return [self._row_to_chunk(row) for row in rows]

    def get_unembedded_chunks(self, limit: int = 1000) -> List[ChunkRecord]:
        """Get chunks that haven't been embedded yet."""
        with self._get_connection() as conn:
            rows = conn.execute(
                "SELECT * FROM chunks WHERE embedded_at IS NULL LIMIT ?",
                (limit,)
            ).fetchall()

        return [self._row_to_chunk(row) for row in rows]

    def mark_chunks_embedded(self, chunk_ids: List[str]):
        """Mark chunks as embedded."""
        if not chunk_ids:
            return

        with self._get_connection() as conn:
            now = datetime.now().isoformat()
            conn.executemany(
                "UPDATE chunks SET embedded_at = ? WHERE id = ?",
                [(now, cid) for cid in chunk_ids]
            )

    def delete_note(self, note_id: str):
        """Delete a note and its chunks."""
        with self._get_connection() as conn:
            conn.execute("DELETE FROM chunks WHERE note_id = ?", (note_id,))
            conn.execute("DELETE FROM notes WHERE id = ?", (note_id,))

    def get_stats(self) -> Dict[str, Any]:
        """Get database statistics."""
        with self._get_connection() as conn:
            stats = {}

            # Total notes
            row = conn.execute("SELECT COUNT(*) as count FROM notes").fetchone()
            stats['total_notes'] = row['count']

            # Total chunks
            row = conn.execute("SELECT COUNT(*) as count FROM chunks").fetchone()
            stats['total_chunks'] = row['count']

            # Embedded chunks
            row = conn.execute(
                "SELECT COUNT(*) as count FROM chunks WHERE embedded_at IS NOT NULL"
            ).fetchone()
            stats['embedded_chunks'] = row['count']

            # By compartment level
            rows = conn.execute("""
                SELECT compartment_level, COUNT(*) as count
                FROM notes
                GROUP BY compartment_level
                ORDER BY compartment_level
            """).fetchall()
            stats['by_compartment'] = {row['compartment_level']: row['count'] for row in rows}

            # Date range
            row = conn.execute("""
                SELECT MIN(created_at) as earliest, MAX(created_at) as latest
                FROM notes
            """).fetchone()
            stats['date_range'] = {
                'earliest': row['earliest'],
                'latest': row['latest'],
            }

        return stats

    def _row_to_note(self, row: sqlite3.Row) -> NoteRecord:
        """Convert database row to NoteRecord."""
        return NoteRecord(
            id=row['id'],
            title=row['title'],
            created_at=self._parse_datetime(row['created_at']),
            updated_at=self._parse_datetime(row['updated_at']),
            compartment_level=row['compartment_level'],
            tags=json.loads(row['tags']) if row['tags'] else [],
            source_url=row['source_url'],
            word_count=row['word_count'],
            chunk_count=row['chunk_count'],
            file_path=row['file_path'],
            processed_at=self._parse_datetime(row['processed_at']) or datetime.now(),
            evernote_guid=row['evernote_guid'],
        )

    def _row_to_chunk(self, row: sqlite3.Row) -> ChunkRecord:
        """Convert database row to ChunkRecord."""
        return ChunkRecord(
            id=row['id'],
            note_id=row['note_id'],
            chunk_index=row['chunk_index'],
            content=row['content'],
            token_count=row['token_count'],
            embedded_at=self._parse_datetime(row['embedded_at']),
        )

    def _parse_datetime(self, value: Optional[str]) -> Optional[datetime]:
        """Parse datetime string."""
        if not value:
            return None
        try:
            return datetime.fromisoformat(value)
        except ValueError:
            return None


if __name__ == "__main__":
    # Test the database
    import uuid

    print("Testing MetadataDB...")

    db = MetadataDB("./test_metadata.db")
    db.initialize()

    # Insert a test note
    note = NoteRecord(
        id=str(uuid.uuid4()),
        title="Test Note",
        created_at=datetime.now(),
        updated_at=datetime.now(),
        compartment_level=2,
        tags=["test", "example"],
        source_url=None,
        word_count=100,
        chunk_count=2,
        file_path="/test/path/note.md",
        processed_at=datetime.now(),
    )

    db.insert_note(note)
    print(f"Inserted note: {note.id}")

    # Insert chunks
    chunks = [
        ChunkRecord(
            id=str(uuid.uuid4()),
            note_id=note.id,
            chunk_index=0,
            content="First chunk content...",
            token_count=50,
        ),
        ChunkRecord(
            id=str(uuid.uuid4()),
            note_id=note.id,
            chunk_index=1,
            content="Second chunk content...",
            token_count=50,
        ),
    ]

    db.insert_chunks(chunks)
    print(f"Inserted {len(chunks)} chunks")

    # Get stats
    stats = db.get_stats()
    print(f"Stats: {stats}")

    # Cleanup
    Path("./test_metadata.db").unlink()
    print("Test complete!")
