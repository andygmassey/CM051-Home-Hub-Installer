"""VENDOR COPY test, run against vendor/cm048_pipeline, the tree that ships.

A redacted (L2) reminder title must not carry the raw ISO deadline.

Defect: "Follow up on conversation -- 2026-10-14" reached the customer's
timeline and wiki digest, because reminders_push appended todo.deadline to
the title. The deadline already travels in its own field
(PushDecision.push_deadline, the reminder's due date), so the title never
needed it. Synthetic data only.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src.conversation_writer import ConversationBundle, ConversationSummary, Todo
from src.reminders_push import decide_push

ISO_DATE = re.compile(r"20\d\d-\d\d-\d\d")
DEADLINE = "2026-10-14"


def _bundle(participants, level="L2"):
    return ConversationBundle(
        conversation_id="synthetic-1",
        source_kind="channel",
        source_subtype="imessage",
        source_session_id="s-1",
        channel="im",
        participants=tuple(participants),
        started_at="2026-10-01T09:00:00Z",
        ended_at="2026-10-01T09:30:00Z",
        summary=ConversationSummary(overall="Synthetic.", topics=()),
        transcript="synthetic transcript",
        privacy_level=level,
    )


def _decide(participants, deadline=DEADLINE):
    todo = Todo(id="t1", text="send the synthetic draft", owner="user", deadline=deadline)
    return decide_push(
        todo, _bundle(participants), demo_mode=False, user_id="user",
        summary_path=Path("/tmp/synthetic/summary.md"),
    )


@pytest.mark.parametrize("participants", [
    ("user", "partner_a"),                  # one other party
    ("user", "partner_a", "partner_b"),  # multi-party
    ("user",),                                # solo
])
def test_l2_title_has_no_iso_date_and_due_date_carries_deadline(participants):
    d = _decide(participants)
    assert d.eligible
    assert d.push_title.startswith("Follow up")
    assert not ISO_DATE.search(d.push_title), d.push_title
    assert d.push_deadline == DEADLINE


def test_no_deadline_gives_no_due_date_and_same_title():
    with_deadline = _decide(("user", "partner_a"))
    without = _decide(("user", "partner_a"), deadline=None)
    assert without.push_deadline is None
    assert without.push_title == with_deadline.push_title
