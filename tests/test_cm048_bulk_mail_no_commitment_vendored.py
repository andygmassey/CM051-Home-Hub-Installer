"""VENDOR COPY test, run against vendor/cm048_pipeline, the tree that ships.

Mirror of the CM048 #115 cases in tests/test_outstanding_todos.py (brief
readability). The brief carried a todo owned by the owner that was a sales
call to action lifted from a waitlist mailing ("click to confirm your place
on the waitlist"). Inbound bulk, marketing, newsletter and automated mail is
never the owner's commitment, whether or not the processor stamped
``non_relational`` first. Synthetic fixtures only (example.com, the
approved synthetic cast).
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src import outstanding_todos  # noqa: E402

_CTA_TABLE = (
    "## Action items\n\n"
    "| Owner | Action | Deadline | Priority |\n"
    "| --- | --- | --- | --- |\n"
    "| Operator | Click to confirm your place on the waitlist | — | high |\n"
)


@pytest.fixture(autouse=True)
def _isolated(monkeypatch):
    monkeypatch.setenv("OSTLER_QDRANT_URL", "http://127.0.0.1:9")


def _email(**overrides) -> dict:
    base = {
        "conversation_id": "2030-11-04_waitlist_1",
        "date": "2030-11-04",
        "channel": "email",
        "participants": [
            {"id": "user", "display": "Operator", "role": "user",
             "email": "operator@example.com"},
            {"id": "other:launch-team", "display": "launch team", "role": "other",
             "email": "launch.team@example.com"},
        ],
    }
    base.update(overrides)
    return base


def test_control_a_human_email_still_yields_its_commitment() -> None:
    todos = outstanding_todos.extract_outstanding_todos(_CTA_TABLE, _email())
    assert [t.owner for t in todos] == ["user"]


@pytest.mark.parametrize(
    "overrides",
    [
        {"headers": {"List-Unsubscribe": "<mailto:u@example.com>"}},
        {"headers": {"Precedence": "bulk"}},
        {"from": "noreply@example.com"},
        {"non_relational": True},
    ],
)
def test_bulk_mail_yields_no_commitment(overrides: dict) -> None:
    meta = _email(**overrides)
    if "from" in overrides:
        meta["participants"][1]["email"] = overrides["from"]
    assert outstanding_todos.extract_outstanding_todos(_CTA_TABLE, meta) == []
