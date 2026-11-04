"""VENDOR COPY test, run against vendor/cm048_pipeline, the tree that ships.

Mirror of CM048 tests/test_scam_guard.py and tests/test_reply_debt_owed.py
(CM048 #110). The 2026-11-04 evening brief repeated a todo extracted from an
advance-fee fraud email and listed six threads as waiting on a reply when
none needed one. Synthetic fixtures only: fraud wording written for this
test, the approved synthetic cast.
"""
from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src import outstanding_todos, reminders_push, scam_guard  # noqa: E402
from src.conversation_writer import ConversationBundle, ConversationSummary, Todo  # noqa: E402
from src.reply_debt import Message, Thread, detect, owed_verdict  # noqa: E402

SCAM = "Contact the Foreign Funds Administrator immediately to arrange payment."


@pytest.fixture(autouse=True)
def _isolated(monkeypatch):
    monkeypatch.setenv("OSTLER_QDRANT_URL", "http://127.0.0.1:9")


def _enrichment(*actions):
    rows = "\n".join(f"| Operator | {a} | | high | |" for a in actions)
    return ("## Action items\n\n| Owner | Action | Deadline | Priority | Notes |\n"
            "| --- | --- | --- | --- | --- |\n" + rows + "\n\n## Next\n")


def _meta(**extra):
    m = {"conversation_id": "2030-11-04_email_synthetic", "date": "2030-11-04",
         "channel": "email", "subject": "Following up",
         "participants": [{"id": "user", "display": "Operator", "role": "user"},
                          {"id": "other:funds-office", "display": "Funds Office", "role": "other"}]}
    m.update(extra)
    return m


def _texts(meta, *actions, transcript=""):
    return [t.action_text for t in outstanding_todos.extract_outstanding_todos(
        _enrichment(*actions), meta, transcript=transcript)]


def test_the_measured_scam_todo_is_never_written():
    assert _texts(_meta(), SCAM, "Book the venue") == ["Book the venue"]


@pytest.mark.parametrize("extra", [
    {"mailbox": "Junk"}, {"labels": ["SPAM"]}, {"headers": {"X-Spam-Flag": "YES"}},
    {"is_junk": True}, {"subject": "URGENT: release of funds to the beneficiary"},
])
def test_junk_spam_or_fraud_mail_produces_no_todo(extra):
    assert _texts(_meta(**extra), "Book the venue") == []


def test_clean_mail_keeps_its_todos_control():
    assert _texts(_meta(), "Book the venue") == ["Book the venue"]


def test_payment_to_a_stranger_dropped_payment_to_a_known_person_kept():
    assert _texts(_meta(), "Pay the release charge to the account provided") == []
    assert _texts(_meta(), "Pay back the dinner money",
                  transcript="received:\nShall I?\nsent:\nYes please.\n") == ["Pay back the dinner money"]


def test_fraud_wording_dropped_even_from_a_known_contact():
    assert _texts(_meta(owner_has_written=True), "Buy three gift cards and send the codes") == []


def _bundle(text, extra=None, transcript="received:\nHello."):
    started = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return ConversationBundle(
        conversation_id="email-synthetic-1", source_kind="channel", source_subtype="email",
        source_session_id="Mail::synthetic-1", channel="email",
        participants=("user", "Sam Example"), started_at=started, ended_at="",
        summary=ConversationSummary(overall="Synthetic.", topics=()), transcript=transcript,
        todos=(Todo(id="t1", text=text, owner="user"),), privacy_level="L1",
        extra_metadata=extra or {})


def test_reminders_never_receive_a_scam():
    for text, extra in [(SCAM, None), ("Book the venue for Friday", {"mailbox": "Junk"})]:
        b = _bundle(text, extra)
        d = reminders_push.decide_push(b.todos[0], b, demo_mode=False, user_id="user",
                                       summary_path=Path("/tmp/synthetic/summary.md"))
        assert not d.eligible and d.skip_reason == reminders_push.SKIP_REASON_SCAM, text


NOW = datetime(2030, 11, 4, 20, 0, tzinfo=timezone.utc)


def _t(text, owner=False, hours=48, prior=()):
    msgs = [Message(sender="x", text=p_text, timestamp=NOW - timedelta(hours=hours + 2),
                    is_from_owner=p_owner) for p_text, p_owner in prior]
    msgs.append(Message(sender="x", text=text, timestamp=NOW - timedelta(hours=hours),
                        is_from_owner=owner))
    return Thread(thread_id="t", channel="imessage", messages=tuple(msgs),
                  counterpart_name="Alex Example")


@pytest.mark.parametrize("thread, want", [
    (_t("Thanks so much!"), ("no", "closer")),
    (_t("FYI the school closes early on Friday afternoon"), ("no", "fyi_or_automated")),
    (_t("Got home safe"), ("no", "short_statement")),
    (_t("Are you coming on Saturday?"), ("yes", "ask")),
    (_t("Great, the numbers are in the shared folder now",
        prior=[("I'll check and get back to you", True)]), ("yes", "owner_promised")),
    (_t("I finished the draft over the weekend and put it in the shared folder"),
     ("ambiguous", "statement")),
])
def test_owed_verdict_per_rule(thread, want):
    assert owed_verdict(thread) == want
    listed = detect([thread], now=NOW, min_score=0.0)
    assert bool(listed) == (want[0] != "no")
