"""A chat.db SCHEMA MISMATCH must fail LOUD, never silently return [].

Walk #30 (v1.0.108 owner-knowledge) ingested 0 of 1075 iMessages and scored
0/80. ROOT CAUSE: both shipped readers SELECT ``c.account_login``; the test
chat.db lacked it, sqlite raised ``no such column: c.account_login``, and the
readers logged it and ``return []``. A zero-message read is INDISTINGUISHABLE
at the consumer from "you have not messaged anyone", so every source reported
"ok" and the broken harness looked like a product failure.

These tests FAIL on the old code (which returned [] on the drift) and pass on
the fix (which raises ``ChatDbSchemaError``). The benign-empty control proves
the fix did not over-raise: a valid but empty store still returns [] silently.
The end-to-end test drives a REAL consumer (``write_reply_debt_snapshot``) and
asserts it now records ``status: "error"`` where it used to record
``status: "ok"`` with an empty thread list.
"""
from __future__ import annotations

import sqlite3
import sys
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor"))

import imessage_source.reader as im_src  # noqa: E402
import ostler_fda.imessage as im_fda  # noqa: E402
from imessage_source import pipeline as im_pipeline  # noqa: E402
from imessage_source.reader import ChatDbSchemaError as SrcSchemaError  # noqa: E402
from ostler_fda.imessage import ChatDbSchemaError as FdaSchemaError  # noqa: E402

MAC_EPOCH = 978307200

# The real macOS chat.db schema the readers were written against (copied from
# tests/test_first_window_end_to_end.py::_make_chat_db).
_FULL_SCHEMA = """
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT, style INTEGER, account_login TEXT);
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, is_from_me INTEGER, date INTEGER,
                          cache_has_attachments INTEGER, service TEXT, handle_id INTEGER);
    CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
"""
# The EXACT walk #30 drift: `chat` with no `account_login` column. The
# conversation query (which does not SELECT it) still succeeds; the MESSAGE
# query raises.
_DRIFT_NO_ACCOUNT_LOGIN = _FULL_SCHEMA.replace(", account_login TEXT", "")
# A drift the CONVERSATION query itself hits: `chat` with no `style` column.
_DRIFT_NO_STYLE = _FULL_SCHEMA.replace(", style INTEGER", "")


def _now_ns() -> int:
    return int((time.time() - MAC_EPOCH) * 1e9)


def _populate(db: sqlite3.Connection, *, has_style: bool, n_msgs: int = 3) -> None:
    if has_style:
        db.execute(
            "INSERT INTO chat (ROWID, guid, display_name, style) VALUES (1, 'chat-1', NULL, 45)"
        )
    else:
        db.execute("INSERT INTO chat (ROWID, guid, display_name) VALUES (1, 'chat-1', NULL)")
    db.execute("INSERT INTO handle VALUES (1, 'person1@example.invalid')")
    db.execute("INSERT INTO chat_handle_join VALUES (1, 1)")
    for k in range(n_msgs):
        db.execute(
            "INSERT INTO message (ROWID, text, is_from_me, date, cache_has_attachments, "
            "service, handle_id) VALUES (?,?,?,?,0,'iMessage',1)",
            (k + 1, f"synthetic line {k}", k % 2, _now_ns() - k),
        )
        db.execute("INSERT INTO chat_message_join VALUES (1, ?)", (k + 1,))


def _make_db(path: Path, schema: str, *, has_style: bool = True, rows: bool = True) -> Path:
    db = sqlite3.connect(str(path))
    db.executescript(schema)
    if rows:
        _populate(db, has_style=has_style)
    db.commit()
    db.close()
    return path


