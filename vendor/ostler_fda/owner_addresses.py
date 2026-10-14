"""The owner's own email addresses, so ingest never mints them as People.

DMG #27 walk: the owner's own addresses (a per-service alias on the owner's own
domain, for example) became People. Measured read-only on the walk box: 15
Person nodes created by ``calendar_fda`` held an address on the owner's own
domain, because the owner is an attendee of their own invites and every
attendee is minted as a Person.

THE RULE (Andy, decided). An address is the OWNER when it is

  1. on the owner's contact card (the Contacts "me" card),
  2. a Mail account (an account address in the macOS accounts store),
  3. a From address of mail in a Sent mailbox, or
  4. an address that mail delivered to the owner's mailbox was addressed to,
     EXCEPT mail carrying List-Id or List-Unsubscribe (mailing lists).

NEVER a whole domain. Most people use a work domain, and treating it as the
owner would fold every colleague into the owner. Every clause here yields
exact addresses; nothing compares domains.

HOW CLAUSE 4 IS READ, AND WHY IT IS NARROWER THAN ITS WORDS. The source is the
Mail Envelope Index, which stores To and Cc recipients (``recipients.type`` 0
and 1) and, per message, ``list_id_hash`` and ``unsubscribe_type`` (non-zero
when the message carried List-Id / List-Unsubscribe). It does NOT store
Delivered-To: that header is NOT INSTRUMENTED here, it would need the .emlx
bodies. A To list with several addresses names colleagues as well as the owner,
so only a message whose To holds exactly ONE address is evidence, and only
mail in an INBOX (what was delivered, not filed or archived: Gmail's All Mail
also holds the owner's SENT mail, whose single To is somebody else). The
address must be the sole To on mail from at least two different senders, none
of them the owner, so one person's habit of Bcc'ing the owner while addressing
themselves or a colleague cannot make that colleague the owner.

Read-only throughout: every database is opened ``mode=ro`` / ``immutable=1``.
Any source that cannot be read contributes nothing and is reported as such;
it never raises into the extraction.
"""
from __future__ import annotations

import json
import logging
import sqlite3
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, Optional, Set
from urllib.parse import unquote

logger = logging.getLogger(__name__)

OWNER_ADDRESSES_FILE = "owner_addresses.json"

#: Clause 4 needs the address to be the sole To on mail from this many
#: distinct non-owner senders.
MIN_DISTINCT_SENDERS = 2

_SENT_NAMES = {"sent", "sent messages", "sent items", "sent mail"}


def _norm(addr: Optional[str]) -> str:
    a = (addr or "").strip().lower()
    if "<" in a and ">" in a:
        a = a.split("<", 1)[1].split(">", 1)[0].strip()
    if a.startswith("mailto:"):
        a = a[len("mailto:"):]
    return a if ("@" in a and "." in a.split("@", 1)[1]) else ""


def _mailbox_leaf(url: Optional[str]) -> str:
    if not url:
        return ""
    return unquote(url.rstrip("/").rsplit("/", 1)[-1]).strip().lower()


def is_sent_mailbox(url: Optional[str]) -> bool:
    return _mailbox_leaf(url) in _SENT_NAMES


def is_inbox(url: Optional[str]) -> bool:
    return _mailbox_leaf(url) == "inbox"


