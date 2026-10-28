"""VENDOR COPY test, run against vendor/cm048_pipeline, the tree that ships.

Mirror of CM048 tests/test_reminders_push.py (title quality gate, notes,
staleness). A reminder is pushed only with a specific title, a human notes
line, and a source newer than the cutoff. Synthetic cast names only.
"""
from __future__ import annotations

import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src import reminders_push
from src.conversation_writer import ConversationBundle, ConversationSummary, Todo


@pytest.fixture(autouse=True)
def _isolated(monkeypatch):
    monkeypatch.setenv("OSTLER_QDRANT_URL", "http://127.0.0.1:9")
    monkeypatch.delenv("OSTLER_TODO_MAX_AGE_DAYS", raising=False)


def _iso(days_ago: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _decide(text, *, level="L1", participants=("user", "Sam"), age=2,
            started_at=None, date="", resolver=None, **kw):
    todo = Todo(id="t1", text=text, owner="user", deadline=None)
    bundle = ConversationBundle(
        conversation_id="synthetic-1", source_kind="channel",
        source_subtype="imessage", source_session_id="s-1", channel="im",
        participants=tuple(participants),
        started_at=_iso(age) if started_at is None else started_at,
        ended_at="", summary=ConversationSummary(overall="Synthetic.", topics=()),
        transcript="synthetic", todos=(todo,), privacy_level=level, date=date,
    )
    return reminders_push.decide_push(
        todo, bundle, demo_mode=False, user_id="user",
        summary_path=Path("/tmp/synthetic/summary.md"),
        name_resolver=resolver or (lambda h: h if h.isalpha() else None), **kw,
    )


GOOD = ["Give Sam the venue quote", "Get Alex a dentist appointment",
        "Follow up with Sam about the venue quote", "Pay the plumber the deposit"]

BAD = [
    ("Follow up on commitment", "generic_follow_up"),
    ("Follow up on a conversation", "generic_follow_up"),
    ("Follow up with @sam", "handle"),
    ("Follow up with @sam-example-com", "handle"),
    ("Give Sam the file at " + "/" + "Users" + "/x/Conversations/summary.md", "path"),
    ("Open file:///tmp/a/summary.md", "path"),
    ("Email sam@example.com the quote", "email"),
    ("Follow up on the investigation to determine what is needed", "vague_follow_up"),
    ("Follow up with Sam", "generic_follow_up"),
    ("Send the quote -- 2026-05-12", "iso_date"),
    ("(empty commitment)", "empty"),
    ("Send " + "very long " * 12 + "note", "too_long"),
]


@pytest.mark.parametrize("title", GOOD)
def test_good_titles_pass(title):
    assert reminders_push.title_quality_reason(title) is None
    d = _decide(title)
    assert d.eligible and d.push_title == title


@pytest.mark.parametrize("title,reason", BAD)
def test_each_generic_pattern_is_rejected(title, reason):
    assert reminders_push.title_quality_reason(title) == reason
    for level in ("L0", "L1"):
        d = _decide(title, level=level)
        assert not d.eligible and d.skip_reason == "no_specific_action"
        assert d.push_title == "" and d.push_notes == ""


@pytest.mark.parametrize("participants", [("user", "Sam"), ("user", "Sam", "Alex"), ("user",)])
def test_l2_group_solo_and_unresolved_are_never_generic_pushed(participants):
    d = _decide("Give Sam the venue quote", level="L2", participants=participants,
                resolver=lambda h: None)
    assert not d.eligible and d.skip_reason == "no_specific_action"


def test_l2_resolved_one_to_one_keeps_name_and_text():
    d = _decide("Send the venue quote", level="L2")
    assert d.eligible and d.push_title == "Sam: Send the venue quote"


def test_notes_are_human_readable():
    d = _decide("Give Sam the venue quote", started_at="2026-10-12T10:00:00Z",
                max_age_days_override=10000)
    assert d.push_notes == "From your conversation with Sam, 12 Oct 2026"
    assert "file://" not in d.push_notes and "/" not in d.push_notes
    assert not re.search(r"\d{4}-\d{2}-\d{2}", d.push_notes)


@pytest.mark.parametrize("participants,expected", [
    (("user", "+447700900001"), "From your conversation, 12 Oct 2026"),
    (("user", "Sam", "Alex"), "From your group conversation, 12 Oct 2026"),
])
def test_notes_never_print_handles_or_numbers(participants, expected):
    d = _decide("Give Sam the venue quote", participants=participants,
                started_at="2026-10-12T10:00:00Z", max_age_days_override=10000,
                resolver=lambda h: h if h.isalpha() else None)
    assert d.eligible and d.push_notes == expected


def test_400_day_old_todo_is_not_pushed():
    d = _decide("Give Sam the venue quote", age=400)
    assert not d.eligible and d.skip_reason == "stale_source"


def test_cutoff_boundary_and_config(monkeypatch):
    assert _decide("Give Sam the venue quote", age=29).eligible
    assert not _decide("Give Sam the venue quote", age=31).eligible
    monkeypatch.setenv("OSTLER_TODO_MAX_AGE_DAYS", "60")
    assert _decide("Give Sam the venue quote", age=45).eligible
    monkeypatch.setenv("OSTLER_TODO_MAX_AGE_DAYS", "0")
    assert _decide("Give Sam the venue quote", age=400).eligible


def test_date_only_source_uses_bundle_date():
    assert not _decide("Give Sam the venue quote", started_at="", date="2021-08-12").eligible
