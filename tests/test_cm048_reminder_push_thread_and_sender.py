"""One open reminder per person/thread, none for organisations or automated
senders, and "<Name>: <short text>" for a private 1:1 (Andy's decision:
1:1 L2 commitment text now syncs to iCloud). Synthetic data only.
"""
from __future__ import annotations

import os
import re
import sqlite3
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))
os.environ.setdefault("OSTLER_SERVICE_TOKEN", "test-only-thread-token")

from src import reminders_push
from src.conversation_writer import ConversationBundle, ConversationSummary, Todo
from src.reminders_push import apply_push_status_to_todos, decide_push, thread_key_for

PHONE = "+15550100"
STORE = {
    PHONE: {"display_name": PHONE, "given_name": "Jane", "family_name": "Doe",
            "phones": [PHONE]},
    "+15550111": {"display_name": "example bank support team",
                  "emails": ["noreply@bank.invalid"], "phones": ["+15550111"]},
}


@pytest.fixture(autouse=True)
def _store(monkeypatch, tmp_path):
    # the fail-open path writes <ostler>/logs/cm048-reminders.err: keep it
    # out of the developer's (or CI runner's) real ~/.ostler
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "ostler"))
    monkeypatch.setattr(reminders_push, "_people_store_record", lambda h: STORE.get(h))


def _bundle(participants, sid="s-1", level="L2"):
    return ConversationBundle(
        conversation_id=f"c-{sid}", source_kind="channel", source_subtype="imessage",
        source_session_id=sid, channel="im", participants=tuple(participants),
        started_at="2026-10-01T09:00:00Z", ended_at="2026-10-01T09:30:00Z",
        summary=ConversationSummary(overall="Synthetic.", topics=()),
        transcript="synthetic", privacy_level=level,
    )


def _todo(i="t1", text="send the synthetic draft"):
    return Todo(id=i, text=text, owner="user", deadline=None)


def _decide(participants, text="send the synthetic draft", level="L2"):
    return decide_push(_todo(text=text), _bundle(participants, level=level),
                       demo_mode=False, user_id="user", summary_path=Path("/tmp/s.md"))


def _apply(db, participants, sid, todos):
    return apply_push_status_to_todos(
        tuple(todos), _bundle(participants, sid=sid), summary_path=Path("/tmp/s.md"),
        user_id="user", db_path=db)


def _rows(db, where="1=1"):
    c = sqlite3.connect(db)
    try:
        return c.execute(
            f"SELECT source_session_id, todo_id, status, skip_reason, push_title, thread_key "
            f"FROM reminders_map WHERE {where}").fetchall()
    finally:
        c.close()


# ---- (b) titles ---------------------------------------------------------

def test_1to1_resolved_gives_name_colon_short_text():
    assert _decide(("user", PHONE)).push_title == "Jane Doe: send the synthetic draft"


def test_text_is_truncated_and_stripped_of_handles():
    long = ("send the numbers to bob@example.invalid or call +1 555 0100 about "
            "2026-10-14 and follow @handle_x with a long tail of words after")
    t = _decide(("user", PHONE), text=long).push_title
    assert t.startswith("Jane Doe: ")
    body = t[len("Jane Doe: "):]
    assert len(body) <= 63
    for bad in ("@", "5550100", "555 0100", "2026-10-14", "handle_x"):
        assert bad not in t, (bad, t)


def test_unresolved_1to1_is_generic_and_multiparty_is_generic():
    assert _decide(("user", "+15550999")).skip_reason == "no_specific_action"
    assert _decide(("user", PHONE, "+15550998")).skip_reason == "no_specific_action"


# ---- (c) organisations / automated senders ------------------------------

def test_a_bank_sender_pushes_nothing(tmp_path):
    d = _decide(("user", "+15550111"))
    assert not d.eligible and d.skip_reason == "non_human_sender"
    db = tmp_path / "m.db"
    _apply(db, ("user", "+15550111"), "s-1", [_todo()])
    assert [r for r in _rows(db) if r[2] == "pending"] == []


def test_an_unstored_org_shaped_label_pushes_nothing():
    d = _decide(("user", "example holdings ltd"))
    assert not d.eligible and d.skip_reason == "non_human_sender"


def _rules_unloadable(monkeypatch):
    monkeypatch.setattr(reminders_push, "_PEOPLE_RULES", None)
    monkeypatch.setattr(reminders_push, "_PEOPLE_TRIED", False)
    monkeypatch.setattr(reminders_push, "_people_rules_candidates", lambda: [])


