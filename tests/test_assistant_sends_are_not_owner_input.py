"""The assistant's own sends never reach extraction as the owner's words.

Walk #27 (Mini16, 2026-10-14): the morning brief and the evening wrap go out by
iMessage to the owner's own number, FROM the owner's Apple ID. chat.db records
them as is_from_me=1, so the readers bundled them as the owner speaking: 141
assistant sends with is_from_me=1, 9 bundles, 7 facts extracted.

Two properties, both on synthetic fixtures (no real names, numbers or text):

  (a) 0 assistant-sent messages reach the CM048 hand-off, in either direction
      (the self-chat stores an outgoing and an inbound copy of each send);
  (b) a message the owner typed to themselves from the SAME Apple ID still
      reaches it, including one worded exactly like a brief but carrying no
      marker, and one with the robot emoji in the middle of the text.

Readers covered: imessage_source (the live bundling path, through
process_imessage), ostler_fda.imessage, whatsapp_source and email_source.
"""
from __future__ import annotations

import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from pathlib import Path

import pytest

VENDOR = Path(__file__).resolve().parents[1] / "vendor"
sys.path.insert(0, str(VENDOR))

from email_source import reader as email_reader  # noqa: E402
from imessage_source import pipeline as im_pipeline  # noqa: E402
from imessage_source import reader as im_reader  # noqa: E402
from ostler_fda import imessage as fda_imessage  # noqa: E402
from whatsapp_source import reader as wa_reader  # noqa: E402

ROBOT = "\U0001F916"
MARKER = "⁣⁤⁣"
OWNER = "+15550100001"  # the owner's own number, reserved 555-01xx range

# What the assistant sends. The first is the default identity prefix; the
# second is a customer who emptied the prefix, so only the invisible marker
# the sender appends identifies it.
BRIEF = f"{ROBOT} Good morning. Today: standup at 09:30, dentist at 15:00."
WRAP_NO_PREFIX = f"Evening wrap. Two things still open for tomorrow.{MARKER}"

# What the owner types to themselves. The first is worded like a brief on
# purpose: the negative control for (b). No marker, no prefix.
OWNER_BRIEF_LOOKALIKE = "Good morning. Today: standup at 09:30, dentist moved to Thursday."
OWNER_MID_ROBOT = f"Remind me to return the {ROBOT} kit to the library"

ASSISTANT_TEXTS = [BRIEF, WRAP_NO_PREFIX]
OWNER_TEXTS = [OWNER_BRIEF_LOOKALIKE, OWNER_MID_ROBOT]

# A CONTACT whose message happens to open with the same emoji. A person, so
# kept. Only the owner's own account carries the assistant's prefixed sends.
FRIEND = "+15550100002"
CONTACT_ROBOT = f"{ROBOT} lol that film was terrible, see you Friday"


# ---------------------------------------------------------------------------
# One predicate, four copies: hold them to one table.
# ---------------------------------------------------------------------------

CASES = [
    # text, sent from the owner's account, expected
    (BRIEF, True, True),
    ("   " + BRIEF, True, True),
    (WRAP_NO_PREFIX, True, True),
    (WRAP_NO_PREFIX, False, True),     # the marker counts in any direction
    (CONTACT_ROBOT, False, False),     # a contact's emoji-led message is kept
    (BRIEF, False, False),             # the prefix alone, inbound: kept
    (OWNER_BRIEF_LOOKALIKE, True, False),
    (OWNER_MID_ROBOT, True, False),
    ("", True, False),
    (None, True, False),
]


@pytest.mark.parametrize("module", [im_reader, fda_imessage], ids=["imessage_source", "ostler_fda"])
@pytest.mark.parametrize("text,from_owner,expected", CASES)
def test_every_copy_of_the_rule_agrees(module, text, from_owner, expected):
    assert module.is_assistant_send(text, from_owner=from_owner) is expected


def test_the_copies_share_their_constants():
    assert im_reader.ASSISTANT_SEND_PREFIX == fda_imessage.ASSISTANT_SEND_PREFIX == ROBOT
    assert im_reader.ASSISTANT_SEND_MARKER == fda_imessage.ASSISTANT_SEND_MARKER == MARKER
    # whatsapp_source and email_source import the ostler_fda definition.
    assert wa_reader.is_assistant_send is fda_imessage.is_assistant_send
    assert "from ostler_fda.imessage import is_assistant_send" in (
        VENDOR / "email_source" / "reader.py"
    ).read_text()


