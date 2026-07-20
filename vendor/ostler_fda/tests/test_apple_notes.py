"""Tests for the Apple Notes KNOWLEDGE extractor.

All fixtures are SYNTHETIC -- a tiny temp SQLite built to match the
real Apple Notes schema (ZTITLE1 / ZTITLE2 / ZCREATIONDATE3 /
ZMODIFICATIONDATE1 / gzipped notesgardenpb protobuf bodies). No real
personal notes are read.
"""
from __future__ import annotations

import gzip
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

from ostler_fda.apple_notes import (
    DEFAULT_COMPARTMENT_LEVEL,
    MAC_EPOCH_OFFSET,
    SOURCE,
    Note,
    _decode_body,
    _extract_proto_text,
    _mac_to_datetime,
    _strip_leading_title,
    extract_notes,
    notes_stats,
)


# ---------------------------------------------------------------------------
# Synthetic protobuf fixture builders
# ---------------------------------------------------------------------------

def _varint(value: int) -> bytes:
    out = bytearray()
    while True:
        b = value & 0x7F
        value >>= 7
        if value:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _len_field(field_number: int, payload: bytes) -> bytes:
    """Encode one length-delimited (wire type 2) protobuf field."""
    key = (field_number << 3) | 2
    return _varint(key) + _varint(len(payload)) + payload


def _build_notesgardenpb(note_text: str) -> bytes:
    """Build a minimal notesgardenpb message carrying ``note_text``.

    Nesting mirrors what the real extractor walks:
        NoteStoreProto.document (field 2)
          -> Document.note      (field 3)
            -> Note.note_text   (field 2)
    """
    note = _len_field(2, note_text.encode("utf-8"))
    document = _len_field(3, note)
    store = _len_field(2, document)
    return store


def _gzip(data: bytes) -> bytes:
    return gzip.compress(data)


def _gzipped_note(note_text: str) -> bytes:
    return _gzip(_build_notesgardenpb(note_text))


# ---------------------------------------------------------------------------
# Synthetic DB (real schema)
# ---------------------------------------------------------------------------

