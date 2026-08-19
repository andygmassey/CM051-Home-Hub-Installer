"""Thread raw Apple Mail messages into conversation threads.

Email is already self-threading: every reply carries ``In-Reply-To``
and ``References`` headers pointing at the messages it answers. We
union messages that reference each other (a connected-components walk
over the reference graph) and fall back to a normalised-subject match
for clients that drop the reference headers. Each connected component
becomes one ``EmailThread`` -> one CM048 four-artefact bundle.

Each thread becomes:
  - a stable ``conversation_id`` (``YYYY-MM-DD_<slug>_<short-hash>``)
  - a cleaned, speaker-labelled transcript (markdown)
  - a CM048 metadata dict (``channel="email"``, participants with
    ``email`` fields, plus the ``email_thread`` sidecar the CM048
    ``_email_adapter`` folds into frontmatter)

No real-person data is hard-coded here; display names come from the
parsed ``From`` header or an optional contacts map the caller passes.
"""
from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from typing import Callable, Optional

from .reader import EmailMessage

_SLUG_RE = re.compile(r"[^a-z0-9]+")
# Reply / forward subject prefixes stripped before subject-fallback
# threading. Covers common English + a couple of localisations Apple
# Mail emits.
_SUBJECT_PREFIX_RE = re.compile(
    r"^\s*(re|fwd|fw|aw|wg|sv|vs)\s*:\s*", re.IGNORECASE
)


@dataclass
class EmailThread:
    """One email conversation threaded out of the flat message list."""

    conversation_id: str
    thread_id: str  # root Message-Id of the thread
    messages: list[EmailMessage]
    subject: str
    participant_addresses: list[str]  # non-user addresses, lower-cased
    extra: dict = field(default_factory=dict)

    @property
    def started_at(self) -> str:
        return _iso(self.messages[0])

    @property
    def ended_at(self) -> str:
        return _iso(self.messages[-1])

    @property
    def date(self) -> str:
        ts = self.messages[0].timestamp
        return ts.date().isoformat() if ts else "0000-00-00"


def _iso(message: EmailMessage) -> str:
    if message.timestamp is None:
        return ""
    return message.timestamp.isoformat().replace("+00:00", "Z")


def _slug(text: str, max_len: int = 32) -> str:
    cleaned = _SLUG_RE.sub("-", (text or "").lower()).strip("-")
    return cleaned[:max_len].rstrip("-") or "conversation"


def _short_hash(*parts: str) -> str:
    payload = "\x1f".join(parts)
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:8]


def _normalise_subject(subject: str) -> str:
    """Strip reply / forward prefixes for subject-fallback grouping."""
    prev = None
    cur = subject or ""
    while prev != cur:
        prev = cur
        cur = _SUBJECT_PREFIX_RE.sub("", cur)
    return cur.strip().lower()


class _Union:
    """Tiny union-find over message ids."""

    def __init__(self) -> None:
        self._parent: dict[str, str] = {}

    def find(self, key: str) -> str:
        self._parent.setdefault(key, key)
        root = key
        while self._parent[root] != root:
            root = self._parent[root]
        # Path compression.
        while self._parent[key] != root:
            self._parent[key], key = root, self._parent[key]
        return root

    def union(self, a: str, b: str) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self._parent[ra] = rb


