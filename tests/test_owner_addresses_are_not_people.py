#!/usr/bin/env python3
"""DMG #27: the owner's own addresses must never become People.

Andy's rule, decided: an address is the owner's when it is on the owner's
contact card, is a Mail account, is a From address in Sent mail, or is an
address that mail delivered to the owner's mailbox was addressed to, EXCEPT
mail carrying List-Id or List-Unsubscribe. NEVER a whole domain.

Each clause is tested on its own, the mailing-list exclusion on both headers,
and the domain rule by a colleague on the SAME domain as the owner's alias who
must still become a Person. Synthetic SQLite stores shaped like the macOS ones
(Contacts, accounts, Mail Envelope Index); the SPARQL transport is stubbed.
Cast names and example.com addresses only.
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

from ostler_fda import owner_addresses as oa  # noqa: E402
from ostler_fda import pwg_ingest as m  # noqa: E402

FAILURES: list = []


def check(cond, msg):
    print(("ok: " if cond else "FAIL: ") + msg)
    if not cond:
        FAILURES.append(msg)


# Addresses, composed at runtime so no address-shaped literal sits in the file.
# The owner's alias and the colleague share a domain on purpose.
AT = "@"
EX = "example.com"
OWN_DOM = "doe." + EX


def _a(local, dom):
    return local + AT + dom


ME_CARD = _a("jane.doe", EX)
ACCOUNT = _a("jane", "example.org")
SENT_FROM = _a("jdoe.sent", "example.net")
ALIAS = _a("shop-alias", OWN_DOM)          # per-service alias, owner's domain
COLLEAGUE = _a("bob.smith", OWN_DOM)       # same domain, a different person
LIST_ALIAS = _a("list-alias", OWN_DOM)     # only ever reached via a list
UNSUB_ALIAS = _a("unsub-alias", OWN_DOM)   # only ever reached via List-Unsubscribe
ONE_SENDER_ALIAS = _a("lone", OWN_DOM)     # sole To from ONE sender only
SENDERS = [_a(n, EX) for n in ("alex", "sam", "tom")]


def make_addressbook(root: Path) -> Path:
    src = root / "Sources" / "AAAA"
    src.mkdir(parents=True)
    con = sqlite3.connect(src / "AddressBook-v22.abcddb")
    con.executescript(
        "CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZME INTEGER);"
        "CREATE TABLE ZABCDEMAILADDRESS (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZADDRESS TEXT, ZADDRESSNORMALIZED TEXT);"
        "INSERT INTO ZABCDRECORD VALUES (1, 7);"      # container row: me card is 7
        "INSERT INTO ZABCDRECORD VALUES (7, NULL);"   # the me card
        "INSERT INTO ZABCDRECORD VALUES (8, NULL);"   # somebody else's card
    )
    con.execute("INSERT INTO ZABCDEMAILADDRESS VALUES (1, 7, ?, ?)", (ME_CARD.upper(), ME_CARD))
    con.execute("INSERT INTO ZABCDEMAILADDRESS VALUES (2, 8, ?, ?)", (COLLEAGUE, COLLEAGUE))
    con.commit()
    con.close()
    return root


def make_accounts(path: Path) -> Path:
    con = sqlite3.connect(path)
    con.executescript("CREATE TABLE ZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZUSERNAME TEXT);")
    con.executemany("INSERT INTO ZACCOUNT (ZUSERNAME) VALUES (?)", [(ACCOUNT,), (ACCOUNT,), ("not-an-address",)])
    con.commit()
    con.close()
    return path


def make_envelope(path: Path) -> Path:
    con = sqlite3.connect(path)
    con.executescript(
        "CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);"
        "CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);"
        "CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, sender INTEGER, mailbox INTEGER,"
        " list_id_hash INTEGER, unsubscribe_type INTEGER);"
        "CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);"
        "INSERT INTO mailboxes VALUES (1, 'imap://ACCT-UUID/INBOX');"
        "INSERT INTO mailboxes VALUES (2, 'imap://ACCT-UUID/Sent%20Messages');"
        "INSERT INTO mailboxes VALUES (3, 'imap://ACCT-UUID/%5BGmail%5D/All%20Mail');"
    )
    ids = {}

    def addr(a):
        if a not in ids:
            ids[a] = len(ids) + 1
            con.execute("INSERT INTO addresses VALUES (?, ?, '')", (ids[a], a))
        return ids[a]

    n = [0]

    def msg(sender, mailbox, to, cc=(), list_id=0, unsub=0):
        n[0] += 1
        con.execute("INSERT INTO messages VALUES (?, ?, ?, ?, ?)", (n[0], addr(sender), mailbox, list_id, unsub))
        for i, t in enumerate(to):
            con.execute("INSERT INTO recipients (message, address, type, position) VALUES (?, ?, 0, ?)", (n[0], addr(t), i))
        for i, t in enumerate(cc):
            con.execute("INSERT INTO recipients (message, address, type, position) VALUES (?, ?, 1, ?)", (n[0], addr(t), i))

    # clause 3: the owner's Sent mail, From the sent address, To a colleague
    msg(SENT_FROM, 2, [COLLEAGUE])
    # clause 4: sole To = ALIAS, delivered to INBOX, from two different senders
    msg(SENDERS[0], 1, [ALIAS])
    msg(SENDERS[1], 1, [ALIAS])
    # a colleague on the same domain appears on MULTI-To mail from many senders
    for s in SENDERS:
        msg(s, 1, [ALIAS, COLLEAGUE])
    # the exclusions: same shape as ALIAS, but every message is list mail
    msg(SENDERS[0], 1, [LIST_ALIAS], list_id=12345)
    msg(SENDERS[1], 1, [LIST_ALIAS], list_id=67890)
    msg(SENDERS[0], 1, [UNSUB_ALIAS], unsub=2)
    msg(SENDERS[1], 1, [UNSUB_ALIAS], unsub=2)
    # one sender only, twice: not enough independent evidence
    msg(SENDERS[2], 1, [ONE_SENDER_ALIAS])
    msg(SENDERS[2], 1, [ONE_SENDER_ALIAS])
    # an archive (Gmail All Mail) holds the owner's SENT mail too: its sole To
    # is somebody else, and it must not count as delivered to the owner.
    msg(SENDERS[0], 3, [COLLEAGUE])
    msg(SENDERS[1], 3, [COLLEAGUE])
    con.commit()
    con.close()
    return path


tmp = Path(tempfile.mkdtemp())
ab = make_addressbook(tmp / "AddressBook")
acc = make_accounts(tmp / "Accounts4.sqlite")
env = make_envelope(tmp / "Envelope Index")
fda = tmp / "fda"
fda.mkdir()
counts = oa.collect(fda, envelope_index=env, ab_root=ab, accounts_db=acc, use_mail=True)
owner = oa.load_owner_addresses(fda)
clauses = json.loads((fda / oa.OWNER_ADDRESSES_FILE).read_text())["addresses"]

print("== the four clauses ==")
check("me_card" in clauses.get(ME_CARD, []), "clause 1: an address on the owner's contact card is the owner")
check("mail_account" in clauses.get(ACCOUNT, []), "clause 2: a Mail account address is the owner")
check("sent_from" in clauses.get(SENT_FROM, []), "clause 3: a From address in Sent mail is the owner")
check("delivered_to" in clauses.get(ALIAS, []), "clause 4: the sole To of delivered mail from two senders is the owner")

print("== exclusions ==")
check(LIST_ALIAS not in owner, "mail carrying List-Id is not evidence")
check(UNSUB_ALIAS not in owner, "mail carrying List-Unsubscribe is not evidence")
check(ONE_SENDER_ALIAS not in owner, "one sender's mail alone is not evidence")
check(COLLEAGUE not in owner, "a colleague on the owner's alias DOMAIN is not the owner (no domain rule)")
check(not any(a.endswith(AT + EX) and a not in (ME_CARD,) for a in owner),
      "no sender became the owner")
check(counts["owner_addresses"] == 4, f"exactly the four owner addresses, got {counts['owner_addresses']}")


# ── the ingest writers: owner addresses create no Person, colleagues do ──

class FakeStore:
    def __init__(self):
        self.updates = []

    def query(self, sparql):
        return []

    def update(self, sparql):
        self.updates.append(sparql)

    def created_identifier_values(self):
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


print("== calendar ingest ==")
(fda / "calendar_events.json").write_text(json.dumps([{
    "title": "Planning", "start_date": "2026-08-01T12:00:00", "location": "",
    "attendees": [ALIAS, ME_CARD, COLLEAGUE],
}]))
st = install()
res = m.ingest_calendar(fda)
made = st.created_identifier_values()
check(COLLEAGUE in made, "positive control: the colleague on the same domain DOES become a Person")
check(ALIAS not in made and ME_CARD not in made, f"the owner's own addresses do not (created: {len(made)})")
check(res.get("owner_addresses_skipped") == 2, f"two owner attendees counted as skipped, got {res.get('owner_addresses_skipped')}")

print("== mail contacts ingest ==")
(fda / "apple_mail_contacts.json").write_text(json.dumps({SENT_FROM: 40, ACCOUNT: 9, COLLEAGUE: 12}))
st = install()
res = m.ingest_mail_contacts(fda)
made = st.created_identifier_values()
check(COLLEAGUE in made, "positive control: a frequent colleague DOES become a Person")
check(SENT_FROM not in made and ACCOUNT not in made, "the owner's Sent From and account addresses do not")

print("== no owner file: nothing suppressed ==")
(fda / oa.OWNER_ADDRESSES_FILE).unlink()
st = install()
m.ingest_calendar(fda)
check(ALIAS in st.created_identifier_values(),
      "control: without owner evidence the alias is created, so the suppression above is the owner rule")

print(f"\n{len(FAILURES)} failed")
sys.exit(1 if FAILURES else 0)
