"""Google Takeout (Gmail mbox) extractor.

Reads Gmail mbox files exported via Google Takeout
(https://takeout.google.com). Treats the file as the structural moat
vs Poke / Granola: full Gmail content with zero Google API surface,
no OAuth, no CASA audit, no sub-processor. The user downloads the
archive themselves and points Ostler at it (or drops it in
~/Downloads – the installer auto-detects).

This module is policy-aware: it is gated behind the user's per-source
consent in the install picker (OSTLER_FDA_SOURCES contains
"google_takeout"). See `extract_all.py` for the wiring.

Approach
--------
A real Gmail Takeout archive is one or more zip files like
`takeout-20260113T064626Z-1-001.zip`. Unzipped, the layout is:

    Takeout/
        Mail/
            All mail Including Spam and Trash.mbox
            ...
        Calendar/
        Contacts/
        ...

For mbox parsing we use Python's built-in `mailbox` library. CM021's
`FastMboxParser` is faster on 40 GB+ files but Takeout archives are
typically 1-5 GB; the standard library is plenty fast at that size
and avoids vendoring a non-trivial dependency.
"""
from __future__ import annotations

import email
import logging
import mailbox
import re
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from email.header import decode_header
from email.utils import parseaddr, parsedate_to_datetime
from pathlib import Path
from typing import Iterable, Iterator, Optional

logger = logging.getLogger(__name__)


TAKEOUT_ZIP_PATTERN = re.compile(r"^takeout-\d{8}T\d{6}Z(-\d+)*\.zip$", re.IGNORECASE)
DEFAULT_SEARCH_DIRS = (
    Path.home() / "Downloads",
    Path.home() / "Desktop",
    Path.home() / "Documents",
)
DEFAULT_BODY_PREVIEW_CHARS = 500


@dataclass
class TakeoutMessage:
    """One Gmail message extracted from a Takeout mbox."""
    message_id: str
    from_address: str
    from_name: str
    from_domain: str
    to_addresses: list[str]
    subject: str
    date: Optional[datetime]
    body_preview: str
    gmail_labels: list[str]
    is_sent: bool = False


@dataclass
class TakeoutSummary:
    """Aggregate stats for a parsed mbox."""
    total_messages: int = 0
    by_year: dict[int, int] = field(default_factory=dict)
    top_sender_domains: list[tuple[str, int]] = field(default_factory=list)
    top_senders: list[tuple[str, int]] = field(default_factory=list)
    gmail_labels: dict[str, int] = field(default_factory=dict)
    sent_count: int = 0
    received_count: int = 0


def find_takeout_zips(search_dirs: Iterable[Path] = DEFAULT_SEARCH_DIRS) -> list[Path]:
    """Return paths to Google Takeout zip archives found in the given dirs.

    A Takeout zip is named `takeout-YYYYMMDDTHHMMSSZ-N-NNN.zip`.
    """
    found: list[Path] = []
    for d in search_dirs:
        if not d.exists() or not d.is_dir():
            continue
        for entry in d.iterdir():
            if entry.is_file() and TAKEOUT_ZIP_PATTERN.match(entry.name):
                found.append(entry)
    return sorted(found)


def find_mbox_files(search_dirs: Iterable[Path] = DEFAULT_SEARCH_DIRS) -> list[Path]:
    """Return paths to .mbox files found in the given dirs (recursive,
    capped at 4 levels to avoid pathological filesystems).
    """
    found: list[Path] = []
    for d in search_dirs:
        if not d.exists() or not d.is_dir():
            continue
        for path in d.rglob("*.mbox"):
            # Cap recursion depth manually
            try:
                depth = len(path.relative_to(d).parts)
            except ValueError:
                continue
            if depth > 4:
                continue
            if path.is_file():
                found.append(path)
    return sorted(found)


def extract_mbox_from_zip(zip_path: Path, dest_dir: Path) -> Optional[Path]:
    """Extract the Gmail mbox file from a Takeout zip into dest_dir.
    Returns the path to the extracted mbox, or None if no mbox is present
    inside the archive (Takeout archive may be Calendar-only etc.).
    """
    dest_dir.mkdir(parents=True, exist_ok=True)
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            mbox_members = [m for m in zf.namelist() if m.lower().endswith(".mbox")]
            if not mbox_members:
                return None
            # Take the first mbox; Gmail Takeout typically has exactly one.
            member = mbox_members[0]
            extracted = zf.extract(member, dest_dir)
            return Path(extracted)
    except zipfile.BadZipFile as e:
        logger.warning("Bad Takeout zip %s: %s", zip_path, e)
        return None


def _decode_header_value(value: str) -> str:
    """Decode RFC 2047 encoded-word headers. Returns plain text."""
    if not value:
        return ""
    try:
        parts = decode_header(value)
    except Exception:
        return value
    decoded_parts = []
    for chunk, charset in parts:
        if isinstance(chunk, bytes):
            try:
                decoded_parts.append(chunk.decode(charset or "utf-8", errors="replace"))
            except (LookupError, TypeError):
                decoded_parts.append(chunk.decode("utf-8", errors="replace"))
        else:
            decoded_parts.append(chunk)
    return "".join(decoded_parts).strip()


