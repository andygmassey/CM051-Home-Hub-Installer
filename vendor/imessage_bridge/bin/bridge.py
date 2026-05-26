#!/usr/bin/env python3
"""Assistant-user iMessage bridge producer.

Polls the running user's iMessage ``chat.db`` for new inbound messages
since the last poll and appends them as JSON-lines to
``/Users/Shared/imessage-bridge/inbox.jsonl`` for the assistant-side
reader (``ostler-assistant`` / ``zeroclaw-channels::imessage``) to drain.

Reader contract (single source of truth for the JSONL record shape):
    crates/zeroclaw-channels/src/imessage.rs in the ostler-assistant
    repo. Reader fields are documented in
    ``imessage-bridge/INBOX_SCHEMA.md`` alongside this script.

Each record is a single line of JSON with these keys:
    rowid       integer  iMessage row id (used for de-dup + ordering)
    sender      string   phone number or email of the remote party
    text        string   message body (may be empty if attachment only)
    timestamp   integer  unix epoch seconds (optional; reader falls
                         back to wall-clock if absent)

The reader drains and truncates the file atomically per poll cycle, so
the producer only ever appends and never has to delete its own writes.

Design notes:

- Read-only SQLite URI: ``file:<path>?mode=ro`` mirrors the pattern in
  ``ostler_fda/imessage.py``. Avoids racing iMessage's writer.

- Idempotency: we persist the last successfully-emitted ``ROWID`` to
  ``/Users/Shared/imessage-bridge/state.json`` between poll cycles so a
  restart (LaunchAgent reload, machine reboot) does not re-emit history
  the reader has already drained.

- Poll cadence: 30 seconds is the default. iMessage's own background
  poll loop runs faster than that, so a 30s tick gives the receive
  side time to settle without leaving inbound messages invisible to the
  assistant for more than half a minute.

- Privacy: stdout prints counts only. Never message bodies. Never
  phone numbers or email addresses. The customer's terminal output and
  any logs collected by support remain free of conversation contents.

- Full Disk Access: reading ``~/Library/Messages/chat.db`` requires FDA
  on macOS Sequoia or newer. If permission is denied we log a single
  warning (rate-limited) and keep polling: granting FDA mid-run starts
  producing records on the next tick without a restart.

British English. No em-dashes (customer-visible script).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import sqlite3
import sys
import time
from pathlib import Path
from typing import Optional

# Module-level constants matching the reader's expectations. If the
# reader path ever moves, mirror the change here and in INBOX_SCHEMA.md.
BRIDGE_INBOX_DIR = Path("/Users/Shared/imessage-bridge")
BRIDGE_INBOX_PATH = BRIDGE_INBOX_DIR / "inbox.jsonl"
BRIDGE_STATE_PATH = BRIDGE_INBOX_DIR / "state.json"

DEFAULT_CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"
DEFAULT_POLL_INTERVAL_SECONDS = 30

# Mac absolute-time epoch offset (seconds since 2001-01-01).
MAC_EPOCH_OFFSET = 978_307_200

logger = logging.getLogger("imessage-bridge")


def _convert_mac_timestamp(raw: int) -> int:
    """Convert iMessage stored timestamp to Unix epoch seconds.

    Ventura and newer store nanoseconds since the Mac epoch; older
    macOS stores plain seconds. We detect by magnitude.
    """
    if raw > 1e15:  # nanoseconds (Ventura+)
        return int(raw / 1e9) + MAC_EPOCH_OFFSET
    return int(raw) + MAC_EPOCH_OFFSET


def _load_last_rowid(state_path: Path) -> int:
    """Read the last-emitted ROWID from state.json, or 0 if first run."""
    if not state_path.exists():
        return 0
    try:
        with state_path.open("r", encoding="utf-8") as fp:
            data = json.load(fp)
        rowid = data.get("last_rowid", 0)
        if not isinstance(rowid, int) or rowid < 0:
            logger.warning("state.json last_rowid not a non-negative int; resetting to 0")
            return 0
        return rowid
    except (json.JSONDecodeError, OSError) as exc:
        logger.warning("state.json unreadable (%s); resetting to 0", exc.__class__.__name__)
        return 0


def _save_last_rowid(state_path: Path, rowid: int) -> None:
    """Persist the last-emitted ROWID atomically (write + rename)."""
    tmp_path = state_path.with_suffix(".json.tmp")
    try:
        with tmp_path.open("w", encoding="utf-8") as fp:
            json.dump({"last_rowid": int(rowid)}, fp)
        os.replace(tmp_path, state_path)
    except OSError as exc:
        logger.warning("failed to persist state.json (%s)", exc.__class__.__name__)
        # Best-effort: leave the temp file around for the next tick to
        # overwrite. Re-emitting a handful of messages is recoverable.


def _open_chat_db_readonly(db_path: Path) -> Optional[sqlite3.Connection]:
    """Open chat.db read-only. Returns None on permission denial."""
    if not db_path.exists():
        logger.warning("chat.db not found at %s", db_path)
        return None
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5)
    except sqlite3.OperationalError as exc:
        msg = str(exc).lower()
        if "authorization denied" in msg or "unable to open" in msg:
            logger.warning(
                "cannot read iMessage chat.db (Full Disk Access likely not granted)"
            )
            return None
        logger.warning("sqlite open failed: %s", exc.__class__.__name__)
        return None
    conn.row_factory = sqlite3.Row
    return conn


def fetch_new_messages(
    conn: sqlite3.Connection,
    after_rowid: int,
    max_rows: int = 500,
) -> list[dict]:
    """Pull inbound messages from chat.db with ROWID > ``after_rowid``.

    Outbound messages (``is_from_me = 1``) are filtered out so the
    assistant only sees what the remote party actually said. Empty
    message bodies (attachment-only) are dropped to match the reader's
    blank-text skip rule.

    Returns a list of dicts shaped for the reader contract. The list
    is empty when there is nothing new.
    """
    try:
        rows = conn.execute(
            """
            SELECT
                m.ROWID                          AS rowid,
                m.text                           AS text,
                m.date                           AS date,
                COALESCE(h.id, '')               AS sender
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.ROWID > ?
              AND m.is_from_me = 0
            ORDER BY m.ROWID ASC
            LIMIT ?
            """,
            (after_rowid, max_rows),
        ).fetchall()
    except sqlite3.OperationalError as exc:
        logger.warning("chat.db query failed: %s", exc.__class__.__name__)
        return []

    records: list[dict] = []
    for row in rows:
        text = row["text"]
        sender = row["sender"]
        rowid = int(row["rowid"])
        date_raw = row["date"]

        # Match the reader's empty-line skip semantics so the producer
        # never writes records the reader would discard anyway.
        if not text or not text.strip():
            continue
        if not sender:
            continue

        if date_raw is None:
            timestamp = int(time.time())
        else:
            timestamp = _convert_mac_timestamp(int(date_raw))

        records.append(
            {
                "rowid": rowid,
                "sender": sender,
                "text": text,
                "timestamp": timestamp,
            }
        )

    return records


def append_records(inbox_path: Path, records: list[dict]) -> None:
    """Append records to inbox.jsonl as one JSON object per line.

    Uses standard text append: the reader drains and truncates per
    poll, so multiple writes per cycle are safe. POSIX append on a
    local filesystem is atomic per ``write(2)`` call.
    """
    if not records:
        return
    inbox_path.parent.mkdir(parents=True, exist_ok=True)
    # Open in append mode (binary) so we can do a single write per
    # record. Newline-terminated JSON is what the reader expects.
    with inbox_path.open("a", encoding="utf-8") as fp:
        for rec in records:
            fp.write(json.dumps(rec, ensure_ascii=False))
            fp.write("\n")


def poll_once(
    db_path: Path = DEFAULT_CHAT_DB,
    inbox_path: Path = BRIDGE_INBOX_PATH,
    state_path: Path = BRIDGE_STATE_PATH,
) -> int:
    """Run one poll cycle. Returns the count of records appended.

    Pure function over the filesystem state, no global side effects
    beyond inbox.jsonl + state.json. Used by tests directly.
    """
    inbox_path.parent.mkdir(parents=True, exist_ok=True)

    last_rowid = _load_last_rowid(state_path)
    conn = _open_chat_db_readonly(db_path)
    if conn is None:
        return 0
    try:
        records = fetch_new_messages(conn, after_rowid=last_rowid)
    finally:
        conn.close()

    if not records:
        return 0

    append_records(inbox_path, records)

    # Persist the new high-water mark only after the append succeeded.
    new_high = max(r["rowid"] for r in records)
    _save_last_rowid(state_path, new_high)
    return len(records)


def run(
    poll_interval_seconds: int = DEFAULT_POLL_INTERVAL_SECONDS,
    db_path: Path = DEFAULT_CHAT_DB,
    inbox_path: Path = BRIDGE_INBOX_PATH,
    state_path: Path = BRIDGE_STATE_PATH,
) -> None:
    """Long-running poll loop. SIGTERM / SIGINT exits cleanly."""
    stop = {"flag": False}

    def _handler(signum, frame):  # noqa: ARG001
        stop["flag"] = True

    signal.signal(signal.SIGTERM, _handler)
    signal.signal(signal.SIGINT, _handler)

    logger.info("iMessage bridge starting; interval=%ss", poll_interval_seconds)

    while not stop["flag"]:
        try:
            appended = poll_once(
                db_path=db_path,
                inbox_path=inbox_path,
                state_path=state_path,
            )
            if appended:
                # Privacy: count only. Never message bodies / phone
                # numbers / email addresses.
                logger.info("appended %d record(s)", appended)
        except Exception as exc:  # pragma: no cover - defensive
            logger.warning("poll error (%s); continuing", exc.__class__.__name__)

        # Sleep in 1s slices so SIGTERM is responsive without waiting
        # a full interval for shutdown.
        for _ in range(poll_interval_seconds):
            if stop["flag"]:
                break
            time.sleep(1)

    logger.info("iMessage bridge stopped")


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Assistant-user iMessage bridge producer.",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=DEFAULT_POLL_INTERVAL_SECONDS,
        help="seconds between polls (default: %(default)s)",
    )
    parser.add_argument(
        "--chat-db",
        type=Path,
        default=DEFAULT_CHAT_DB,
        help="path to iMessage chat.db (default: %(default)s)",
    )
    parser.add_argument(
        "--inbox",
        type=Path,
        default=BRIDGE_INBOX_PATH,
        help="path to inbox.jsonl drain file (default: %(default)s)",
    )
    parser.add_argument(
        "--state",
        type=Path,
        default=BRIDGE_STATE_PATH,
        help="path to state.json (default: %(default)s)",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="run a single poll and exit (useful for testing)",
    )
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    args = _parse_args(argv if argv is not None else sys.argv[1:])

    if args.once:
        appended = poll_once(
            db_path=args.chat_db,
            inbox_path=args.inbox,
            state_path=args.state,
        )
        print(f"appended {appended} record(s)")
        return 0

    run(
        poll_interval_seconds=args.interval,
        db_path=args.chat_db,
        inbox_path=args.inbox,
        state_path=args.state,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
