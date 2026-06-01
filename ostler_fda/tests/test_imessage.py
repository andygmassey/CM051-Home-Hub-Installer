"""Tests for iMessage extractor."""
from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

from ostler_fda.imessage import (
    MAC_EPOCH_OFFSET,
    Conversation,
    _convert_timestamp,
    conversation_stats,
    extract_conversations,
    extract_messages,
)


def _create_chat_db(path: Path) -> sqlite3.Connection:
    """Create an iMessage chat.db with the expected schema."""
    conn = sqlite3.connect(str(path))
    conn.executescript("""
        CREATE TABLE handle (
            ROWID INTEGER PRIMARY KEY,
            id TEXT
        );
        CREATE TABLE chat (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT,
            display_name TEXT,
            style INTEGER
        );
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY,
            text TEXT,
            handle_id INTEGER,
            date INTEGER,
            is_from_me INTEGER,
            cache_has_attachments INTEGER DEFAULT 0
        );
        CREATE TABLE chat_handle_join (
            chat_id INTEGER,
            handle_id INTEGER
        );
        CREATE TABLE chat_message_join (
            chat_id INTEGER,
            message_id INTEGER
        );
    """)
    return conn


def _recent_mac_time_seconds(hours_ago: int = 1) -> int:
    """Mac absolute time in seconds (pre-Ventura format)."""
    return int(
        datetime.now(timezone.utc).timestamp()
        - MAC_EPOCH_OFFSET
        - (hours_ago * 3600)
    )


def _recent_mac_time_nanos(hours_ago: int = 1) -> int:
    """Mac absolute time in nanoseconds (Ventura+ format)."""
    return int(
        (datetime.now(timezone.utc).timestamp()
         - MAC_EPOCH_OFFSET
         - (hours_ago * 3600)) * 1e9
    )


class TestConvertTimestamp:
    """Test timestamp conversion for both formats."""

    def test_seconds_format(self):
        """Pre-Ventura: seconds since 2001-01-01."""
        # 2025-01-01 00:00:00 UTC
        mac_seconds = int(datetime(2025, 1, 1, tzinfo=timezone.utc).timestamp() - MAC_EPOCH_OFFSET)
        dt = _convert_timestamp(mac_seconds)
        assert dt.year == 2025
        assert dt.month == 1
        assert dt.day == 1

    def test_nanoseconds_format(self):
        """Ventura+: nanoseconds since 2001-01-01."""
        mac_seconds = int(datetime(2025, 6, 15, 12, 0, 0, tzinfo=timezone.utc).timestamp() - MAC_EPOCH_OFFSET)
        mac_nanos = mac_seconds * int(1e9)
        dt = _convert_timestamp(mac_nanos)
        assert dt.year == 2025
        assert dt.month == 6
        assert dt.day == 15


