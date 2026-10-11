"""Doctor shows one line when the customer deleted Ostler's Reminders list.

The assistant parks rows as status 'reminders_list_removed' and pushes
nothing (assistant repo, crates/ostler-reminders). This pins the Doctor side
of that contract against the real mapping-DB shape. Synthetic data only.
"""
from __future__ import annotations

import sqlite3
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "doctor" / "agent"))

import reminders_runtime
from reminders_runtime import STATE_LIST_REMOVED, STATE_OK, read_reminders_runtime

LINE = "Ostler's Reminders list was removed; turn reminders back on?"


def _db(home: Path, statuses):
    home.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(home / "reminders_map.db")
    c.execute(
        "CREATE TABLE reminders_map (user_id TEXT, source_session_id TEXT, todo_id TEXT, "
        "status TEXT, push_title TEXT, last_seen_at TEXT)"
    )
    for i, st in enumerate(statuses):
        c.execute("INSERT INTO reminders_map VALUES ('u','s',?,?,'t','2026-10-11')", (f"t{i}", st))
    c.commit()
    c.close()


def test_state_is_list_removed_when_rows_are_parked(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path))
    _db(tmp_path, ["pushed", "reminders_list_removed", "reminders_list_removed"])
    r = read_reminders_runtime()
    assert r["state"] == STATE_LIST_REMOVED and r["removed_count"] == 2


def test_healthy_table_is_not_list_removed(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path))
    _db(tmp_path, ["pushed", "pending"])
    assert read_reminders_runtime()["state"] == STATE_OK


def test_the_tile_shows_the_one_line(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path))
    _db(tmp_path, ["reminders_list_removed"])
    import dashboard_components

    html = dashboard_components.render_reminders_runtime()
    assert "Ostler&#x27;s Reminders list was removed" in html or "Ostler's Reminders list was removed" in html
    assert "turn reminders back on?" in html
