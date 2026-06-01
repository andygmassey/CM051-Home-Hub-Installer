"""Tests for Safari history extractor."""
from __future__ import annotations

import sqlite3
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import pytest

from ostler_fda.safari_history import (
    MAC_EPOCH_OFFSET,
    HistoryEntry,
    extract_history,
    top_domains,
    to_timeline_entries,
)


def _create_history_db(path: Path, entries: list[tuple]) -> None:
    """Create a Safari History.db with test data.

    entries: list of (url, visit_count, visit_time_mac, title)
    """
    conn = sqlite3.connect(str(path))
    conn.execute("""
        CREATE TABLE history_items (
            id INTEGER PRIMARY KEY,
            url TEXT,
            visit_count INTEGER
        )
    """)
    conn.execute("""
        CREATE TABLE history_visits (
            id INTEGER PRIMARY KEY,
            history_item INTEGER,
            visit_time REAL,
            title TEXT,
            redirect_source INTEGER,
            FOREIGN KEY (history_item) REFERENCES history_items(id)
        )
    """)
    for i, (url, count, visit_time, title) in enumerate(entries, 1):
        conn.execute(
            "INSERT INTO history_items (id, url, visit_count) VALUES (?, ?, ?)",
            (i, url, count),
        )
        conn.execute(
            "INSERT INTO history_visits (history_item, visit_time, title, redirect_source) VALUES (?, ?, ?, NULL)",
            (i, visit_time, title),
        )
    conn.commit()
    conn.close()


def _recent_mac_time(hours_ago: int = 1) -> float:
    """Return a Mac absolute time for N hours ago."""
    return datetime.now(timezone.utc).timestamp() - MAC_EPOCH_OFFSET - (hours_ago * 3600)


class TestExtractHistory:
    """Test safari history extraction."""

    def test_basic_extraction(self, tmp_path):
        db = tmp_path / "History.db"
        _create_history_db(db, [
            ("https://example.com/page1", 3, _recent_mac_time(1), "Example Page"),
            ("https://github.com/repo", 1, _recent_mac_time(2), "GitHub Repo"),
        ])
        entries = extract_history(db_path=db)
        assert len(entries) == 2
        assert entries[0].domain == "example.com"
        assert entries[0].title == "Example Page"
        assert entries[0].visit_count == 3

    def test_skips_localhost(self, tmp_path):
        db = tmp_path / "History.db"
        _create_history_db(db, [
            ("http://localhost:8080/test", 1, _recent_mac_time(1), "Local"),
            ("https://example.com/", 1, _recent_mac_time(1), "Remote"),
        ])
        entries = extract_history(db_path=db)
        assert len(entries) == 1
        assert entries[0].domain == "example.com"

    def test_skips_non_http(self, tmp_path):
        db = tmp_path / "History.db"
        _create_history_db(db, [
            ("file:///Users/test/doc.html", 1, _recent_mac_time(1), "File"),
            ("https://example.com/", 1, _recent_mac_time(1), "Web"),
        ])
        entries = extract_history(db_path=db)
        assert len(entries) == 1

    def test_since_days_filter(self, tmp_path):
        db = tmp_path / "History.db"
        # One entry from 1 hour ago, one from 400 days ago
        old_time = _recent_mac_time(400 * 24)
        _create_history_db(db, [
            ("https://recent.com/", 1, _recent_mac_time(1), "Recent"),
            ("https://old.com/", 1, old_time, "Old"),
        ])
        entries = extract_history(db_path=db, since_days=365)
        assert len(entries) == 1
        assert entries[0].domain == "recent.com"

    def test_min_visits_filter(self, tmp_path):
        db = tmp_path / "History.db"
        _create_history_db(db, [
            ("https://popular.com/", 5, _recent_mac_time(1), "Popular"),
            ("https://rare.com/", 1, _recent_mac_time(1), "Rare"),
        ])
        entries = extract_history(db_path=db, min_visits=3)
        assert len(entries) == 1
        assert entries[0].domain == "popular.com"

    def test_file_not_found(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            extract_history(db_path=tmp_path / "nonexistent.db")

    def test_empty_database(self, tmp_path):
        db = tmp_path / "History.db"
        _create_history_db(db, [])
        entries = extract_history(db_path=db)
        assert entries == []

    def test_timestamp_conversion(self, tmp_path):
        """Mac absolute time should convert correctly to UTC datetime."""
        db = tmp_path / "History.db"
        # 2025-01-01 12:00:00 UTC as Mac absolute time
        mac_time = datetime(2025, 1, 1, 12, 0, 0, tzinfo=timezone.utc).timestamp() - MAC_EPOCH_OFFSET
        _create_history_db(db, [
            ("https://example.com/", 1, mac_time, "Test"),
        ])
        entries = extract_history(db_path=db, since_days=3650)
        assert len(entries) == 1
        assert entries[0].visit_time.year == 2025
        assert entries[0].visit_time.month == 1
        assert entries[0].visit_time.day == 1


class TestTopDomains:
    """Test domain aggregation."""

    def test_sorts_by_visits(self):
        now = datetime.now(timezone.utc)
        entries = [
            HistoryEntry("https://a.com/1", "a.com", "A1", now, 1),
            HistoryEntry("https://a.com/2", "a.com", "A2", now, 1),
            HistoryEntry("https://b.com/1", "b.com", "B1", now, 1),
        ]
        domains = top_domains(entries)
        assert domains[0].domain == "a.com"
        assert domains[0].total_visits == 2
        assert domains[0].unique_urls == 2

    def test_excludes_infra_domains(self):
        now = datetime.now(timezone.utc)
        entries = [
            HistoryEntry("https://google.com/search", "google.com", "Search", now, 1),
            HistoryEntry("https://example.com/", "example.com", "Ex", now, 1),
        ]
        domains = top_domains(entries, exclude_infra=True)
        assert len(domains) == 1
        assert domains[0].domain == "example.com"

    def test_includes_infra_when_asked(self):
        now = datetime.now(timezone.utc)
        entries = [
            HistoryEntry("https://google.com/search", "google.com", "Search", now, 1),
        ]
        domains = top_domains(entries, exclude_infra=False)
        assert len(domains) == 1

    def test_limit(self):
        now = datetime.now(timezone.utc)
        entries = [
            HistoryEntry(f"https://d{i}.com/", f"d{i}.com", f"D{i}", now, 1)
            for i in range(10)
        ]
        domains = top_domains(entries, limit=3)
        assert len(domains) == 3


class TestTimelineEntries:
    """Test timeline format conversion."""

    def test_format(self):
        now = datetime.now(timezone.utc)
        entries = [
            HistoryEntry("https://example.com/page", "example.com", "Page", now, 2),
        ]
        timeline = to_timeline_entries(entries)
        assert len(timeline) == 1
        assert timeline[0]["type"] == "web_visit"
        assert timeline[0]["source"] == "safari_history"
        assert timeline[0]["url"] == "https://example.com/page"
        assert timeline[0]["visit_count"] == 2
