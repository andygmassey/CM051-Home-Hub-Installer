#!/usr/bin/env python3
"""DMG #27: machine senders do not become People; a human who replied does.

Calendar notification / system senders, no-reply senders and mailing lists
appeared on the walk's People list as "Unknown contact". This executes the
shipped code on synthetic input:

  1. noreply_reason / header_reason: the address patterns and all four headers
     (List-Id, List-Unsubscribe, Auto-Submitted, Precedence), with
     "Auto-Submitted: no" and a plain person as negative controls.
  2. A synthetic Mail Envelope Index: list-only, no-reply and notification
     senders are machine; a real person on an "info@" style address who
     replied in a thread the owner wrote in is a CORRESPONDENT and is kept.
  3. ingest_calendar / ingest_mail_contacts with the SPARQL transport stubbed:
     machine senders create no Person, people do, and the "info@" human who
     replied DOES (the role-address rule used to drop them).

Cast names only; every address is composed at runtime.
"""
from __future__ import annotations

import json
import re
import sqlite3
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "vendor"))

from ostler_fda import machine_senders as ms  # noqa: E402
from ostler_fda import pwg_ingest as m  # noqa: E402

FAILURES: list = []


def check(cond, msg):
    print(("ok: " if cond else "FAIL: ") + msg)
    if not cond:
        FAILURES.append(msg)


AT = "@"


def _a(local, dom):
    return local + AT + dom


EX = "example.com"
OWNER = _a("jane", EX)
NOREPLY = _a("no-reply", "shop." + EX)
CAL_NOTIFY = _a("calendar-notification", "cal." + EX)
CAL_SYSTEM = _a("c0ffee123", "group.calendar.google.com")
NOTIFY_DOMAIN = _a("statements", "notification.bank." + EX)
LIST_ONLY = _a("weekly", "club." + EX)
INFO_HUMAN = _a("info", "smithjoinery." + EX)       # a sole trader who replied
INFO_SILENT = _a("info", "brownbakery." + EX)        # never replied: role rule still applies
BOB = _a("bob.smith", EX)                            # a person the owner wrote to
ROSS = _a("ross.coe", EX)                            # runs a newsletter; the owner wrote to him
CARL = _a("carl.jones", EX)                          # a person, one of whose three mails is list mail

print("== 1. address and header rules ==")
check(ms.noreply_reason(NOREPLY) == "no-reply", "a no-reply local part is machine")
check(ms.noreply_reason(CAL_NOTIFY) == "no-reply", "a calendar-notification local part is machine")
check(ms.noreply_reason(CAL_SYSTEM) == "calendar-system", "a shared-calendar system address is machine")
check(ms.noreply_reason(NOTIFY_DOMAIN) == "notification-domain", "a notification subdomain is machine")
check(ms.noreply_reason(BOB) is None and ms.noreply_reason(INFO_HUMAN) is None,
      "a person's address, and an info@ address, are not machine by address alone")
check(ms.header_reason({"List-Id": "<club.example.com>"}) == "list-id", "List-Id")
check(ms.header_reason({"List-Unsubscribe": "<mailto:x>"}) == "list-unsubscribe", "List-Unsubscribe")
check(ms.header_reason({"Auto-Submitted": "auto-generated"}) == "auto-submitted", "Auto-Submitted")
check(ms.header_reason({"Precedence": "bulk"}) == "precedence", "Precedence: bulk")
check(ms.header_reason({"Auto-Submitted": "no", "Precedence": "first-class"}) is None,
      "Auto-Submitted: no and an ordinary Precedence are a person writing")


