"""WhatsApp per-person windowed aggregates (vendor/whatsapp_source/person_windows.py).

Synthetic chats and utterances only. JIDs are reserved synthetic values.

Coverage:
  - a one-to-one chat aggregates by its contact JID, both directions
  - the contract fixture (same file as CM048 #127, CM040 #15, CM051 email) is pinned
  - group chats contribute nothing
  - a tier-2 chat with no contact JID contributes nothing
  - an L3 contact contributes nothing and is absent from the output
  - utterances with no timestamp are skipped
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(_REPO_ROOT))

sys.path.insert(0, str(_REPO_ROOT / "vendor"))  # ostler_fda imports are top-level
from ostler_fda.whatsapp_history import WhatsAppChat  # noqa: E402
from vendor.whatsapp_source import person_windows as pw  # noqa: E402
from vendor.whatsapp_source.reader import WhatsAppConversation, WhatsAppUtterance  # noqa: E402

ALICE = "15550000001@s.whatsapp.net"
BOB = "15550000002@s.whatsapp.net"
NOW = datetime.now(timezone.utc).replace(microsecond=0)
FIXTURE = Path(__file__).parent / "fixtures" / "person_windows_contract.json"


def conv(*, chat_id, jid, is_group=False, msgs=()):
    chat = WhatsAppChat(chat_id=chat_id, tier="T1" if not is_group else "T2",
                        is_group=is_group, contact_jid=jid)
    return WhatsAppConversation(chat=chat, utterances=list(msgs))


def utt(*, from_me, days_ago, hours=0.0):
    return WhatsAppUtterance(author_jid=None if from_me else ALICE, is_from_me=from_me,
                             timestamp=NOW - timedelta(days=days_ago) + timedelta(hours=hours),
                             text="x")


def by(rows):
    return {r["person_id"]: r for r in rows}


def test_contract_fixture_is_the_pinned_fixture():
    assert json.loads(FIXTURE.read_text()) == pw.contract_snapshot()


def test_one_to_one_chat_counts_both_directions_by_contact_jid():
    c = conv(chat_id="1", jid=ALICE, msgs=[utt(from_me=False, days_ago=3),
                                           utt(from_me=True, days_ago=3, hours=1.0)])
    r = by(pw.windows_from_whatsapp([c], now=NOW))[ALICE]
    assert (r["sent_30"], r["recv_30"]) == (1, 1)
    assert r["median_reply_min_365"] == pytest.approx(60.0)


def test_group_chat_contributes_nothing():
    c = conv(chat_id="2", jid=BOB, is_group=True, msgs=[utt(from_me=False, days_ago=2)])
    assert pw.windows_from_whatsapp([c], now=NOW) == []


def test_chat_without_contact_jid_contributes_nothing():
    c = conv(chat_id="3", jid=None, msgs=[utt(from_me=False, days_ago=2)])
    assert pw.windows_from_whatsapp([c], now=NOW) == []


def test_l3_contact_contributes_nothing_and_is_absent():
    a = conv(chat_id="4", jid=ALICE, msgs=[utt(from_me=False, days_ago=2)])
    b = conv(chat_id="5", jid=BOB, msgs=[utt(from_me=False, days_ago=2)])
    rows = pw.windows_from_whatsapp([a, b], now=NOW, l3_jids=frozenset({ALICE}))
    assert [r["person_id"] for r in rows] == [BOB]
    assert "15550000001" not in json.dumps(rows)


def test_untimestamped_utterance_is_skipped():
    bad = WhatsAppUtterance(author_jid=ALICE, is_from_me=False, timestamp=None, text="x")
    c = conv(chat_id="6", jid=ALICE, msgs=[bad, utt(from_me=False, days_ago=2)])
    r = by(pw.windows_from_whatsapp([c], now=NOW))[ALICE]
    assert r["recv_365"] == 1