def _ro(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?immutable=1", uri=True)


# ── clause 1: the Contacts me card ─────────────────────────────────────

def me_card_emails(ab_root: Optional[Path] = None) -> Set[str]:
    """Every email on the Contacts me card, across every AddressBook source.
    ``ZABCDRECORD.ZME`` on a source's container row names the me card's Z_PK."""
    root = ab_root or (Path.home() / "Library" / "Application Support" / "AddressBook")
    dbs = [root / "AddressBook-v22.abcddb", *sorted(root.glob("Sources/*/AddressBook-v22.abcddb"))]
    out: Set[str] = set()
    for db in dbs:
        if not db.is_file():
            continue
        try:
            con = _ro(db)
            try:
                rows = con.execute(
                    "SELECT e.ZADDRESS, e.ZADDRESSNORMALIZED FROM ZABCDEMAILADDRESS e "
                    "WHERE e.ZOWNER IN (SELECT ZME FROM ZABCDRECORD WHERE ZME IS NOT NULL)"
                ).fetchall()
            finally:
                con.close()
        except sqlite3.Error as exc:
            logger.info("owner addresses: me card unreadable in one source (%s)", type(exc).__name__)
            continue
        for a, n in rows:
            for v in (a, n):
                if _norm(v):
                    out.add(_norm(v))
    return out


# ── clause 2: Mail accounts ────────────────────────────────────────────

def mail_account_emails(accounts_db: Optional[Path] = None) -> Set[str]:
    db = accounts_db or (Path.home() / "Library" / "Accounts" / "Accounts4.sqlite")
    if not db.is_file():
        return set()
    try:
        con = _ro(db)
        try:
            rows = con.execute(
                "SELECT DISTINCT ZUSERNAME FROM ZACCOUNT WHERE ZUSERNAME LIKE '%@%.%'"
            ).fetchall()
        finally:
            con.close()
    except sqlite3.Error as exc:
        logger.info("owner addresses: accounts store unreadable (%s)", type(exc).__name__)
        return set()
    return {_norm(r[0]) for r in rows if _norm(r[0])}


# ── clauses 3 and 4: the Mail Envelope Index ───────────────────────────

def mail_evidence(envelope_index: Path):
    """Returns (sent_from, sole_to) where ``sent_from`` is every From address of
    a message in a Sent mailbox and ``sole_to`` maps an address to the set of
    senders whose non-list INBOX mail named it as the ONLY To recipient."""
    con = _ro(envelope_index)
    try:
        mailboxes = {r[0]: r[1] for r in con.execute("SELECT ROWID, url FROM mailboxes")}
        cols = {r[1] for r in con.execute("PRAGMA table_info(messages)")}
        list_sql = (
            "COALESCE(m.list_id_hash, 0) <> 0" if "list_id_hash" in cols else "0"
        ) + " OR " + (
            "COALESCE(m.unsubscribe_type, 0) <> 0" if "unsubscribe_type" in cols else "0"
        )
        msgs = con.execute(
            f"SELECT m.ROWID, a.address, m.mailbox, ({list_sql}) "
            "FROM messages m LEFT JOIN addresses a ON m.sender = a.ROWID"
        ).fetchall()
        to_rows = con.execute(
            "SELECT r.message, a.address FROM recipients r "
            "JOIN addresses a ON r.address = a.ROWID WHERE r.type = 0"
        ).fetchall()
    finally:
        con.close()
    to_by_msg: Dict[int, Set[str]] = defaultdict(set)
    for mid, addr in to_rows:
        if _norm(addr):
            to_by_msg[mid].add(_norm(addr))
    sent_from: Set[str] = set()
    candidates = []
    for mid, sender, mbox, is_list in msgs:
        url = mailboxes.get(mbox)
        s = _norm(sender)
        if is_sent_mailbox(url):
            if s:
                sent_from.add(s)
        elif is_inbox(url) and not is_list:
            tos = to_by_msg.get(mid, set())
            if len(tos) == 1 and s:
                candidates.append((s, next(iter(tos))))
    sole_to: Dict[str, Set[str]] = defaultdict(set)
    for s, to in candidates:
        if s != to:
            sole_to[to].add(s)
    return sent_from, dict(sole_to)


def classify(me: Iterable[str], accounts: Iterable[str], sent_from: Iterable[str],
             sole_to: Dict[str, Set[str]], min_senders: int = MIN_DISTINCT_SENDERS) -> Dict[str, list]:
    """address -> the clauses that make it the owner's. Exact addresses only."""
    out: Dict[str, list] = defaultdict(list)
    for clause, addrs in (("me_card", me), ("mail_account", accounts), ("sent_from", sent_from)):
        for a in addrs:
            if _norm(a):
                out[_norm(a)].append(clause)
    strong = set(out)
    for addr, senders in sole_to.items():
        independent = {s for s in senders if s not in strong}
        if len(independent) >= min_senders:
            out[addr].append("delivered_to")
    return dict(out)


def collect(output_dir: Path, *, envelope_index: Optional[Path] = None,
            ab_root: Optional[Path] = None, accounts_db: Optional[Path] = None,
            use_mail: bool = True) -> dict:
    """Compute and write ``owner_addresses.json``. Returns counts only."""
    me = me_card_emails(ab_root)
    accounts = mail_account_emails(accounts_db)
    sent_from: Set[str] = set()
    sole_to: Dict[str, Set[str]] = {}
    mail_status = "disabled"
    if use_mail:
        try:
            if envelope_index is None:
                from .apple_mail import _find_envelope_index
                envelope_index = _find_envelope_index()
            sent_from, sole_to = mail_evidence(envelope_index)
            mail_status = "ok"
        except Exception as exc:  # noqa: BLE001 -- reported, never raised
            mail_status = f"unreadable:{type(exc).__name__}"
    owner = classify(me, accounts, sent_from, sole_to)
    (Path(output_dir) / OWNER_ADDRESSES_FILE).write_text(
        json.dumps({"addresses": owner}, indent=2, sort_keys=True)
    )
    counts = {
        "owner_addresses": len(owner),
        "me_card": len(me), "mail_account": len(accounts),
        "sent_from": len(sent_from),
        "delivered_to": sum(1 for v in owner.values() if "delivered_to" in v),
        "mail": mail_status,
    }
    logger.info("[ok] Owner addresses: %s", json.dumps(counts, sort_keys=True))
    return counts


def load_owner_addresses(fda_dir: Path) -> Set[str]:
    """The owner's addresses as written by ``collect``. Absent file -> empty
    set (nothing is suppressed that was not proven to be the owner's)."""
    p = Path(fda_dir) / OWNER_ADDRESSES_FILE
    try:
        data = json.loads(p.read_text())
    except (OSError, ValueError):
        return set()
    return {_norm(a) for a in (data.get("addresses") or {}) if _norm(a)}


def is_owner_address(value: Optional[str], owner: Set[str]) -> bool:
    n = _norm(value)
    return bool(n) and n in owner
