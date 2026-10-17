"""D2: the Reminders tile must not read green when no push ever succeeded.

Before: any table without a permission_denied row was STATE_OK ("Reminders are
syncing") even if every row was status=failed, and an unreadable DB rendered
nothing at all. Synthetic data only.
"""
import sqlite3
import sys
from pathlib import Path

import pytest

AGENT = Path(__file__).resolve().parent.parent / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))

import reminders_runtime as rr  # noqa: E402


def _db(tmp_path, statuses):
    home = tmp_path / "ostler"
    home.mkdir()
    conn = sqlite3.connect(str(home / "reminders_map.db"))
    conn.execute(
        "CREATE TABLE reminders_map (user_id TEXT, source_session_id TEXT, todo_id TEXT,"
        " status TEXT NOT NULL, push_title TEXT, last_seen_at TEXT NOT NULL)"
    )
    for i, s in enumerate(statuses):
        conn.execute(
            "INSERT INTO reminders_map VALUES ('u','s',?,?,?,?)",
            (str(i), s, "Synthetic todo %d" % i, "2026-10-01T00:00:00Z"),
        )
    conn.commit()
    conn.close()
    return home


@pytest.fixture(autouse=True)
def _home(monkeypatch, tmp_path):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path / "ostler"))


def _read(tmp_path, statuses):
    _db(tmp_path, statuses)
    return rr.read_reminders_runtime()


def test_every_row_failed_is_not_ok(tmp_path):
    r = _read(tmp_path, ["failed", "failed", "failed"])
    assert r["state"] == "push_failing", r
    assert r["failed_count"] == 3


def test_some_pushed_is_still_ok(tmp_path):
    """Control: a transient failure beside real pushes stays green."""
    r = _read(tmp_path, ["pushed", "pushed", "failed"])
    assert r["state"] == rr.STATE_OK, r


def test_all_pushed_is_ok(tmp_path):
    assert _read(tmp_path, ["pushed", "skipped"])["state"] == rr.STATE_OK


def test_unreadable_db_is_cannot_read_not_no_data(tmp_path):
    home = tmp_path / "ostler"
    home.mkdir()
    (home / "reminders_map.db").write_bytes(b"this is not a sqlite database at all" * 40)
    r = rr.read_reminders_runtime()
    assert r["state"] == "cannot_read", r
    assert r["reason"]


def test_tile_says_so(tmp_path):
    import dashboard_components as dc

    _db(tmp_path, ["failed", "failed"])
    html = dc.render_reminders_runtime()
    assert "Reminders are syncing" not in html
    assert "not reaching" in html.lower()
    # unreadable: rendered, not hidden
    (tmp_path / "ostler" / "reminders_map.db").write_bytes(b"garbage" * 100)
    assert "Could not check" in dc.render_reminders_runtime()
