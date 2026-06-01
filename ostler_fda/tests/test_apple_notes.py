"""Tests for Apple Notes extractor."""
from __future__ import annotations

import gzip
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

from ostler_fda.apple_notes import (
    MAC_EPOCH_OFFSET,
    Note,
    _html_to_text,
    extract_notes,
)


def _create_notes_db(path: Path) -> sqlite3.Connection:
    """Create a NoteStore.sqlite with the expected schema."""
    conn = sqlite3.connect(str(path))
    conn.executescript("""
        CREATE TABLE ZICCLOUDSYNCINGOBJECT (
            Z_PK INTEGER PRIMARY KEY,
            ZTITLE TEXT,
            ZSNIPPET TEXT,
            ZCREATIONDATE REAL,
            ZMODIFICATIONDATE REAL,
            ZISPINNED INTEGER DEFAULT 0,
            ZISPASSWORDPROTECTED INTEGER DEFAULT 0,
            ZMARKEDFORDELETION INTEGER DEFAULT 0,
            ZFOLDER INTEGER,
            ZNOTEDATA INTEGER
        );
        CREATE TABLE ZICNOTEDATA (
            Z_PK INTEGER PRIMARY KEY,
            ZDATA BLOB
        );
    """)
    return conn


def _mac_time(year: int, month: int, day: int) -> float:
    return datetime(year, month, day, tzinfo=timezone.utc).timestamp() - MAC_EPOCH_OFFSET


def _gzip_html(html: str) -> bytes:
    return gzip.compress(html.encode("utf-8"))


class TestHtmlToText:
    """Test HTML stripping."""

    def test_strips_tags(self):
        result = _html_to_text("<p>Hello <b>world</b></p>")
        assert "Hello" in result
        assert "world" in result
        assert "<" not in result

    def test_plain_text_passthrough(self):
        assert _html_to_text("No tags here") == "No tags here"

    def test_empty_string(self):
        assert _html_to_text("") == ""

    def test_nested_tags(self):
        text = _html_to_text("<div><ul><li>Item 1</li><li>Item 2</li></ul></div>")
        assert "Item 1" in text
        assert "Item 2" in text


