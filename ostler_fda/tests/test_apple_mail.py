"""Tests for Apple Mail extractor."""
from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

from ostler_fda.apple_mail import (
    EmailMessage,
    extract_messages,
    email_stats,
    frequent_contacts,
)


def _create_mail_db(path: Path) -> sqlite3.Connection:
    """Create a Mail Envelope Index with the expected schema."""
    conn = sqlite3.connect(str(path))
    conn.executescript("""
        CREATE TABLE mailboxes (
            ROWID INTEGER PRIMARY KEY,
            url TEXT
        );
        CREATE TABLE messages (
            ROWID INTEGER PRIMARY KEY,
            subject TEXT,
            sender TEXT,
            date_sent REAL,
            date_received REAL,
            read INTEGER DEFAULT 0,
            flagged INTEGER DEFAULT 0,
            message_id TEXT,
            mailbox INTEGER
        );
        CREATE TABLE addresses (
            ROWID INTEGER PRIMARY KEY,
            address TEXT,
            comment TEXT
        );
        CREATE TABLE recipients (
            ROWID INTEGER PRIMARY KEY,
            message_id INTEGER,
            address_id INTEGER
        );
    """)
    return conn


def _recent_unix_time(hours_ago: int = 1) -> float:
    """Mail uses Unix timestamps, not Mac epoch."""
    return datetime.now(timezone.utc).timestamp() - (hours_ago * 3600)


