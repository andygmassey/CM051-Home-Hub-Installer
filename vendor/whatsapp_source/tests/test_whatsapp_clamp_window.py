"""The daytime 2-day clamp must not cost a busy chat its older history.

Before: a clamped tick moved the per-chat watermark to the newest message, so
the next full-window tick skipped the chat and only ever kept 2 days.
Synthetic data only.
"""
from __future__ import annotations

import json
import sqlite3
import sys
from datetime import timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from whatsapp_source.pipeline import process_whatsapp

from test_whatsapp_source import (  # noqa: E402
    _NOW, _StubDispatch, _mac_ts, chatdb,  # noqa: F401
)

JID = "111" + chr(64) + "s.whatsapp.net"
OLD_TEXT = "Synthetic message from a month ago."


def _add_old_message(db):
    conn = sqlite3.connect(str(db))
    conn.execute(
        "INSERT INTO ZWAMESSAGE "
        "(Z_PK, ZCHATSESSION, ZISFROMME, ZMESSAGEDATE, ZFROMJID, ZTEXT, ZMESSAGETYPE) "
        "VALUES (900, 1, 0, ?, ?, ?, 0)",
        (_mac_ts(_NOW - timedelta(days=30)), JID, OLD_TEXT),
    )
    conn.commit()
    conn.close()


def _run(chatdb, cmd, state, days):
    return process_whatsapp(
        db_path=chatdb, pwg_convo_cmd=cmd, state_path=state,
        since_days=days, now_utc=_NOW,
    )


def test_a_full_window_tick_after_a_clamped_tick_reads_the_older_history(chatdb, tmp_path):
    _add_old_message(chatdb)
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"

    first = _run(chatdb, cmd, state, 2)
    assert first["chats_dispatched"] == 2
    assert not any(OLD_TEXT in r["transcript"] for r in stub.load())

    second = _run(chatdb, cmd, state, 365)
    assert second["chats_dispatched"] >= 1, second
    assert any(OLD_TEXT in r["transcript"] for r in stub.load())

    third = _run(chatdb, cmd, state, 365)
    assert third["chats_dispatched"] == 0 and third["chats_skipped"] == 2


def test_a_clamped_tick_after_a_full_tick_does_not_redispatch(chatdb, tmp_path):
    """Control: narrowing the window must not churn every chat."""
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"
    _run(chatdb, cmd, state, 365)
    again = _run(chatdb, cmd, state, 2)
    assert again["chats_dispatched"] == 0 and again["chats_skipped"] == 2


def test_state_written_before_windows_existed_is_read_once_on_a_wide_tick(chatdb, tmp_path):
    stub = _StubDispatch()
    cmd = stub.make_cmd(tmp_path)
    state = tmp_path / "state.json"
    _run(chatdb, cmd, state, 2)
    saved = json.loads(state.read_text())
    saved.pop("windows")  # simulate the pre-fix state file
    state.write_text(json.dumps(saved))
    assert _run(chatdb, cmd, state, 2)["chats_dispatched"] == 0
    assert _run(chatdb, cmd, state, 365)["chats_dispatched"] == 2
    assert _run(chatdb, cmd, state, 365)["chats_dispatched"] == 0
