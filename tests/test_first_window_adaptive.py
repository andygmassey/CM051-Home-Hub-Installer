"""#30: the FIRST install window widens when the default holds too little.

The ladder opens at 45 days. An owner whose messages are all older than that
saw 0 conversations on day one. These tests drive the SHIPPED
``ostler_fda.extract_all.run_all`` over a synthetic chat.db (the real iMessage
extractor, the real ladder), and pin:

  * sparse recent history (every message 60 to 400 days old) reaches the
    minimum on day one;
  * dense history keeps the 45-day window and does not widen;
  * an explicit operator pin is honoured;
  * the chosen window is logged per source, counts only.

Synthetic data only: handles are reserved-range placeholders, no text bodies.
"""
from __future__ import annotations

import logging
import os
import sqlite3
import sys
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor"))

MAC_EPOCH = 978307200
DAY = 86400


def _mac_ns(days_ago: float) -> int:
    return int((time.time() - days_ago * DAY - MAC_EPOCH) * 1e9)


def _make_chat_db(path: Path, chats: list[tuple[int, int]]) -> None:
    """chats: (age_in_days_of_newest_message, message_count) per chat."""
    db = sqlite3.connect(str(path))
    db.executescript("""
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT, style INTEGER);
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    """)
    mid = 0
    for i, (age, n) in enumerate(chats, start=1):
        db.execute("INSERT INTO chat VALUES (?,?,?,45)", (i, f"chat-{i}", None))
        db.execute("INSERT INTO handle VALUES (?,?)", (i, f"person{i}@example.invalid"))
        db.execute("INSERT INTO chat_handle_join VALUES (?,?)", (i, i))
        for k in range(n):
            mid += 1
            db.execute("INSERT INTO message VALUES (?,?)", (mid, _mac_ns(age + k * 0.001)))
            db.execute("INSERT INTO chat_message_join VALUES (?,?)", (i, mid))
    db.commit()
    db.close()


@pytest.fixture()
def box(tmp_path, monkeypatch):
    state = tmp_path / "state"
    state.mkdir()
    monkeypatch.setenv("OSTLER_STATE_DIR", str(state))
    # The busy predicate (lib/ostler_catchup.busy_reason) reads OSTLER_HOME and
    # the load average; pin both so this suite is not hostage to the machine.
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path / "ohome"))
    monkeypatch.setenv("OSTLER_CATCHUP_MAX_LOAD_PER_CORE", "100000")
    monkeypatch.syspath_prepend(str(REPO / "lib"))
    for k in ("OSTLER_IMESSAGE_BACKFILL_DAYS", "OSTLER_FIRST_WINDOW_MIN_MESSAGES",
              "OSTLER_FIRST_WINDOW_MIN_CONVERSATIONS", "OSTLER_FIRST_WINDOW_BUDGET_SECONDS"):
        monkeypatch.delenv(k, raising=False)
    from ostler_fda import imessage
    db = tmp_path / "chat.db"
    monkeypatch.setattr(imessage, "DEFAULT_CHAT_DB", db)
    # The settling shard writer is not under test.
    monkeypatch.setattr(imessage, "_emit_settling", lambda *a, **k: None)
    return tmp_path, db, state


def _run(tmp_path):
    from ostler_fda import extract_all
    out = tmp_path / "out"
    summary = extract_all.run_all(output_dir=out, enabled_sources=["imessage"])
    return summary["sources"]["imessage"]


