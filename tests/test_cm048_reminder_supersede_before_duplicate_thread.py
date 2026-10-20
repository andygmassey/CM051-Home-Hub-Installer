"""An updated conversation must not lose its reminder to its own stale row.

CM048 #93/#95/#96 (re-vendored for v1.0.111) supersede a conversation's pending
reminder rows that a later run of the SAME conversation no longer contains.
CM051 keeps a vendored one-open-reminder-per-thread gate (thread_key,
duplicate_thread). Upstream supersedes AFTER the per-todo loop; with the vendored
gate that order skips the updated todo as a duplicate of the stale row, then
supersedes the stale row, and the customer ends with NO reminder. Archie's
condition on the re-vendor: supersede BEFORE the duplicate_thread gate.
Synthetic data only.
"""
from __future__ import annotations

import os
import sqlite3
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))
os.environ.setdefault("OSTLER_SERVICE_TOKEN", "test-only-supersede-token")

from src import reminders_push
from src.conversation_writer import ConversationBundle, ConversationSummary, Todo
from src.reminders_push import apply_push_status_to_todos

PHONE = "+15550100"
STORE = {PHONE: {"display_name": PHONE, "given_name": "Jane", "family_name": "Doe", "phones": [PHONE]}}


@pytest.fixture(autouse=True)
def _store(monkeypatch, tmp_path):
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "ostler"))
    monkeypatch.setattr(reminders_push, "_people_store_record", lambda h: STORE.get(h))


def _bundle():
    return ConversationBundle(
        conversation_id="c-1", source_kind="channel", source_subtype="imessage",
        source_session_id="s-1", channel="im", participants=("user", PHONE),
        started_at="2026-10-01T09:00:00Z", ended_at="2026-10-01T09:30:00Z",
        summary=ConversationSummary(overall="Synthetic.", topics=()),
        transcript="synthetic", privacy_level="L2",
    )


def _apply(db, todos):
    return apply_push_status_to_todos(tuple(todos), _bundle(), summary_path=Path("/tmp/s.md"),
                                      user_id="user", db_path=db)


def _rows(db):
    c = sqlite3.connect(db)
    try:
        return c.execute("SELECT todo_id, status, skip_reason FROM reminders_map ORDER BY todo_id").fetchall()
    finally:
        c.close()


def test_updated_conversation_keeps_one_reminder_for_the_new_todo(tmp_path):
    db = tmp_path / "m.db"
    _apply(db, [Todo(id="t1", text="send the synthetic draft", owner="user", deadline=None)])
    assert [r[1] for r in _rows(db)] == ["pending"]
    # The conversation grew and was re-extracted: the old todo is gone and a
    # different one (different wording, same person/thread) replaced it.
    _apply(db, [Todo(id="t2", text="book the synthetic venue", owner="user", deadline=None)])
    rows = dict((r[0], (r[1], r[2])) for r in _rows(db))
    assert rows["t1"] == ("skipped", "superseded_by_update"), rows
    assert rows["t2"][0] == "pending", ("the updated todo lost its reminder", rows)


def test_an_unchanged_rerun_is_still_one_reminder(tmp_path):
    db = tmp_path / "m.db"
    t = Todo(id="t1", text="send the synthetic draft", owner="user", deadline=None)
    _apply(db, [t]); _apply(db, [t])
    assert _rows(db) == [("t1", "pending", None)]
