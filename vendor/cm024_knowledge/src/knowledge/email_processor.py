"""
Email Processor - Extracts correspondence emails for knowledge extraction.

Supports multiple formats:
- MBOX (Gmail exports)
- EML files (iCloud Mail exports, standard format)

Filters for personal correspondence (not marketing/newsletters) and
groups into threads for LLM summarization.

Usage:
    processor = EmailProcessor()

    # Auto-detect format
    threads = processor.process("path/to/mail.mbox", limit=1000)
    threads = processor.process("path/to/eml_folder/", limit=1000)

    # Or specify format explicitly
    threads = processor.process_mbox("path/to/mail.mbox")
    threads = processor.process_eml_directory("path/to/eml_folder/")
"""

import base64
import email
import email.message
import logging
import quopri
import re
import zipfile
from dataclasses import dataclass, field
from datetime import datetime
from email.header import decode_header
from email.utils import parseaddr, parsedate_to_datetime
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Optional, Set, Union

from .thread_aggregator import ThreadAggregator, EmailThread

logger = logging.getLogger(__name__)


# Personal email domains (likely correspondence, not marketing)
PERSONAL_DOMAINS = {
    "gmail.com", "googlemail.com",
    "yahoo.com", "yahoo.co.uk", "yahoo.fr",
    "hotmail.com", "outlook.com", "live.com", "msn.com",
    "icloud.com", "me.com", "mac.com",
    "aol.com",
    "protonmail.com", "proton.me",
    "fastmail.com", "fastmail.fm",
}

# Domains that are almost always marketing/notifications (not correspondence)
EXCLUDE_DOMAINS = {
    # Marketing platforms
    "mailchimp.com", "sendgrid.net", "amazonses.com", "mailgun.org",
    "constantcontact.com", "hubspot.com", "salesforce.com",
    # Notifications
    "github.com", "gitlab.com", "bitbucket.org",
    "slack.com", "discord.com",
    "twitter.com", "facebook.com", "instagram.com",
    "linkedin.com",  # Usually notifications, not personal
    "pinterest.com", "reddit.com",
    # Transactional
    "noreply", "no-reply", "donotreply",
    # Known noise
    "quora.com", "medium.com", "substack.com",
    "scmp.com", "puck.news",
}

# Address patterns that indicate marketing/notifications
MARKETING_ADDRESS_PATTERNS = [
    r"noreply@",
    r"no-reply@",
    r"donotreply@",
    r"notifications?@",
    r"alerts?@",
    r"newsletter@",
    r"marketing@",
    r"promo@",
    r"info@",
    r"support@",
    r"help@",
    r"team@",
    r"hello@",
    r"news@",
    r"updates?@",
]


@dataclass
class ProcessorStats:
    """Processing statistics."""
    total_read: int = 0
    filtered_domain: int = 0
    filtered_pattern: int = 0
    filtered_marketing: int = 0
    correspondence_found: int = 0
    threads_created: int = 0
    errors: int = 0


