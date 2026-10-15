"""#30 (Archie's A3 question): on day one, does a SPARSE history (every
conversation older than 45 days) reach (a) the people graph and (b)
CONVERSATIONS?

Two paths, traced:
  (a) imports/fda -> pwg_ingest.ingest_all (people, graph).      Driven by
      backfill_ladder.finish_pending_first_windows, the function the first
      quiet firing runs.
  (b) chat.db -> imessage_source.pipeline.process_imessage -> CM048 dispatch
      (the conversation bundles). Reads chat.db and its own watermark, NOT
      imports/fda, so widening imports/fda alone leaves conversations empty.

Synthetic data only: handles are reserved-domain placeholders.
"""
from __future__ import annotations

import json
import logging
import sqlite3
import sys
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor"))
sys.path.insert(0, str(REPO / "vendor" / "imessage_source" / ".."))   # vendor/ (package imessage_source)

MAC_EPOCH = 978307200
DAY = 86400
N = 60


def _mac_ns(days_ago: float) -> int:
    return int((time.time() - days_ago * DAY - MAC_EPOCH) * 1e9)


def _make_chat_db(path: Path, chats):
    db = sqlite3.connect(str(path))
    db.executescript("""
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT, style INTEGER, account_login TEXT);
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, is_from_me INTEGER, date INTEGER,
                              cache_has_attachments INTEGER, service TEXT, handle_id INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    """)
    mid = 0
    for i, (age, n) in enumerate(chats, start=1):
        db.execute("INSERT INTO chat VALUES (?,?,?,45,NULL)", (i, f"chat-{i}", None))
        db.execute("INSERT INTO handle VALUES (?,?)", (i, f"person{i}@example.invalid"))
        db.execute("INSERT INTO chat_handle_join VALUES (?,?)", (i, i))
        for k in range(n):
            mid += 1
            db.execute("INSERT INTO message VALUES (?,?,?,?,0,'iMessage',?)",
                       (mid, f"synthetic line {k}", k % 2, _mac_ns(age + k * 0.001), i))
            db.execute("INSERT INTO chat_message_join VALUES (?,?)", (i, mid))
    db.commit()
    db.close()


SPARSE = [(60 + (i * 340) // (N - 1), 40) for i in range(N)]     # all 60..400 days old
DENSE = [(1 + i % 20, 40) for i in range(80)]


@pytest.fixture()
def box(tmp_path, monkeypatch):
    state = tmp_path / "state"
    state.mkdir()
    monkeypatch.setenv("OSTLER_STATE_DIR", str(state))
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path / "ohome"))
    monkeypatch.setenv("OSTLER_CATCHUP_MAX_LOAD_PER_CORE", "100000")
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("OSTLER_IMESSAGE_BACKFILL_DAYS", raising=False)
    monkeypatch.delenv("OSTLER_IMESSAGE_SINCE_DAYS", raising=False)
    monkeypatch.syspath_prepend(str(REPO / "lib"))
    return tmp_path, tmp_path / "chat.db", state


def _install_marker(tmp_path):
    m = tmp_path / "ohome" / "state" / "install-in-progress"
    m.parent.mkdir(parents=True, exist_ok=True)
    return m


# ── (b) conversations ───────────────────────────────────────────────────────

def _bundle_run(tmp_path, db, monkeypatch, since_days=30):
    from imessage_source import pipeline
    sent = []
    monkeypatch.setattr(pipeline, "_dispatch_to_cm048",
                        lambda transcript, metadata, **k: (sent.append(metadata), 0)[1])
    summary = pipeline.process_imessage(db_path=db, state_path=tmp_path / "im_state.json",
                                        since_days=since_days, pwg_convo_cmd=["true"])
    return summary, sent


def test_sparse_history_yields_conversation_bundles_on_day_one(box, monkeypatch, caplog):
    tmp_path, db, state = box
    _make_chat_db(db, SPARSE)
    caplog.set_level(logging.INFO)
    summary, sent = _bundle_run(tmp_path, db, monkeypatch)
    assert len(sent) >= 50, f"{len(sent)} conversation bundles dispatched on a sparse day one"
    assert "[first-window] imessage-bundle" in caplog.text, caplog.text


def test_dense_history_keeps_the_30_day_bundle_window(box, monkeypatch):
    tmp_path, db, state = box
    _make_chat_db(db, DENSE + [(300, 40), (500, 40)])
    summary, sent = _bundle_run(tmp_path, db, monkeypatch)
    assert len(sent) == 80, len(sent)          # the two old chats stay out


def test_the_bundle_window_is_not_widened_during_the_install(box, monkeypatch, caplog):
    tmp_path, db, state = box
    _make_chat_db(db, SPARSE)
    marker = _install_marker(tmp_path)
    marker.write_text("pid=1\n")
    summary, sent = _bundle_run(tmp_path, db, monkeypatch)
    assert sent == [], "the install foreground dispatched widened history"
    marker.unlink()
    summary, sent = _bundle_run(tmp_path, db, monkeypatch)
    assert len(sent) >= 50, len(sent)


# ── (a) the graph, via the first quiet firing ──────────────────────────────

def test_a_deferred_first_window_reaches_the_graph_on_the_first_quiet_firing(box, monkeypatch):
    tmp_path, db, state = box
    _make_chat_db(db, SPARSE)
    from ostler_fda import backfill_ladder as bl, extract_all, imessage, pwg_ingest
    monkeypatch.setattr(imessage, "DEFAULT_CHAT_DB", db)
    monkeypatch.setattr(imessage, "_emit_settling", lambda *a, **k: None)
    fda = tmp_path / "fda"
    marker = _install_marker(tmp_path)
    marker.write_text("pid=1\n")
    extract_all.run_all(output_dir=fda, enabled_sources=["imessage"])      # the install foreground
    assert json.loads((fda / "imessage_conversations.json").read_text()) == []
    assert (state / "first_window_pending_imessage").exists()

    updates = []
    monkeypatch.setattr(pwg_ingest, "_sparql_update", lambda q: updates.append(q))
    monkeypatch.setattr(pwg_ingest, "_sparql_query", lambda q: [])
    marker.unlink()                                                         # install over: quiet
    out = bl.finish_pending_first_windows(fda)
    assert out["status"] == "ok", out
    convs = json.loads((fda / "imessage_conversations.json").read_text())
    assert len(convs) >= 50, len(convs)
    people = {f"person{i}@example.invalid" for i in range(1, N + 1) if any(f"person{i}@example.invalid" in q for q in updates)}
    assert len(people) >= 50, f"{len(people)} people reached the graph writer"
    assert not (state / "first_window_pending_imessage").exists()


def test_nothing_pending_means_nothing_runs(box):
    tmp_path, db, state = box
    from ostler_fda import backfill_ladder as bl
    assert bl.finish_pending_first_windows(tmp_path / "fda")["status"] == "nothing_pending"
