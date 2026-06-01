"""Tests for Photos metadata extractor."""
from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

from ostler_fda.photos_metadata import (
    MAC_EPOCH_OFFSET,
    PersonInPhotos,
    PhotoEvent,
    extract_people,
    extract_photo_events,
)


def _create_photos_db(path: Path) -> sqlite3.Connection:
    """Create a Photos.sqlite with the expected schema."""
    conn = sqlite3.connect(str(path))
    conn.executescript("""
        CREATE TABLE ZPERSON (
            Z_PK INTEGER PRIMARY KEY,
            ZFULLNAME TEXT,
            ZTYPE INTEGER DEFAULT 0
        );
        CREATE TABLE ZDETECTEDFACE (
            Z_PK INTEGER PRIMARY KEY,
            ZPERSON INTEGER,
            ZASSET INTEGER
        );
        CREATE TABLE ZASSET (
            Z_PK INTEGER PRIMARY KEY,
            ZDATECREATED REAL,
            ZLATITUDE REAL,
            ZLONGITUDE REAL,
            ZREVERSELOCATIONDATA BLOB,
            ZTRASHEDSTATE INTEGER DEFAULT 0
        );
    """)
    return conn


def _mac_time(year: int, month: int, day: int) -> float:
    return datetime(year, month, day, tzinfo=timezone.utc).timestamp() - MAC_EPOCH_OFFSET


def _recent_mac_time(hours_ago: int = 1) -> float:
    return datetime.now(timezone.utc).timestamp() - MAC_EPOCH_OFFSET - (hours_ago * 3600)


