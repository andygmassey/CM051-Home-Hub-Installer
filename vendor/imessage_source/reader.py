"""Read conversations + messages from the macOS iMessage ``chat.db``.

iMessage stores everything in ``~/Library/Messages/chat.db`` (SQLite).
Reading it requires Full Disk Access (FDA) on macOS Sequoia+, which
the Ostler installer grants at setup time.

Tables of interest:
    message            individual messages (text, timestamp, sender)
    handle             phone numbers / Apple IDs (participants)
    chat               conversation threads (1:1 or group)
    chat_handle_join   participants -> chats
    chat_message_join  messages -> chats

Timestamps are Mac absolute time (seconds since 2001-01-01). macOS
Ventura+ stores them in nanoseconds; we detect and normalise.

The reader opens the DB read-only (``mode=ro``) and never writes. A
``db_path`` argument is injectable so tests run against a synthetic
fixture DB with no real-person data.
"""
from __future__ import annotations

import logging
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

MAC_EPOCH_OFFSET = 978307200  # 2001-01-01T00:00:00Z in Unix seconds
DEFAULT_CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"

# chat.style values: 43 = group, 45 = individual (1:1).
_CHAT_STYLE_GROUP = 43


@dataclass
class Conversation:
    """A conversation thread (1:1 or group)."""

    chat_id: str  # chat.guid -- stable across re-reads
    display_name: Optional[str]
    participants: list[str]  # handle ids (phone / email)
    message_count: int
    first_message: Optional[datetime]
    last_message: Optional[datetime]
    is_group: bool


@dataclass
class Message:
    """A single iMessage / SMS row."""

    rowid: int
    text: Optional[str]
    sender: str  # handle id, or "me" for outgoing
    timestamp: datetime
    is_from_me: bool
    chat_id: str
    has_attachment: bool
    service: str  # "iMessage" | "SMS"


def _convert_timestamp(raw: int) -> datetime:
    """Mac absolute time -> aware UTC datetime.

    Ventura+ uses nanoseconds; older macOS uses seconds. We detect by
    magnitude (ns values are astronomically large as seconds).
    """
    if raw > 1e15:  # nanoseconds (Ventura+)
        unix_ts = (raw / 1e9) + MAC_EPOCH_OFFSET
    else:  # seconds (older macOS)
        unix_ts = raw + MAC_EPOCH_OFFSET
    return datetime.fromtimestamp(unix_ts, tz=timezone.utc)


def _connect_ro(db_path: Path) -> sqlite3.Connection:
    """Open ``chat.db`` read-only, translating the FDA-denied error
    into a clear ``PermissionError`` the installer / Doctor can act
    on."""
    if not db_path.exists():
        raise FileNotFoundError(f"iMessage database not found at {db_path}")
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.OperationalError as exc:
        if "authorization denied" in str(exc).lower():
            raise PermissionError(
                "Cannot read iMessage history. Grant Full Disk Access "
                "to the Ostler Hub in System Settings > Privacy & "
                "Security > Full Disk Access."
            ) from exc
        raise
    conn.row_factory = sqlite3.Row
    return conn


def extract_conversations(
    db_path: Optional[Path] = None,
    since_days: int = 365,
    min_messages: int = 2,
) -> list[Conversation]:
    """Return conversation threads, most-recent-first.

    Args:
        db_path: chat.db location (injectable for tests).
        since_days: only threads active within the last N days
            (``0`` disables the cutoff).
        min_messages: drop threads shorter than this.
    """
    db_path = db_path or DEFAULT_CHAT_DB
    conn = _connect_ro(db_path)
    try:
        rows = conn.execute(
            """
            SELECT
                c.guid          AS chat_id,
                c.display_name  AS display_name,
                c.style         AS chat_style,
                COUNT(DISTINCT cmj.message_id) AS message_count,
                MIN(m.date)     AS first_msg,
                MAX(m.date)     AS last_msg,
                GROUP_CONCAT(DISTINCT h.id) AS participants
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m            ON m.ROWID = cmj.message_id
            LEFT JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            LEFT JOIN handle h        ON h.ROWID = chj.handle_id
            GROUP BY c.ROWID
            HAVING message_count >= ?
            ORDER BY last_msg DESC
            """,
            (min_messages,),
        ).fetchall()
    except sqlite3.OperationalError as exc:
        logger.error("Failed to query iMessage conversations: %s", exc)
        return []
    finally:
        conn.close()

    out: list[Conversation] = []
    cutoff = None
    if since_days:
        cutoff = datetime.now(timezone.utc).timestamp() - (since_days * 86400)
    for row in rows:
        participants = []
        if row["participants"]:
            participants = [
                p.strip() for p in row["participants"].split(",") if p.strip()
            ]
        first = _convert_timestamp(row["first_msg"]) if row["first_msg"] else None
        last = _convert_timestamp(row["last_msg"]) if row["last_msg"] else None
        if cutoff is not None and last and last.timestamp() < cutoff:
            continue
        out.append(
            Conversation(
                chat_id=row["chat_id"],
                display_name=row["display_name"],
                participants=participants,
                message_count=row["message_count"],
                first_message=first,
                last_message=last,
                is_group=(row["chat_style"] == _CHAT_STYLE_GROUP),
            )
        )
    logger.info("Extracted %d iMessage conversations", len(out))
    return out


def extract_messages(
    chat_id: str,
    db_path: Optional[Path] = None,
    limit: int = 2000,
) -> list[Message]:
    """Return messages for one thread in chronological order.

    Args:
        chat_id: chat.guid from ``extract_conversations``.
        db_path: chat.db location (injectable for tests).
        limit: cap on messages fetched (most recent first, then
            re-ordered chronologically).
    """
    db_path = db_path or DEFAULT_CHAT_DB
    conn = _connect_ro(db_path)
    try:
        rows = conn.execute(
            """
            SELECT
                m.ROWID                    AS rowid,
                m.text                     AS text,
                m.is_from_me               AS is_from_me,
                m.date                     AS date,
                m.cache_has_attachments    AS has_attachment,
                m.service                  AS service,
                COALESCE(h.id, 'me')       AS sender
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c                ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h         ON h.ROWID = m.handle_id
            WHERE c.guid = ?
            ORDER BY m.date DESC
            LIMIT ?
            """,
            (chat_id, limit),
        ).fetchall()
    except sqlite3.OperationalError as exc:
        logger.error("Failed to query messages for %s: %s", chat_id, exc)
        return []
    finally:
        conn.close()

    out: list[Message] = []
    for row in rows:
        if row["date"] is None:
            continue
        out.append(
            Message(
                rowid=row["rowid"],
                text=row["text"],
                sender="me" if row["is_from_me"] else row["sender"],
                timestamp=_convert_timestamp(row["date"]),
                is_from_me=bool(row["is_from_me"]),
                chat_id=chat_id,
                has_attachment=bool(row["has_attachment"]),
                service=(row["service"] or "iMessage"),
            )
        )
    out.reverse()  # chronological
    return out