class EmailProcessor:
    """
    Processes MBOX files to extract correspondence emails.

    Filters out marketing, newsletters, and notifications to keep
    only genuine personal correspondence.
    """

    def __init__(
        self,
        user_domains: Optional[List[str]] = None,
        known_contacts: Optional[Set[str]] = None,
        additional_exclude_domains: Optional[Set[str]] = None,
    ):
        """
        Initialize processor.

        Args:
            user_domains: Domains belonging to the user (for sent detection)
            known_contacts: Email addresses of known contacts (always include)
            additional_exclude_domains: Extra domains to exclude
        """
        self.user_domains = {d.lower() for d in (user_domains or [])}
        self.known_contacts = {c.lower() for c in (known_contacts or [])}
        self.exclude_domains = EXCLUDE_DOMAINS.copy()
        if additional_exclude_domains:
            self.exclude_domains.update(additional_exclude_domains)

        self.stats = ProcessorStats()
        self._marketing_patterns = [re.compile(p, re.IGNORECASE) for p in MARKETING_ADDRESS_PATTERNS]

    def process_mbox(
        self,
        mbox_path: str,
        limit: Optional[int] = None,
        min_thread_messages: int = 2,
        min_body_length: int = 100,
        progress_callback: Optional[Callable[[int], None]] = None,
    ) -> List[EmailThread]:
        """
        Process MBOX file and return correspondence threads.

        Args:
            mbox_path: Path to MBOX file
            limit: Maximum emails to process
            min_thread_messages: Minimum messages per thread
            min_body_length: Minimum body length per thread
            progress_callback: Called every 1000 emails with count

        Returns:
            List of EmailThread objects
        """
        self.stats = ProcessorStats()
        aggregator = ThreadAggregator()

        for email_data in self._stream_mbox(mbox_path, limit, progress_callback):
            self.stats.total_read += 1

            # Check if correspondence
            if not self._is_correspondence(email_data):
                continue

            self.stats.correspondence_found += 1

            # Add to aggregator
            aggregator.add_email(
                message_id=email_data["message_id"],
                from_address=email_data["from_address"],
                to_addresses=email_data["to_addresses"],
                subject=email_data["subject"],
                body=email_data["body"],
                date=email_data["date"],
                from_name=email_data["from_name"],
                is_sent=email_data["is_sent"],
            )

        # Get threads
        threads = aggregator.get_threads(
            min_messages=min_thread_messages,
            min_body_length=min_body_length,
        )

        self.stats.threads_created = len(threads)
        logger.info(
            f"Processed {self.stats.total_read:,} emails, "
            f"found {self.stats.correspondence_found:,} correspondence, "
            f"created {self.stats.threads_created:,} threads"
        )

        return threads

    def process_eml_directory(
        self,
        eml_path: str,
        limit: Optional[int] = None,
        min_thread_messages: int = 2,
        min_body_length: int = 100,
        progress_callback: Optional[Callable[[int], None]] = None,
    ) -> List[EmailThread]:
        """
        Process directory of EML files and return correspondence threads.

        Supports:
        - Directory containing .eml files (recursive)
        - Zip file containing .eml files

        Args:
            eml_path: Path to directory or zip file containing EML files
            limit: Maximum emails to process
            min_thread_messages: Minimum messages per thread
            min_body_length: Minimum body length per thread
            progress_callback: Called every 1000 emails with count

        Returns:
            List of EmailThread objects
        """
        self.stats = ProcessorStats()
        aggregator = ThreadAggregator()

        for email_data in self._stream_eml(eml_path, limit, progress_callback):
            self.stats.total_read += 1

            # Check if correspondence
            if not self._is_correspondence(email_data):
                continue

            self.stats.correspondence_found += 1

            # Add to aggregator
            aggregator.add_email(
                message_id=email_data["message_id"],
                from_address=email_data["from_address"],
                to_addresses=email_data["to_addresses"],
                subject=email_data["subject"],
                body=email_data["body"],
                date=email_data["date"],
                from_name=email_data["from_name"],
                is_sent=email_data["is_sent"],
            )

        # Get threads
        threads = aggregator.get_threads(
            min_messages=min_thread_messages,
            min_body_length=min_body_length,
        )

        self.stats.threads_created = len(threads)
        logger.info(
            f"Processed {self.stats.total_read:,} EML files, "
            f"found {self.stats.correspondence_found:,} correspondence, "
            f"created {self.stats.threads_created:,} threads"
        )

        return threads

    def process(
        self,
        path: str,
        limit: Optional[int] = None,
        min_thread_messages: int = 2,
        min_body_length: int = 100,
        progress_callback: Optional[Callable[[int], None]] = None,
    ) -> List[EmailThread]:
        """
        Process email source (auto-detect format).

        Automatically detects:
        - MBOX files (by .mbox extension or content)
        - EML directories (folders containing .eml files)
        - Zip files containing EML files

        Args:
            path: Path to MBOX file, EML directory, or zip file
            limit: Maximum emails to process
            min_thread_messages: Minimum messages per thread
            min_body_length: Minimum body length per thread
            progress_callback: Called every 1000 emails with count

        Returns:
            List of EmailThread objects
        """
        p = Path(path)

        # Check if it's an MBOX file
        if p.suffix.lower() == '.mbox':
            return self.process_mbox(path, limit, min_thread_messages, min_body_length, progress_callback)

        # Check if it's a zip file
        if p.suffix.lower() == '.zip':
            return self.process_eml_directory(path, limit, min_thread_messages, min_body_length, progress_callback)

        # Check if it's a directory
        if p.is_dir():
            # Check if it contains EML files
            eml_files = list(p.rglob("*.eml"))
            if eml_files:
                return self.process_eml_directory(path, limit, min_thread_messages, min_body_length, progress_callback)
            # Check if it looks like an MBOX (no extension)
            # Try reading first line
            for child in p.iterdir():
                if child.is_file() and child.stat().st_size > 0:
                    with open(child, 'r', errors='ignore') as f:
                        first_line = f.readline()
                        if first_line.startswith('From '):
                            return self.process_mbox(str(child), limit, min_thread_messages, min_body_length, progress_callback)

        # Default: try as MBOX
        return self.process_mbox(path, limit, min_thread_messages, min_body_length, progress_callback)

    def _is_correspondence(self, email_data: Dict[str, Any]) -> bool:
        """Check if email is genuine correspondence (not marketing)."""
        from_addr = email_data["from_address"].lower()
        from_domain = email_data["from_domain"].lower()

        # Always include known contacts
        if from_addr in self.known_contacts:
            return True

        # Check excluded domains
        if any(excl in from_domain for excl in self.exclude_domains):
            self.stats.filtered_domain += 1
            return False

        # Check marketing address patterns
        for pattern in self._marketing_patterns:
            if pattern.search(from_addr):
                self.stats.filtered_pattern += 1
                return False

        # Check if from a personal domain
        if from_domain in PERSONAL_DOMAINS:
            return True

        # Check if from user's domain (colleague correspondence)
        if any(d in from_domain for d in self.user_domains):
            return True

        # Heuristics for other domains
        # Short body is likely automated
        body = email_data.get("body", "")
        if len(body) < 50:
            self.stats.filtered_marketing += 1
            return False

        # Check for marketing-like content patterns
        body_lower = body.lower()
        marketing_phrases = [
            "unsubscribe",
            "opt out",
            "email preferences",
            "you are receiving this",
            "manage your subscription",
            "click here to",
            "view in browser",
        ]
        marketing_count = sum(1 for phrase in marketing_phrases if phrase in body_lower)
        if marketing_count >= 2:
            self.stats.filtered_marketing += 1
            return False

        # Default: include if from corporate domain (potential colleague/contact)
        # This is permissive - better to include and filter later
        return True

    def _stream_mbox(
        self,
        mbox_path: str,
        limit: Optional[int],
        progress_callback: Optional[Callable[[int], None]],
    ) -> Iterator[Dict[str, Any]]:
        """Stream emails from MBOX file."""
        path = Path(mbox_path)
        if not path.exists():
            raise FileNotFoundError(f"MBOX file not found: {mbox_path}")

        count = 0
        current_headers: Dict[str, str] = {}
        current_body_lines: List[str] = []
        in_headers = True
        header_buffer: List[str] = []

        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                # New email starts with "From " at beginning of line
                if line.startswith('From ') and (
                    len(line) > 5 and
                    not line.startswith('From:') and
                    '@' in line[:100]
                ):
                    # Process previous email
                    if current_headers:
                        try:
                            email_data = self._build_email(current_headers, current_body_lines)
                            count += 1

                            if progress_callback and count % 1000 == 0:
                                progress_callback(count)

                            yield email_data

                            if limit and count >= limit:
                                return

                        except Exception as e:
                            self.stats.errors += 1
                            logger.debug(f"Error parsing email: {e}")

                    # Reset for new email
                    current_headers = {}
                    current_body_lines = []
                    in_headers = True
                    header_buffer = []
                    continue

                if in_headers:
                    if line.strip() == '':
                        in_headers = False
                        self._parse_headers(header_buffer, current_headers)
                    else:
                        header_buffer.append(line)
                else:
                    current_body_lines.append(line)

        # Process last email
        if current_headers and (not limit or count < limit):
            try:
                yield self._build_email(current_headers, current_body_lines)
            except Exception as e:
                self.stats.errors += 1

    def _parse_headers(self, lines: List[str], headers: Dict[str, str]):
        """Parse email headers."""
        current_key = None
        current_value = []

        for line in lines:
            if line.startswith((' ', '\t')) and current_key:
                current_value.append(line.strip())
            elif ':' in line:
                if current_key:
                    headers[current_key] = ' '.join(current_value)
                key, _, value = line.partition(':')
                current_key = key.strip()
                current_value = [value.strip()]

        if current_key:
            headers[current_key] = ' '.join(current_value)

    def _build_email(
        self,
        headers: Dict[str, str],
        body_lines: List[str]
    ) -> Dict[str, Any]:
        """Build email data dict from parsed content."""
        # From
        from_raw = headers.get('From', '')
        from_name, from_addr = parseaddr(from_raw)
        from_name = self._decode_header(from_name)
        from_domain = from_addr.split('@')[1].lower() if '@' in from_addr else 'unknown'

        # To
        to_raw = headers.get('To', '')
        to_addresses = [parseaddr(a)[1] for a in to_raw.split(',') if a.strip()]

        # Subject
        subject = self._decode_header(headers.get('Subject', ''))

        # Date
        date = None
        date_str = headers.get('Date', '')
        if date_str:
            try:
                date = parsedate_to_datetime(date_str)
            except Exception:
                pass

        # Body
        body = self._extract_body(body_lines, headers)

        # Is sent by user?
        is_sent = any(d in from_addr.lower() for d in self.user_domains)

        # Gmail labels (if present)
        labels = []
        labels_raw = headers.get('X-Gmail-Labels', '')
        if labels_raw:
            for label in labels_raw.split(','):
                label = label.strip().strip('"')
                if label:
                    labels.append(label)
        if 'Sent' in labels:
            is_sent = True

        return {
            "message_id": headers.get('Message-ID', f'unknown_{hash(from_raw)}'),
            "from_address": from_addr,
            "from_name": from_name,
            "from_domain": from_domain,
            "to_addresses": to_addresses,
            "subject": subject,
            "date": date,
            "body": body,
            "is_sent": is_sent,
            "labels": labels,
        }

    def _decode_header(self, value: str) -> str:
        """Decode encoded header value."""
        if not value:
            return ''

        if '=?' in value:
            try:
                decoded_parts = decode_header(value)
                result = []
                for content, encoding in decoded_parts:
                    if isinstance(content, bytes):
                        encoding = encoding or 'utf-8'
                        try:
                            result.append(content.decode(encoding, errors='replace'))
                        except Exception:
                            result.append(content.decode('utf-8', errors='replace'))
                    else:
                        result.append(content)
                return ' '.join(result)
            except Exception:
                pass

        return value

    def _extract_body(self, body_lines: List[str], headers: Dict[str, str]) -> str:
        """Extract readable text from body."""
        body = ''.join(body_lines)

        content_type = headers.get('Content-Type', '').lower()
        transfer_encoding = headers.get('Content-Transfer-Encoding', '').lower()

        # Handle encoding
        if 'base64' in transfer_encoding:
            try:
                lines = [l for l in body.split('\n') if l.strip() and not l.startswith('--')]
                encoded = ''.join(lines)
                body = base64.b64decode(encoded).decode('utf-8', errors='replace')
            except Exception:
                pass
        elif 'quoted-printable' in transfer_encoding:
            try:
                body = quopri.decodestring(body.encode()).decode('utf-8', errors='replace')
            except Exception:
                pass

        # Handle HTML
        if 'text/html' in content_type:
            body = self._html_to_text(body)

        # Handle multipart (simplified - just extract text parts)
        if 'multipart' in content_type:
            body = self._extract_from_multipart(body)

        # Clean up
        body = re.sub(r'\s+', ' ', body)
        body = body[:10000]  # Limit size

        return body.strip()

    def _html_to_text(self, html: str) -> str:
        """Convert HTML to plain text."""
        # Remove script/style
        html = re.sub(r'<script[^>]*>.*?</script>', '', html, flags=re.DOTALL | re.IGNORECASE)
        html = re.sub(r'<style[^>]*>.*?</style>', '', html, flags=re.DOTALL | re.IGNORECASE)

        # Convert breaks to spaces
        html = re.sub(r'<br\s*/?>', ' ', html, flags=re.IGNORECASE)
        html = re.sub(r'</p>', ' ', html, flags=re.IGNORECASE)
        html = re.sub(r'</div>', ' ', html, flags=re.IGNORECASE)

        # Remove tags
        html = re.sub(r'<[^>]+>', '', html)

        # Decode entities
        html = html.replace('&nbsp;', ' ')
        html = html.replace('&amp;', '&')
        html = html.replace('&lt;', '<')
        html = html.replace('&gt;', '>')
        html = html.replace('&quot;', '"')
        html = html.replace('&#39;', "'")

        return html

    def _extract_from_multipart(self, body: str) -> str:
        """Extract text from multipart email (simplified)."""
        # Look for text/plain part
        parts = re.split(r'--[^\n]+\n', body)

        for part in parts:
            if 'Content-Type: text/plain' in part:
                # Extract content after headers
                if '\n\n' in part:
                    content = part.split('\n\n', 1)[1]
                    return content

        # Fallback: just clean the whole body
        return self._html_to_text(body)

    def _stream_eml(
        self,
        eml_path: str,
        limit: Optional[int],
        progress_callback: Optional[Callable[[int], None]],
    ) -> Iterator[Dict[str, Any]]:
        """
        Stream emails from EML files (directory or zip).

        Args:
            eml_path: Path to directory or zip containing EML files
            limit: Maximum emails to yield
            progress_callback: Called every 1000 emails

        Yields:
            Email data dicts
        """
        path = Path(eml_path)
        count = 0

        # Handle zip file
        if path.suffix.lower() == '.zip':
            yield from self._stream_eml_from_zip(path, limit, progress_callback)
            return

        # Handle directory
        if not path.is_dir():
            raise ValueError(f"EML path must be a directory or zip file: {eml_path}")

        # Find all EML files recursively
        eml_files = sorted(path.rglob("*.eml"))
        logger.info(f"Found {len(eml_files):,} EML files in {path}")

        for eml_file in eml_files:
            try:
                email_data = self._parse_eml_file(eml_file)
                if email_data:
                    count += 1
                    yield email_data

                    if progress_callback and count % 1000 == 0:
                        progress_callback(count)

                    if limit and count >= limit:
                        return

            except Exception as e:
                self.stats.errors += 1
                logger.debug(f"Error parsing {eml_file.name}: {e}")

    def _stream_eml_from_zip(
        self,
        zip_path: Path,
        limit: Optional[int],
        progress_callback: Optional[Callable[[int], None]],
    ) -> Iterator[Dict[str, Any]]:
        """Stream EML files from a zip archive."""
        count = 0

        with zipfile.ZipFile(zip_path, 'r') as zf:
            # Get list of EML files in zip
            eml_names = [n for n in zf.namelist() if n.lower().endswith('.eml')]
            logger.info(f"Found {len(eml_names):,} EML files in {zip_path.name}")

            for name in eml_names:
                try:
                    with zf.open(name) as f:
                        content = f.read()
                        email_data = self._parse_eml_bytes(content, name)
                        if email_data:
                            count += 1
                            yield email_data

                            if progress_callback and count % 1000 == 0:
                                progress_callback(count)

                            if limit and count >= limit:
                                return

                except Exception as e:
                    self.stats.errors += 1
                    logger.debug(f"Error parsing {name}: {e}")

    def _parse_eml_file(self, eml_path: Path) -> Optional[Dict[str, Any]]:
        """Parse a single EML file."""
        with open(eml_path, 'rb') as f:
            content = f.read()
        return self._parse_eml_bytes(content, eml_path.name)

    def _parse_eml_bytes(self, content: bytes, filename: str) -> Optional[Dict[str, Any]]:
        """Parse EML content from bytes."""
        try:
            msg = email.message_from_bytes(content)
            return self._build_email_from_message(msg, filename)
        except Exception as e:
            logger.debug(f"Failed to parse EML {filename}: {e}")
            return None

    def _build_email_from_message(
        self,
        msg: email.message.Message,
        filename: str
    ) -> Dict[str, Any]:
        """Build email data dict from email.message.Message object."""
        # From
        from_raw = msg.get('From', '')
        from_name, from_addr = parseaddr(from_raw)
        from_name = self._decode_header(from_name)
        from_domain = from_addr.split('@')[1].lower() if '@' in from_addr else 'unknown'

        # To
        to_raw = msg.get('To', '')
        to_addresses = [parseaddr(a)[1] for a in to_raw.split(',') if a.strip()]

        # Subject
        subject = self._decode_header(msg.get('Subject', ''))

        # Date
        date = None
        date_str = msg.get('Date', '')
        if date_str:
            try:
                date = parsedate_to_datetime(date_str)
            except Exception:
                pass

        # Message ID
        message_id = msg.get('Message-ID', f'eml_{filename}')

        # Body - extract text from message
        body = self._extract_body_from_message(msg)

        # Is sent by user? (check if in Sent folder or from user domain)
        is_sent = 'sent' in filename.lower() or any(d in from_addr.lower() for d in self.user_domains)

        return {
            "message_id": message_id,
            "from_address": from_addr,
            "from_name": from_name,
            "from_domain": from_domain,
            "to_addresses": to_addresses,
            "subject": subject,
            "date": date,
            "body": body,
            "is_sent": is_sent,
            "labels": [],
        }

    def _extract_body_from_message(self, msg: email.message.Message) -> str:
        """Extract readable text from email.message.Message."""
        body_parts = []

        if msg.is_multipart():
            for part in msg.walk():
                content_type = part.get_content_type()
                content_disposition = str(part.get("Content-Disposition", ""))

                # Skip attachments
                if "attachment" in content_disposition:
                    continue

                # Prefer text/plain, fall back to text/html
                if content_type == "text/plain":
                    try:
                        payload = part.get_payload(decode=True)
                        if payload:
                            charset = part.get_content_charset() or 'utf-8'
                            text = payload.decode(charset, errors='replace')
                            body_parts.append(text)
                    except Exception:
                        pass
                elif content_type == "text/html" and not body_parts:
                    try:
                        payload = part.get_payload(decode=True)
                        if payload:
                            charset = part.get_content_charset() or 'utf-8'
                            html = payload.decode(charset, errors='replace')
                            body_parts.append(self._html_to_text(html))
                    except Exception:
                        pass
        else:
            # Single part message
            content_type = msg.get_content_type()
            try:
                payload = msg.get_payload(decode=True)
                if payload:
                    charset = msg.get_content_charset() or 'utf-8'
                    text = payload.decode(charset, errors='replace')
                    if content_type == "text/html":
                        text = self._html_to_text(text)
                    body_parts.append(text)
            except Exception:
                pass

        body = '\n'.join(body_parts)

        # Clean up
        body = re.sub(r'\s+', ' ', body)
        body = body[:10000]  # Limit size

        return body.strip()
