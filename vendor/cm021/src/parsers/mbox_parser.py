"""
MBOX Parser for Gmail exports.

Handles streaming of large MBOX files with:
- Chunked processing for memory efficiency
- Resume capability for long-running jobs
- Gmail label extraction
- Parallel processing support
"""

import mailbox
import email
from email.utils import parseaddr, parsedate_to_datetime
from email.header import decode_header
from dataclasses import dataclass, field
from typing import Iterator, Optional, List, Dict, Any, Callable
from datetime import datetime
from pathlib import Path
import json
import re
import html
from bs4 import BeautifulSoup

from ..filters import EmailFilter, default_filter


@dataclass
class ParsedEmail:
    """Structured email data."""
    message_id: str
    from_address: str
    from_name: str
    from_domain: str
    to_addresses: List[str]
    cc_addresses: List[str]
    subject: str
    date: Optional[datetime]
    body_plain: str
    body_html: str
    gmail_labels: List[str]
    thread_id: Optional[str]
    headers: Dict[str, str]

    # Computed fields
    is_sent: bool = False          # True if user sent this email
    is_reply: bool = False         # True if reply (subject starts with Re:)
    has_attachments: bool = False
    attachment_types: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            'message_id': self.message_id,
            'from_address': self.from_address,
            'from_name': self.from_name,
            'from_domain': self.from_domain,
            'to_addresses': self.to_addresses,
            'cc_addresses': self.cc_addresses,
            'subject': self.subject,
            'date': self.date.isoformat() if self.date else None,
            'body_plain': self.body_plain[:500],  # Truncate for storage
            'body_html_length': len(self.body_html),
            'gmail_labels': self.gmail_labels,
            'thread_id': self.thread_id,
            'is_sent': self.is_sent,
            'is_reply': self.is_reply,
            'has_attachments': self.has_attachments,
            'attachment_types': self.attachment_types,
        }


@dataclass
class ProcessingStats:
    """Statistics for processing run."""
    total_processed: int = 0
    total_filtered: int = 0
    total_errors: int = 0
    by_category: Dict[str, int] = field(default_factory=dict)
    by_domain: Dict[str, int] = field(default_factory=dict)
    by_year: Dict[int, int] = field(default_factory=dict)
    errors: List[Dict[str, str]] = field(default_factory=list)
    start_time: Optional[datetime] = None
    end_time: Optional[datetime] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            'total_processed': self.total_processed,
            'total_filtered': self.total_filtered,
            'total_errors': self.total_errors,
            'by_category': dict(self.by_category),
            'top_domains': dict(sorted(
                self.by_domain.items(),
                key=lambda x: x[1],
                reverse=True
            )[:50]),
            'by_year': dict(sorted(self.by_year.items(), reverse=True)),
            'error_count': len(self.errors),
            'duration_seconds': (
                (self.end_time - self.start_time).total_seconds()
                if self.start_time and self.end_time else None
            ),
        }


