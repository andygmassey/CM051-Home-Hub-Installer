"""Read individual email messages from the macOS Apple Mail store.

Apple Mail keeps each message as an ``.emlx`` file nested several
directories deep under ``~/Library/Mail``. Reading that tree requires
Full Disk Access (FDA) on macOS Sequoia+, which the Ostler installer
grants at setup time.

This reader reuses the low-level primitives from
``ostler_fda.apple_mail_mbox`` (``discover_emlx_files`` and
``parse_emlx``) so the Hub has exactly one Apple Mail parser. On top
of those primitives it parses the RFC 822 headers and body with the
standard-library ``email`` package, producing a flat list of
``EmailMessage`` records that the threader segments into conversation
threads.

No real-person data is hard-coded here. A ``mail_dir`` argument is
injectable so tests run against a synthetic ``.emlx`` fixture tree
with no real names / addresses.
"""
from __future__ import annotations

import email
import logging
import quopri
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from email.header import decode_header
from email.message import Message as PyMessage
from email.utils import getaddresses, parsedate_to_datetime
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


def _default_mail_dir() -> Path:
    """Resolve the Apple Mail root.

    Mirrors ``ostler_fda.apple_mail_mbox.default_mail_dir`` so the
    conversation feed and the facts feed read the same tree: honour
    ``OSTLER_MAIL_DIR`` first, then ``~/Library/Mail``.
    """
    import os

    override = os.getenv("OSTLER_MAIL_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Mail"


@dataclass
class EmailMessage:
    """A single email after RFC 822 parsing."""

    message_id: str          # angle-stripped Message-Id (stable key)
    in_reply_to: Optional[str]
    references: list[str] = field(default_factory=list)
    subject: str = ""
    from_name: str = ""
    from_address: str = ""
    to_addresses: list[tuple[str, str]] = field(default_factory=list)  # (name, addr)
    cc_addresses: list[tuple[str, str]] = field(default_factory=list)
    timestamp: Optional[datetime] = None
    body: str = ""
    source_path: Optional[Path] = None


def _decode(value: object) -> str:
    """Decode an RFC 2047 encoded-word header value to plain text.

    ``value`` may be a plain ``str`` OR an ``email.header.Header`` -- the stdlib
    email parser hands back Header objects for some fields. Coerce to ``str``
    first: a Header is not iterable, so the ``"=?" in`` membership test below
    would otherwise raise ``TypeError: argument of type 'Header' is not
    iterable`` and crash every email-source run (starving email conversations
    and email last-contact).
    """
    if value is None:
        return ""
    value = str(value)
    if not value:
        return ""
    if "=?" not in value:
        return value
    try:
        parts = decode_header(value)
        out: list[str] = []
        for content, enc in parts:
            if isinstance(content, bytes):
                out.append(content.decode(enc or "utf-8", errors="replace"))
            else:
                out.append(content)
        return " ".join(out)
    except Exception:  # pragma: no cover -- defensive
        return value


def _strip_angles(value: Optional[str]) -> str:
    return (value or "").strip().strip("<>").strip()


def _references(value: Optional[str]) -> list[str]:
    """Parse a References / In-Reply-To header into angle-stripped ids."""
    if not value:
        return []
    return [
        _strip_angles(tok)
        for tok in re.findall(r"<[^>]+>", value)
        if _strip_angles(tok)
    ]


_HTML_TAG_RE = re.compile(r"<[^>]+>")
_HTML_BR_RE = re.compile(r"<br\s*/?>", re.IGNORECASE)
_HTML_BLOCK_RE = re.compile(r"</?(p|div)[^>]*>", re.IGNORECASE)
_HTML_DROP_RE = re.compile(
    r"<(script|style)[^>]*>.*?</\1>", re.DOTALL | re.IGNORECASE
)


def _html_to_text(html: str) -> str:
    html = _HTML_DROP_RE.sub("", html)
    html = _HTML_BR_RE.sub("\n", html)
    html = _HTML_BLOCK_RE.sub("\n", html)
    html = _HTML_TAG_RE.sub("", html)
    html = (
        html.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", '"')
    )
    return html


def _decode_part_payload(part: PyMessage) -> str:
    """Decode one MIME part's payload to text, honouring its encoding."""
    payload = part.get_payload(decode=True)
    if payload is None:
        # Not a leaf with bytes; fall back to the raw string payload.
        raw = part.get_payload()
        return raw if isinstance(raw, str) else ""
    charset = part.get_content_charset() or "utf-8"
    try:
        return payload.decode(charset, errors="replace")
    except (LookupError, UnicodeDecodeError):
        return payload.decode("utf-8", errors="replace")


def _extract_body(msg: PyMessage) -> str:
    """Pull a plain-text body out of an email message.

    Prefers ``text/plain``; falls back to a flattened ``text/html``.
    Skips attachments. Caps line count so a runaway HTML newsletter
    does not blow up the transcript.
    """
    plain: Optional[str] = None
    html: Optional[str] = None
    if msg.is_multipart():
        for part in msg.walk():
            if part.is_multipart():
                continue
            disposition = (part.get("Content-Disposition") or "").lower()
            if "attachment" in disposition:
                continue
            ctype = part.get_content_type()
            if ctype == "text/plain" and plain is None:
                plain = _decode_part_payload(part)
            elif ctype == "text/html" and html is None:
                html = _decode_part_payload(part)
    else:
        ctype = msg.get_content_type()
        text = _decode_part_payload(msg)
        # Single-part messages may still be quoted-printable html.
        if "quoted-printable" in (
            (msg.get("Content-Transfer-Encoding") or "").lower()
        ) and msg.get_payload(decode=True) is None:
            try:
                text = quopri.decodestring(text.encode()).decode(
                    "utf-8", errors="replace"
                )
            except Exception:  # pragma: no cover -- defensive
                pass
        if ctype == "text/html":
            html = text
        else:
            plain = text

    body = plain if plain is not None else (
        _html_to_text(html) if html is not None else ""
    )
    lines = body.replace("\r\n", "\n").split("\n")
    if len(lines) > 500:
        lines = lines[:500]
    return "\n".join(line.rstrip() for line in lines).strip()


def _parse_one(rfc822_bytes: bytes, source_path: Optional[Path]) -> Optional[EmailMessage]:
    """Parse RFC 822 bytes into an ``EmailMessage`` (or ``None`` if no id)."""
    try:
        msg = email.message_from_bytes(rfc822_bytes)
    except Exception as exc:  # pragma: no cover -- defensive
        logger.warning("Could not parse message %s: %s", source_path, exc)
        return None

    message_id = _strip_angles(msg.get("Message-Id") or msg.get("Message-ID"))
    if not message_id:
        # Without a Message-Id we cannot thread reliably; synthesise a
        # stable one from the source path so the message still threads
        # as a singleton rather than being silently dropped.
        message_id = (
            f"no-id-{source_path.name}" if source_path else "no-id-unknown"
        )

    from_pairs = getaddresses([msg.get("From", "")])
    from_name, from_address = ("", "")
    if from_pairs:
        from_name = _decode(from_pairs[0][0])
        from_address = from_pairs[0][1].strip().lower()

    to_addresses = [
        (_decode(name), addr.strip().lower())
        for name, addr in getaddresses(msg.get_all("To", []))
        if addr.strip()
    ]
    cc_addresses = [
        (_decode(name), addr.strip().lower())
        for name, addr in getaddresses(msg.get_all("Cc", []))
        if addr.strip()
    ]

    timestamp: Optional[datetime] = None
    date_hdr = msg.get("Date")
    if date_hdr:
        try:
            timestamp = parsedate_to_datetime(date_hdr)
            if timestamp is not None and timestamp.tzinfo is None:
                timestamp = timestamp.replace(tzinfo=timezone.utc)
        except (TypeError, ValueError):
            timestamp = None

    return EmailMessage(
        message_id=message_id,
        in_reply_to=(_references(msg.get("In-Reply-To")) or [None])[0],
        references=_references(msg.get("References")),
        subject=_decode(msg.get("Subject", "")),
        from_name=from_name,
        from_address=from_address,
        to_addresses=to_addresses,
        cc_addresses=cc_addresses,
        timestamp=timestamp,
        body=_extract_body(msg),
        source_path=source_path,
    )


def read_messages(
    mail_dir: Optional[Path] = None,
    since_days: int = 365,
    now: Optional[datetime] = None,
) -> list[EmailMessage]:
    """Read Apple Mail ``.emlx`` files into a flat ``EmailMessage`` list.

    Args:
        mail_dir: Apple Mail root (injectable for tests). Defaults to
            ``OSTLER_MAIL_DIR`` or ``~/Library/Mail``.
        since_days: only messages received within the last N days
            (``0`` disables the cutoff). The fresh-install clamp.
        now: override for "now" (tests).

    Raises:
        PermissionError: if the Mail tree exists but FDA is denied.
    """
    from ostler_fda.apple_mail_mbox import discover_emlx_files, parse_emlx

    mail_dir = mail_dir or _default_mail_dir()
    now = now or datetime.now(tz=timezone.utc)
    cutoff = None
    if since_days:
        cutoff = now.timestamp() - (since_days * 86400)

    out: list[EmailMessage] = []
    for emlx_path in discover_emlx_files(mail_dir):
        try:
            parsed = parse_emlx(emlx_path)
        except PermissionError:
            raise PermissionError(
                "Cannot read Apple Mail messages. Grant Full Disk "
                "Access to the Ostler Hub in System Settings > Privacy "
                "& Security > Full Disk Access."
            )
        except (ValueError, OSError) as exc:
            logger.warning("Skipping unreadable .emlx %s: %s", emlx_path, exc)
            continue

        if (
            cutoff is not None
            and parsed.received_at is not None
            and parsed.received_at.timestamp() < cutoff
        ):
            continue

        message = _parse_one(parsed.rfc822_bytes, emlx_path)
        if message is None:
            continue
        # parse_emlx already resolved received_at (Date header or mtime);
        # prefer the body-parsed Date but fall back so ordering holds.
        if message.timestamp is None:
            message.timestamp = parsed.received_at
        out.append(message)

    logger.info("Read %d email messages from %s", len(out), mail_dir)
    return out
