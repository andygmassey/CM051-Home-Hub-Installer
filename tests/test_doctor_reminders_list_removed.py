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
        "status TEXT, push_title TEXT, last_seen_at TEXT, failure_reason TEXT)"
    )
    for i, st in enumerate(statuses):
        c.execute("INSERT INTO reminders_map VALUES ('u','s',?,?,'t','2026-10-11',NULL)", (f"t{i}", st))
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


# ---- the control: "turn reminders back on" ------------------------------

def test_the_tile_has_the_button_that_asks_the_question(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path))
    _db(tmp_path, ["reminders_list_removed"])
    import dashboard_components

    html = dashboard_components.render_reminders_runtime()
    assert 'id="remindersTurnOnBtn"' in html
    assert "/api/v1/reminders/turn-on" in html


def test_a_healthy_tile_has_no_button(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path))
    _db(tmp_path, ["pushed"])
    import dashboard_components

    assert "remindersTurnOnBtn" not in dashboard_components.render_reminders_runtime()


def test_turn_back_on_forgets_the_id_and_rearms_only_parked_rows(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path))
    _db(tmp_path, ["reminders_list_removed", "reminders_list_removed", "pushed", "skipped"])
    (tmp_path / "reminders_list_id").write_text("cal-123")
    r = reminders_runtime.turn_reminders_back_on()
    assert r == {"ok": True, "rearmed": 2, "error": None}
    assert not (tmp_path / "reminders_list_id").exists()
    c = sqlite3.connect(tmp_path / "reminders_map.db")
    got = sorted(x[0] for x in c.execute("SELECT status FROM reminders_map"))
    c.close()
    assert got == ["pending", "pending", "pushed", "skipped"]
    assert read_reminders_runtime()["state"] == STATE_OK


def test_the_route_is_guarded_and_works(tmp_path, monkeypatch):
    pytest.importorskip("fastapi")
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path))
    _db(tmp_path, ["reminders_list_removed"])
    try:
        import web_ui
        from fastapi.testclient import TestClient
    except Exception as exc:  # the Doctor app needs its own deps
        pytest.skip("web_ui not importable here: %s" % exc)
    c = TestClient(web_ui.app, base_url="http://127.0.0.1:8089")
    # cross-site: refused, nothing changed
    bad = c.post("/api/v1/reminders/turn-on", headers={"Sec-Fetch-Site": "cross-site"})
    assert bad.status_code == 403
    assert read_reminders_runtime()["state"] == STATE_LIST_REMOVED
    # wrong Host: refused
    off = TestClient(web_ui.app, base_url="http://evil.example").post("/api/v1/reminders/turn-on")
    assert off.status_code == 403
    ok = c.post("/api/v1/reminders/turn-on", headers={"Sec-Fetch-Site": "same-origin"})
    assert ok.status_code == 200 and ok.json()["rearmed"] == 1
    assert read_reminders_runtime()["state"] == STATE_OK
