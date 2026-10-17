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


def _make_chat_db(path: Path, chats, bursts: int = 1, burst_gap_days: float = 10.0):
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
        for b in range(bursts):
            for k in range(n):
                mid += 1
                db.execute("INSERT INTO message VALUES (?,?,?,?,0,'iMessage',?)",
                           (mid, f"synthetic line {b}.{k}", k % 2,
                            _mac_ns(age + b * burst_gap_days + k * 0.001), i))
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


# ── the EMAIL bundle path (same 30-day clamp) ──────────────────────────────

def _mail_tree(mail_dir: Path, ages_days):
    from datetime import datetime, timedelta, timezone
    from email.utils import format_datetime
    now = datetime.now(timezone.utc)
    for i, age in enumerate(ages_days):
        dt = now - timedelta(days=age)
        rfc = ("\r\n".join([
            f"From: Sender {i} <sender{i}@partner.test>", "To: <operator@example.test>",
            f"Subject: Synthetic topic {i}", f"Date: {format_datetime(dt)}",
            f"Message-Id: <m{i}@partner.test>", "Content-Type: text/plain; charset=utf-8",
        ]) + "\r\n\r\nsynthetic body\r\n").encode()
        plist = b'<?xml version="1.0"?><plist version="1.0"><dict></dict></plist>\n'
        d = mail_dir / "V10" / "acc.mbox" / "INBOX.mbox" / "UUID" / "Data" / "1" / "Messages"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{i}.emlx").write_bytes(f"{len(rfc)}\n".encode() + rfc + plist)


def _mail_run(tmp_path, monkeypatch, since_days=30):
    from email_source import pipeline
    sent = []
    monkeypatch.setattr(pipeline, "_dispatch_to_cm048",
                        lambda transcript, metadata, **k: (sent.append(metadata), 0)[1])
    monkeypatch.setattr(pipeline, "_seed_all", lambda *a, **k: 0)
    summary = pipeline.process_email(mail_dir=tmp_path / "mail", state_path=tmp_path / "em_state.json",
                                     since_days=since_days, user_address="operator@example.test",
                                     pwg_convo_cmd=["true"])
    return summary, sent


