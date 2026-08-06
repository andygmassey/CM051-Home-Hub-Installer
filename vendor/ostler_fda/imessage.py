"""Extract conversation history from iMessage's chat.db.

iMessage stores all messages in:
    ~/Library/Messages/chat.db

Tables:
    message: individual messages with timestamps, text, sender
    handle: phone numbers and email addresses (participants)
    chat: group/individual conversation threads
    chat_handle_join: maps participants to chats
    chat_message_join: maps messages to chats

Timestamps use Mac absolute time (seconds since 2001-01-01).
Since macOS Ventura, timestamps are in nanoseconds (divide by 1e9).

Requires Full Disk Access (FDA) permission on macOS Sequoia+.
"""
from __future__ import annotations

import logging
import sqlite3
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from .settling_progress import report_settling_progress

logger = logging.getLogger(__name__)

# Settling-progress cadence: emit a shard update whenever more than this many
# seconds have passed since the last emit, or at the end of the loop. Per the
# writer helper's docstring the cost story is disk I/O, not compute; ~30s
# matches the other producers so the customer sees roughly aligned ticks.
_SETTLING_TICK_INTERVAL_SECONDS = 30.0

# Channel + shard identifiers for the settling-progress panel. `messages` is
# the one channel with two producers (iMessage + WhatsApp); the CM044 reader
# sums any `messages.*` shards into the single `messages` channel.
_SETTLING_CHANNEL = "messages"
_SETTLING_SHARD = "imessage"

MAC_EPOCH_OFFSET = 978307200
DEFAULT_CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"


@dataclass
class Conversation:
    """A conversation thread (individual or group)."""
    chat_id: str
    display_name: Optional[str]
    participants: list[str]  # phone numbers or email addresses
    message_count: int
    first_message: Optional[datetime]
    last_message: Optional[datetime]
    is_group: bool


@dataclass
class Message:
    """A single iMessage."""
    text: Optional[str]
    sender: str  # phone/email, or "me" for outgoing
    timestamp: datetime
    is_from_me: bool
    chat_id: str
    has_attachment: bool


def _convert_timestamp(raw: int) -> datetime:
    """Convert iMessage timestamp to datetime.

    macOS Ventura+ uses nanoseconds. Older versions use seconds.
    We detect by checking if the value is unreasonably large for seconds.
    """
    if raw > 1e15:  # nanoseconds (Ventura+)
        unix_ts = (raw / 1e9) + MAC_EPOCH_OFFSET
    else:  # seconds (older macOS)
        unix_ts = raw + MAC_EPOCH_OFFSET
    return datetime.fromtimestamp(unix_ts, tz=timezone.utc)


def _emit_settling(
    *,
    done: int,
    total: int,
    needs_source: bool = False,
    started_at: Optional[str] = None,
) -> None:
    """Best-effort settling-progress emit for the iMessage backfill.

    Wraps :func:`report_settling_progress` in a broad try/except so a full
    disk or unwritable state dir can never abort the caller's ingest loop --
    the helper itself already swallows I/O errors, but a defensive belt keeps
    us honest against future refactors.
    """
    try:
        report_settling_progress(
            channel=_SETTLING_CHANNEL,
            done=done,
            total=total,
            needs_source=needs_source,
            started_at=started_at,
            shard=_SETTLING_SHARD,
        )
    except Exception:  # noqa: BLE001 -- see docstring
        logger.warning(
            "settling-progress: iMessage emit failed; continuing extract",
            exc_info=True,
        )