class TestExtractNotes:
    """Test note extraction."""

    def test_basic_extraction(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)

        html = _gzip_html("<html><body>This is a test note with some content.</body></html>")
        conn.execute(
            "INSERT INTO ZICNOTEDATA (Z_PK, ZDATA) VALUES (1, ?)",
            (html,),
        )
        conn.execute("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, ZTITLE, ZSNIPPET, ZCREATIONDATE, ZMODIFICATIONDATE,
             ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZFOLDER, ZNOTEDATA)
            VALUES (1, 'Test Note', 'snippet', ?, ?, 0, 0, 0, NULL, 1)
        """, (_mac_time(2025, 3, 15), _mac_time(2025, 3, 16)))
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db)
        assert len(notes) == 1
        assert notes[0].title == "Test Note"
        assert "test note" in notes[0].text.lower()
        assert notes[0].word_count > 0

    def test_skips_locked_by_default(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)

        conn.execute("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, ZTITLE, ZSNIPPET, ZCREATIONDATE, ZMODIFICATIONDATE,
             ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZFOLDER, ZNOTEDATA)
            VALUES (1, 'Secret Note', 'secret', ?, ?, 0, 1, 0, NULL, NULL)
        """, (_mac_time(2025, 1, 1), _mac_time(2025, 1, 1)))
        conn.execute("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, ZTITLE, ZSNIPPET, ZCREATIONDATE, ZMODIFICATIONDATE,
             ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZFOLDER, ZNOTEDATA)
            VALUES (2, 'Open Note', 'open', ?, ?, 0, 0, 0, NULL, NULL)
        """, (_mac_time(2025, 1, 1), _mac_time(2025, 1, 1)))
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db, include_locked=False)
        assert len(notes) == 1
        assert notes[0].title == "Open Note"

    def test_includes_locked_when_asked(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)

        conn.execute("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, ZTITLE, ZSNIPPET, ZCREATIONDATE, ZMODIFICATIONDATE,
             ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZFOLDER, ZNOTEDATA)
            VALUES (1, 'Secret Note', 'secret', ?, ?, 0, 1, 0, NULL, NULL)
        """, (_mac_time(2025, 1, 1), _mac_time(2025, 1, 1)))
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db, include_locked=True)
        assert len(notes) == 1

    def test_skips_deleted(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)

        conn.execute("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, ZTITLE, ZSNIPPET, ZCREATIONDATE, ZMODIFICATIONDATE,
             ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZFOLDER, ZNOTEDATA)
            VALUES (1, 'Deleted Note', 'deleted', ?, ?, 0, 0, 1, NULL, NULL)
        """, (_mac_time(2025, 1, 1), _mac_time(2025, 1, 1)))
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db)
        assert len(notes) == 0

    def test_folder_names(self, tmp_path):
        """Notes in folders should have their folder name populated."""
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)

        # Create a folder (ZISPINNED and ZISPASSWORDPROTECTED must exist
        # for the query to match — but folders don't have these columns
        # in the real schema, so they'll be returned as notes too.
        # The real Apple schema uses ZTYPEUTI to distinguish, but our
        # simplified test schema doesn't have that. Test that the note
        # with a folder reference gets the folder name.)
        conn.execute("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, ZTITLE, ZCREATIONDATE, ZMODIFICATIONDATE,
             ZMARKEDFORDELETION, ZISPINNED, ZISPASSWORDPROTECTED)
            VALUES (10, 'Work', ?, ?, 0, 0, 0)
        """, (_mac_time(2025, 1, 1), _mac_time(2025, 1, 1)))

        # Create a note in the folder
        conn.execute("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, ZTITLE, ZSNIPPET, ZCREATIONDATE, ZMODIFICATIONDATE,
             ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZFOLDER, ZNOTEDATA)
            VALUES (1, 'Work Note', 'work stuff', ?, ?, 0, 0, 0, 10, NULL)
        """, (_mac_time(2025, 1, 1), _mac_time(2025, 1, 1)))
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db)
        # Find the actual note (folder row may also appear since our
        # test schema lacks ZTYPEUTI filtering)
        work_notes = [n for n in notes if n.title == "Work Note"]
        assert len(work_notes) == 1
        assert work_notes[0].folder == "Work"

    def test_falls_back_to_snippet(self, tmp_path):
        """When body_data is NULL, use snippet."""
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)

        conn.execute("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, ZTITLE, ZSNIPPET, ZCREATIONDATE, ZMODIFICATIONDATE,
             ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZFOLDER, ZNOTEDATA)
            VALUES (1, 'Snippet Note', 'this is the snippet text', ?, ?, 0, 0, 0, NULL, NULL)
        """, (_mac_time(2025, 1, 1), _mac_time(2025, 1, 1)))
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db)
        assert len(notes) == 1
        assert notes[0].text == "this is the snippet text"

    def test_file_not_found(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            extract_notes(db_path=tmp_path / "nonexistent.sqlite")

    def test_null_creation_date(self, tmp_path):
        """Notes with NULL or zero creation dates should not crash (year 0 bug)."""
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)

        # NULL creation date
        conn.execute("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, ZTITLE, ZSNIPPET, ZCREATIONDATE, ZMODIFICATIONDATE,
             ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZFOLDER, ZNOTEDATA)
            VALUES (1, 'Null Date Note', 'test', NULL, ?, 0, 0, 0, NULL, NULL)
        """, (_mac_time(2025, 1, 1),))
        # Zero creation date
        conn.execute("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, ZTITLE, ZSNIPPET, ZCREATIONDATE, ZMODIFICATIONDATE,
             ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZFOLDER, ZNOTEDATA)
            VALUES (2, 'Zero Date Note', 'test', 0, ?, 0, 0, 0, NULL, NULL)
        """, (_mac_time(2025, 1, 1),))
        # Negative creation date (corrupt data)
        conn.execute("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT
            (Z_PK, ZTITLE, ZSNIPPET, ZCREATIONDATE, ZMODIFICATIONDATE,
             ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZFOLDER, ZNOTEDATA)
            VALUES (3, 'Negative Date Note', 'test', -978307200, ?, 0, 0, 0, NULL, NULL)
        """, (_mac_time(2025, 1, 1),))
        conn.commit()
        conn.close()

        # Should not crash
        notes = extract_notes(db_path=db)
        assert len(notes) == 3
        for note in notes:
            assert note.created_at.year >= 2000

    def test_empty_database(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)
        conn.close()

        notes = extract_notes(db_path=db)
        assert notes == []
