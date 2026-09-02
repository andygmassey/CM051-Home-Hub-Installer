"""
Thread Aggregator - Groups emails into conversation threads.

Groups emails by normalized subject line, handles Re:/Fwd: prefixes,
and orders messages chronologically within threads.

Usage:
    aggregator = ThreadAggregator()

    # Add emails
    for email in emails:
        aggregator.add_email(email)

    # Get threads
    threads = aggregator.get_threads(min_messages=2)
"""

import hashlib
import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Dict, List, Optional


@dataclass
class EmailMessage:
    """A single email message."""

    message_id: str
    from_address: str
    from_name: Optional[str]
    to_addresses: List[str]
    cc_addresses: List[str]
    subject: str
    date: Optional[datetime]
    body: str
    is_sent: bool = False  # Did user send this?

    # Computed
    normalized_subject: str = ""
    is_reply: bool = False
    is_forward: bool = False

    def __post_init__(self):
        """Compute derived fields."""
        self.normalized_subject = self._normalize_subject(self.subject)
        subject_lower = self.subject.lower().strip()
        self.is_reply = subject_lower.startswith("re:")
        self.is_forward = subject_lower.startswith(("fwd:", "fw:"))

    @staticmethod
    def _normalize_subject(subject: str) -> str:
        """Normalize subject to thread key."""
        if not subject:
            return ""

        # Remove Re:, Fwd:, Fw: prefixes (may be nested)
        normalized = subject
        while True:
            new_normalized = re.sub(
                r"^(re|fwd|fw):\s*",
                "",
                normalized,
                flags=re.IGNORECASE
            ).strip()
            if new_normalized == normalized:
                break
            normalized = new_normalized

        # Normalize whitespace
        normalized = " ".join(normalized.split())

        # Lowercase for comparison
        normalized = normalized.lower()

        # Truncate to reasonable length
        return normalized[:150]

    def to_dict(self) -> Dict[str, Any]:
        return {
            "message_id": self.message_id,
            "from_address": self.from_address,
            "from_name": self.from_name,
            "to_addresses": self.to_addresses,
            "cc_addresses": self.cc_addresses,
            "subject": self.subject,
            "date": self.date.isoformat() if self.date else None,
            "body_preview": self.body[:500] if self.body else "",
            "body_length": len(self.body) if self.body else 0,
            "is_sent": self.is_sent,
            "is_reply": self.is_reply,
            "is_forward": self.is_forward,
        }


@dataclass
class EmailThread:
    """A conversation thread containing multiple emails."""

    thread_id: str
    subject: str  # Original subject (first email's subject)
    normalized_subject: str
    messages: List[EmailMessage] = field(default_factory=list)

    # Computed after finalization
    participants: List[str] = field(default_factory=list)
    date_range_start: Optional[datetime] = None
    date_range_end: Optional[datetime] = None
    message_count: int = 0
    total_body_length: int = 0

    def add_message(self, message: EmailMessage):
        """Add a message to the thread."""
        self.messages.append(message)

    def finalize(self):
        """Compute aggregate stats after all messages added."""
        if not self.messages:
            return

        # Sort by date (handle mixed timezone-aware and naive datetimes)
        def sort_key(m):
            if m.date is None:
                return (0, datetime.min)  # No date goes first
            # Convert to timestamp to avoid tz comparison issues
            try:
                return (1, m.date.timestamp())
            except (ValueError, OSError):
                return (0, datetime.min)

        self.messages.sort(key=sort_key)

        # Use first message's subject as canonical
        self.subject = self.messages[0].subject

        # Date range (handle mixed timezone-aware and naive datetimes)
        dated_messages = [m for m in self.messages if m.date]
        if dated_messages:
            # Use timestamp for comparison to avoid tz issues
            def safe_timestamp(dt):
                try:
                    return dt.timestamp()
                except (ValueError, OSError):
                    return 0

            sorted_by_date = sorted(dated_messages, key=lambda m: safe_timestamp(m.date))
            self.date_range_start = sorted_by_date[0].date
            self.date_range_end = sorted_by_date[-1].date

        # Participants (unique email addresses)
        participants_set = set()
        for msg in self.messages:
            participants_set.add(msg.from_address.lower())
            for to_addr in msg.to_addresses:
                participants_set.add(to_addr.lower())
        self.participants = sorted(participants_set)

        # Counts
        self.message_count = len(self.messages)
        self.total_body_length = sum(len(m.body) for m in self.messages if m.body)

    def get_thread_content(self, max_messages: int = 50) -> str:
        """
        Get combined thread content for summarization.

        Args:
            max_messages: Maximum messages to include (most recent if truncated)

        Returns:
            Combined thread content
        """
        messages_to_include = self.messages[-max_messages:] if len(self.messages) > max_messages else self.messages

        parts = []
        for msg in messages_to_include:
            date_str = msg.date.strftime("%Y-%m-%d %H:%M") if msg.date else "Unknown date"
            direction = "[SENT]" if msg.is_sent else "[RECEIVED]"

            header = f"--- {direction} {date_str} - From: {msg.from_name or msg.from_address} ---"
            parts.append(header)

            # Truncate very long bodies
            body = msg.body[:5000] if msg.body else "(no body)"
            parts.append(body)
            parts.append("")

        return "\n".join(parts)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "thread_id": self.thread_id,
            "subject": self.subject,
            "normalized_subject": self.normalized_subject,
            "participants": self.participants,
            "date_range_start": self.date_range_start.isoformat() if self.date_range_start else None,
            "date_range_end": self.date_range_end.isoformat() if self.date_range_end else None,
            "message_count": self.message_count,
            "total_body_length": self.total_body_length,
            "messages": [m.to_dict() for m in self.messages],
        }