def extract_conversations(
    db_path: Optional[Path] = None,
    since_days: int = 365,
    min_messages: int = 2,
) -> list[Conversation]:
    """Extract conversation threads from iMessage.

    Args:
        db_path: Path to chat.db.
        since_days: Only include conversations active in last N days.
        min_messages: Minimum messages to include a conversation.

    Returns:
        List of Conversation objects, most recent first.

    Raises:
        PermissionError: If FDA is not granted.
    """
    db_path = db_path or DEFAULT_CHAT_DB

    # Stamp the backfill start once, up front. The helper preserves this
    # across subsequent ticks so the rate-based ETA in CM044 falls as work
    # completes rather than resetting on every write.
    started_at = datetime.now(timezone.utc).isoformat()

    if not db_path.exists():
        # chat.db is a system-installed file on macOS Sequoia+, so
        # "missing" is unusual (custom test env, damaged install) rather
        # than "source not connected". needs_source stays False -- the
        # WhatsApp producer owns the true needs_source path for messages.
        raise FileNotFoundError(f"iMessage database not found at {db_path}")

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            raise PermissionError(
                "Cannot read iMessage history. Grant Full Disk Access."
            ) from e
        raise

    conn.row_factory = sqlite3.Row

    try:
        rows = conn.execute("""
            SELECT
                c.guid as chat_id,
                c.display_name,
                c.style as chat_style,
                COUNT(DISTINCT cmj.message_id) as message_count,
                MIN(m.date) as first_msg,
                MAX(m.date) as last_msg,
                GROUP_CONCAT(DISTINCT h.id) as participants
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            LEFT JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            LEFT JOIN handle h ON h.ROWID = chj.handle_id
            GROUP BY c.ROWID
            HAVING message_count >= ?
            ORDER BY last_msg DESC
        """, (min_messages,)).fetchall()
    except sqlite3.OperationalError as e:
        logger.error("Failed to query iMessage: %s", e)
        conn.close()
        return []

    conn.close()

    # Total is measured ONCE up front from the SQL row count so the bar
    # cannot move backwards if a downstream retry re-invokes this function
    # against a growing chat.db. `done` counts conversations we accept
    # after the since_days filter -- items fully processed, not items read.
    total = len(rows)

    if total == 0:
        # Nothing to do -- emit a ready shard (needs_source=False) so the
        # reader classifies as ready rather than waiting. iMessage's source
        # (chat.db) is always connected on macOS; a zero-row extract is
        # "you haven't messaged anyone", not "no source".
        _emit_settling(done=0, total=0, needs_source=False, started_at=started_at)
        logger.info("Extracted 0 conversations from iMessage")
        return []

    # Initial emit with total set -- gives the panel a real denominator
    # from the very first tick.
    _emit_settling(done=0, total=total, started_at=started_at)

    conversations = []
    done = 0
    last_tick = time.monotonic()
    for row in rows:
        participants = []
        if row["participants"]:
            participants = [p.strip() for p in row["participants"].split(",") if p.strip()]

        first = _convert_timestamp(row["first_msg"]) if row["first_msg"] else None
        last = _convert_timestamp(row["last_msg"]) if row["last_msg"] else None

        # Filter by since_days
        if last and since_days:
            cutoff = datetime.now(timezone.utc).timestamp() - (since_days * 86400)
            if last.timestamp() < cutoff:
                done += 1
                # Filtered items still count against the queue -- the
                # customer's view is "we've looked at this one", not "we
                # kept it". Emit a tick if the throttle has elapsed.
                now = time.monotonic()
                if done == total or now - last_tick >= _SETTLING_TICK_INTERVAL_SECONDS:
                    _emit_settling(done=done, total=total, started_at=started_at)
                    last_tick = now
                continue

        # chat_style 43 = group, 45 = individual
        is_group = (row["chat_style"] == 43)

        conversations.append(Conversation(
            chat_id=row["chat_id"],
            display_name=row["display_name"],
            participants=participants,
            message_count=row["message_count"],
            first_message=first,
            last_message=last,
            is_group=is_group,
        ))

        done += 1
        # 30s throttle -- ~1000 rows/second at the SQL layer would otherwise
        # thrash the customer's disk with tiny shard rewrites. See the
        # writer helper's docstring for the rationale.
        now = time.monotonic()
        if done == total or now - last_tick >= _SETTLING_TICK_INTERVAL_SECONDS:
            _emit_settling(done=done, total=total, started_at=started_at)
            last_tick = now

    # Belt-and-braces final emit so `done == total` is on disk even if the
    # loop's terminal tick fired before the last item completed processing.
    _emit_settling(done=total, total=total, started_at=started_at)

    logger.info("Extracted %d conversations from iMessage", len(conversations))
    return conversations


def extract_messages(
    chat_id: str,
    db_path: Optional[Path] = None,
    limit: int = 500,
) -> list[Message]:
    """Extract messages from a specific conversation.

    Args:
        chat_id: The chat GUID from extract_conversations().
        db_path: Path to chat.db.
        limit: Maximum messages to return (most recent first).

    Returns:
        List of Message objects, chronological order.
    """
    db_path = db_path or DEFAULT_CHAT_DB

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            raise PermissionError(
                "Cannot read iMessage history. Grant Full Disk Access."
            ) from e
        raise

    conn.row_factory = sqlite3.Row

    try:
        rows = conn.execute("""
            SELECT
                m.text,
                m.is_from_me,
                m.date,
                m.cache_has_attachments as has_attachment,
                COALESCE(h.id, 'me') as sender
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE c.guid = ?
            ORDER BY m.date DESC
            LIMIT ?
        """, (chat_id, limit)).fetchall()
    except sqlite3.OperationalError as e:
        logger.error("Failed to query messages: %s", e)
        conn.close()
        return []

    conn.close()

    messages = []
    for row in rows:
        if row["date"] is None:
            continue

        messages.append(Message(
            text=row["text"],
            sender="me" if row["is_from_me"] else row["sender"],
            timestamp=_convert_timestamp(row["date"]),
            is_from_me=bool(row["is_from_me"]),
            chat_id=chat_id,
            has_attachment=bool(row["has_attachment"]),
        ))

    # Return in chronological order
    messages.reverse()
    return messages


def conversation_stats(conversations: list[Conversation]) -> dict:
    """Generate summary stats for the user's iMessage history.

    Returns a dict suitable for the install summary screen.
    """
    if not conversations:
        return {"total_conversations": 0}

    total_messages = sum(c.message_count for c in conversations)
    unique_contacts = set()
    for c in conversations:
        unique_contacts.update(c.participants)

    return {
        "total_conversations": len(conversations),
        "total_messages": total_messages,
        "unique_contacts": len(unique_contacts),
        "group_chats": sum(1 for c in conversations if c.is_group),
        "oldest_conversation": min(
            (c.first_message for c in conversations if c.first_message),
            default=None,
        ),
    }