@pytest.fixture(autouse=True)
def _isolate_state(tmp_path, monkeypatch):
    # ostler_fda.extract_conversations emits a settling-progress shard; keep it
    # out of the real ~/.ostler.
    monkeypatch.setenv("OSTLER_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))


# --------------------------------------------------------------------------- #
# Sanity: a valid schema with rows reads messages in BOTH readers.
# --------------------------------------------------------------------------- #
def test_valid_schema_reads_messages_both_readers(tmp_path):
    db = _make_db(tmp_path / "full.db", _FULL_SCHEMA)

    convs = im_src.extract_conversations(db_path=db, since_days=0)
    assert len(convs) == 1
    assert len(im_src.extract_messages(convs[0].chat_id, db_path=db)) == 3

    convs2 = im_fda.extract_conversations(db_path=db, since_days=0)
    assert len(convs2) == 1
    assert len(im_fda.extract_messages(convs2[0].chat_id, db_path=db)) == 3


# --------------------------------------------------------------------------- #
# The walk #30 drift: missing account_login. extract_messages must RAISE,
# not return []. (Old code: returned [] -> this test goes red.)
# --------------------------------------------------------------------------- #
def test_missing_account_login_raises_in_imessage_source(tmp_path):
    db = _make_db(tmp_path / "drift.db", _DRIFT_NO_ACCOUNT_LOGIN)
    # conversation query does not SELECT account_login, so it still works
    convs = im_src.extract_conversations(db_path=db, since_days=0)
    assert len(convs) == 1
    with pytest.raises(SrcSchemaError) as ei:
        im_src.extract_messages(convs[0].chat_id, db_path=db)
    assert "account_login" in str(ei.value)


def test_missing_account_login_raises_in_ostler_fda(tmp_path):
    db = _make_db(tmp_path / "drift.db", _DRIFT_NO_ACCOUNT_LOGIN)
    convs = im_fda.extract_conversations(db_path=db, since_days=0)
    assert len(convs) == 1
    with pytest.raises(FdaSchemaError) as ei:
        im_fda.extract_messages(convs[0].chat_id, db_path=db)
    assert "account_login" in str(ei.value)


# --------------------------------------------------------------------------- #
# A drift the CONVERSATION query hits (missing `style`) must RAISE there too.
# --------------------------------------------------------------------------- #
def test_missing_column_in_conversation_query_raises_both(tmp_path):
    db = _make_db(tmp_path / "nostyle.db", _DRIFT_NO_STYLE, has_style=False)
    with pytest.raises(SrcSchemaError):
        im_src.extract_conversations(db_path=db, since_days=0)
    with pytest.raises(FdaSchemaError):
        im_fda.extract_conversations(db_path=db, since_days=0)


# --------------------------------------------------------------------------- #
# NEGATIVE CONTROL: a valid but EMPTY store is a benign empty -> [] with NO
# raise. Proves the fix distinguishes "broken reader" from "no messages yet"
# and did not over-raise.
# --------------------------------------------------------------------------- #
def test_benign_empty_store_returns_empty_without_raising(tmp_path):
    db = _make_db(tmp_path / "empty.db", _FULL_SCHEMA, rows=False)
    assert im_src.extract_conversations(db_path=db, since_days=0) == []
    assert im_fda.extract_conversations(db_path=db, since_days=0) == []
    # a valid-schema chat_id that simply has no messages also returns []
    assert im_src.extract_messages("chat-absent", db_path=db) == []
    assert im_fda.extract_messages("chat-absent", db_path=db) == []


# --------------------------------------------------------------------------- #
# END-TO-END through a REAL consumer: write_reply_debt_snapshot reads chat.db
# via both reader functions and records a status. On the drift it must record
# "error" (loud). Old code recorded "ok" with an empty thread list -- the
# silent zero walk #30 shipped.
# --------------------------------------------------------------------------- #
def test_schema_drift_recorded_as_error_end_to_end(tmp_path):
    db = _make_db(tmp_path / "drift.db", _DRIFT_NO_ACCOUNT_LOGIN)
    out = tmp_path / "reply_debt.json"
    status = im_pipeline.write_reply_debt_snapshot(
        db_path=db, out_path=out, lookback_days=3650
    )
    assert status == "error"


def test_valid_schema_recorded_as_ok_end_to_end(tmp_path):
    db = _make_db(tmp_path / "full.db", _FULL_SCHEMA)
    out = tmp_path / "reply_debt.json"
    status = im_pipeline.write_reply_debt_snapshot(
        db_path=db, out_path=out, lookback_days=3650
    )
    assert status == "ok"
