"""A valid todo is never dropped for length (v1.0.121).

Run against vendor/cm048_pipeline, the tree that ships. Before the fix an
L0/L1 todo over 80 characters was rejected by the title gate and reported as
``no_specific_action``, so a real commitment vanished and the reason hid why.
Now the title is cut at a word boundary (ellipsis, <= 80 chars) and the FULL
text goes in the Reminders notes. Synthetic cast only.
"""
from __future__ import annotations

import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src import reminders_push
from src.conversation_writer import ConversationBundle, ConversationSummary, Todo

LONG = ("email Jane Doe about the quarterly supplier report and the "
        "revised costings by Friday afternoon")


@pytest.fixture(autouse=True)
def _isolated(monkeypatch):
    monkeypatch.setenv("OSTLER_QDRANT_URL", "http://127.0.0.1:9")
    monkeypatch.delenv("OSTLER_TODO_MAX_AGE_DAYS", raising=False)
    monkeypatch.setattr(reminders_push, "_people_store_record", lambda h: None)


def _iso(days_ago: int = 2) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _bundle(todo, *, level="L1", participants=("user", "Sam"), age=2):
    return ConversationBundle(
        conversation_id="synthetic-long-1", source_kind="channel",
        source_subtype="imessage", source_session_id="s-long-1", channel="im",
        participants=tuple(participants), started_at=_iso(age), ended_at="",
        summary=ConversationSummary(overall="Synthetic.", topics=()),
        transcript="synthetic", todos=(todo,), privacy_level=level, date="",
    )


def _todo(text, tid="t1"):
    return Todo(id=tid, text=text, owner="user", deadline=None)


def _decide(text, **kw):
    level = kw.pop("level", "L1")
    participants = kw.pop("participants", ("user", "Sam"))
    resolver = kw.pop("resolver", lambda h: h if h.isalpha() else None)
    todo = _todo(text)
    return reminders_push.decide_push(
        todo, _bundle(todo, level=level, participants=participants),
        demo_mode=False, user_id="user",
        summary_path=Path("synthetic/summary.md"),
        name_resolver=resolver, **kw,
    )


def test_the_fixture_is_over_the_limit():
    assert len(LONG) > reminders_push.MAX_TITLE_CHARS


@pytest.mark.parametrize("level", ["L0", "L1"])
def test_a_overlong_valid_todo_is_pushed_cut_at_a_word_boundary(level):
    d = _decide(LONG, level=level)
    assert d.eligible, d.skip_reason
    assert len(d.push_title) <= reminders_push.MAX_TITLE_CHARS
    assert d.push_title.endswith("…")
    stem = d.push_title[:-1]
    assert LONG.startswith(stem)
    assert LONG[len(stem)] == " ", "cut must land on a word boundary"
    assert d.push_notes.startswith(LONG), d.push_notes
    assert "From your conversation with Sam" in d.push_notes


@pytest.mark.parametrize("n", range(75, 130, 3))
def test_every_overlong_length_cuts_on_a_boundary_within_80(n):
    text = ("send Sam the " + "venue " * 30)[:n].rstrip() + " now"
    d = _decide(text)
    if len(text) <= 80:
        assert d.eligible and d.push_title == text and d.push_notes.startswith("From")
        return
    assert d.eligible, d.skip_reason
    assert len(d.push_title) <= 80 and d.push_title.endswith("…")
    assert text.startswith(d.push_title[:-1])
    assert d.push_notes.startswith(text)


def test_a_title_that_fits_is_untouched_and_notes_unchanged():
    d = _decide("Give Sam the venue quote")
    assert d.eligible and d.push_title == "Give Sam the venue quote"
    assert d.push_notes.startswith("From your conversation with Sam")
    assert "Give Sam" not in d.push_notes