class TestExtractConversations:
    """Test conversation extraction."""

    def test_basic_conversation(self, tmp_path):
        db = tmp_path / "chat.db"
        conn = _create_chat_db(db)

        # Insert a handle (contact)
        conn.execute("INSERT INTO handle (ROWID, id) VALUES (1, '+447777123456')")
        # Insert a chat
        conn.execute("INSERT INTO chat (ROWID, guid, display_name, style) VALUES (1, 'chat123', NULL, 45)")
        # Link handle to chat
        conn.execute("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1)")
        # Insert messages
        t = _recent_mac_time_seconds(1)
        conn.execute("INSERT INTO message (ROWID, text, handle_id, date, is_from_me, cache_has_attachments) VALUES (1, 'Hello', 1, ?, 0, 0)", (t,))
        conn.execute("INSERT INTO message (ROWID, text, handle_id, date, is_from_me, cache_has_attachments) VALUES (2, 'Hi back', NULL, ?, 1, 0)", (t + 60,))
        conn.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1)")
        conn.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 2)")
        conn.commit()
        conn.close()

        convos = extract_conversations(db_path=db, min_messages=1)
        assert len(convos) == 1
        assert convos[0].message_count == 2
        assert "+447777123456" in convos[0].participants
        assert convos[0].is_group is False

    def test_group_chat(self, tmp_path):
        db = tmp_path / "chat.db"
        conn = _create_chat_db(db)

        conn.execute("INSERT INTO handle (ROWID, id) VALUES (1, '+447777111111')")
        conn.execute("INSERT INTO handle (ROWID, id) VALUES (2, '+447777222222')")
        conn.execute("INSERT INTO chat (ROWID, guid, display_name, style) VALUES (1, 'group1', 'The Gang', 43)")
        conn.execute("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1)")
        conn.execute("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 2)")

        t = _recent_mac_time_seconds(1)
        for i in range(3):
            conn.execute(
                "INSERT INTO message (ROWID, text, handle_id, date, is_from_me, cache_has_attachments) VALUES (?, 'msg', 1, ?, 0, 0)",
                (i + 1, t + i * 60),
            )
            conn.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, ?)", (i + 1,))

        conn.commit()
        conn.close()

        convos = extract_conversations(db_path=db, min_messages=2)
        assert len(convos) == 1
        assert convos[0].is_group is True
        assert convos[0].display_name == "The Gang"
        assert len(convos[0].participants) == 2

    def test_min_messages_filter(self, tmp_path):
        db = tmp_path / "chat.db"
        conn = _create_chat_db(db)

        conn.execute("INSERT INTO handle (ROWID, id) VALUES (1, '+447777111111')")
        conn.execute("INSERT INTO chat (ROWID, guid, display_name, style) VALUES (1, 'chat1', NULL, 45)")
        conn.execute("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1)")

        t = _recent_mac_time_seconds(1)
        conn.execute("INSERT INTO message (ROWID, text, handle_id, date, is_from_me, cache_has_attachments) VALUES (1, 'single', 1, ?, 0, 0)", (t,))
        conn.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1)")
        conn.commit()
        conn.close()

        convos = extract_conversations(db_path=db, min_messages=2)
        assert len(convos) == 0

    def test_file_not_found(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            extract_conversations(db_path=tmp_path / "nonexistent.db")


class TestExtractMessages:
    """Test per-conversation message extraction."""

    def test_extract_by_chat_id(self, tmp_path):
        db = tmp_path / "chat.db"
        conn = _create_chat_db(db)

        conn.execute("INSERT INTO handle (ROWID, id) VALUES (1, '+447777111111')")
        conn.execute("INSERT INTO chat (ROWID, guid, display_name, style) VALUES (1, 'chat1', NULL, 45)")

        t = _recent_mac_time_seconds(1)
        conn.execute("INSERT INTO message (ROWID, text, handle_id, date, is_from_me, cache_has_attachments) VALUES (1, 'Hello', 1, ?, 0, 0)", (t,))
        conn.execute("INSERT INTO message (ROWID, text, handle_id, date, is_from_me, cache_has_attachments) VALUES (2, 'Hey!', NULL, ?, 1, 0)", (t + 60,))
        conn.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1)")
        conn.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 2)")
        conn.commit()
        conn.close()

        msgs = extract_messages("chat1", db_path=db)
        assert len(msgs) == 2
        # Chronological order
        assert msgs[0].text == "Hello"
        assert msgs[0].is_from_me is False
        assert msgs[1].text == "Hey!"
        assert msgs[1].is_from_me is True
        assert msgs[1].sender == "me"


class TestConversationStats:
    """Test stats computation."""

    def test_stats(self):
        now = datetime.now(timezone.utc)
        convos = [
            Conversation("c1", None, ["+44111", "+44222"], 10, now, now, False),
            Conversation("c2", "Group", ["+44222", "+44333"], 5, now, now, True),
        ]
        stats = conversation_stats(convos)
        assert stats["total_conversations"] == 2
        assert stats["total_messages"] == 15
        assert stats["unique_contacts"] == 3
        assert stats["group_chats"] == 1

    def test_empty_stats(self):
        stats = conversation_stats([])
        assert stats["total_conversations"] == 0
