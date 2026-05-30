"""Extract email metadata from macOS Mail.app databases.

macOS Mail stores message metadata in an Envelope Index SQLite
database. We extract subjects, senders, recipients, and dates
 -- NOT email body content. This keeps extraction fast and
avoids pulling in huge amounts of text.

Database location:
    ~/Library/Mail/V*/MailData/Envelope Index

The V* directory corresponds to the Mail data format version
(V10 on Sonoma/Sequoia, V9 on Ventura, etc.).

Requires Full Disk Access (FDA) on macOS Sequoia+.
"""
from __future__ import annotations

import logging
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


DEFAULT_MAIL_DIR = Path.home() / "Library" / "Mail"


@dataclass
class EmailMessage:
    """Metadata for a single email message."""
    subject: str
    sender: str
    date_sent: Optional[datetime]
    date_received: Optional[datetime]
    recipients: list[str]
    mailbox: Optional[str]
    is_read: bool
    is_flagged: bool
    message_id: Optional[str]


def _find_envelope_index(mail_dir: Optional[Path] = None) -> Path:
    """Locate the Mail Envelope Index database.

    Apple increments the V* version directory with major macOS
    updates, so we find the highest version present.
    """
    mail_dir = mail_dir or DEFAULT_MAIL_DIR

    if not mail_dir.exists():
        raise FileNotFoundError(
            f"Mail directory not found at {mail_dir}. "
            "Is Mail.app configured on this Mac?"
        )

    # Find V* directories, pick the highest version
    v_dirs = sorted(
        mail_dir.glob("V*/MailData"),
        key=lambda p: int(p.parent.name[1:]) if p.parent.name[1:].isdigit() else 0,
        reverse=True,
    )

    if not v_dirs:
        raise FileNotFoundError(
            f"No Mail data version directories found in {mail_dir}"
        )

    envelope = v_dirs[0] / "Envelope Index"
    if not envelope.exists():
        # Try without MailData
        envelope = v_dirs[0].parent / "Envelope Index"
        if not envelope.exists():
            raise FileNotFoundError(
                f"Envelope Index not found in {v_dirs[0]}"
            )

    return envelope


