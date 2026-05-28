"""Regression test for the 2026-05-28 first-run clamp fix.

Before the fix bridge.py initialised ``last_rowid = 0`` when
state.json was missing, then emitted every inbound message in
chat.db into inbox.jsonl (LIMIT 500 per 30s tick). The consumer
side (ostler-assistant) then asked the LLM to reply to every
historical message, producing the Marvin self-talk loop observed
across two threads on Andy's own number.

This test refuses the regression shape: on first run, with a
populated chat.db and an absent state.json, bridge.poll_once must
NOT append anything to inbox.jsonl, and state.json must be saved
at the current MAX(ROWID).
"""

from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

# Make the bin/ module importable without packaging.
_BIN = Path(__file__).resolve().parents[1] / "bin"
sys.path.insert(0, str(_BIN))

import bridge  # noqa: E402  - sys.path side effect required


def _make_chatdb(db_path: Path, inbound_count: int, outbound_count: int) -> int:
    """Create a minimal chat.db-shaped sqlite db. Returns MAX(ROWID)."""
    conn = sqlite3.connect(db_path)
    conn.executescript(
        """
        CREATE TABLE handle (
            ROWID INTEGER PRIMARY KEY,
            id TEXT
        );
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY,
            text TEXT,
            date INTEGER,
            handle_id INTEGER,
            is_from_me INTEGER DEFAULT 0
        );
        INSERT INTO handle (ROWID, id) VALUES (1, '+15551234567');
        """
    )
    for i in range(inbound_count):
        conn.execute(
            "INSERT INTO message (text, date, handle_id, is_from_me) "
            "VALUES (?, 0, 1, 0)",
            (f"historical inbound {i}",),
        )
    for i in range(outbound_count):
        conn.execute(
            "INSERT INTO message (text, date, handle_id, is_from_me) "
            "VALUES (?, 0, 1, 1)",
            (f"historical outbound {i}",),
        )
    conn.commit()
    row = conn.execute("SELECT MAX(ROWID) FROM message WHERE is_from_me = 0").fetchone()
    conn.close()
    return int(row[0])


def test_first_run_does_not_replay_history(tmp_path: Path) -> None:
    """First run with absent state.json must NOT dump history into inbox."""
    db = tmp_path / "chat.db"
    inbox = tmp_path / "inbox.jsonl"
    state = tmp_path / "state.json"

    max_rowid = _make_chatdb(db, inbound_count=100, outbound_count=20)
    assert max_rowid > 0, "test setup failed: empty chat.db"
    assert not state.exists()

    appended = bridge.poll_once(db_path=db, inbox_path=inbox, state_path=state)

    assert appended == 0, "first run leaked historical messages into inbox.jsonl"
    assert not inbox.exists() or inbox.read_text() == "", (
        "inbox.jsonl must be empty after first-run clamp"
    )
    assert state.exists(), "state.json must be persisted on first run"
    saved = json.loads(state.read_text())
    assert saved["last_rowid"] == max_rowid, (
        f"state.json should clamp to MAX(ROWID)={max_rowid}, got {saved}"
    )


def test_second_run_emits_only_new_messages(tmp_path: Path) -> None:
    """Subsequent runs emit messages added AFTER first-run clamp."""
    db = tmp_path / "chat.db"
    inbox = tmp_path / "inbox.jsonl"
    state = tmp_path / "state.json"

    _make_chatdb(db, inbound_count=10, outbound_count=2)

    # First run clamps.
    assert bridge.poll_once(db_path=db, inbox_path=inbox, state_path=state) == 0

    # Now add 3 new inbound messages.
    conn = sqlite3.connect(db)
    for i in range(3):
        conn.execute(
            "INSERT INTO message (text, date, handle_id, is_from_me) "
            "VALUES (?, 0, 1, 0)",
            (f"new inbound {i}",),
        )
    conn.commit()
    conn.close()

    appended = bridge.poll_once(db_path=db, inbox_path=inbox, state_path=state)
    assert appended == 3, f"second run should emit 3 new messages, got {appended}"
    lines = [ln for ln in inbox.read_text().splitlines() if ln.strip()]
    assert len(lines) == 3
    for ln in lines:
        record = json.loads(ln)
        assert record["sender"] == "+15551234567"
        assert record["text"].startswith("new inbound")
