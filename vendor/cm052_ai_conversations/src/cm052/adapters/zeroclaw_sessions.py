"""Adapter for ZeroClaw's gateway sessions SQLite DB.

Schema (verified, live + archive identical):

    CREATE TABLE sessions (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        session_key TEXT NOT NULL,
        role        TEXT NOT NULL,
        content     TEXT NOT NULL,
        created_at  TEXT NOT NULL
    );

    CREATE TABLE session_metadata (
        session_key   TEXT PRIMARY KEY,
        created_at    TEXT NOT NULL,
        last_activity TEXT NOT NULL,
        message_count INTEGER NOT NULL DEFAULT 0,
        name          TEXT,
        state         TEXT NOT NULL DEFAULT 'idle',
        turn_id       TEXT,
        turn_started_at TEXT
    );

The gateway DB carries per-message timestamps in ``sessions.created_at``,
unlike the channel JSONLs. The adapter populates ``Message.timestamp``
from this column.

Empty DBs are expected at launch (the gateway populates as the new
chat UI is used). The adapter must handle missing tables and zero rows
without raising.
"""
from __future__ import annotations

import hashlib
import sqlite3
from collections.abc import Iterable
from pathlib import Path

from ..provenance import ConversationProvenance
from ..schemas import Conversation, Message


def _conversation_id(session_key: str) -> str:
    """Deterministic id derived from the gateway session_key.

    Re-reads of the same DB produce the same conversation_id, so
    downstream sinks remain idempotent across runs.
    """
    payload = f"zeroclaw_gateway:gateway:{session_key}".encode()
    return f"zg-{hashlib.sha1(payload).hexdigest()[:16]}"


def _table_exists(conn: sqlite3.Connection, name: str) -> bool:
    cur = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        (name,),
    )
    return cur.fetchone() is not None


def read(db_path: Path) -> Iterable[Conversation]:
    """Yield one ``Conversation`` per ``session_metadata`` row.

    Channel is hardcoded to ``"manual"`` because gateway sessions are
    typed in the chat UI directly, not arriving via SMS / IM / email.
    Adapter callers can override at the unifier layer if a session was
    explicitly tagged with a different originating channel.
    """
    if not db_path.exists():
        return
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        if not _table_exists(conn, "session_metadata") or not _table_exists(
            conn, "sessions"
        ):
            return
        meta_rows = conn.execute(
            "SELECT session_key, created_at, last_activity, message_count, "
            "name FROM session_metadata"
        ).fetchall()
        for session_key, created_at, last_activity, _msg_count, name in meta_rows:
            msg_rows = conn.execute(
                "SELECT role, content, created_at FROM sessions "
                "WHERE session_key = ? ORDER BY id ASC",
                (session_key,),
            ).fetchall()
            messages = [
                Message(
                    role=role,
                    content=content,
                    timestamp=ts,
                    line_index=idx,
                )
                for idx, (role, content, ts) in enumerate(msg_rows)
            ]
            yield Conversation(
                conversation_id=_conversation_id(session_key),
                provenance=ConversationProvenance(
                    source_kind="zeroclaw_gateway",
                    source_subtype="gateway",
                    original_session_id=session_key,
                ),
                channel="manual",
                participants=[],
                messages=messages,
                last_activity=last_activity,
                created_at=created_at,
                name=name,
            )
    finally:
        conn.close()