class ThreadAggregator:
    """
    Aggregates emails into conversation threads.

    Groups emails by normalized subject line and chronological order.
    """

    def __init__(self):
        self._threads: Dict[str, EmailThread] = {}  # normalized_subject -> thread
        self._message_ids: set = set()  # Track seen message IDs

        self._stats = {
            "emails_added": 0,
            "duplicates_skipped": 0,
            "threads_created": 0,
        }

    def add_email(
        self,
        message_id: str,
        from_address: str,
        to_addresses: List[str],
        subject: str,
        body: str,
        date: Optional[datetime] = None,
        from_name: Optional[str] = None,
        cc_addresses: Optional[List[str]] = None,
        is_sent: bool = False,
    ) -> bool:
        """
        Add an email to the aggregator.

        Args:
            message_id: Unique message identifier
            from_address: Sender email
            to_addresses: Recipient emails
            subject: Email subject
            body: Email body text
            date: Email date
            from_name: Sender name
            cc_addresses: CC recipients
            is_sent: Whether user sent this email

        Returns:
            True if added, False if duplicate
        """
        # Skip duplicates
        if message_id in self._message_ids:
            self._stats["duplicates_skipped"] += 1
            return False

        self._message_ids.add(message_id)

        # Create message
        message = EmailMessage(
            message_id=message_id,
            from_address=from_address,
            from_name=from_name,
            to_addresses=to_addresses,
            cc_addresses=cc_addresses or [],
            subject=subject,
            date=date,
            body=body,
            is_sent=is_sent,
        )

        # Get or create thread
        normalized = message.normalized_subject
        if not normalized:
            # Create unique thread for empty subjects
            normalized = f"_empty_{message_id}"

        if normalized not in self._threads:
            thread_id = hashlib.md5(normalized.encode()).hexdigest()[:16]
            self._threads[normalized] = EmailThread(
                thread_id=thread_id,
                subject=subject,
                normalized_subject=normalized,
            )
            self._stats["threads_created"] += 1

        self._threads[normalized].add_message(message)
        self._stats["emails_added"] += 1

        return True

    def get_threads(
        self,
        min_messages: int = 1,
        max_messages: Optional[int] = None,
        min_body_length: int = 0,
    ) -> List[EmailThread]:
        """
        Get aggregated threads.

        Args:
            min_messages: Minimum messages per thread
            max_messages: Maximum messages per thread (None = no limit)
            min_body_length: Minimum total body length

        Returns:
            List of EmailThread objects, sorted by most recent first
        """
        threads = []

        for thread in self._threads.values():
            thread.finalize()

            # Apply filters
            if thread.message_count < min_messages:
                continue

            if max_messages and thread.message_count > max_messages:
                continue

            if thread.total_body_length < min_body_length:
                continue

            threads.append(thread)

        # Sort by most recent message first (use timestamps to avoid tz issues)
        def thread_sort_key(t):
            if t.date_range_end is None:
                return 0
            try:
                return t.date_range_end.timestamp()
            except (ValueError, OSError):
                return 0

        threads.sort(key=thread_sort_key, reverse=True)

        return threads

    def get_single_message_emails(self) -> List[EmailMessage]:
        """Get emails that don't belong to a thread (single messages)."""
        single = []

        for thread in self._threads.values():
            thread.finalize()
            if thread.message_count == 1:
                single.extend(thread.messages)

        return single

    @property
    def stats(self) -> Dict[str, int]:
        return self._stats.copy()


def create_thread_id(normalized_subject: str) -> str:
    """Create a deterministic thread ID from normalized subject."""
    return hashlib.md5(normalized_subject.encode()).hexdigest()[:16]
