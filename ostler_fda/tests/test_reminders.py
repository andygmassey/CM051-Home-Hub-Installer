"""Tests for Reminders extractor."""
from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

from ostler_fda.reminders import (
    MAC_EPOCH_OFFSET,
    Reminder,
    extract_reminders,
    reminder_stats,
)


def _create_reminders_db(path: Path) -> sqlite3.Connection:
    """Create a Reminders database with the expected schema."""
    conn = sqlite3.connect(str(path))
    conn.executescript("""
        CREATE TABLE ZREMCDCALENDARLIST (
            Z_PK INTEGER PRIMARY KEY,
            ZTITLE TEXT
        );
        CREATE TABLE ZREMCDREMINDER (
            Z_PK INTEGER PRIMARY KEY,
            ZTITLE1 TEXT,
            ZCOMPLETED INTEGER DEFAULT 0,
            ZDUEDATE REAL,
            ZCOMPLETIONDATE REAL,
            ZCREATIONDATE REAL,
            ZPRIORITY INTEGER DEFAULT 0,
            ZNOTES TEXT,
            ZFLAGGED INTEGER DEFAULT 0,
            ZLIST INTEGER
        );
    """)
    return conn


def _mac_time(year: int, month: int, day: int) -> float:
    return datetime(year, month, day, tzinfo=timezone.utc).timestamp() - MAC_EPOCH_OFFSET


def _recent_mac_time(hours_ago: int = 1) -> float:
    return datetime.now(timezone.utc).timestamp() - MAC_EPOCH_OFFSET - (hours_ago * 3600)