# ---------------------------------------------------------------------------
# iMessage: a synthetic self-chat, the shape chat.db has on the walk box.
# ---------------------------------------------------------------------------

def _mac_ns(dt: datetime) -> int:
    return int((dt.timestamp() - 978307200) * 1e9)


def _build_chat_db(path: Path) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT,
                           display_name TEXT, style INTEGER,
                           account_login TEXT, chat_identifier TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT,
                              is_from_me INTEGER, date INTEGER,
                              cache_has_attachments INTEGER, service TEXT,
                              handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        """
    )
    conn.execute("INSERT INTO handle VALUES (1, ?)", (OWNER,))
    conn.execute(
        "INSERT INTO chat VALUES (1, 'iMessage;-;self', NULL, 45, ?, ?)",
        ("P:" + OWNER, OWNER),
    )
    conn.execute("INSERT INTO chat_handle_join VALUES (1, 1)")
    # A second chat, with a contact, received on the owner's account.
    conn.execute("INSERT INTO handle VALUES (2, ?)", (FRIEND,))
    conn.execute(
        "INSERT INTO chat VALUES (2, 'iMessage;-;friend', NULL, 45, ?, ?)",
        ("P:" + OWNER, FRIEND),
    )
    conn.execute("INSERT INTO chat_handle_join VALUES (2, 2)")
    base = datetime.now(timezone.utc) - timedelta(hours=2)
    rows = [
        # The assistant's sends: the outgoing copy (is_from_me=1) and the
        # inbound copy (is_from_me=0, from the owner's own handle).
        (BRIEF, 1, None),
        (BRIEF, 0, 1),
        (WRAP_NO_PREFIX, 1, None),
        (WRAP_NO_PREFIX, 0, 1),
        # The owner's own notes to self.
        (OWNER_BRIEF_LOOKALIKE, 1, None),
        (OWNER_MID_ROBOT, 1, None),
    ]
    for i, (text, from_me, handle) in enumerate(rows, start=1):
        conn.execute(
            "INSERT INTO message VALUES (?, ?, ?, ?, 0, 'iMessage', ?)",
            (i, text, from_me, _mac_ns(base + timedelta(minutes=i)), handle),
        )
        conn.execute("INSERT INTO chat_message_join VALUES (1, ?)", (i,))
    # The contact's emoji-led message, plus a reply, in the friend chat.
    for j, (text, from_me, handle) in enumerate(
        [(CONTACT_ROBOT, 0, 2), ("Friday works", 1, None)], start=100
    ):
        conn.execute(
            "INSERT INTO message VALUES (?, ?, ?, ?, 0, 'iMessage', ?)",
            (j, text, from_me, _mac_ns(base + timedelta(minutes=j)), handle),
        )
        conn.execute("INSERT INTO chat_message_join VALUES (2, ?)", (j,))
    conn.commit()
    conn.close()


@pytest.fixture
def chat_db(tmp_path):
    p = tmp_path / "chat.db"
    _build_chat_db(p)
    return p


def test_imessage_bundle_carries_no_assistant_text_and_keeps_the_owners(
    chat_db, tmp_path, monkeypatch
):
    handed_off: list[str] = []

    def fake_dispatch(transcript, metadata, *, pwg_convo_cmd, dry_run):
        handed_off.append(transcript)
        return 0

    monkeypatch.setattr(im_pipeline, "_dispatch_to_cm048", fake_dispatch)
    summary = im_pipeline.process_imessage(
        db_path=chat_db,
        contacts_path=tmp_path / "no-contacts.yaml",
        state_path=tmp_path / "state.json",
        pwg_convo_cmd=["unused"],
    )
    assert summary["sessions_failed"] == 0
    everything = "\n".join(handed_off)
    # (a) 0 assistant sends reach extraction.
    for text in ASSISTANT_TEXTS:
        core = text.replace(ROBOT, "").replace(MARKER, "").strip()
        assert core not in everything, "an assistant send reached CM048"
    # (b) the owner's own notes still do, including the brief look-alike.
    for text in OWNER_TEXTS:
        assert text in everything, "an owner-typed note was dropped"
    # (c) a contact's message that opens with the emoji is a person's words.
    assert CONTACT_ROBOT in everything, "a contact's emoji-led message was dropped"


def test_a_chat_of_only_assistant_sends_dispatches_nothing(tmp_path, monkeypatch):
    p = tmp_path / "chat.db"
    _build_chat_db(p)
    conn = sqlite3.connect(p)
    # Leave only the assistant's sends: drop the owner's notes and the
    # contact chat.
    conn.execute("DELETE FROM message WHERE ROWID IN (5, 6, 100, 101)")
    conn.execute("DELETE FROM chat_message_join WHERE message_id IN (5, 6, 100, 101)")
    conn.commit()
    conn.close()
    calls = []
    monkeypatch.setattr(
        im_pipeline, "_dispatch_to_cm048",
        lambda *a, **k: calls.append(a) or 0,
    )
    summary = im_pipeline.process_imessage(
        db_path=p,
        contacts_path=tmp_path / "no-contacts.yaml",
        state_path=tmp_path / "state.json",
        pwg_convo_cmd=["unused"],
    )
    assert calls == [] and summary["sessions_dispatched"] == 0


def test_ostler_fda_imessage_reader_drops_the_same_rows(chat_db):
    texts = [m.text for m in fda_imessage.extract_messages("iMessage;-;self", db_path=chat_db)]
    assert texts == OWNER_TEXTS
    friend = [m.text for m in fda_imessage.extract_messages("iMessage;-;friend", db_path=chat_db)]
    assert CONTACT_ROBOT in friend, "a contact's emoji-led message was dropped"


# ---------------------------------------------------------------------------
# WhatsApp: a send through the owner's linked account is ZISFROMME=1.
# ---------------------------------------------------------------------------

def test_whatsapp_reader_drops_assistant_sends_and_keeps_the_owners():
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute(
        "CREATE TABLE ZWAMESSAGE (ZCHATSESSION INTEGER, ZMESSAGETYPE INTEGER,"
        " ZFROMJID TEXT, ZISFROMME INTEGER, ZMESSAGEDATE REAL, ZTEXT TEXT)"
    )
    for i, (text, from_me) in enumerate(
        [(BRIEF, 1), (WRAP_NO_PREFIX, 1), (OWNER_BRIEF_LOOKALIKE, 1), (OWNER_MID_ROBOT, 1),
         (CONTACT_ROBOT, 0)]
    ):
        conn.execute(
            "INSERT INTO ZWAMESSAGE VALUES (1, ?, NULL, ?, ?, ?)",
            (wa_reader.MESSAGE_TYPE_TEXT, from_me, 800000000.0 + i, text),
        )
    got = wa_reader._read_bodies_for_chat(conn, 1, cutoff_mac_ts=None, max_messages=None)
    assert [u.text for u in got] == OWNER_TEXTS + [CONTACT_ROBOT]


# ---------------------------------------------------------------------------
# Email: an assistant email lands in the owner's own mailbox.
# ---------------------------------------------------------------------------

def _emlx(mail_dir: Path, name: str, body: str, dt: datetime,
          sender: str = "owner@example.test") -> None:
    headers = [
        f"From: Sender <{sender}>",
        "To: <owner@example.test>",
        "Subject: Today",
        f"Date: {format_datetime(dt)}",
        f"Message-Id: <{name}@example.test>",
        "Content-Type: text/plain; charset=utf-8",
    ]
    rfc822 = ("\r\n".join(headers) + "\r\n\r\n" + body + "\r\n").encode("utf-8")
    nested = mail_dir / "V10" / "account.mbox" / "INBOX.mbox" / "U" / "Data" / "Messages"
    nested.mkdir(parents=True, exist_ok=True)
    (nested / f"{name}.emlx").write_bytes(
        f"{len(rfc822)}\n".encode() + rfc822 + b"<plist/>\n"
    )


def test_email_reader_drops_assistant_sends_and_keeps_the_owners(tmp_path):
    now = datetime.now(timezone.utc)
    for i, body in enumerate(ASSISTANT_TEXTS + OWNER_TEXTS):
        _emlx(tmp_path, f"m{i}", body, now - timedelta(hours=1, minutes=i))
    _emlx(tmp_path, "contact", CONTACT_ROBOT, now - timedelta(hours=2),
          sender="friend@example.test")
    got = email_reader.read_messages(mail_dir=tmp_path, since_days=0, now=now,
                                     user_address="owner@example.test")
    assert sorted(m.body for m in got) == sorted(OWNER_TEXTS + [CONTACT_ROBOT])
