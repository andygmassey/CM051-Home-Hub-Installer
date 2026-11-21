"""Email per-person windowed aggregates (vendor/email_source/person_windows.py).

Synthetic EmailMessage rows only. Addresses are reserved example.com values.

Coverage:
  - inbound from a counterparty counts received; owner reply counts sent
  - the contract fixture (same file as CM048 #127 and CM040 #15) is pinned
  - robot or list mail contributes nothing
  - Junk and Trash mail contribute nothing
  - group mail (more than one counterparty) contributes nothing
  - owner-to-self contributes nothing
  - an L3 counterparty contributes nothing, not even a count
  - owner address matching is case-insensitive
  - reply latency is from the first unanswered inbound to the owner reply
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(_REPO_ROOT))

from vendor.email_source import person_windows as pw  # noqa: E402
from vendor.email_source.reader import EmailMessage  # noqa: E402

OWNER = "owner-synthetic@example.com"
ALICE = "alice-synthetic@example.com"
BOB = "bob-synthetic@example.com"
NOW = datetime.now(timezone.utc).replace(microsecond=0)
FIXTURE = Path(__file__).parent / "fixtures" / "person_windows_contract.json"


def mail(*, frm, to, days_ago, hours=0.0, mailbox="INBOX", headers=None, cc=()):
    return EmailMessage(
        message_id=f"m-{frm}-{days_ago}-{hours}-{mailbox}",
        in_reply_to=None,
        from_address=frm,
        to_addresses=[("", a) for a in to],
        cc_addresses=[("", a) for a in cc],
        timestamp=NOW - timedelta(days=days_ago) + timedelta(hours=hours),
        headers=headers or {},
        mailbox=mailbox,
    )


def by(rows):
    return {r["person_id"]: r for r in rows}


def test_contract_fixture_is_the_pinned_fixture():
    assert json.loads(FIXTURE.read_text()) == pw.contract_snapshot()


def test_inbound_counts_received_and_owner_reply_counts_sent():
    msgs = [mail(frm=ALICE, to=[OWNER], days_ago=3),
            mail(frm=OWNER, to=[ALICE], days_ago=3, hours=2.0)]
    r = by(pw.windows_from_emails(msgs, owner_addresses=[OWNER], now=NOW))[ALICE]
    assert (r["sent_30"], r["recv_30"]) == (1, 1)
    assert r["median_reply_min_365"] == pytest.approx(120.0)


def test_robot_mail_contributes_nothing():
    msgs = [mail(frm=ALICE, to=[OWNER], days_ago=2, headers={"list-id": "<x>"})]
    assert pw.windows_from_emails(msgs, owner_addresses=[OWNER], now=NOW) == []


def test_junk_and_trash_contribute_nothing():
    msgs = [mail(frm=ALICE, to=[OWNER], days_ago=2, mailbox="Junk"),
            mail(frm=ALICE, to=[OWNER], days_ago=2, mailbox="Trash")]
    assert pw.windows_from_emails(msgs, owner_addresses=[OWNER], now=NOW) == []


def test_group_mail_contributes_nothing():
    msgs = [mail(frm=ALICE, to=[OWNER, BOB], days_ago=2),
            mail(frm=OWNER, to=[ALICE, BOB], days_ago=2, hours=1.0)]
    assert pw.windows_from_emails(msgs, owner_addresses=[OWNER], now=NOW) == []


def test_owner_to_self_contributes_nothing():
    msgs = [mail(frm=OWNER, to=[OWNER], days_ago=2)]
    assert pw.windows_from_emails(msgs, owner_addresses=[OWNER], now=NOW) == []


def test_l3_counterparty_contributes_nothing_and_is_absent():
    msgs = [mail(frm=ALICE, to=[OWNER], days_ago=2),
            mail(frm=BOB, to=[OWNER], days_ago=2)]
    rows = pw.windows_from_emails(msgs, owner_addresses=[OWNER], now=NOW,
                                  l3_addresses=frozenset({ALICE}))
    assert [r["person_id"] for r in rows] == [BOB]
    assert "alice-synthetic" not in json.dumps(rows)


def test_owner_address_matches_case_insensitively():
    msgs = [mail(frm=ALICE, to=["OWNER-Synthetic@Example.COM"], days_ago=2)]
    rows = pw.windows_from_emails(msgs, owner_addresses=[OWNER], now=NOW)
    assert [r["person_id"] for r in rows] == [ALICE]


def test_reply_latency_runs_from_first_unanswered_inbound():
    msgs = [mail(frm=ALICE, to=[OWNER], days_ago=2, hours=0.0),
            mail(frm=ALICE, to=[OWNER], days_ago=2, hours=3.0),
            mail(frm=OWNER, to=[ALICE], days_ago=1, hours=0.0)]
    r = by(pw.windows_from_emails(msgs, owner_addresses=[OWNER], now=NOW))[ALICE]
    assert r["median_reply_min_365"] == pytest.approx(24 * 60.0, abs=1.0)