class TestExtractReminders:
    """Test reminder extraction."""

    def test_basic_extraction(self, tmp_path):
        db_dir = tmp_path / "Stores"
        db_dir.mkdir()
        db = db_dir / "reminders.sqlite"
        conn = _create_reminders_db(db)

        conn.execute("INSERT INTO ZREMCDCALENDARLIST (Z_PK, ZTITLE) VALUES (1, 'Shopping')")
        conn.execute("""
            INSERT INTO ZREMCDREMINDER
            (Z_PK, ZTITLE1, ZCOMPLETED, ZDUEDATE, ZCOMPLETIONDATE, ZCREATIONDATE,
             ZPRIORITY, ZNOTES, ZFLAGGED, ZLIST)
            VALUES (1, 'Buy milk', 0, ?, NULL, ?, 0, 'Semi-skimmed', 0, 1)
        """, (_recent_mac_time(-24), _recent_mac_time(48)))
        conn.commit()
        conn.close()

        reminders = extract_reminders(db_path=db)
        assert len(reminders) == 1
        assert reminders[0].title == "Buy milk"
        assert reminders[0].is_completed is False
        assert reminders[0].list_name == "Shopping"
        assert reminders[0].notes == "Semi-skimmed"

    def test_completed_reminder(self, tmp_path):
        db_dir = tmp_path / "Stores"
        db_dir.mkdir()
        db = db_dir / "reminders.sqlite"
        conn = _create_reminders_db(db)

        conn.execute("""
            INSERT INTO ZREMCDREMINDER
            (Z_PK, ZTITLE1, ZCOMPLETED, ZCOMPLETIONDATE, ZCREATIONDATE, ZPRIORITY, ZFLAGGED, ZLIST)
            VALUES (1, 'Done task', 1, ?, ?, 0, 0, NULL)
        """, (_recent_mac_time(1), _recent_mac_time(48)))
        conn.commit()
        conn.close()

        reminders = extract_reminders(db_path=db)
        assert len(reminders) == 1
        assert reminders[0].is_completed is True
        assert reminders[0].completion_date is not None

    def test_exclude_completed(self, tmp_path):
        db_dir = tmp_path / "Stores"
        db_dir.mkdir()
        db = db_dir / "reminders.sqlite"
        conn = _create_reminders_db(db)

        conn.execute("""
            INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE1, ZCOMPLETED, ZCREATIONDATE, ZPRIORITY, ZFLAGGED, ZLIST)
            VALUES (1, 'Pending', 0, ?, 0, 0, NULL)
        """, (_recent_mac_time(1),))
        conn.execute("""
            INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE1, ZCOMPLETED, ZCREATIONDATE, ZPRIORITY, ZFLAGGED, ZLIST)
            VALUES (2, 'Done', 1, ?, 0, 0, NULL)
        """, (_recent_mac_time(1),))
        conn.commit()
        conn.close()

        reminders = extract_reminders(db_path=db, include_completed=False)
        assert len(reminders) == 1
        assert reminders[0].title == "Pending"

    def test_flagged_reminder(self, tmp_path):
        db_dir = tmp_path / "Stores"
        db_dir.mkdir()
        db = db_dir / "reminders.sqlite"
        conn = _create_reminders_db(db)

        conn.execute("""
            INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE1, ZCOMPLETED, ZCREATIONDATE, ZPRIORITY, ZFLAGGED, ZLIST)
            VALUES (1, 'Urgent', 0, ?, 1, 1, NULL)
        """, (_recent_mac_time(1),))
        conn.commit()
        conn.close()

        reminders = extract_reminders(db_path=db)
        assert reminders[0].is_flagged is True
        assert reminders[0].priority == 1

    def test_skips_blank_titles(self, tmp_path):
        db_dir = tmp_path / "Stores"
        db_dir.mkdir()
        db = db_dir / "reminders.sqlite"
        conn = _create_reminders_db(db)

        conn.execute("""
            INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE1, ZCOMPLETED, ZCREATIONDATE, ZPRIORITY, ZFLAGGED, ZLIST)
            VALUES (1, NULL, 0, ?, 0, 0, NULL)
        """, (_recent_mac_time(1),))
        conn.execute("""
            INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE1, ZCOMPLETED, ZCREATIONDATE, ZPRIORITY, ZFLAGGED, ZLIST)
            VALUES (2, 'Real task', 0, ?, 0, 0, NULL)
        """, (_recent_mac_time(1),))
        conn.commit()
        conn.close()

        reminders = extract_reminders(db_path=db)
        assert len(reminders) == 1
        assert reminders[0].title == "Real task"

    def test_since_days_filter(self, tmp_path):
        db_dir = tmp_path / "Stores"
        db_dir.mkdir()
        db = db_dir / "reminders.sqlite"
        conn = _create_reminders_db(db)

        conn.execute("""
            INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE1, ZCOMPLETED, ZCREATIONDATE, ZPRIORITY, ZFLAGGED, ZLIST)
            VALUES (1, 'Recent', 0, ?, 0, 0, NULL)
        """, (_recent_mac_time(1),))
        conn.execute("""
            INSERT INTO ZREMCDREMINDER (Z_PK, ZTITLE1, ZCOMPLETED, ZCREATIONDATE, ZPRIORITY, ZFLAGGED, ZLIST)
            VALUES (2, 'Ancient', 0, ?, 0, 0, NULL)
        """, (_recent_mac_time(400 * 24),))
        conn.commit()
        conn.close()

        reminders = extract_reminders(db_path=db, since_days=365)
        assert len(reminders) == 1
        assert reminders[0].title == "Recent"

    def test_file_not_found(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            extract_reminders(db_path=tmp_path / "nonexistent.sqlite")

    def test_empty_database(self, tmp_path):
        db_dir = tmp_path / "Stores"
        db_dir.mkdir()
        db = db_dir / "reminders.sqlite"
        conn = _create_reminders_db(db)
        conn.close()

        reminders = extract_reminders(db_path=db)
        assert reminders == []


class TestReminderStats:
    """Test stats computation."""

    def test_stats(self):
        now = datetime.now(timezone.utc)
        past = datetime(2025, 1, 1, tzinfo=timezone.utc)
        reminders = [
            Reminder("Task 1", False, past, None, now, 0, None, "Work", False),
            Reminder("Task 2", True, None, now, now, 0, None, "Work", False),
            Reminder("Task 3", False, None, None, now, 1, None, "Personal", True),
        ]
        stats = reminder_stats(reminders)
        assert stats["total_reminders"] == 3
        assert stats["completed"] == 1
        assert stats["pending"] == 2
        assert stats["flagged"] == 1
        assert stats["lists"] == 2
        assert stats["overdue"] == 1  # Task 1 has past due date

    def test_empty_stats(self):
        stats = reminder_stats([])
        assert stats["total_reminders"] == 0
        assert stats["completed"] == 0