def test_sparse_mail_yields_thread_bundles_on_day_one(box, monkeypatch, caplog):
    tmp_path, db, state = box
    _mail_tree(tmp_path / "mail", [60 + (i * 340) // (N - 1) for i in range(N)])
    caplog.set_level(logging.INFO)
    summary, sent = _mail_run(tmp_path, monkeypatch)
    assert len(sent) >= 50, f"{len(sent)} mail thread bundles dispatched on a sparse day one"
    assert "[first-window] email-bundle" in caplog.text, caplog.text


def test_dense_mail_keeps_the_30_day_window(box, monkeypatch):
    tmp_path, db, state = box
    _mail_tree(tmp_path / "mail", [1 + i % 20 for i in range(80)] + [300, 500])
    summary, sent = _mail_run(tmp_path, monkeypatch)
    assert len(sent) == 80, len(sent)


def test_mail_window_is_not_widened_during_the_install_or_when_pinned(box, monkeypatch):
    tmp_path, db, state = box
    _mail_tree(tmp_path / "mail", [60 + (i * 340) // (N - 1) for i in range(N)])
    marker = _install_marker(tmp_path)
    marker.write_text("pid=1\n")
    summary, sent = _mail_run(tmp_path, monkeypatch)
    assert sent == [], "the install foreground bundled widened mail"
    marker.unlink()
    monkeypatch.setenv("OSTLER_EMAIL_SINCE_DAYS", "30")                      # operator pin
    summary, sent = _mail_run(tmp_path, monkeypatch)
    assert sent == [], "an operator pin was widened"
    monkeypatch.delenv("OSTLER_EMAIL_SINCE_DAYS")
    summary, sent = _mail_run(tmp_path, monkeypatch)
    assert len(sent) >= 50, len(sent)


# ── the widened bundle tick and #2907's catch-up adapter must not double-bundle ──
#
# Both derive conversation_id with threader.thread_messages (chat_id + the
# session's first timestamp), so the same session gets the SAME id from either
# path and CM048 (one state dir per id) upserts. These tests RUN both over one
# fixture and assert the DISTINCT id set is unchanged by the second path.
# #2907's vendor/imessage_source/catchup.py is not in this branch; point
# OSTLER_CATCHUP_MESSAGES_PY at a copy, or this is CANNOT-RUN (skipped), not a pass.

def _catchup_module():
    import importlib.util, os
    path = os.environ.get("OSTLER_CATCHUP_MESSAGES_PY") or str(REPO / "vendor" / "imessage_source" / "catchup.py")
    if not Path(path).is_file():
        pytest.skip("CANNOT-RUN: #2907's imessage_source/catchup.py is not in this tree "
                    "(set OSTLER_CATCHUP_MESSAGES_PY)")
    import ostler_catchup  # noqa: F401  (lib/ is on sys.path via the box fixture)
    spec = importlib.util.spec_from_file_location("imessage_source.catchup", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["imessage_source.catchup"] = mod
    spec.loader.exec_module(mod)
    return mod


def _catchup_ids(tmp_path, db, monkeypatch):
    import ostler_catchup as oc
    cu = _catchup_module()
    ids = []
    monkeypatch.setenv("OSTLER_CATCHUP_STATE_DIR", str(tmp_path / "cu_state"))
    monkeypatch.setattr(cu, "_dispatch_to_cm048", lambda t, m, **k: (ids.append(m["conversation_id"]), 0)[1])
    ad = cu.IMessageCatchup(db_path=db, state_path=tmp_path / "im_state.json", pwg_convo_cmd=["true"])
    for _ in range(200):
        s = oc.run([ad], budget_seconds=1e9, busy=lambda: None)
        if s["sources"]["imessage"]["complete"]:
            break
    return ids


def test_widened_bundles_then_catchup_add_no_second_bundle(box, monkeypatch):
    tmp_path, db, state = box
    _make_chat_db(db, SPARSE, bursts=2)
    # Ground truth: every session in the fixture, from a catch-up-only walk in a
    # throwaway state dir (nothing forward has run there).
    truth_dir = tmp_path / "truth"
    truth_dir.mkdir()
    truth = set(_catchup_ids(truth_dir, db, monkeypatch))
    assert len(truth) == 2 * N, len(truth)
    _, fwd = _bundle_run(tmp_path, db, monkeypatch)
    fwd_ids = {m["conversation_id"] for m in fwd}
    assert len(fwd_ids) >= 100, len(fwd_ids)
    cu_ids = set(_catchup_ids(tmp_path, db, monkeypatch))
    # A different derivation for the same session would put an id OUTSIDE the
    # truth set (or make the union exceed it). Same derivation: the union is
    # exactly the sessions that exist, each once. The catch-up's own ids are
    # the ones OLDER than the widened window, which the bundle tick never read.
    assert fwd_ids <= truth and cu_ids <= truth, "an id differs from the one the other path gives the same session"
    assert fwd_ids | cu_ids == truth
    assert len(fwd_ids & cu_ids) == 0, "the catch-up re-bundled sessions the widened tick already did"


def test_catchup_then_widened_bundles_add_no_second_bundle(box, monkeypatch):
    tmp_path, db, state = box
    _make_chat_db(db, SPARSE, bursts=2)
    cu_ids = set(_catchup_ids(tmp_path, db, monkeypatch))
    assert len(cu_ids) == 2 * N, len(cu_ids)                # catch-up reads every session
    _, fwd = _bundle_run(tmp_path, db, monkeypatch)
    fwd_ids = {m["conversation_id"] for m in fwd}
    assert fwd_ids, "the widened bundle tick dispatched nothing"
    assert fwd_ids <= cu_ids, f"{len(fwd_ids - cu_ids)} bundle id(s) differ from the catch-up's for the same session"
    assert len(fwd_ids | cu_ids) == len(cu_ids)
