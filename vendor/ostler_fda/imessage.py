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

from .tcc_refusal import is_fda_refusal
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from .settling_progress import report_settling_progress

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# A chat.db SCHEMA MISMATCH must fail LOUD, never return an empty list.
#
# chat.db is a system file whose schema macOS can change between releases. When
# a SELECT names a column the installed schema no longer has, sqlite raises
# OperationalError("no such column: ..."). This reader used to log that and
# `return []`, which is INDISTINGUISHABLE at the consumer from "you have not
# messaged anyone". Walk #30 ingested 0 of 1075 iMessages exactly this way (a
# chat.db without `account_login`) and the whole owner-knowledge run scored
# 0/80 while every source still reported "ok". A benign empty store raises
# nothing and returns zero rows, so the OperationalError arm is ONLY ever a
# reader/schema fault: it is re-raised as ChatDbSchemaError so the consumer
# (extract_all) records the source as "error" (Doctor-visible) instead of a
# green zero. The one OperationalError that is NOT a schema fault, a transient
# "database is locked" while Messages writes, is left as a degrade-to-empty for
# that one tick (an outage, not a broken reader).
#
# Kept in step with vendor/imessage_source/reader.py; recorded in
# vendor/divergences/WRITER_READER_MISMATCHES.UNRECORDED.md.
# ---------------------------------------------------------------------------
class ChatDbSchemaError(RuntimeError):
    """A chat.db query failed because the on-disk schema did not match what
    this reader SELECTs. Raised LOUD, never swallowed into an empty list."""


_SCHEMA_ERROR_MARKERS = (
    "no such column",
    "no such table",
    "no such function",
    "has no column named",
    "malformed database schema",
)


def _raise_if_schema_mismatch(exc: sqlite3.OperationalError, what: str) -> None:
    """Re-raise a schema-shaped OperationalError as ChatDbSchemaError.

    A no-op for any other OperationalError (e.g. a transient lock), so the
    caller keeps its existing degrade-to-empty for that narrow case.
    """
    if any(marker in str(exc).lower() for marker in _SCHEMA_ERROR_MARKERS):
        raise ChatDbSchemaError(
            f"iMessage chat.db {what} failed on a schema mismatch ({exc}). "
            "This is a reader/schema fault (a macOS update likely changed the "
            "chat.db columns), not an empty history, so it is refused rather "
            "than reported as 0 messages."
        ) from exc


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


# The assistant's own sends are not the owner's words. The brief and wrap go
# out from the owner's Apple ID, so chat.db marks them is_from_me=1. Same rule
# and same constants as imessage_source/reader.py (see the note there);
# tests/test_assistant_sends_are_not_owner_input.py holds the copies in step.
ASSISTANT_SEND_PREFIX = "\U0001F916"  # robot face, the identity prefix
ASSISTANT_SEND_MARKER = "\u2063\u2064\u2063"  # invisible sep, plus, sep


def _owner_sent(row) -> bool:
    """Was this row sent from the owner's own account?

    is_from_me=1, or the inbound copy in the owner's Note-to-Self chat: a
    one-handle chat whose handle IS the account it was received on (the
    same test ostler-assistant's POLL_QUERY_SELF_CHAT uses). The brief lands
    in that chat as both an outgoing and an inbound row.
    """
    if row["is_from_me"]:
        return True
    hid = row["handle_id"] or ""
    login = row["account_login"] or ""
    return bool(hid) and row["n_handles"] == 1 and login in ("E:" + hid, "P:" + hid)


def is_assistant_send(text: Optional[str], from_owner: bool = False) -> bool:
    """True when ``text`` was written by the Ostler assistant, not a person.

    The invisible marker counts in any direction: only the assistant stamps
    it. The robot-emoji PREFIX counts only on a row the owner's own account
    sent (``from_owner``), because that is the only place the assistant's
    sends appear with it. A contact whose message happens to open with the
    same emoji is a person, and their words are kept.
    """
    if not text:
        return False
    if ASSISTANT_SEND_MARKER in text:
        return True
    return from_owner and text.lstrip().startswith(ASSISTANT_SEND_PREFIX)


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
        if is_fda_refusal(e, db_path):
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
        conn.close()
        _raise_if_schema_mismatch(e, "conversation query")
        logger.error("Failed to query iMessage: %s", e)
        return []

    conn.close()

    # Total is measured ONCE up front so the bar cannot move backwards if a
    # downstream retry re-invokes this function against a growing chat.db.
    #
    # THE UNIT IS MESSAGES, NOT CONVERSATIONS (changed 2026-08-08).
    # It used to be len(rows) -- the number of chats scanned -- and `done`
    # incremented for every row INCLUDING the ones the since_days filter threw
    # away, with the comment "the customer's view is 'we've looked at this
    # one'". It is not. Scanning a chat row is instant; ingesting its messages
    # is the work that takes days, and the panel exists to say so. On a real
    # box that shipped 167 of 167 -- 100%, in under a minute -- while 28,405
    # messages sat unread, because nearly every chat fell outside the window.
    #
    # Counting messages makes the denominator the thing the customer actually
    # waits for, and makes a widening backfill window visibly move the bar.
    total = sum(int(r["message_count"] or 0) for r in rows)

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
                # A chat outside the window is NOT done -- its messages have
                # not been ingested and will only arrive when the backfill
                # window widens. Counting it as done is what let a fresh
                # install reach 100% having ingested almost nothing.
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

        done += int(row["message_count"] or 0)
        # 30s throttle -- ~1000 rows/second at the SQL layer would otherwise
        # thrash the customer's disk with tiny shard rewrites. See the
        # writer helper's docstring for the rationale.
        now = time.monotonic()
        if done == total or now - last_tick >= _SETTLING_TICK_INTERVAL_SECONDS:
            _emit_settling(done=done, total=total, started_at=started_at)
            last_tick = now

    # Final emit carries the ACTUAL done, not total. The previous version
    # passed done=total here "belt-and-braces", which meant every run ended at
    # 100% no matter how much of the corpus the window had excluded -- it
    # overwrote the honest count with a claim of completion.
    _emit_settling(done=done, total=total, started_at=started_at)

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
        if is_fda_refusal(e, db_path):
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
                COALESCE(h.id, 'me') as sender,
                h.id as handle_id,
                c.account_login as account_login,
                (SELECT COUNT(*) FROM chat_handle_join x
                  WHERE x.chat_id = c.ROWID) as n_handles
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE c.guid = ?
            ORDER BY m.date DESC
            LIMIT ?
        """, (chat_id, limit)).fetchall()
    except sqlite3.OperationalError as e:
        conn.close()
        _raise_if_schema_mismatch(e, "message query")
        logger.error("Failed to query messages: %s", e)
        return []

    conn.close()

    messages = []
    for row in rows:
        if row["date"] is None:
            continue
        if is_assistant_send(row["text"], from_owner=_owner_sent(row)):
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