def _extract_body_preview(msg: email.message.Message, max_chars: int) -> str:
    """Pull the first text/plain part as a short preview. Falls back to
    text/html with tags stripped if no plain part is present.
    """
    if msg.is_multipart():
        for part in msg.walk():
            if part.is_multipart():
                continue
            ctype = part.get_content_type()
            if ctype == "text/plain":
                payload = part.get_payload(decode=True)
                if payload:
                    text = payload.decode(part.get_content_charset() or "utf-8", errors="replace")
                    return text.strip()[:max_chars]
        # No plain part – fall back to first text/html stripped
        for part in msg.walk():
            if part.get_content_type() == "text/html":
                payload = part.get_payload(decode=True)
                if payload:
                    raw = payload.decode(part.get_content_charset() or "utf-8", errors="replace")
                    stripped = re.sub(r"<[^>]+>", "", raw)
                    return re.sub(r"\s+", " ", stripped).strip()[:max_chars]
        return ""
    # Not multipart
    payload = msg.get_payload(decode=True)
    if not payload:
        return ""
    text = payload.decode(msg.get_content_charset() or "utf-8", errors="replace")
    if msg.get_content_type() == "text/html":
        text = re.sub(r"<[^>]+>", "", text)
        text = re.sub(r"\s+", " ", text)
    return text.strip()[:max_chars]


def _build_message(
    msg: email.message.Message,
    user_email: Optional[str] = None,
    body_preview_chars: int = DEFAULT_BODY_PREVIEW_CHARS,
) -> TakeoutMessage:
    """Convert a python email.message.Message into a TakeoutMessage."""
    from_raw = msg.get("From", "")
    from_name_raw, from_addr = parseaddr(from_raw)
    from_name = _decode_header_value(from_name_raw)
    from_addr = from_addr.lower()
    from_domain = from_addr.split("@", 1)[1] if "@" in from_addr else "unknown"

    to_raw = msg.get("To", "")
    to_addresses = [parseaddr(a)[1].lower() for a in to_raw.split(",") if a.strip()]

    subject = _decode_header_value(msg.get("Subject", ""))

    date_obj: Optional[datetime] = None
    date_str = msg.get("Date", "")
    if date_str:
        try:
            date_obj = parsedate_to_datetime(date_str)
        except (TypeError, ValueError):
            date_obj = None

    labels_raw = msg.get("X-Gmail-Labels", "")
    gmail_labels: list[str] = []
    if labels_raw:
        for label in labels_raw.split(","):
            label = label.strip().strip('"').strip("'")
            if label:
                gmail_labels.append(label)

    is_sent = bool(user_email) and from_addr == user_email.lower()
    if not is_sent and "Sent" in gmail_labels:
        is_sent = True

    body_preview = _extract_body_preview(msg, body_preview_chars)

    return TakeoutMessage(
        message_id=msg.get("Message-ID", "").strip("<>"),
        from_address=from_addr,
        from_name=from_name,
        from_domain=from_domain,
        to_addresses=to_addresses,
        subject=subject,
        date=date_obj,
        body_preview=body_preview,
        gmail_labels=gmail_labels,
        is_sent=is_sent,
    )


def stream_messages(
    mbox_path: Path,
    since_days: Optional[int] = None,
    limit: Optional[int] = None,
    user_email: Optional[str] = None,
    body_preview_chars: int = DEFAULT_BODY_PREVIEW_CHARS,
) -> Iterator[TakeoutMessage]:
    """Yield TakeoutMessage objects from an mbox file.

    Args:
        mbox_path: Path to the .mbox file.
        since_days: Only yield messages newer than this many days.
            None = no date filter.
        limit: Max messages to yield. None = unlimited.
        user_email: User's own email address – used to mark sent items
            even when the X-Gmail-Labels header doesn't include 'Sent'.
        body_preview_chars: How much of the body to keep as a preview.
    """
    if not mbox_path.exists():
        raise FileNotFoundError(mbox_path)

    cutoff: Optional[datetime] = None
    if since_days is not None:
        cutoff = datetime.now(timezone.utc) - _timedelta(since_days)

    yielded = 0
    box = mailbox.mbox(str(mbox_path), create=False)
    try:
        for raw in box:
            try:
                tm = _build_message(raw, user_email=user_email, body_preview_chars=body_preview_chars)
            except Exception as e:
                logger.debug("Skipping unparseable mbox message: %s", e)
                continue

            if cutoff is not None and tm.date is not None:
                # Coerce naive datetimes to UTC for comparison
                d = tm.date if tm.date.tzinfo else tm.date.replace(tzinfo=timezone.utc)
                if d < cutoff:
                    continue

            yield tm
            yielded += 1
            if limit is not None and yielded >= limit:
                break
    finally:
        box.close()


def summarise(messages: Iterable[TakeoutMessage], top_n: int = 20) -> TakeoutSummary:
    """Aggregate stats over a list/iterable of TakeoutMessage."""
    summary = TakeoutSummary()
    sender_addr_counts: dict[str, int] = {}
    sender_domain_counts: dict[str, int] = {}

    for m in messages:
        summary.total_messages += 1
        if m.is_sent:
            summary.sent_count += 1
        else:
            summary.received_count += 1

        if m.date is not None:
            year = m.date.year
            summary.by_year[year] = summary.by_year.get(year, 0) + 1

        if m.from_address:
            sender_addr_counts[m.from_address] = sender_addr_counts.get(m.from_address, 0) + 1
        if m.from_domain:
            sender_domain_counts[m.from_domain] = sender_domain_counts.get(m.from_domain, 0) + 1

        for label in m.gmail_labels:
            summary.gmail_labels[label] = summary.gmail_labels.get(label, 0) + 1

    summary.top_senders = sorted(sender_addr_counts.items(), key=lambda kv: -kv[1])[:top_n]
    summary.top_sender_domains = sorted(sender_domain_counts.items(), key=lambda kv: -kv[1])[:top_n]
    return summary


def _timedelta(days: int):
    """Local helper to avoid importing timedelta at module top
    (reads better at the call site)."""
    from datetime import timedelta
    return timedelta(days=days)