def test_one_unbroken_run_is_refused_with_its_own_reason():
    d = _decide("x" * 120)
    assert not d.eligible
    assert d.skip_reason == "title_too_long" == reminders_push.SKIP_REASON_TITLE_TOO_LONG
    assert d.push_title == "" and d.push_notes == ""


def test_negative_a_vague_short_todo_is_still_no_specific_action():
    for text in ("Follow up with Sam", "Follow up on a conversation"):
        d = _decide(text)
        assert not d.eligible and d.skip_reason == "no_specific_action", text


def test_a_long_todo_hiding_an_email_past_char_80_is_still_refused():
    text = LONG + " and copy sam@example.com"
    assert text.index("sam@") > 80
    d = _decide(text)
    assert not d.eligible and d.skip_reason == "no_specific_action"
    assert d.push_notes == ""


def test_l2_never_puts_todo_text_in_the_notes():
    d = _decide(LONG, level="L2")
    assert d.eligible
    assert len(d.push_title) <= 80
    assert "supplier" not in d.push_notes and "costings" not in d.push_notes


def test_every_skip_reason_decide_push_emits_is_distinct_and_named():
    seen = {}

    def note(label, d):
        assert not d.eligible, label
        seen[label] = d.skip_reason

    note("empty", _decide("   "))
    todo = _todo("Give Sam the venue quote")
    note("unknown_level", reminders_push.decide_push(
        todo, _bundle(todo, level="L9"), demo_mode=False, user_id="user",
        summary_path=Path("s.md")))
    note("l3", _decide("Give Sam the venue quote", level="L3"))
    other = Todo(id="t2", text="Give Sam the venue quote", owner="Sam", deadline=None)
    note("owner_other", reminders_push.decide_push(
        other, _bundle(other), demo_mode=False, user_id="user",
        summary_path=Path("s.md")))
    old = reminders_push.decide_push(
        todo, _bundle(todo, age=400), demo_mode=False, user_id="user",
        summary_path=Path("s.md"), name_resolver=lambda h: h)
    note("stale", old)
    note("non_human", _decide("Give Sam the venue quote",
                              participants=("user", "example holdings ltd"),
                              resolver=None))
    note("vague", _decide("Follow up with Sam"))
    note("too_long", _decide("x" * 120))
    assert len(seen) == 8
    assert len(set(seen.values())) == 8, seen
    assert set(seen.values()) == {
        "empty_text", "unknown_privacy_level", "l3", "owed_by_other",
        "stale_source", "non_human_sender", "no_specific_action", "title_too_long",
    }
    consts = {k: v for k, v in vars(reminders_push).items() if k.startswith("SKIP_REASON_")}
    assert len(set(consts.values())) == len(consts), "two constants share a value"
    assert set(seen.values()) <= set(consts.values())


def test_end_to_end_through_the_push_pipeline_and_mapping_db(tmp_path):
    db = tmp_path / "m.db"
    long_todo, vague, blob = _todo(LONG, "a"), _todo("Follow up with Sam", "b"), _todo("y" * 130, "c")
    bundle = _bundle(long_todo)
    reminders_push.apply_push_status_to_todos(
        (long_todo, vague, blob), bundle, summary_path=tmp_path / "summary.md",
        user_id="user", db_path=db,
        )
    conn = sqlite3.connect(db)
    try:
        rows = {r[0]: r[1:] for r in conn.execute(
            "SELECT todo_id, status, skip_reason, push_title, push_notes FROM reminders_map")}
    except sqlite3.OperationalError:
        tables = [r[0] for r in conn.execute("select name from sqlite_master")]
        raise AssertionError(f"mapping table not found in {tables}")
    finally:
        conn.close()
    status, reason, title, notes = rows["a"]
    assert status == "pending" and reason is None
    assert len(title) <= 80 and title.endswith("…") and notes.startswith(LONG)
    assert rows["b"][0] == "skipped" and rows["b"][1] == "no_specific_action"
    assert rows["c"][0] == "skipped" and rows["c"][1] == "title_too_long"
