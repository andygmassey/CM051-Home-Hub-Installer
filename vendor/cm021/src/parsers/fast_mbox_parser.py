"""
Fast MBOX Parser using direct file streaming.

The Python mailbox library is too slow for very large files (40GB+)
because it builds an index first. This parser reads line-by-line
for streaming efficiency.
"""

import re
from dataclasses import dataclass, field
from typing import Iterator, Optional, List, Dict, Any, Callable
from datetime import datetime
from email.utils import parseaddr, parsedate_to_datetime
from email.header import decode_header
from pathlib import Path
import base64
import quopri

from ..filters import EmailFilter, default_filter


@dataclass
class FastEmail:
    """Lightweight email representation for fast parsing."""
    message_id: str
    from_address: str
    from_name: str
    from_domain: str
    to_addresses: List[str]
    subject: str
    date: Optional[datetime]
    body_text: str
    gmail_labels: List[str]
    headers: Dict[str, str]

    # Computed
    is_sent: bool = False
    is_reply: bool = False

    def to_dict(self) -> Dict[str, Any]:
        return {
            'message_id': self.message_id,
            'from_address': self.from_address,
            'from_name': self.from_name,
            'from_domain': self.from_domain,
            'to_addresses': self.to_addresses,
            'subject': self.subject,
            'date': self.date.isoformat() if self.date else None,
            'body_preview': self.body_text[:300],
            'gmail_labels': self.gmail_labels,
            'is_sent': self.is_sent,
            'is_reply': self.is_reply,
        }


@dataclass
class ParserStats:
    """Processing statistics."""
    total_read: int = 0
    total_filtered: int = 0
    total_errors: int = 0
    by_year: Dict[int, int] = field(default_factory=dict)
    by_domain: Dict[str, int] = field(default_factory=dict)
    by_label: Dict[str, int] = field(default_factory=dict)
    processing_time_seconds: float = 0.0