def _create_notes_db(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(str(path))
    conn.executescript("""
        CREATE TABLE ZICCLOUDSYNCINGOBJECT (
            Z_PK INTEGER PRIMARY KEY,
            ZTITLE1 TEXT,
            ZTITLE2 TEXT,
            ZSNIPPET TEXT,
            ZCREATIONDATE REAL,
            ZCREATIONDATE1 REAL,
            ZCREATIONDATE3 REAL,
            ZMODIFICATIONDATE REAL,
            ZMODIFICATIONDATE1 REAL,
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


def _insert_folder(conn: sqlite3.Connection, pk: int, name: str) -> None:
    conn.execute(
        "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2) VALUES (?, ?)",
        (pk, name),
    )


def _insert_note(
    conn: sqlite3.Connection,
    pk: int,
    title: str,
    *,
    body: bytes | None = None,
    snippet: str | None = None,
    created3: float | None = None,
    modified1: float | None = None,
    locked: int = 0,
    deleted: int = 0,
    pinned: int = 0,
    folder_pk: int | None = None,
) -> None:
    note_data_pk = None
    if body is not None:
        note_data_pk = 1000 + pk
        conn.execute(
            "INSERT INTO ZICNOTEDATA (Z_PK, ZDATA) VALUES (?, ?)",
            (note_data_pk, body),
        )
    conn.execute(
        """
        INSERT INTO ZICCLOUDSYNCINGOBJECT
        (Z_PK, ZTITLE1, ZSNIPPET, ZCREATIONDATE3, ZMODIFICATIONDATE1,
         ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZFOLDER, ZNOTEDATA)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (pk, title, snippet, created3, modified1, pinned, locked,
         deleted, folder_pk, note_data_pk),
    )


# ---------------------------------------------------------------------------
# Unit tests: protobuf + helpers
# ---------------------------------------------------------------------------

class TestProtobufExtraction:
    def test_extracts_note_text(self):
        raw = _build_notesgardenpb("Title\n\nbody line one\nbody line two")
        assert _extract_proto_text(raw) == "Title\n\nbody line one\nbody line two"

    def test_returns_none_on_garbage(self):
        assert _extract_proto_text(b"\xff\xff\xff not protobuf") is None

    def test_handles_empty(self):
        assert _extract_proto_text(b"") is None


class TestDecodeBody:
    def test_gzipped_protobuf(self):
        blob = _gzipped_note("My Note\n\nfirst para\nsecond para")
        text = _decode_body(blob, "My Note", None)
        # Title line stripped, body preserved.
        assert text == "first para\nsecond para"

    def test_gzipped_html_fallback(self):
        blob = _gzip(b"<html><body>Plain <b>HTML</b> body</body></html>")
        text = _decode_body(blob, "Whatever", None)
        assert "Plain" in text and "HTML" in text and "<" not in text

    def test_uncompressed_blob(self):
        # Not gzip-magic: decoder treats as raw bytes, then protobuf, then text.
        raw = _build_notesgardenpb("T\n\nhello")
        text = _decode_body(raw, "T", None)
        assert "hello" in text

    def test_falls_back_to_snippet_when_no_body(self):
        assert _decode_body(None, "T", "snippet text") == "snippet text"

    def test_empty_snippet_no_body(self):
        assert _decode_body(None, "T", None) == ""


class TestStripLeadingTitle:
    def test_strips_duplicate_title_line(self):
        assert _strip_leading_title("Shopping\n\nmilk\neggs", "Shopping") == "milk\neggs"

    def test_keeps_body_when_no_duplicate(self):
        assert _strip_leading_title("milk\neggs", "Shopping") == "milk\neggs"

    def test_normalises_crlf(self):
        assert _strip_leading_title("T\r\n\r\nbody", "T") == "body"


class TestMacDate:
    def test_converts(self):
        dt = _mac_to_datetime(_mac_time(2025, 3, 15))
        assert dt is not None and dt.year == 2025 and dt.month == 3

    def test_null_returns_none(self):
        assert _mac_to_datetime(None) is None

    def test_zero_returns_none(self):
        assert _mac_to_datetime(0) is None

    def test_negative_returns_none(self):
        assert _mac_to_datetime(-978307200) is None


# ---------------------------------------------------------------------------
# Integration: extract_notes against synthetic real-schema DB
# ---------------------------------------------------------------------------

class TestExtractNotes:
    def test_basic_extraction_knowledge_shape(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)
        _insert_note(
            conn, 1, "Test Note",
            body=_gzipped_note("Test Note\n\nThis is the body content."),
            created3=_mac_time(2025, 3, 15),
            modified1=_mac_time(2025, 3, 16),
        )
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db)
        assert len(notes) == 1
        n = notes[0]
        assert n.title == "Test Note"
        assert n.content == "This is the body content."
        assert n.source == SOURCE == "apple_notes"
        assert n.compartment_level == DEFAULT_COMPARTMENT_LEVEL == 2
        assert n.created.year == 2025 and n.created.month == 3
        assert n.updated.day == 16
        assert n.word_count == 5
        assert n.tags == []

    def test_notebook_from_folder(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)
        _insert_folder(conn, 10, "Work")
        _insert_note(
            conn, 1, "Work Note",
            body=_gzipped_note("Work Note\n\nwork stuff"),
            created3=_mac_time(2025, 1, 1),
            modified1=_mac_time(2025, 1, 1),
            folder_pk=10,
        )
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db)
        work = [n for n in notes if n.title == "Work Note"]
        assert len(work) == 1
        assert work[0].notebook == "Work"

    def test_skips_locked_by_default(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)
        _insert_note(conn, 1, "Secret", body=_gzipped_note("Secret\n\nx"),
                     locked=1, modified1=_mac_time(2025, 1, 1))
        _insert_note(conn, 2, "Open", body=_gzipped_note("Open\n\ny"),
                     modified1=_mac_time(2025, 1, 2))
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db, include_locked=False)
        assert [n.title for n in notes] == ["Open"]

    def test_includes_locked_when_asked(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)
        _insert_note(conn, 1, "Secret", body=_gzipped_note("Secret\n\nx"),
                     locked=1, modified1=_mac_time(2025, 1, 1))
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db, include_locked=True)
        assert len(notes) == 1
        assert notes[0].is_locked is True

    def test_skips_deleted(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)
        _insert_note(conn, 1, "Gone", body=_gzipped_note("Gone\n\nx"),
                     deleted=1, modified1=_mac_time(2025, 1, 1))
        conn.commit()
        conn.close()

        assert extract_notes(db_path=db) == []

    def test_empty_note_skipped_body_blank(self, tmp_path):
        # A note whose body decodes to empty + no snippet still surfaces
        # as a record (title only) -- but content is empty, word_count 0.
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)
        _insert_note(conn, 1, "Titled", body=_gzipped_note("Titled"),
                     modified1=_mac_time(2025, 1, 1))
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db)
        assert len(notes) == 1
        assert notes[0].content == ""
        assert notes[0].word_count == 0

    def test_null_dates_do_not_crash(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)
        # No dates populated at all.
        _insert_note(conn, 1, "Dateless", body=_gzipped_note("Dateless\n\nx"))
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db)
        assert len(notes) == 1
        # created/updated may be None but extraction must not crash.
        assert notes[0].title == "Dateless"

    def test_date_cross_fill(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)
        # Only modification date present; creation should cross-fill.
        _insert_note(conn, 1, "OneDate", body=_gzipped_note("OneDate\n\nx"),
                     modified1=_mac_time(2025, 5, 5))
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db)
        n = notes[0]
        assert n.created is not None and n.updated is not None
        assert n.created == n.updated

    def test_snippet_fallback_when_no_body_blob(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)
        _insert_note(conn, 1, "Snip", body=None, snippet="just the snippet",
                     modified1=_mac_time(2025, 1, 1))
        conn.commit()
        conn.close()

        # body is None so the LEFT JOIN to ZICNOTEDATA yields NULL ZDATA;
        # but the note has ZNOTEDATA NULL so the real-schema query
        # (WHERE ZNOTEDATA IS NOT NULL) skips it. Confirm that contract.
        notes = extract_notes(db_path=db)
        assert notes == []

    def test_file_not_found(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            extract_notes(db_path=tmp_path / "nope.sqlite")

    def test_empty_database(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)
        conn.close()
        assert extract_notes(db_path=db) == []

    def test_ordering_most_recent_first(self, tmp_path):
        db = tmp_path / "NoteStore.sqlite"
        conn = _create_notes_db(db)
        _insert_note(conn, 1, "Older", body=_gzipped_note("Older\n\na"),
                     modified1=_mac_time(2024, 1, 1))
        _insert_note(conn, 2, "Newer", body=_gzipped_note("Newer\n\nb"),
                     modified1=_mac_time(2025, 1, 1))
        conn.commit()
        conn.close()

        notes = extract_notes(db_path=db)
        assert [n.title for n in notes] == ["Newer", "Older"]


class TestNotesStats:
    def test_stats(self):
        notes = [
            Note("A", "one two", "Work", None, None, [], SOURCE, 2, False, False, 2),
            Note("B", "three", "Work", None, None, [], SOURCE, 2, False, False, 1),
            Note("C", "", None, None, None, [], SOURCE, 2, False, False, 0),
        ]
        stats = notes_stats(notes)
        assert stats["notes"] == 3
        assert stats["total_words"] == 3
        assert stats["notebooks"] == 1
