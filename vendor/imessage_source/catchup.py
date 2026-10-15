"""Full-history catch-up for iMessage bundles (v1.0.108, catch-up 2/6).

The forward feed (``pipeline.process_imessage``) only looks at chats active
in the last 30 days, and only at each chat's newest ``extract_messages``
limit (2,000) rows. Everything older, and every chat that went quiet more
than 30 days ago, was never bundled. This adapter walks every chat in
chat.db BACKWARDS from that edge to its first message, in whole sessions,
and hands each session to CM048 through the same dispatch the forward feed
uses. Driven by ``lib/ostler_catchup.py`` (run from com.ostler.export-scan).

WHERE EACH CHAT STARTS. A chat the forward feed has a watermark for has had
its newest ``extract_messages`` limit rows bundled, so the walk starts just
below the oldest of those. Any other chat starts at its newest message.

ORDER, AND WHY "BACK TO" MEANS SOMETHING. Every chat keeps a frontier (the
newest row not yet read). Each batch takes the chat whose frontier is
NEWEST, so the largest frontier only ever falls, and everything newer than it
has been read in every chat. That largest frontier is what Doctor shows.

WHOLE SESSIONS. A batch reads at least ``limit`` rows and then keeps going
until the next older row is more than the session gap away, so a session is
never split across two batches. Sessions are cut by ``threader.thread_messages``
with the forward feed's gap, so a session the forward feed already bundled
gets the SAME conversation_id here, and CM048 (one state dir per id) does not
write it twice.

Key = conversation_id. Counts only in logs.
"""
from __future__ import annotations

import inspect
import logging
import os
from datetime import timedelta
from pathlib import Path
from typing import Optional

import ostler_catchup as oc

from .pipeline import (
    _dispatch_to_cm048,
    _load_contacts_map,
    _load_privacy_map,
    _load_state,
    _name_resolver,
    _resolve_pwg_convo_cmd,
    _state_path,
)
from .reader import (
    DEFAULT_CHAT_DB,
    Message,
    _connect_ro,
    _convert_timestamp,
    _owner_sent,
    extract_messages,
    is_assistant_send,
)
from .threader import DEFAULT_SESSION_GAP, build_metadata, render_transcript, thread_messages

logger = logging.getLogger(__name__)

# The forward feed's per-chat window, read from the reader rather than copied.
FORWARD_PER_CHAT_LIMIT = inspect.signature(extract_messages).parameters["limit"].default

_PAGE = 500

_ROWS_SQL = """
    SELECT
        m.ROWID                    AS rowid,
        m.text                     AS text,
        m.is_from_me               AS is_from_me,
        m.date                     AS date,
        m.cache_has_attachments    AS has_attachment,
        m.service                  AS service,
        COALESCE(h.id, 'me')       AS sender,
        h.id                       AS handle_id,
        c.account_login            AS account_login,
        (SELECT COUNT(*) FROM chat_handle_join x
          WHERE x.chat_id = c.ROWID) AS n_handles
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat c                ON c.ROWID = cmj.chat_id
    LEFT JOIN handle h         ON h.ROWID = m.handle_id
    WHERE c.guid = ? AND m.date IS NOT NULL
      AND (m.date < ? OR (m.date = ? AND m.ROWID < ?))
    ORDER BY m.date DESC, m.ROWID DESC
    LIMIT ?
"""

_HEAD_SQL = """
    SELECT m.date, m.ROWID FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat c ON c.ROWID = cmj.chat_id
    WHERE c.guid = ? AND m.date IS NOT NULL
      AND (m.date < ? OR (m.date = ? AND m.ROWID < ?))
    ORDER BY m.date DESC, m.ROWID DESC LIMIT 1
"""

# Larger than any real chat.db date (ns since 2001 for ~290 years).
_NO_BOUND = 1 << 62