class FastMboxParser:
    """
    Fast streaming MBOX parser.

    Reads file directly without building an index.
    Much faster for very large files (40GB+).
    """

    def __init__(
        self,
        mbox_path: str,
        email_filter: Optional[EmailFilter] = None,
        user_domain: Optional[str] = None,
    ):
        self.mbox_path = Path(mbox_path)
        self.filter = email_filter or default_filter
        self.user_domain = user_domain.lower() if user_domain else None
        self.stats = ParserStats()

    def stream(
        self,
        limit: Optional[int] = None,
        progress_callback: Optional[Callable[[int], None]] = None,
    ) -> Iterator[FastEmail]:
        """
        Stream emails from MBOX.

        Args:
            limit: Maximum emails to yield
            progress_callback: Called with count every 1000 emails
        """
        import time
        start_time = time.time()

        self.stats = ParserStats()
        count = 0

        current_headers: Dict[str, str] = {}
        current_body_lines: List[str] = []
        in_headers = True
        header_buffer: List[str] = []

        with open(self.mbox_path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                # New email starts with "From " at beginning of line
                if line.startswith('From ') and (
                    len(line) > 5 and
                    not line.startswith('From:') and
                    '@' in line[:100]  # Likely "From user@domain date"
                ):
                    # Process previous email if we have headers
                    if current_headers:
                        try:
                            email = self._build_email(current_headers, current_body_lines)
                            self.stats.total_read += 1
                            count += 1

                            # Track stats
                            if email.date:
                                year = email.date.year
                                self.stats.by_year[year] = self.stats.by_year.get(year, 0) + 1
                            self.stats.by_domain[email.from_domain] = self.stats.by_domain.get(email.from_domain, 0) + 1
                            for label in email.gmail_labels:
                                self.stats.by_label[label] = self.stats.by_label.get(label, 0) + 1

                            # Progress callback
                            if progress_callback and count % 1000 == 0:
                                progress_callback(count)

                            yield email

                            if limit and count >= limit:
                                break

                        except Exception as e:
                            self.stats.total_errors += 1

                    # Reset for new email
                    current_headers = {}
                    current_body_lines = []
                    in_headers = True
                    header_buffer = []
                    continue

                if in_headers:
                    if line.strip() == '':
                        # End of headers
                        in_headers = False
                        self._parse_headers(header_buffer, current_headers)
                    else:
                        header_buffer.append(line)
                else:
                    # Body line
                    current_body_lines.append(line)

        # Process last email
        if current_headers and (not limit or count < limit):
            try:
                email = self._build_email(current_headers, current_body_lines)
                self.stats.total_read += 1
                yield email
            except:
                self.stats.total_errors += 1

        self.stats.processing_time_seconds = time.time() - start_time

    def stream_filtered(
        self,
        limit: Optional[int] = None,
        **kwargs
    ) -> Iterator[FastEmail]:
        """Stream with noise filtering applied."""
        yielded = 0
        for email in self.stream(limit=None, **kwargs):
            # Check domain exclusion
            if self.filter.should_exclude_domain(email.from_domain):
                self.stats.total_filtered += 1
                continue

            # Check label exclusion
            if self.filter.should_exclude_labels(email.gmail_labels):
                self.stats.total_filtered += 1
                continue

            yield email
            yielded += 1

            if limit and yielded >= limit:
                break

    def _parse_headers(self, lines: List[str], headers: Dict[str, str]):
        """Parse email headers from lines."""
        current_key = None
        current_value = []

        for line in lines:
            if line.startswith((' ', '\t')) and current_key:
                # Continuation of previous header
                current_value.append(line.strip())
            elif ':' in line:
                # Save previous header
                if current_key:
                    headers[current_key] = ' '.join(current_value)

                # Start new header
                key, _, value = line.partition(':')
                current_key = key.strip()
                current_value = [value.strip()]

        # Save last header
        if current_key:
            headers[current_key] = ' '.join(current_value)

    def _build_email(
        self,
        headers: Dict[str, str],
        body_lines: List[str]
    ) -> FastEmail:
        """Build FastEmail from parsed data."""
        # From
        from_raw = headers.get('From', '')
        from_name, from_addr = parseaddr(from_raw)
        from_name = self._decode_header_value(from_name)
        from_domain = from_addr.split('@')[1].lower() if '@' in from_addr else 'unknown'

        # To
        to_raw = headers.get('To', '')
        to_addresses = [parseaddr(a)[1] for a in to_raw.split(',') if a.strip()]

        # Subject
        subject = self._decode_header_value(headers.get('Subject', ''))

        # Date
        date = None
        date_str = headers.get('Date', '')
        if date_str:
            try:
                date = parsedate_to_datetime(date_str)
            except:
                pass

        # Gmail labels
        labels_raw = headers.get('X-Gmail-Labels', '')
        gmail_labels = []
        if labels_raw:
            for label in labels_raw.split(','):
                label = label.strip().strip('"')
                if label:
                    gmail_labels.append(label)

        # Body (simplified - just text extraction)
        body_text = self._extract_body_text(body_lines, headers)

        # Sent by user?
        is_sent = (self.user_domain and self.user_domain in from_addr.lower()) or 'Sent' in gmail_labels

        # Reply?
        is_reply = subject.lower().startswith('re:') or 'In-Reply-To' in headers

        return FastEmail(
            message_id=headers.get('Message-ID', f'unknown_{hash(from_raw)}'),
            from_address=from_addr,
            from_name=from_name,
            from_domain=from_domain,
            to_addresses=to_addresses,
            subject=subject,
            date=date,
            body_text=body_text,
            gmail_labels=gmail_labels,
            headers=headers,
            is_sent=is_sent,
            is_reply=is_reply,
        )

    def _decode_header_value(self, value: str) -> str:
        """Decode encoded header value."""
        if not value:
            return ''

        # Check for RFC 2047 encoding
        if '=?' in value:
            try:
                decoded_parts = decode_header(value)
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
                pass

        return value

    def _extract_body_text(self, body_lines: List[str], headers: Dict[str, str]) -> str:
        """Extract readable text from body."""
        # Join body
        body = ''.join(body_lines)

        # Check content type
        content_type = headers.get('Content-Type', '').lower()
        transfer_encoding = headers.get('Content-Transfer-Encoding', '').lower()

        # Handle encoding
        if 'base64' in transfer_encoding:
            try:
                # Find base64 content
                lines = [l for l in body.split('\n') if l.strip() and not l.startswith('--')]
                encoded = ''.join(lines)
                decoded = base64.b64decode(encoded).decode('utf-8', errors='replace')
                body = decoded
            except:
                pass
        elif 'quoted-printable' in transfer_encoding:
            try:
                body = quopri.decodestring(body.encode()).decode('utf-8', errors='replace')
            except:
                pass

        # If HTML, try to extract text
        if 'text/html' in content_type:
            body = self._html_to_text(body)

        # Clean up
        body = re.sub(r'\s+', ' ', body)  # Collapse whitespace
        body = body[:5000]  # Limit size

        return body.strip()

    def _html_to_text(self, html: str) -> str:
        """Simple HTML to text conversion."""
        # Remove script/style
        html = re.sub(r'<script[^>]*>.*?</script>', '', html, flags=re.DOTALL | re.IGNORECASE)
        html = re.sub(r'<style[^>]*>.*?</style>', '', html, flags=re.DOTALL | re.IGNORECASE)

        # Remove tags
        html = re.sub(r'<[^>]+>', ' ', html)

        # Decode entities
        html = html.replace('&nbsp;', ' ')
        html = html.replace('&amp;', '&')
        html = html.replace('&lt;', '<')
        html = html.replace('&gt;', '>')
        html = html.replace('&quot;', '"')

        return html


def fast_parse(
    mbox_path: str,
    limit: Optional[int] = None,
    filter_noise: bool = True,
    progress_callback: Optional[Callable[[int], None]] = None,
) -> Iterator[FastEmail]:
    """
    Convenience function to parse MBOX quickly.

    Args:
        mbox_path: Path to MBOX file
        limit: Maximum emails to yield
        filter_noise: If True, exclude known noise domains
        progress_callback: Called every 1000 emails with count
    """
    parser = FastMboxParser(mbox_path)
    if filter_noise:
        yield from parser.stream_filtered(limit=limit, progress_callback=progress_callback)
    else:
        yield from parser.stream(limit=limit, progress_callback=progress_callback)