def thread_messages(
    messages: list[EmailMessage],
    *,
    min_thread_messages: int = 1,
    subject_fallback: bool = True,
) -> list[EmailThread]:
    """Group a flat message list into ``EmailThread`` objects.

    Primary key: the reference graph (Message-Id / In-Reply-To /
    References). Secondary key (when ``subject_fallback``): messages
    sharing a normalised subject are unioned too, catching clients
    that strip reference headers.

    Threads shorter than ``min_thread_messages`` are dropped. Email
    threading keeps singletons by default (a one-message thread is
    still a conversation worth a bundle, unlike a lone "ok" iMessage)
    but the caller can raise the floor.
    """
    if not messages:
        return []

    by_id: dict[str, EmailMessage] = {}
    for m in messages:
        # First writer wins for a duplicate Message-Id (same message
        # filed in two mailboxes, e.g. Inbox + All Mail).
        by_id.setdefault(m.message_id, m)

    uf = _Union()
    for m in by_id.values():
        uf.find(m.message_id)
        if m.in_reply_to:
            uf.union(m.message_id, m.in_reply_to)
        for ref in m.references:
            uf.union(m.message_id, ref)

    if subject_fallback:
        subject_groups: dict[str, list[str]] = {}
        for m in by_id.values():
            norm = _normalise_subject(m.subject)
            if not norm:
                continue
            subject_groups.setdefault(norm, []).append(m.message_id)
        for ids in subject_groups.values():
            for other in ids[1:]:
                uf.union(ids[0], other)

    # Collect components, but only over message ids we actually have a
    # message for (references can point at messages outside the read
    # window).
    components: dict[str, list[EmailMessage]] = {}
    for m in by_id.values():
        root = uf.find(m.message_id)
        components.setdefault(root, []).append(m)

    threads: list[EmailThread] = []
    for component_messages in components.values():
        if len(component_messages) < min_thread_messages:
            continue
        ordered = sorted(
            component_messages,
            key=lambda x: (x.timestamp is None, x.timestamp),
        )
        root_message = ordered[0]
        thread_id = root_message.message_id
        subject = (
            root_message.subject
            or next((m.subject for m in ordered if m.subject), "")
        )

        # Non-user participant addresses are resolved later by the
        # pipeline (which knows the user's own address). Here we just
        # collect every distinct sender + recipient address.
        addresses: list[str] = []
        for m in ordered:
            for addr in [m.from_address] + [a for _, a in m.to_addresses] + [
                a for _, a in m.cc_addresses
            ]:
                if addr and addr not in addresses:
                    addresses.append(addr)

        first_ts = ordered[0].timestamp
        slug_source = subject or root_message.from_address or thread_id
        date_str = first_ts.date().isoformat() if first_ts else "0000-00-00"
        conv_id = (
            f"{date_str}_{_slug(slug_source)}_"
            f"{_short_hash(thread_id, _iso(ordered[0]))}"
        )
        threads.append(
            EmailThread(
                conversation_id=conv_id,
                thread_id=thread_id,
                messages=ordered,
                subject=subject,
                participant_addresses=addresses,
            )
        )

    # Newest-first so a tick processes recent conversations first.
    threads.sort(
        key=lambda t: (
            t.messages[-1].timestamp is None,
            t.messages[-1].timestamp,
        ),
        reverse=True,
    )
    return threads


def render_transcript(
    thread: EmailThread,
    *,
    user_address: str,
    name_for_address: Callable[[str], str],
) -> str:
    """Render a cleaned, speaker-labelled markdown transcript.

    ``name_for_address(addr) -> display`` resolves an address to a
    display name (caller supplies, from the contacts map or the
    parsed From name). Messages sent from ``user_address`` are
    labelled "You". A subject line opens the transcript so the
    rendered bundle is self-describing.
    """
    lines: list[str] = []
    if thread.subject:
        lines.append(f"# {thread.subject}")
        lines.append("")
    user_address = (user_address or "").strip().lower()
    for m in thread.messages:
        ts = _iso(m)
        if m.from_address and m.from_address == user_address:
            speaker = "You"
        else:
            speaker = name_for_address(m.from_address) or m.from_address or "Unknown"
        body = (m.body or "").strip() or "[no text]"
        header = f"**{speaker}** ({ts})" if ts else f"**{speaker}**"
        lines.append(f"{header}:")
        lines.append(body)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def build_metadata(
    thread: EmailThread,
    *,
    user_display_name: str,
    user_address: str,
    name_for_address: Callable[[str], str],
    privacy_level: Optional[str] = None,
) -> dict:
    """Assemble the CM048 metadata dict for an email thread.

    Shape matches the CM048 ``_email_adapter`` expectations
    (``channel="email"``, ``participants[*].email``, and an
    ``email_thread`` sidecar with thread_id / subject / message_count
    / first_message_at / last_message_at / message_ids /
    in_reply_to_chain). Participants are dicts with ``id`` / ``display``
    / ``role`` / ``email``; the user is role ``"user"``, everyone else
    ``"other"``.
    """
    user_address = (user_address or "").strip().lower()
    participants = [
        {
            "id": "user",
            "display": user_display_name,
            "role": "user",
            "email": user_address,
        }
    ]
    seen: set[str] = {user_address} if user_address else set()
    for addr in thread.participant_addresses:
        if not addr or addr in seen:
            continue
        seen.add(addr)
        display = name_for_address(addr) or addr
        participants.append(
            {
                "id": _slug(display) or addr,
                "display": display,
                "role": "other",
                "email": addr,
            }
        )

    message_ids = [m.message_id for m in thread.messages]
    in_reply_to_chain = [m.in_reply_to for m in thread.messages if m.in_reply_to]

    metadata: dict = {
        "conversation_id": thread.conversation_id,
        "date": thread.date,
        "source": "email",
        "channel": "email",
        "shape": "correspondence",
        "started_at": thread.started_at,
        "ended_at": thread.ended_at,
        "source_session_id": thread.thread_id,
        "source_app": "mail",
        "capture_source": "hr015_email_source",
        "participants": participants,
        "email_thread": {
            "thread_id": thread.thread_id,
            "subject": thread.subject,
            "message_count": len(thread.messages),
            "first_message_at": thread.started_at,
            "last_message_at": thread.ended_at,
            "message_ids": message_ids,
            "in_reply_to_chain": in_reply_to_chain,
        },
    }
    if privacy_level:
        metadata["privacy_level"] = privacy_level
    return metadata