def _row_to_message(row, chat_id: str) -> Optional[Message]:
    """The reader's own row filter: assistant sends are dropped exactly as
    ``reader.extract_messages`` drops them."""
    if row["date"] is None:
        return None
    if is_assistant_send(row["text"], from_owner=_owner_sent(row)):
        return None
    return Message(
        rowid=row["rowid"],
        text=row["text"],
        sender="me" if row["is_from_me"] else row["sender"],
        timestamp=_convert_timestamp(row["date"]),
        is_from_me=bool(row["is_from_me"]),
        chat_id=chat_id,
        has_attachment=bool(row["has_attachment"]),
        service=(row["service"] or "iMessage"),
    )


def _raw_to_ns(raw: int) -> int:
    """Seconds-era rows compare against nanosecond-era rows correctly only on
    one scale; chat.db holds one era per database, so this is for gaps."""
    return raw if raw > 1e15 else int(raw * 1e9)


# EX_TEMPFAIL: `pwg-convo process` exits 75 when the model/gateway cannot be reached.
SINK_UNAVAILABLE_RC = 75


class IMessageCatchup(oc.Adapter):
    source = "imessage"
    doctor_row = "imessage"
    batch_size = 120  # rows per batch, extended to a whole session

    def __init__(self, *, db_path: Optional[Path] = None, contacts_path: Optional[Path] = None,
                 user_display_name: Optional[str] = None, state_path: Optional[Path] = None,
                 pwg_convo_cmd: Optional[list] = None, session_gap: timedelta = DEFAULT_SESSION_GAP):
        self.db_path = Path(db_path) if db_path else DEFAULT_CHAT_DB
        self.state_path = state_path
        self.contacts_path = contacts_path
        self.user_display_name = user_display_name or os.getenv("OSTLER_USER_DISPLAY_NAME", "You")
        self.pwg_convo_cmd = pwg_convo_cmd
        self.gap_ns = int(session_gap.total_seconds() * 1e9)
        self.session_gap = session_gap
        contacts = _load_contacts_map(contacts_path)
        self._privacy = _load_privacy_map(contacts_path)
        self._name = _name_resolver(contacts)
        self._chat_meta: dict = {}

    # ── cursor ──────────────────────────────────────────────────────────
    def _chats(self, conn):
        return conn.execute(
            "SELECT c.guid AS guid, c.display_name AS display_name, c.style AS style, "
            "MAX(m.date) AS last FROM chat c "
            "JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID "
            "JOIN message m ON m.ROWID = cmj.message_id "
            "WHERE m.date IS NOT NULL GROUP BY c.ROWID").fetchall()

    def start_cursor(self):
        # Built on the first batch, inside the loop's error handling, so a
        # missing or unreadable chat.db is a recorded read failure, not a crash.
        return None

    def _initial_chats(self, conn):
        """{guid: {"before": [date, rowid], "head": date}} for every chat
        with something left to read below its starting edge."""
        forward = (_load_state(self.state_path or _state_path()).get("watermarks") or {})
        chats = {}
        for row in self._chats(conn):
            guid = row["guid"]
            before = [_NO_BOUND, _NO_BOUND]
            if guid in forward:
                # The forward feed bundled this chat's newest
                # FORWARD_PER_CHAT_LIMIT rows: start just below the oldest.
                edge = conn.execute(
                    "SELECT m.date, m.ROWID FROM message m "
                    "JOIN chat_message_join cmj ON cmj.message_id = m.ROWID "
                    "JOIN chat c ON c.ROWID = cmj.chat_id WHERE c.guid = ? "
                    "ORDER BY m.date DESC LIMIT 1 OFFSET ?",
                    (guid, FORWARD_PER_CHAT_LIMIT - 1)).fetchone()
                if edge is None:
                    continue  # the forward window already holds the whole chat
                before = [edge[0], edge[1]]
            head = conn.execute(_HEAD_SQL, (guid, before[0], before[0], before[1])).fetchone()
            if head is not None:
                chats[guid] = {"before": before, "head": head[0]}
        return chats

    # ── batches ─────────────────────────────────────────────────────────
    def _meta(self, conn, guid):
        if guid not in self._chat_meta:
            row = conn.execute("SELECT display_name, style FROM chat WHERE guid = ?", (guid,)).fetchone()
            self._chat_meta[guid] = (row["display_name"] if row else None,
                                     bool(row and row["style"] == 43))
        return self._chat_meta[guid]

    def next_batch(self, cursor, limit):
        conn = _connect_ro(self.db_path)
        try:
            if cursor is None:
                chats = self._initial_chats(conn)
            else:
                chats = {g: dict(v) for g, v in cursor.get("chats", {}).items()}
            if not chats:
                return oc.Batch(items=[], next_cursor={"chats": {}}, oldest_at=None, exhausted=True)
            guid = max(chats, key=lambda g: chats[g]["head"])
            before = list(chats[guid]["before"])
            rows = []
            while True:
                page = conn.execute(_ROWS_SQL, (guid, before[0], before[0], before[1], _PAGE)).fetchall()
                start = len(rows)
                rows.extend(page)
                cut = None
                # A session boundary at or beyond `limit` rows: the next older
                # row is more than the session gap away.
                for i in range(max(start, limit, 1), len(rows)):
                    if _raw_to_ns(rows[i - 1]["date"]) - _raw_to_ns(rows[i]["date"]) > self.gap_ns:
                        cut = i
                        break
                if cut is not None:
                    rows = rows[:cut]
                    break
                if len(page) < _PAGE:
                    break
                before = [rows[-1]["date"], rows[-1]["rowid"]]
            display_name, is_group = self._meta(conn, guid)
            last = rows[-1] if rows else None
            nxt = None
            if last is not None:
                nxt = conn.execute(_HEAD_SQL, (guid, last["date"], last["date"], last["rowid"])).fetchone()
        finally:
            conn.close()

        msgs = [m for m in (_row_to_message(r, guid) for r in reversed(rows)) if m is not None]
        sessions = thread_messages(guid, msgs, is_group=is_group, display_name=display_name,
                                   gap=self.session_gap)
        if nxt is None:
            del chats[guid]
        else:
            chats[guid] = {"before": [last["date"], last["rowid"]], "head": nxt[0]}
        # Everything newer than the largest remaining frontier has been read,
        # in every chat, so that frontier is the honest "back to" date.
        if chats:
            oldest = _convert_timestamp(max(v["head"] for v in chats.values()))
        else:
            oldest = _convert_timestamp(last["date"]) if last is not None else None
        return oc.Batch(items=sessions, next_cursor={"chats": chats},
                        oldest_at=oc.to_iso(oldest), exhausted=not chats)

    def key(self, session):
        return session.conversation_id

    def process(self, session):
        level = None
        for handle in session.participant_handles:
            if self._privacy.get(handle) == "L3":
                level = "L3"
                break
        transcript = render_transcript(session, name_for_handle=self._name)
        metadata = build_metadata(session, user_display_name=self.user_display_name,
                                  name_for_handle=self._name, privacy_level=level)
        rc = _dispatch_to_cm048(transcript, metadata,
                                pwg_convo_cmd=self.pwg_convo_cmd or _resolve_pwg_convo_cmd(),
                                dry_run=False)
        if rc == SINK_UNAVAILABLE_RC:
            # pwg-convo could not reach its model or gateway: an outage, not a
            # verdict on this conversation. Raising a ConnectionError keeps it
            # out of the poison-attempt count (lib/ostler_catchup.py).
            raise ConnectionError("pwg-convo: sink unavailable (exit 75)")
        return rc == 0


def adapters():
    """Factory for ``ostler_catchup run --adapters <pkg>.catchup:adapters``."""
    db = os.environ.get("OSTLER_IMESSAGE_CHAT_DB", "").strip()
    contacts = os.environ.get("OSTLER_CONTACTS", "").strip()
    return [IMessageCatchup(db_path=Path(db) if db else None,
                            contacts_path=Path(contacts) if contacts else None)]