def extract_messages(
    db_path: Optional[Path] = None,
    since_days: int = 365,
    limit: int = 10000,
) -> list[EmailMessage]:
    """Extract email metadata from the Mail Envelope Index.

    Args:
        db_path: Path to the Envelope Index. Auto-detected if None.
        since_days: Only include emails from the last N days.
        limit: Maximum number of messages to extract.

    Returns:
        List of EmailMessage objects, most recent first.
    """
    if db_path is None:
        db_path = _find_envelope_index()

    if not db_path.exists():
        raise FileNotFoundError(f"Mail Envelope Index not found at {db_path}")

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            raise PermissionError(
                "Cannot read Mail data. Grant Full Disk Access."
            ) from e
        raise

    conn.row_factory = sqlite3.Row

    # Mail stores dates as Unix timestamps (not Mac epoch)
    cutoff = datetime.now(timezone.utc).timestamp() - (since_days * 86400)

    # Try Sonoma/Sequoia schema first (V10)
    try:
        rows = conn.execute("""
            SELECT
                m.ROWID as msg_rowid,
                m.subject,
                m.sender as sender,
                m.date_sent,
                m.date_received,
                m.read as is_read,
                m.flagged as is_flagged,
                m.message_id,
                mb.url as mailbox_url
            FROM messages m
            LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
            WHERE m.date_received > ?
            ORDER BY m.date_received DESC
            LIMIT ?
        """, (cutoff, limit)).fetchall()
    except sqlite3.OperationalError:
        # Try alternative schema
        try:
            rows = conn.execute("""
                SELECT
                    ROWID as msg_rowid,
                    subject,
                    sender,
                    date_sent,
                    date_received,
                    read as is_read,
                    flagged as is_flagged,
                    message_id,
                    NULL as mailbox_url
                FROM messages
                WHERE date_received > ?
                ORDER BY date_received DESC
                LIMIT ?
            """, (cutoff, limit)).fetchall()
        except sqlite3.OperationalError as e:
            logger.error("Mail schema not recognised: %s", e)
            conn.close()
            return []

    # Get recipients from the addresses table
    recipient_map: dict[str, list[str]] = {}
    try:
        recip_rows = conn.execute("""
            SELECT r.message_id, a.address, a.comment as name
            FROM recipients r
            JOIN addresses a ON r.address_id = a.ROWID
        """).fetchall()
        for rr in recip_rows:
            mid = rr["message_id"]
            if mid not in recipient_map:
                recipient_map[mid] = []
            addr = rr["address"] or rr["name"] or ""
            if addr:
                recipient_map[mid].append(addr)
    except sqlite3.OperationalError:
        pass  # Recipients table may differ across versions

    conn.close()

    messages = []
    for row in rows:
        subject = row["subject"]
        if not subject:
            continue

        date_sent = None
        if row["date_sent"]:
            try:
                date_sent = datetime.fromtimestamp(
                    row["date_sent"], tz=timezone.utc
                )
            except (OSError, ValueError):
                pass

        date_received = None
        if row["date_received"]:
            try:
                date_received = datetime.fromtimestamp(
                    row["date_received"], tz=timezone.utc
                )
            except (OSError, ValueError):
                pass

        # Extract mailbox name from URL (e.g. "imap://user@server/INBOX")
        mailbox = None
        if row["mailbox_url"]:
            url = row["mailbox_url"]
            # Take last path component
            if "/" in url:
                mailbox = url.rsplit("/", 1)[-1]

        msg_id = row["message_id"]
        msg_rowid = row["msg_rowid"]
        recipients = recipient_map.get(msg_rowid, [])
        messages.append(EmailMessage(
            subject=subject,
            sender=row["sender"] or "",
            date_sent=date_sent,
            date_received=date_received,
            recipients=recipients,
            mailbox=mailbox,
            is_read=bool(row["is_read"]),
            is_flagged=bool(row["is_flagged"]),
            message_id=msg_id,
        ))

    logger.info("Extracted %d email messages", len(messages))
    return messages


def email_stats(messages: list[EmailMessage]) -> dict:
    """Compute summary statistics for extracted emails."""
    senders: dict[str, int] = {}
    mailboxes: set[str] = set()

    for msg in messages:
        if msg.sender:
            # Extract just the email address from "Name <email>" format
            sender = msg.sender
            if "<" in sender and ">" in sender:
                sender = sender.split("<")[1].split(">")[0]
            # Get domain
            if "@" in sender:
                domain = sender.split("@")[1].lower()
                senders[domain] = senders.get(domain, 0) + 1
        if msg.mailbox:
            mailboxes.add(msg.mailbox)

    top_domains = sorted(senders.items(), key=lambda x: x[1], reverse=True)[:10]

    return {
        "total_messages": len(messages),
        "unread": sum(1 for m in messages if not m.is_read),
        "flagged": sum(1 for m in messages if m.is_flagged),
        "mailboxes": len(mailboxes),
        "top_sender_domains": [d for d, _ in top_domains],
    }


def frequent_contacts(messages: list[EmailMessage], limit: int = 50) -> dict[str, int]:
    """Count email frequency by sender address.

    Useful for cross-referencing with the contact graph to find
    people the user communicates with most.
    """
    counts: dict[str, int] = {}
    for msg in messages:
        sender = msg.sender
        if not sender:
            continue
        # Normalise "Name <email>" to just the email
        if "<" in sender and ">" in sender:
            sender = sender.split("<")[1].split(">")[0].lower()
        counts[sender] = counts.get(sender, 0) + 1

    sorted_contacts = sorted(counts.items(), key=lambda x: x[1], reverse=True)
    return dict(sorted_contacts[:limit])