def make_envelope(path: Path) -> Path:
    con = sqlite3.connect(path)
    con.executescript(
        "CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);"
        "CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);"
        "CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, sender INTEGER, mailbox INTEGER,"
        " list_id_hash INTEGER, unsubscribe_type INTEGER, conversation_id INTEGER);"
        "CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);"
        "INSERT INTO mailboxes VALUES (1, 'imap://ACCT/INBOX');"
        "INSERT INTO mailboxes VALUES (2, 'imap://ACCT/Sent%20Messages');"
    )
    ids = {}

    def addr(a):
        if a not in ids:
            ids[a] = len(ids) + 1
            con.execute("INSERT INTO addresses VALUES (?, ?, '')", (ids[a], a))
        return ids[a]

    n = [0]

    def msg(sender, mailbox, to, conv, list_id=0, unsub=0):
        n[0] += 1
        con.execute("INSERT INTO messages VALUES (?, ?, ?, ?, ?, ?)",
                    (n[0], addr(sender), mailbox, list_id, unsub, conv))
        for i, t in enumerate(to):
            con.execute("INSERT INTO recipients (message, address, type, position) VALUES (?, ?, 0, ?)",
                        (n[0], addr(t), i))

    for k in range(3):
        msg(NOREPLY, 1, [OWNER], 100 + k, unsub=1)
        msg(CAL_NOTIFY, 1, [OWNER], 110 + k)
        msg(NOTIFY_DOMAIN, 1, [OWNER], 120 + k)
        msg(LIST_ONLY, 1, [OWNER], 130 + k, list_id=555)
        msg(INFO_SILENT, 1, [OWNER], 140 + k)
    # The info@ human: wrote to the owner, owner replied, they replied again,
    # all in ONE conversation. The owner never addressed a Sent message to the
    # silent info@ sender.
    msg(INFO_HUMAN, 1, [OWNER], 200)
    msg(OWNER, 2, [_a("someone.else", EX)], 200)   # owner's reply in the thread
    msg(INFO_HUMAN, 1, [OWNER], 200)
    msg(INFO_HUMAN, 1, [OWNER], 201)
    # Bob: mostly personal, one list-flagged message. Not all-list -> a person.
    msg(BOB, 1, [OWNER], 300)
    msg(BOB, 1, [OWNER], 301)
    msg(BOB, 1, [OWNER], 302, list_id=777)
    # Carl: never corresponded with, two personal messages and one list mail.
    msg(CARL, 1, [OWNER], 400)
    msg(CARL, 1, [OWNER], 401)
    msg(CARL, 1, [OWNER], 402, list_id=888)
    # Ross: every message he sent is his newsletter (list mail), but the owner
    # wrote to him directly. A person the owner writes to is not a machine.
    msg(ROSS, 1, [OWNER], 500, list_id=999)
    msg(ROSS, 1, [OWNER], 501, list_id=999)
    msg(OWNER, 2, [ROSS], 502)
    # The owner replied to a newsletter: the thread holds a Sent message, but
    # the newsletter's own mail is list mail, so it is not a correspondent.
    msg(OWNER, 2, [_a("someone.else", EX)], 130)
    # The owner forwards a no-reply notification: the thread holds a Sent
    # message, but a no-reply address stays machine.
    msg(OWNER, 2, [BOB], 100)
    con.commit()
    con.close()
    return path


print("== 2. the Mail Envelope Index ==")
tmp = Path(tempfile.mkdtemp())
fda = tmp / "fda"
fda.mkdir()
counts = ms.collect(fda, envelope_index=make_envelope(tmp / "Envelope Index"))
machine, correspondents = ms.load(fda)
check(NOREPLY in machine and CAL_NOTIFY in machine, "no-reply and calendar-notification senders are machine")
check(NOTIFY_DOMAIN in machine, "a notification-subdomain sender is machine")
check(LIST_ONLY in machine, "a sender whose every message is list mail is machine")
check(INFO_HUMAN in correspondents and INFO_HUMAN not in machine,
      "the info@ human who replied in the owner's thread is a correspondent, not machine")
check(CARL not in machine and CARL not in correspondents,
      "a person with one list-flagged message among personal mail is not machine")
check(ROSS in correspondents and ROSS not in machine,
      "a person the owner wrote to is not machine, even if all their mail to the owner is list mail")
check(LIST_ONLY not in correspondents, "replying in a newsletter thread does not make the newsletter a correspondent")
check(INFO_SILENT not in correspondents, "the silent info@ sender is not a correspondent")
check(NOREPLY not in correspondents or NOREPLY in machine,
      "a forwarded no-reply notification stays machine")
check(counts.get("machine") == 4, f"exactly four machine senders, got {counts.get('machine')}")


class FakeStore:
    def __init__(self):
        self.updates = []

    def query(self, sparql):
        return []

    def update(self, sparql):
        self.updates.append(sparql)

    def created(self):
        out = []
        for u in self.updates:
            if "a pwg:Person" in u:
                out += re.findall(r'pwg:identifierValue "([^"]+)"', u)
        return out


def install():
    st = FakeStore()
    m._sparql_query = st.query
    m._sparql_update = st.update
    m._person_exists = lambda uri: False
    return st


print("== 3. ingest ==")
(fda / "apple_mail_contacts.json").write_text(json.dumps(
    {a: 5 for a in (NOREPLY, CAL_NOTIFY, NOTIFY_DOMAIN, LIST_ONLY, INFO_HUMAN, INFO_SILENT, BOB, CARL)}))
st = install()
res = m.ingest_mail_contacts(fda)
made = st.created()
check(BOB in made and CARL in made, "positive control: people become Persons")
check(INFO_HUMAN in made, "the info@ human who replied in a thread becomes a Person")
check(not any(a in made for a in (NOREPLY, CAL_NOTIFY, NOTIFY_DOMAIN, LIST_ONLY)),
      f"no machine sender becomes a Person (made {len(made)})")
check(INFO_SILENT not in made, "the silent info@ sender is still held back by the role rule")
check(res.get("machine_senders_skipped") == 4, f"four machine senders skipped, got {res.get('machine_senders_skipped')}")

(fda / "calendar_events.json").write_text(json.dumps([{
    "title": "Planning", "start_date": "2026-08-01T12:00:00", "location": "",
    "attendees": [CAL_SYSTEM, CAL_NOTIFY, BOB],
}]))
st = install()
res = m.ingest_calendar(fda)
made = st.created()
check(BOB in made, "positive control: a human attendee becomes a Person")
check(CAL_SYSTEM not in made and CAL_NOTIFY not in made, "calendar system / notification attendees do not")

print(f"\n{len(FAILURES)} failed")
sys.exit(1 if FAILURES else 0)
