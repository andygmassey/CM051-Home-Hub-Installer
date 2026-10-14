"""Full-history catch-up for Apple Mail (v1.0.108, CATCHUP_DESIGN_2026-10-15).

Two catch-up sources, both reporting under the Doctor's "email" row.

mail_contacts
-------------
The install-time correspondent pass (extract_all's apple_mail arm) reads the
Envelope Index for five years, at most 100,000 messages, and keeps the top 50
senders (apple_mail.frequent_contacts). Everyone else the owner has ever
corresponded with never becomes a Person. This walks the WHOLE Envelope Index,
newest to oldest, keyset-paged on (date_received, ROWID), with no window, no
message limit and no top-N. Each sender is counted with the same normalisation
frequent_contacts uses; the moment an address reaches
pwg_ingest.MAIL_CONTACT_MIN_COUNT it is handed to pwg_ingest.ingest_mail_contacts,
so the owner-address, machine-sender, role-address and forgotten skips all
apply exactly as they do at install.

Counts are idempotent: a message is counted only if its ROWID was not counted
before, in ONE transaction with its counter bump, so a batch that is re-read
after a kill or a failure never counts a message twice. The ingest key is
``mailcontact:<address>``; the ingest itself looks the identifier up before it
creates anyone, so a repeat after a kill finds the Person it already made.

mail_bodies
-----------
Apple Mail BODIES already have a backward walk: email-ingest's two-checkpoint
sweep (apple_mail_mbox.py) reaches the oldest .emlx in 30-day chunks. A second
walk would write every thread twice. So this source processes nothing: it
mirrors that checkpoint into a catch-up watermark so Doctor reports how far
back the mail bodies have been read, and steps aside for the rest of the tick.

Counts only in every log line. No address, subject or body is logged.
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import sqlite3
import time
from pathlib import Path
from typing import List, Optional

import ostler_catchup as oc

from . import apple_mail

logger = logging.getLogger(__name__)

SOURCE_CONTACTS = "mail_contacts"
SOURCE_BODIES = "mail_bodies"
DOCTOR_ROW = "email"
# Envelope Index rows read per batch. A batch is one indexed range read plus
# one transaction; the cost per tick is dominated by the ingest of the
# addresses that cross the threshold, not by the read.
DEFAULT_BATCH_MESSAGES = 2000
_MSG_LEDGER = SOURCE_CONTACTS + ".msg"

# The files the install-time FDA pass writes beside apple_mail_contacts.json,
# which ingest_mail_contacts reads from the same directory. Copied into every
# catch-up batch dir so every skip the install applies applies here too.
_SKIP_FILES = ("owner_addresses.json", "machine_senders.json")


def _fda_dir() -> Path:
    raw = os.environ.get("OSTLER_CATCHUP_FDA_DIR", "").strip()
    return Path(raw).expanduser() if raw else oc.ostler_home() / "imports" / "fda"


def _envelope_index() -> Path:
    raw = os.environ.get("OSTLER_MAIL_ENVELOPE_INDEX", "").strip()
    return Path(raw).expanduser() if raw else apple_mail._find_envelope_index()


class MailContacts(oc.Adapter):
    source = SOURCE_CONTACTS
    doctor_row = DOCTOR_ROW
    batch_size = DEFAULT_BATCH_MESSAGES

    def __init__(self, envelope_index: Optional[Path] = None, fda_dir: Optional[Path] = None,
                 ledger: Optional["oc.Ledger"] = None):
        self._db_path = envelope_index
        self._fda_dir = fda_dir
        self._ledger = ledger
        from .pwg_ingest import MAIL_CONTACT_MIN_COUNT
        self.threshold = MAIL_CONTACT_MIN_COUNT

    # -- reading ------------------------------------------------------------

    def _ledger_db(self) -> sqlite3.Connection:
        if self._ledger is None:
            self._ledger = oc.Ledger()
        return self._ledger._db

    def start_cursor(self):
        return None   # the newest message: counts need the whole mailbox

    def next_batch(self, cursor, limit):
        db_path = self._db_path or _envelope_index()
        try:
            conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        except sqlite3.OperationalError as e:
            if "authorization denied" in str(e).lower():
                raise PermissionError("Cannot read Mail data. Grant Full Disk Access.") from e
            raise
        conn.row_factory = sqlite3.Row
        try:
            if cursor is None:
                where, params = "1 = 1", ()
            else:
                d, rid = cursor
                where = "({m}date_received < ? OR ({m}date_received = ? AND {m}ROWID < ?))"
                params = (d, d, rid)
            rows = apple_mail.query_message_rows(
                conn, where=where, params=params,
                order="{m}date_received DESC, {m}ROWID DESC", limit=limit)
        finally:
            conn.close()
        if rows is None:
            raise RuntimeError("Mail Envelope Index schema not recognised")

        db = self._ledger_db()
        now = int(time.time())
        seen: List[str] = []
        with db:  # one transaction: a message is counted exactly once
            for r in rows:
                # Parity with frequent_contacts over extract_messages, which
                # drops subject-less rows before counting.
                if not r["subject"]:
                    continue
                sender = apple_mail.normalise_sender(r["sender"] or "")
                if not sender:
                    continue
                cur = db.execute(
                    "INSERT OR IGNORE INTO done (source, key, at) VALUES (?, ?, ?)",
                    (_MSG_LEDGER, str(r["msg_rowid"]), now))
                if cur.rowcount == 1:
                    db.execute(
                        "INSERT INTO counts (source, key, n) VALUES (?, ?, 1) "
                        "ON CONFLICT(source, key) DO UPDATE SET n = n + 1",
                        (SOURCE_CONTACTS, sender))
                if sender not in seen:
                    seen.append(sender)

        items = []
        for addr in seen:
            row = db.execute("SELECT n FROM counts WHERE source = ? AND key = ?",
                             (SOURCE_CONTACTS, addr)).fetchone()
            if row and row[0] >= self.threshold:
                items.append(addr)

        if rows:
            last = rows[-1]
            next_cursor = [last["date_received"], last["msg_rowid"]]
            oldest = oc.to_iso(last["date_received"]) if last["date_received"] else None
        else:
            next_cursor, oldest = cursor, None
        return oc.Batch(items=items, next_cursor=next_cursor, oldest_at=oldest,
                        exhausted=len(rows) < limit)

    # -- writing ------------------------------------------------------------

    def key(self, item):
        return "mailcontact:" + item

    def process(self, item):
        from . import pwg_ingest
        n = self._ledger_db().execute(
            "SELECT n FROM counts WHERE source = ? AND key = ?",
            (SOURCE_CONTACTS, item)).fetchone()
        count = n[0] if n else 0
        batch_dir = oc.state_dir() / "mail_contacts_batch"
        batch_dir.mkdir(parents=True, exist_ok=True)
        src = self._fda_dir or _fda_dir()
        for name in _SKIP_FILES:
            target = batch_dir / name
            if (src / name).is_file():
                shutil.copyfile(src / name, target)
            elif target.exists():
                target.unlink()
        (batch_dir / "apple_mail_contacts.json").write_text(json.dumps({item: count}))
        res = pwg_ingest.ingest_mail_contacts(batch_dir) or {}
        if res.get("status") != "ok":
            return False
        # A lookup that could not run is not an answer: retry next tick.
        return not res.get("people_lookup_failed")


class MailBodies(oc.Adapter):
    """Reports email-ingest's own backward sweep. Processes nothing."""

    source = SOURCE_BODIES
    doctor_row = DOCTOR_ROW
    batch_size = 1

    def __init__(self, checkpoint: Optional[Path] = None):
        self._checkpoint = checkpoint

    def start_cursor(self):
        return {"oldest_processed": None, "complete": False, "seen": 0}

    def next_batch(self, cursor, limit):
        p = self._checkpoint or (oc.ostler_home() / "state" / "apple_mail_mbox_checkpoint.json")
        try:
            ck = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            ck = {}
        oldest = ck.get("oldest_processed") if isinstance(ck, dict) else None
        complete = bool(ck.get("backfill_complete")) if isinstance(ck, dict) else False
        seen = int((cursor or {}).get("seen") or 0) + 1
        return oc.Batch(
            items=[],
            next_cursor={"oldest_processed": oldest, "complete": complete, "seen": seen},
            oldest_at=oc.to_iso(_parse_iso(oldest)) if oldest else None,
            exhausted=complete,
            pause=True,
        )

    def key(self, item):  # pragma: no cover - never called, no items
        return str(item)

    def process(self, item):  # pragma: no cover
        return True


def _parse_iso(value):
    from datetime import datetime, timezone
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def adapters():
    return [MailContacts(), MailBodies()]