class TestExtractPeople:
    """Test face/person extraction."""

    def test_basic_extraction(self, tmp_path):
        db = tmp_path / "Photos.sqlite"
        conn = _create_photos_db(db)

        conn.execute("INSERT INTO ZPERSON (Z_PK, ZFULLNAME, ZTYPE) VALUES (1, 'Alice Chen', 1)")
        conn.execute("INSERT INTO ZASSET (Z_PK, ZDATECREATED) VALUES (1, ?)", (_recent_mac_time(1),))
        conn.execute("INSERT INTO ZASSET (Z_PK, ZDATECREATED) VALUES (2, ?)", (_recent_mac_time(2),))
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (1, 1, 1)")
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (2, 1, 2)")
        conn.commit()
        conn.close()

        people = extract_people(db_path=db)
        assert len(people) == 1
        assert people[0].name == "Alice Chen"
        assert people[0].photo_count == 2
        assert people[0].is_key_face is True

    def test_skips_unnamed(self, tmp_path):
        db = tmp_path / "Photos.sqlite"
        conn = _create_photos_db(db)

        conn.execute("INSERT INTO ZPERSON (Z_PK, ZFULLNAME, ZTYPE) VALUES (1, NULL, 0)")
        conn.execute("INSERT INTO ZPERSON (Z_PK, ZFULLNAME, ZTYPE) VALUES (2, '', 0)")
        conn.execute("INSERT INTO ZPERSON (Z_PK, ZFULLNAME, ZTYPE) VALUES (3, 'Bob', 1)")
        conn.execute("INSERT INTO ZASSET (Z_PK, ZDATECREATED) VALUES (1, ?)", (_recent_mac_time(1),))
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (1, 1, 1)")
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (2, 2, 1)")
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (3, 3, 1)")
        conn.commit()
        conn.close()

        people = extract_people(db_path=db)
        assert len(people) == 1
        assert people[0].name == "Bob"

    def test_sorted_by_photo_count(self, tmp_path):
        db = tmp_path / "Photos.sqlite"
        conn = _create_photos_db(db)

        conn.execute("INSERT INTO ZPERSON (Z_PK, ZFULLNAME, ZTYPE) VALUES (1, 'Rare', 0)")
        conn.execute("INSERT INTO ZPERSON (Z_PK, ZFULLNAME, ZTYPE) VALUES (2, 'Common', 0)")

        for i in range(1, 6):
            conn.execute("INSERT INTO ZASSET (Z_PK, ZDATECREATED) VALUES (?, ?)", (i, _recent_mac_time(i)))

        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (1, 1, 1)")
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (2, 2, 1)")
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (3, 2, 2)")
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (4, 2, 3)")
        conn.commit()
        conn.close()

        people = extract_people(db_path=db)
        assert people[0].name == "Common"
        assert people[0].photo_count == 3

    def test_auto_vs_confirmed(self, tmp_path):
        db = tmp_path / "Photos.sqlite"
        conn = _create_photos_db(db)

        conn.execute("INSERT INTO ZPERSON (Z_PK, ZFULLNAME, ZTYPE) VALUES (1, 'Auto', 0)")
        conn.execute("INSERT INTO ZPERSON (Z_PK, ZFULLNAME, ZTYPE) VALUES (2, 'Confirmed', 1)")
        conn.execute("INSERT INTO ZASSET (Z_PK, ZDATECREATED) VALUES (1, ?)", (_recent_mac_time(1),))
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (1, 1, 1)")
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (2, 2, 1)")
        conn.commit()
        conn.close()

        people = extract_people(db_path=db)
        auto = next(p for p in people if p.name == "Auto")
        confirmed = next(p for p in people if p.name == "Confirmed")
        assert auto.is_key_face is False
        assert confirmed.is_key_face is True

    def test_file_not_found(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            extract_people(db_path=tmp_path / "nonexistent.sqlite")

    def test_empty_database(self, tmp_path):
        db = tmp_path / "Photos.sqlite"
        conn = _create_photos_db(db)
        conn.close()

        people = extract_people(db_path=db)
        assert people == []


class TestExtractPhotoEvents:
    """Test photo event extraction for timeline."""

    def test_basic_extraction(self, tmp_path):
        db = tmp_path / "Photos.sqlite"
        conn = _create_photos_db(db)

        conn.execute("INSERT INTO ZPERSON (Z_PK, ZFULLNAME, ZTYPE) VALUES (1, 'Alice', 1)")
        conn.execute("""
            INSERT INTO ZASSET (Z_PK, ZDATECREATED, ZLATITUDE, ZLONGITUDE, ZTRASHEDSTATE)
            VALUES (1, ?, 22.2783, 114.1747, 0)
        """, (_recent_mac_time(1),))
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (1, 1, 1)")
        conn.commit()
        conn.close()

        events = extract_photo_events(db_path=db)
        assert len(events) == 1
        assert events[0].people == ["Alice"]
        assert events[0].latitude == pytest.approx(22.2783, abs=0.001)
        assert events[0].longitude == pytest.approx(114.1747, abs=0.001)

    def test_skips_trashed(self, tmp_path):
        db = tmp_path / "Photos.sqlite"
        conn = _create_photos_db(db)

        conn.execute("INSERT INTO ZPERSON (Z_PK, ZFULLNAME, ZTYPE) VALUES (1, 'Alice', 1)")
        conn.execute("""
            INSERT INTO ZASSET (Z_PK, ZDATECREATED, ZTRASHEDSTATE) VALUES (1, ?, 1)
        """, (_recent_mac_time(1),))
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (1, 1, 1)")
        conn.commit()
        conn.close()

        events = extract_photo_events(db_path=db)
        assert len(events) == 0

    def test_zero_gps_treated_as_none(self, tmp_path):
        db = tmp_path / "Photos.sqlite"
        conn = _create_photos_db(db)

        conn.execute("INSERT INTO ZPERSON (Z_PK, ZFULLNAME, ZTYPE) VALUES (1, 'Bob', 1)")
        conn.execute("""
            INSERT INTO ZASSET (Z_PK, ZDATECREATED, ZLATITUDE, ZLONGITUDE, ZTRASHEDSTATE)
            VALUES (1, ?, 0, 0, 0)
        """, (_recent_mac_time(1),))
        conn.execute("INSERT INTO ZDETECTEDFACE (Z_PK, ZPERSON, ZASSET) VALUES (1, 1, 1)")
        conn.commit()
        conn.close()

        events = extract_photo_events(db_path=db)
        assert len(events) == 1
        assert events[0].latitude is None
        assert events[0].longitude is None

    def test_file_not_found(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            extract_photo_events(db_path=tmp_path / "nonexistent.sqlite")