def test_sparse_recent_history_reaches_the_minimum_on_day_one(box, caplog):
    tmp_path, db, state = box
    # 60 chats, 40 messages each, newest message 60 to 400 days old: ZERO
    # inside the default 45 days, 2,400 messages in all.
    _make_chat_db(db, [(60 + (i * 340) // 59, 40) for i in range(60)])
    caplog.set_level(logging.INFO)
    stat = _run(tmp_path)
    assert stat["status"] == "ok"
    assert stat["total_messages"] >= 2000 or stat["total_conversations"] >= 50, stat
    assert stat["total_conversations"] > 0
    assert "[first-window] imessage" in caplog.text, caplog.text


def test_dense_history_keeps_the_45_day_window(box, caplog):
    tmp_path, db, state = box
    # 80 chats, 30 messages each, all inside the last 30 days.
    _make_chat_db(db, [(1 + i % 30, 30) for i in range(80)] + [(300, 40), (500, 40)])
    caplog.set_level(logging.INFO)
    stat = _run(tmp_path)
    assert stat["total_conversations"] == 80, stat   # the two old chats stay out
    assert "[first-window] imessage kept 45d" in caplog.text, caplog.text


def test_an_explicit_operator_pin_is_not_widened(box, monkeypatch):
    tmp_path, db, state = box
    monkeypatch.setenv("OSTLER_IMESSAGE_BACKFILL_DAYS", "45")
    _make_chat_db(db, [(100 + i, 40) for i in range(60)])
    stat = _run(tmp_path)
    assert stat["total_conversations"] == 0, stat


def test_widening_stops_when_history_is_exhausted(box, caplog):
    tmp_path, db, state = box
    _make_chat_db(db, [(100, 5), (200, 5)])       # 10 messages in all
    caplog.set_level(logging.INFO)
    stat = _run(tmp_path)
    assert stat["total_conversations"] == 2, stat
    assert "exhausted" in caplog.text, caplog.text


def test_a_later_tick_does_not_re_widen_on_its_own(box):
    tmp_path, db, state = box
    _make_chat_db(db, [(60 + i, 40) for i in range(60)])
    first = _run(tmp_path)
    assert first["total_conversations"] > 0
    # Second run is governed by the ladder's dwell, not by the first-window
    # rule: the marker says the first window was already chosen.
    assert (state / "first_window_imessage.json").exists()


def _marker(tmp_path):
    m = tmp_path / "ohome" / "state" / "install-in-progress"
    m.parent.mkdir(parents=True, exist_ok=True)
    return m


def test_widening_is_deferred_while_the_install_runs_then_done_by_the_first_tick(box, caplog):
    """#30 review A3: the INSTALL foreground never widens. While the install
    marker exists the Mac is busy ('installing'), so the first window is left
    alone, nothing is recorded as chosen, and the source is queued; the first
    post-install run (marker gone) widens and clears the queue."""
    tmp_path, db, state = box
    _make_chat_db(db, [(60 + (i * 340) // 59, 40) for i in range(60)])
    marker = _marker(tmp_path)
    marker.write_text("pid=1\n")
    caplog.set_level(logging.INFO)
    stat = _run(tmp_path)
    assert stat["total_conversations"] == 0, "the install foreground widened"
    assert "[first-window] imessage deferred: busy (installing)" in caplog.text, caplog.text
    assert not (state / "first_window_imessage.json").exists()
    assert (state / "first_window_pending_imessage").read_text().strip() == "imessage"
    marker.unlink()
    stat = _run(tmp_path)
    assert stat["total_conversations"] > 0, stat
    assert (state / "first_window_imessage.json").exists()
    assert not (state / "first_window_pending_imessage").exists()


def test_busy_is_checked_before_every_widening_step(box, caplog):
    from ostler_fda import backfill_ladder as bl
    calls = []
    answers = iter([None, "load"])     # quiet for the first widening, busy for the next

    def extract(d):
        calls.append(d)
        return []

    caplog.set_level(logging.INFO)
    bl.widen_first_window("imessage", 45, extract, lambda r: (0, 0),
                          busy=lambda: next(answers, "load"))
    assert calls == [45, 90], calls     # stopped before 180
    assert "deferred: busy (load)" in caplog.text, caplog.text


def test_the_budget_bounds_a_single_slow_extraction(box, monkeypatch):
    from ostler_fda import backfill_ladder as bl
    monkeypatch.setenv("OSTLER_FIRST_WINDOW_BUDGET_SECONDS", "1")

    def extract(d):
        if d > 45:
            time.sleep(8)          # one batch that would blow the budget
        return []

    t0 = time.monotonic()
    bl.widen_first_window("imessage", 45, extract, lambda r: (0, 0), busy=lambda: None)
    assert time.monotonic() - t0 < 4, "a slow batch ran past the budget"