class TestExtractMessages:
    """Test email message extraction."""

    def test_basic_extraction(self, tmp_path):
        # Create V10/MailData directory structure
        mail_data = tmp_path / "V10" / "MailData"
        mail_data.mkdir(parents=True)
        db = mail_data / "Envelope Index"
        conn = _create_mail_db(db)

        conn.execute("INSERT INTO mailboxes (ROWID, url) VALUES (1, 'imap://user@imap.gmail.com/INBOX')")
        conn.execute("""
            INSERT INTO messages (ROWID, subject, sender, date_sent, date_received, read, flagged, message_id, mailbox)
            VALUES (1, 'Hello World', 'Alice <alice@example.com>', ?, ?, 1, 0, 'msg001', 1)
        """, (_recent_unix_time(2), _recent_unix_time(1)))
        conn.commit()
        conn.close()

        messages = extract_messages(db_path=db)
        assert len(messages) == 1
        assert messages[0].subject == "Hello World"
        assert messages[0].sender == "Alice <alice@example.com>"
        assert messages[0].is_read is True
        assert messages[0].mailbox == "INBOX"

    def test_unread_and_flagged(self, tmp_path):
        mail_data = tmp_path / "V10" / "MailData"
        mail_data.mkdir(parents=True)
        db = mail_data / "Envelope Index"
        conn = _create_mail_db(db)

        conn.execute("""
            INSERT INTO messages (ROWID, subject, sender, date_sent, date_received, read, flagged, message_id, mailbox)
            VALUES (1, 'Urgent', 'boss@corp.com', ?, ?, 0, 1, 'msg002', NULL)
        """, (_recent_unix_time(1), _recent_unix_time(0)))
        conn.commit()
        conn.close()

        messages = extract_messages(db_path=db)
        assert messages[0].is_read is False
        assert messages[0].is_flagged is True

    def test_since_days_filter(self, tmp_path):
        mail_data = tmp_path / "V10" / "MailData"
        mail_data.mkdir(parents=True)
        db = mail_data / "Envelope Index"
        conn = _create_mail_db(db)

        conn.execute("""
            INSERT INTO messages (ROWID, subject, sender, date_sent, date_received, read, flagged, message_id, mailbox)
            VALUES (1, 'Recent', 'a@b.com', ?, ?, 0, 0, 'r1', NULL)
        """, (_recent_unix_time(1), _recent_unix_time(0)))
        conn.execute("""
            INSERT INTO messages (ROWID, subject, sender, date_sent, date_received, read, flagged, message_id, mailbox)
            VALUES (2, 'Old', 'a@b.com', ?, ?, 0, 0, 'r2', NULL)
        """, (_recent_unix_time(400 * 24), _recent_unix_time(400 * 24)))
        conn.commit()
        conn.close()

        messages = extract_messages(db_path=db, since_days=365)
        assert len(messages) == 1
        assert messages[0].subject == "Recent"

    def test_limit(self, tmp_path):
        mail_data = tmp_path / "V10" / "MailData"
        mail_data.mkdir(parents=True)
        db = mail_data / "Envelope Index"
        conn = _create_mail_db(db)

        for i in range(10):
            conn.execute("""
                INSERT INTO messages (ROWID, subject, sender, date_sent, date_received, read, flagged, message_id, mailbox)
                VALUES (?, ?, 'a@b.com', ?, ?, 0, 0, ?, NULL)
            """, (i + 1, f"Email {i}", _recent_unix_time(i), _recent_unix_time(i), f"msg{i}"))
        conn.commit()
        conn.close()

        messages = extract_messages(db_path=db, limit=5)
        assert len(messages) == 5

    def test_skips_empty_subjects(self, tmp_path):
        mail_data = tmp_path / "V10" / "MailData"
        mail_data.mkdir(parents=True)
        db = mail_data / "Envelope Index"
        conn = _create_mail_db(db)

        conn.execute("""
            INSERT INTO messages (ROWID, subject, sender, date_sent, date_received, read, flagged, message_id, mailbox)
            VALUES (1, NULL, 'a@b.com', ?, ?, 0, 0, 'r1', NULL)
        """, (_recent_unix_time(1), _recent_unix_time(0)))
        conn.execute("""
            INSERT INTO messages (ROWID, subject, sender, date_sent, date_received, read, flagged, message_id, mailbox)
            VALUES (2, 'Real email', 'a@b.com', ?, ?, 0, 0, 'r2', NULL)
        """, (_recent_unix_time(1), _recent_unix_time(0)))
        conn.commit()
        conn.close()

        messages = extract_messages(db_path=db)
        assert len(messages) == 1

    def test_with_recipients(self, tmp_path):
        mail_data = tmp_path / "V10" / "MailData"
        mail_data.mkdir(parents=True)
        db = mail_data / "Envelope Index"
        conn = _create_mail_db(db)

        conn.execute("""
            INSERT INTO messages (ROWID, subject, sender, date_sent, date_received, read, flagged, message_id, mailbox)
            VALUES (1, 'Team email', 'boss@corp.com', ?, ?, 1, 0, 'msg001', NULL)
        """, (_recent_unix_time(1), _recent_unix_time(0)))
        conn.execute("INSERT INTO addresses (ROWID, address, comment) VALUES (1, 'alice@corp.com', 'Alice')")
        conn.execute("INSERT INTO addresses (ROWID, address, comment) VALUES (2, 'bob@corp.com', 'Bob')")
        conn.execute("INSERT INTO recipients (ROWID, message_id, address_id) VALUES (1, 1, 1)")
        conn.execute("INSERT INTO recipients (ROWID, message_id, address_id) VALUES (2, 1, 2)")
        conn.commit()
        conn.close()

        messages = extract_messages(db_path=db)
        assert len(messages) == 1
        assert "alice@corp.com" in messages[0].recipients
        assert "bob@corp.com" in messages[0].recipients

    def test_file_not_found(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            extract_messages(db_path=tmp_path / "nonexistent")

    def test_empty_database(self, tmp_path):
        mail_data = tmp_path / "V10" / "MailData"
        mail_data.mkdir(parents=True)
        db = mail_data / "Envelope Index"
        conn = _create_mail_db(db)
        conn.close()

        messages = extract_messages(db_path=db)
        assert messages == []


class TestEmailStats:
    """Test email statistics computation."""

    def test_stats(self):
        now = datetime.now(timezone.utc)
        messages = [
            EmailMessage("Subj 1", "Alice <alice@corp.com>", now, now, [], "INBOX", True, False, "m1"),
            EmailMessage("Subj 2", "bob@corp.com", now, now, [], "INBOX", False, True, "m2"),
            EmailMessage("Subj 3", "carol@other.com", now, now, [], "Sent", True, False, "m3"),
        ]
        stats = email_stats(messages)
        assert stats["total_messages"] == 3
        assert stats["unread"] == 1
        assert stats["flagged"] == 1
        assert stats["mailboxes"] == 2
        assert "corp.com" in stats["top_sender_domains"]

    def test_empty_stats(self):
        stats = email_stats([])
        assert stats["total_messages"] == 0


class TestFrequentContacts:
    """Test sender frequency analysis."""

    def test_counts_senders(self):
        now = datetime.now(timezone.utc)
        messages = [
            EmailMessage("S1", "Alice <alice@corp.com>", now, now, [], None, True, False, "m1"),
            EmailMessage("S2", "Alice <alice@corp.com>", now, now, [], None, True, False, "m2"),
            EmailMessage("S3", "bob@corp.com", now, now, [], None, True, False, "m3"),
        ]
        contacts = frequent_contacts(messages)
        assert contacts["alice@corp.com"] == 2
        assert contacts["bob@corp.com"] == 1

    def test_normalises_format(self):
        now = datetime.now(timezone.utc)
        messages = [
            EmailMessage("S1", "Alice Chen <ALICE@Corp.com>", now, now, [], None, True, False, "m1"),
        ]
        contacts = frequent_contacts(messages)
        assert "alice@corp.com" in contacts

    def test_limit(self):
        now = datetime.now(timezone.utc)
        messages = [
            EmailMessage(f"S{i}", f"user{i}@d{i}.com", now, now, [], None, True, False, f"m{i}")
            for i in range(20)
        ]
        contacts = frequent_contacts(messages, limit=5)
        assert len(contacts) == 5