def test_unloadable_people_rules_fail_open_and_flag_the_row(monkeypatch):
    """The org filter is a QUALITY filter: if its rules cannot load, push
    anyway (a customer never loses all reminders) and flag the decision."""
    _rules_unloadable(monkeypatch)
    d = _decide(("user", PHONE))
    assert d.eligible, d
    assert d.flag == "org_filter_unavailable"
    assert d.push_title == "Jane Doe: send the synthetic draft"


def test_import_failure_pushes_every_row_flagged_and_logs_once_per_run(tmp_path, monkeypatch, caplog):
    """The rules cannot load: EVERY row is pushed (pending) and flagged with
    the distinct reason, and the run logs ONE error line, not one per row."""
    import logging

    _rules_unloadable(monkeypatch)
    db = tmp_path / "m.db"
    with caplog.at_level(logging.ERROR, logger="src.reminders_push"):
        _apply(db, ("user", PHONE), "s-1", [_todo("t1"), _todo("t2", "b"), _todo("t3", "c")])
    rows = _rows(db)
    # the thread already holds one open reminder, so 1 pending + 2 duplicates
    pending = [r for r in rows if r[2] == "pending"]
    assert len(pending) == 1 and pending[0][3] == "org_filter_unavailable", rows
    errs = [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert len(errs) == 1, [r.getMessage() for r in errs]
    assert "WITHOUT the organisation filter" in errs[0].getMessage()


def test_import_failure_does_not_block_distinct_people(tmp_path, monkeypatch):
    _rules_unloadable(monkeypatch)
    db = tmp_path / "m.db"
    for n, who in enumerate((PHONE, "+15550999", "Jane Doe", "John Doe")):
        _apply(db, ("user", who), f"s-{n}", [_todo()])
    pend = [r for r in _rows(db) if r[2] == "pending"]
    # the bare unresolved handle has no displayable name, so the title gate
    # skips it (no_specific_action); every named person is still pushed and
    # flagged
    assert len(pend) == 3, "no named person is dropped when the filter is unavailable"
    assert sorted(str(r[3]) for r in pend) == ["org_filter_unavailable"] * 3
    assert len(_rows(db, "skip_reason='no_specific_action'")) == 1


# ---- (a) one open reminder per person / thread --------------------------

def test_duplicates_for_one_person_collapse_to_one(tmp_path):
    db = tmp_path / "m.db"
    for n in range(6):
        _apply(db, ("user", PHONE), f"s-{n}", [_todo("t1"), _todo("t2", "other thing")])
    live = _rows(db, "status='pending'")
    assert len(live) == 1, live
    assert len(_rows(db, "skip_reason='duplicate_thread'")) == 11


def test_different_people_each_get_one(tmp_path):
    db = tmp_path / "m.db"
    _apply(db, ("user", "Jane Doe"), "s-1", [_todo()])
    _apply(db, ("user", "John Doe"), "s-2", [_todo()])
    assert len(_rows(db, "status='pending'")) == 2


def test_thread_key_survives_a_wiped_map(tmp_path):
    db = tmp_path / "m.db"
    _apply(db, ("user", PHONE), "s-1", [_todo()])
    key1 = _rows(db, "status='pending'")[0][5]
    db.unlink()
    _apply(db, ("user", PHONE), "s-9", [_todo()])
    key2 = _rows(db, "status='pending'")[0][5]
    assert key1 and key1 == key2
    # same person through another spelling of the handle
    b = lambda p: _bundle(("user", p))
    assert thread_key_for(b("+1 (555) 0100"), "user") == thread_key_for(b(PHONE), "user")
    assert thread_key_for(b("15550100@s.whatsapp.net"), "user") == thread_key_for(b(PHONE), "user")
    assert thread_key_for(b("+15550999"), "user") != key1


def test_a_completed_reminder_frees_the_thread(tmp_path):
    db = tmp_path / "m.db"
    _apply(db, ("user", PHONE), "s-1", [_todo()])
    c = sqlite3.connect(db)
    c.execute("ALTER TABLE reminders_map ADD COLUMN completed_at TEXT")
    c.execute("UPDATE reminders_map SET status='pushed', completed_at='2026-10-02'")
    c.commit(); c.close()
    _apply(db, ("user", PHONE), "s-2", [_todo()])
    assert len(_rows(db, "status='pending'")) == 1


def test_no_title_ever_carries_a_handle_phone_email_or_iso_date(tmp_path):
    db = tmp_path / "m.db"
    for n, who in enumerate((PHONE, "+15550999", "a@example.invalid", "15550123@s.whatsapp.net")):
        _apply(db, ("user", who), f"s-{n}", [_todo(text="call +15550100 on 2026-10-14")])
    for r in _rows(db, "push_title IS NOT NULL"):
        assert not re.search(r"\+?\d{6,}|@|20\d\d-\d\d-\d\d", r[4]), r
