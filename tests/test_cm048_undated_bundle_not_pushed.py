"""An undated conversation bundle is NOT pushed to Apple Reminders, unless its
todo still has a deadline today or later (CM048 #120, _in_push_window fails
closed). The vendored writer gate used to return "not stale" for a bundle with
no started_at and no date, so catch-up pushed years-old todos. Synthetic only.
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))
os.environ.setdefault("OSTLER_SERVICE_TOKEN", "test-only-thread-token")

from src import reminders_push
from src.conversation_writer import ConversationBundle, ConversationSummary, Todo
from src.reminders_push import decide_push

PHONE = "+15550100"
STORE = {PHONE: {"display_name": PHONE, "given_name": "Jane", "family_name": "Doe",
                 "phones": [PHONE]}}


@pytest.fixture(autouse=True)
def _store(monkeypatch, tmp_path):
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "ostler"))
    monkeypatch.setattr(reminders_push, "_people_store_record", lambda h: STORE.get(h))


def _bundle(started="", date_="", sid="s-1"):
    return ConversationBundle(
        conversation_id=f"c-{sid}", source_kind="channel", source_subtype="imessage",
        source_session_id=sid, channel="im", participants=(PHONE,),
        started_at=started, ended_at="",
        summary=ConversationSummary(overall="Synthetic.", topics=()),
        transcript="synthetic", privacy_level="L2",
    )


def _decide(bundle, deadline=None):
    todo = Todo(id="t1", text="send the synthetic draft", owner="user", deadline=deadline)
    return decide_push(todo, bundle, demo_mode=False, user_id="user",
                       summary_path=Path("/tmp/synthetic-summary.md"))


def _recent():
    return (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _old():
    return (datetime.now(timezone.utc) - timedelta(days=400)).strftime("%Y-%m-%dT%H:%M:%SZ")


def test_undated_bundle_is_not_pushed():
    # RED on the pre-change gate: an undated bundle came back eligible.
    d = _decide(_bundle(started="", date_=""))
    assert d.eligible is False


def test_undated_bundle_with_future_deadline_is_pushed():
    future = (datetime.now(timezone.utc) + timedelta(days=5)).date().isoformat()
    assert _decide(_bundle(started=""), deadline=future).eligible is True


def test_undated_bundle_with_past_deadline_is_not_pushed():
    past = (datetime.now(timezone.utc) - timedelta(days=5)).date().isoformat()
    assert _decide(_bundle(started=""), deadline=past).eligible is False


def test_recent_dated_bundle_is_still_pushed():
    assert _decide(_bundle(started=_recent())).eligible is True


def test_old_dated_bundle_is_still_not_pushed():
    assert _decide(_bundle(started=_old())).eligible is False


def test_disabling_the_age_cutoff_does_not_push_undated_bundles(monkeypatch):
    # OSTLER_TODO_MAX_AGE_DAYS=0 switches off the AGE cutoff only.
    monkeypatch.setenv("OSTLER_TODO_MAX_AGE_DAYS", "0")
    assert _decide(_bundle(started="")).eligible is False
