"""Extract notes from Apple Notes' NoteStore.sqlite.

Apple Notes stores data in:
    ~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite

The schema uses ZICCLOUDSYNCINGOBJECT as the main table with
different ZTYPEID values for notes, folders, attachments, etc.

Note content is stored as gzipped HTML in ZDATA field of
ZICCLOUDSYNCINGOBJECT. The ZTITLE field contains the note title.

Requires Full Disk Access (FDA) permission on macOS Sequoia+.
"""
from __future__ import annotations

import gzip
import logging
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

# Mac absolute time epoch offset
MAC_EPOCH_OFFSET = 978307200

DEFAULT_NOTES_PATH = (
    Path.home() / "Library" / "Group Containers"
    / "group.com.apple.notes" / "NoteStore.sqlite"
)


class _HTMLTextExtractor(HTMLParser):
    """Strip HTML tags, keep text content."""

    def __init__(self):
        super().__init__()
        self.text_parts = []

    def handle_data(self, data):
        self.text_parts.append(data)

    def get_text(self) -> str:
        return " ".join(self.text_parts).strip()


def _html_to_text(html: str) -> str:
    """Convert HTML to plain text."""
    parser = _HTMLTextExtractor()
    parser.feed(html)
    return parser.get_text()


@dataclass
class Note:
    """A single Apple Note."""
    title: str
    text: str
    folder: Optional[str]
    created_at: datetime
    modified_at: datetime
    is_pinned: bool
    is_locked: bool
    word_count: int


def extract_notes(
    db_path: Optional[Path] = None,
    include_locked: bool = False,
) -> list[Note]:
    """Extract all notes from Apple Notes.

    Args:
        db_path: Path to NoteStore.sqlite.
        include_locked: Include password-locked notes. Default: False
            (locked notes likely contain sensitive info the user
            deliberately protected — respect that by default).

    Returns:
        List of Note objects, most recently modified first.

    Raises:
        PermissionError: If FDA is not granted.
        FileNotFoundError: If NoteStore.sqlite doesn't exist.
    """
    db_path = db_path or DEFAULT_NOTES_PATH

    if not db_path.exists():
        raise FileNotFoundError(f"Apple Notes database not found at {db_path}")

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            raise PermissionError(
                "Cannot read Apple Notes. Grant Full Disk Access."
            ) from e
        raise

    conn.row_factory = sqlite3.Row

    try:
        # Query notes with their folder names
        # ZICCLOUDSYNCINGOBJECT contains both notes and folders
        # Notes have ZTITLE and ZBODY / reference to ZDATA
        rows = conn.execute("""
            SELECT
                n.ZTITLE as title,
                n.ZSNIPPET as snippet,
                n.ZCREATIONDATE as created,
                n.ZMODIFICATIONDATE as modified,
                n.ZISPINNED as pinned,
                n.ZISPASSWORDPROTECTED as locked,
                f.ZTITLE as folder_name,
                nb.ZDATA as body_data
            FROM ZICCLOUDSYNCINGOBJECT n
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f
                ON n.ZFOLDER = f.Z_PK
            LEFT JOIN ZICNOTEDATA nb
                ON n.ZNOTEDATA = nb.Z_PK
            WHERE n.ZTITLE IS NOT NULL
              AND n.ZMARKEDFORDELETION != 1
            ORDER BY n.ZMODIFICATIONDATE DESC
        """).fetchall()
    except sqlite3.OperationalError as e:
        logger.debug("Primary Notes query failed: %s", e)
        # Try simpler query without pinned/locked columns (older macOS)
        try:
            rows = conn.execute("""
                SELECT
                    n.ZTITLE as title,
                    n.ZSNIPPET as snippet,
                    n.ZCREATIONDATE as created,
                    n.ZMODIFICATIONDATE as modified,
                    0 as pinned,
                    0 as locked,
                    NULL as folder_name,
                    nb.ZDATA as body_data
                FROM ZICCLOUDSYNCINGOBJECT n
                LEFT JOIN ZICNOTEDATA nb
                    ON n.ZNOTEDATA = nb.Z_PK
                WHERE n.ZTITLE IS NOT NULL
                ORDER BY n.ZMODIFICATIONDATE DESC
            """).fetchall()
        except sqlite3.OperationalError:
            logger.error("Apple Notes schema not recognised on this macOS version")
            conn.close()
            return []

    conn.close()

    notes = []
    for row in rows:
        # Skip locked notes unless explicitly included
        if row["locked"] and not include_locked:
            continue

        # Extract text from the gzipped HTML body
        text = ""
        if row["body_data"]:
            try:
                html = gzip.decompress(row["body_data"]).decode("utf-8")
                text = _html_to_text(html)
            except Exception:
                text = row["snippet"] or ""
        else:
            text = row["snippet"] or ""

        # Convert Mac absolute time — guard against null/zero/negative
        # timestamps which produce "year 0 out of range" errors
        raw_created = row["created"]
        raw_modified = row["modified"]

        if raw_created and raw_created > 0:
            try:
                created = datetime.fromtimestamp(
                    raw_created + MAC_EPOCH_OFFSET, tz=timezone.utc
                )
            except (ValueError, OSError, OverflowError):
                created = datetime.now(timezone.utc)
                logger.debug("Invalid creation date for note '%s', using now", row["title"])
        else:
            created = datetime.now(timezone.utc)

        if raw_modified and raw_modified > 0:
            try:
                modified = datetime.fromtimestamp(
                    raw_modified + MAC_EPOCH_OFFSET, tz=timezone.utc
                )
            except (ValueError, OSError, OverflowError):
                modified = created
                logger.debug("Invalid modification date for note '%s', using created", row["title"])
        else:
            modified = created

        notes.append(Note(
            title=row["title"] or "Untitled",
            text=text,
            folder=row["folder_name"],
            created_at=created,
            modified_at=modified,
            is_pinned=bool(row["pinned"]),
            is_locked=bool(row["locked"]),
            word_count=len(text.split()),
        ))

    logger.info("Extracted %d notes from Apple Notes", len(notes))
    return notes
