"""Reply-debt snapshot: the owner's outbound mail (Sent folders) must set
owner_wrote / is_from_me even when no owner address is configured.

Root cause (Mini16, 2026-11-11): the tick runs without OSTLER_USER_EMAIL, so
owner="" and `bool(owner) and ...` was False for every row, though Sent mail
is read from disk. Synthetic fixtures only."""
from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from test_email_source import _emlx_bytes  # noqa: E402

from email_source import reader  # noqa: E402
from email_source.pipeline import build_reply_debt_snapshot  # noqa: E402

NOW = datetime.now(tz=timezone.utc)
AT = chr(64)


def _a(local, dom):
    return local + AT + dom


ME = _a("me", "owner.test")
ME2 = _a("me", "work.test")
BOB = _a("bob", "ext.test")
AMY = _a("amy", "ext.test")
CAT = _a("cat", "ext.test")
EXTRA = _a("extra", "owner.test")


def _put(root: Path, mbox_parts: list[str], name: str, **kw) -> None:
    d = root / "V10" / "acct"
    for p in mbox_parts:
        d = d / f"{p}.mbox"
    d = d / "UUID" / "Data" / "1" / "Messages"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{name}.emlx").write_bytes(_emlx_bytes(**kw))


def _tree(tmp_path: Path) -> Path:
    t0 = NOW - timedelta(days=3)
    _put(tmp_path, ["INBOX"], "1", message_id="a1@x", from_addr=BOB, from_name="Bob",
         to_addr=ME, subject="Lunch?", dt=t0, body="Lunch Friday?")
    _put(tmp_path, ["[Google Mail]", "Sent Mail"], "2", message_id="a2@x", from_addr=ME,
         from_name="Me", to_addr=BOB, subject="Re: Lunch?", dt=t0 + timedelta(hours=1),
         body="Yes", in_reply_to="a1@x", references=["a1@x"])
    _put(tmp_path, ["INBOX"], "3", message_id="b1@x", from_addr=AMY, from_name="Amy",
         to_addr=ME, subject="Contract", dt=t0, body="Please review")
    _put(tmp_path, ["Sent Messages"], "4", message_id="c1@x", from_addr=ME2, from_name="Me",
         to_addr=CAT, subject="Hello", dt=t0, body="Hi Cat")
    return tmp_path


def _rows(tmp_path, user_address):
    msgs = reader.read_messages(mail_dir=_tree(tmp_path), since_days=30, user_address=user_address)
    snap = build_reply_debt_snapshot(msgs, user_address=user_address)
    return snap, {r["subject"]: r for r in snap["threads"]}


def test_sent_mail_sets_owner_wrote_without_configured_address(tmp_path):
    snap, rows = _rows(tmp_path, "")
    assert rows["Lunch?"]["owner_wrote"] is True      # replied-to thread
    assert rows["Lunch?"]["last"]["is_from_me"] is True
    assert rows["Contract"]["owner_wrote"] is False       # genuinely unanswered
    assert rows["Hello"]["owner_wrote"] is True           # second owner address (Sent Messages)
    assert set(snap["owner_addresses"]) == {ME, ME2}


def test_configured_addresses_are_comma_separated_and_merged(tmp_path):
    snap, _ = _rows(tmp_path, EXTRA + ", " + ME.upper())
    assert set(snap["owner_addresses"]) == {EXTRA, ME, ME2}


def test_inbox_sender_is_never_inferred_as_owner(tmp_path):
    snap, _ = _rows(tmp_path, "")
    assert BOB not in snap["owner_addresses"]
    assert AMY not in snap["owner_addresses"]