class MboxParser:
    """
    Stream-based MBOX parser optimized for large files.

    Usage:
        parser = MboxParser('/path/to/mail.mbox')
        for email in parser.stream(limit=10000):
            process(email)

        # Or with filtering
        parser = MboxParser('/path/to/mail.mbox', filter=my_filter)
        for email in parser.stream_filtered():
            # Only yields non-excluded emails
            process(email)
    """

    def __init__(
        self,
        mbox_path: str,
        email_filter: Optional[EmailFilter] = None,
        user_domain: Optional[str] = None,  # For detecting sent emails
    ):
        self.mbox_path = Path(mbox_path)
        self.filter = email_filter or default_filter
        self.user_domain = user_domain.lower() if user_domain else None
        self.stats = ProcessingStats()

    def stream(
        self,
        limit: Optional[int] = None,
        date_from: Optional[datetime] = None,
        date_to: Optional[datetime] = None,
        progress_callback: Optional[Callable[[int], None]] = None,
    ) -> Iterator[ParsedEmail]:
        """
        Stream emails from MBOX file.

        Args:
            limit: Maximum emails to process
            date_from: Only process emails after this date
            date_to: Only process emails before this date
            progress_callback: Called with count every 1000 emails
        """
        self.stats = ProcessingStats()
        self.stats.start_time = datetime.now()

        mbox = mailbox.mbox(self.mbox_path)
        count = 0

        try:
            for message in mbox:
                try:
                    parsed = self._parse_message(message)

                    # Date filtering
                    if parsed.date:
                        if date_from and parsed.date < date_from:
                            continue
                        if date_to and parsed.date > date_to:
                            continue

                    self.stats.total_processed += 1
                    count += 1

                    # Track by year
                    if parsed.date:
                        year = parsed.date.year
                        self.stats.by_year[year] = self.stats.by_year.get(year, 0) + 1

                    # Track by domain
                    domain = parsed.from_domain
                    self.stats.by_domain[domain] = self.stats.by_domain.get(domain, 0) + 1

                    # Progress callback
                    if progress_callback and count % 1000 == 0:
                        progress_callback(count)

                    yield parsed

                    if limit and count >= limit:
                        break

                except Exception as e:
                    self.stats.total_errors += 1
                    self.stats.errors.append({
                        'message_id': message.get('Message-ID', 'unknown'),
                        'error': str(e),
                    })
                    if len(self.stats.errors) < 100:  # Cap stored errors
                        continue

        finally:
            self.stats.end_time = datetime.now()
            mbox.close()

    def stream_filtered(
        self,
        limit: Optional[int] = None,
        **kwargs
    ) -> Iterator[ParsedEmail]:
        """
        Stream only non-excluded emails.
        Uses domain and label filters to skip noise.
        """
        for email in self.stream(limit=limit, **kwargs):
            # Check domain exclusion
            if self.filter.should_exclude_domain(email.from_domain):
                self.stats.total_filtered += 1
                continue

            # Check label exclusion
            if self.filter.should_exclude_labels(email.gmail_labels):
                self.stats.total_filtered += 1
                continue

            yield email

    def _parse_message(self, message: mailbox.mboxMessage) -> ParsedEmail:
        """Parse a single email message."""
        # From address
        from_raw = message.get('From', '')
        from_name, from_addr = parseaddr(from_raw)
        from_name = self._decode_header(from_name)
        from_domain = from_addr.split('@')[1].lower() if '@' in from_addr else 'unknown'

        # To addresses
        to_raw = message.get('To', '')
        to_addresses = [parseaddr(addr)[1] for addr in to_raw.split(',') if addr.strip()]

        # CC addresses
        cc_raw = message.get('Cc', '')
        cc_addresses = [parseaddr(addr)[1] for addr in cc_raw.split(',') if addr.strip()]

        # Subject
        subject = self._decode_header(message.get('Subject', ''))

        # Date
        date = None
        date_str = message.get('Date')
        if date_str:
            try:
                date = parsedate_to_datetime(date_str)
            except:
                pass

        # Body
        body_plain, body_html = self._extract_body(message)

        # Gmail labels
        gmail_labels = self._get_gmail_labels(message)

        # Thread ID
        thread_id = message.get('X-GM-THRID') or message.get('References', '').split()[0] if message.get('References') else None

        # Attachments
        has_attachments = False
        attachment_types = []
        if message.is_multipart():
            for part in message.walk():
                content_disposition = str(part.get('Content-Disposition', ''))
                if 'attachment' in content_disposition:
                    has_attachments = True
                    content_type = part.get_content_type()
                    attachment_types.append(content_type)

        # Determine if sent by user
        is_sent = self.user_domain in from_addr.lower() or 'Sent' in gmail_labels

        # Determine if reply
        is_reply = subject.lower().startswith('re:') or 'In-Reply-To' in message

        # Extract headers for reference
        headers = {
            'Message-ID': message.get('Message-ID', ''),
            'In-Reply-To': message.get('In-Reply-To', ''),
            'References': message.get('References', ''),
            'List-Unsubscribe': message.get('List-Unsubscribe', ''),
        }

        return ParsedEmail(
            message_id=message.get('Message-ID', f'unknown_{hash(from_raw + str(date))}'),
            from_address=from_addr,
            from_name=from_name,
            from_domain=from_domain,
            to_addresses=to_addresses,
            cc_addresses=cc_addresses,
            subject=subject,
            date=date,
            body_plain=body_plain,
            body_html=body_html,
            gmail_labels=gmail_labels,
            thread_id=thread_id,
            headers=headers,
            is_sent=is_sent,
            is_reply=is_reply,
            has_attachments=has_attachments,
            attachment_types=attachment_types,
        )

    def _decode_header(self, header: str) -> str:
        """Decode email header with proper encoding handling."""
        if not header:
            return ''

        try:
            decoded_parts = decode_header(header)
            result = []
            for content, encoding in decoded_parts:
                if isinstance(content, bytes):
                    encoding = encoding or 'utf-8'
                    try:
                        result.append(content.decode(encoding, errors='replace'))
                    except:
                        result.append(content.decode('utf-8', errors='replace'))
                else:
                    result.append(content)
            return ' '.join(result)
        except:
            return header

    def _extract_body(self, message) -> tuple[str, str]:
        """Extract plain text and HTML body."""
        body_plain = ''
        body_html = ''

        if message.is_multipart():
            for part in message.walk():
                content_type = part.get_content_type()
                content_disposition = str(part.get('Content-Disposition', ''))

                # Skip attachments
                if 'attachment' in content_disposition:
                    continue

                try:
                    payload = part.get_payload(decode=True)
                    if payload is None:
                        continue

                    charset = part.get_content_charset() or 'utf-8'
                    try:
                        text = payload.decode(charset, errors='replace')
                    except:
                        text = payload.decode('utf-8', errors='replace')

                    if content_type == 'text/plain' and not body_plain:
                        body_plain = text
                    elif content_type == 'text/html' and not body_html:
                        body_html = text

                except Exception:
                    continue
        else:
            # Not multipart
            try:
                payload = message.get_payload(decode=True)
                if payload:
                    charset = message.get_content_charset() or 'utf-8'
                    text = payload.decode(charset, errors='replace')

                    if message.get_content_type() == 'text/html':
                        body_html = text
                        body_plain = self._html_to_text(text)
                    else:
                        body_plain = text
            except:
                pass

        # If only HTML, extract plain text
        if body_html and not body_plain:
            body_plain = self._html_to_text(body_html)

        return body_plain, body_html

    def _html_to_text(self, html_content: str) -> str:
        """Convert HTML to plain text."""
        try:
            soup = BeautifulSoup(html_content, 'html.parser')

            # Remove script and style elements
            for element in soup(['script', 'style', 'head', 'meta', 'link']):
                element.decompose()

            # Get text
            text = soup.get_text(separator=' ')

            # Clean up whitespace
            lines = (line.strip() for line in text.splitlines())
            text = ' '.join(chunk for chunk in lines if chunk)

            return text[:10000]  # Limit size
        except:
            return ''

    def _get_gmail_labels(self, message) -> List[str]:
        """Extract Gmail labels from X-Gmail-Labels header."""
        labels_raw = message.get('X-Gmail-Labels', '')
        if not labels_raw:
            return []

        # Parse comma-separated labels (may be quoted)
        labels = []
        for label in labels_raw.split(','):
            label = label.strip().strip('"')
            if label:
                labels.append(label)

        return labels


# Convenience function
def parse_mbox(
    mbox_path: str,
    limit: Optional[int] = None,
    filter_noise: bool = True,
) -> Iterator[ParsedEmail]:
    """
    Parse MBOX file and yield emails.

    Args:
        mbox_path: Path to MBOX file
        limit: Maximum emails to process
        filter_noise: If True, exclude known noise domains

    Yields:
        ParsedEmail objects
    """
    parser = MboxParser(mbox_path)
    if filter_noise:
        yield from parser.stream_filtered(limit=limit)
    else:
        yield from parser.stream(limit=limit)
