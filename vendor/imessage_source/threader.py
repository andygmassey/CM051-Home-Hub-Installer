"""Thread raw iMessage rows into conversation sessions.

A single chat.db thread (one ``chat.guid``) can span months. The
four-artefact spec wants one bundle per *conversation*, not per
contact-for-all-time. We segment a thread's flat message list into
sessions separated by a quiet gap (default 6h): a burst of messages
in an afternoon is one session; the next morning's burst is another.

Each session becomes:
  - a stable ``conversation_id`` (``YYYY-MM-DD_<slug>_<short-hash>``)
  - a cleaned, speaker-labelled transcript (markdown)
  - a CM048 metadata dict (``channel="im"``, participants, timestamps,
    iMessage-specific keys the CM048 adapter folds into frontmatter)

No real-person data is hard-coded here; display names are resolved by
the caller (``pipeline.py``) from a contacts map and passed in.
"""
from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from datetime import timedelta
from typing import Optional

from .reader import Message

# Default quiet gap that ends a session. Two bursts of messages more
# than this far apart are separate conversations.
DEFAULT_SESSION_GAP = timedelta(hours=6)

_SLUG_RE = re.compile(r"[^a-z0-9]+")


@dataclass
class Session:
    """One conversation session segmented out of a thread."""

    conversation_id: str
    chat_id: str
    messages: list[Message]
    is_group: bool
    participant_handles: list[str]  # non-"me" handle ids in this session
    display_name: Optional[str] = None
    extra: dict = field(default_factory=dict)

    @property
    def started_at(self) -> str:
        return self.messages[0].timestamp.isoformat().replace("+00:00", "Z")

    @property
    def ended_at(self) -> str:
        return self.messages[-1].timestamp.isoformat().replace("+00:00", "Z")

    @property
    def date(self) -> str:
        return self.messages[0].timestamp.date().isoformat()


def _slug(text: str, max_len: int = 32) -> str:
    cleaned = _SLUG_RE.sub("-", (text or "").lower()).strip("-")
    return (cleaned[:max_len].rstrip("-") or "conversation")


def _short_hash(*parts: str) -> str:
    payload = "\x1f".join(parts)
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:8]


def session_window(
    messages: list[Message], gap: timedelta = DEFAULT_SESSION_GAP
) -> list[list[Message]]:
    """Split a chronological message list into sessions by quiet gap.

    Messages must already be chronological (``reader.extract_messages``
    returns them so). A new session starts whenever the gap from the
    previous message exceeds ``gap``.
    """
    if not messages:
        return []
    sessions: list[list[Message]] = [[messages[0]]]
    for prev, cur in zip(messages, messages[1:]):
        if cur.timestamp - prev.timestamp > gap:
            sessions.append([cur])
        else:
            sessions[-1].append(cur)
    return sessions


def thread_messages(
    chat_id: str,
    messages: list[Message],
    *,
    is_group: bool,
    display_name: Optional[str] = None,
    gap: timedelta = DEFAULT_SESSION_GAP,
    min_session_messages: int = 2,
) -> list[Session]:
    """Segment one thread's messages into ``Session`` objects.

    Sessions shorter than ``min_session_messages`` are dropped (a lone
    "ok" is not a conversation worth a four-artefact bundle).
    """
    out: list[Session] = []
    for window in session_window(messages, gap=gap):
        if len(window) < min_session_messages:
            continue
        handles = []
        for m in window:
            if not m.is_from_me and m.sender not in handles:
                handles.append(m.sender)
        first_ts = window[0].timestamp
        slug_source = display_name or (handles[0] if handles else chat_id)
        conv_id = (
            f"{first_ts.date().isoformat()}_{_slug(slug_source)}_"
            f"{_short_hash(chat_id, first_ts.isoformat())}"
        )
        out.append(
            Session(
                conversation_id=conv_id,
                chat_id=chat_id,
                messages=window,
                is_group=is_group,
                participant_handles=handles,
                display_name=display_name,
            )
        )
    return out


def render_transcript(
    session: Session, *, name_for_handle
) -> str:
    """Render a cleaned, speaker-labelled markdown transcript.

    ``name_for_handle(handle) -> display`` resolves a handle id to a
    display name (caller supplies, from the contacts map). The user's
    own outgoing messages are labelled with the configured user name.
    Attachment-only rows render a placeholder so the transcript stays
    honest about what was said.
    """
    lines: list[str] = []
    for m in session.messages:
        ts = m.timestamp.isoformat().replace("+00:00", "Z")
        speaker = "You" if m.is_from_me else name_for_handle(m.sender)
        body = (m.text or "").strip()
        if not body:
            body = "[attachment]" if m.has_attachment else "[no text]"
        lines.append(f"**{speaker}** ({ts}): {body}")
    return "\n".join(lines) + "\n"


def build_metadata(
    session: Session,
    *,
    user_display_name: str,
    name_for_handle,
    privacy_level: Optional[str] = None,
) -> dict:
    """Assemble the CM048 metadata dict for a session.

    Shape matches CM048 ``schemas.py`` IM-channel expectations and the
    ``_imessage_adapter`` extra-key set (chat_identifier, service,
    is_group_chat). Participants are dicts with ``id`` / ``display`` /
    ``role`` -- the user is role ``"user"``, everyone else
    ``"other"``.
    """
    participants = [
        {"id": "user", "display": user_display_name, "role": "user"}
    ]
    for handle in session.participant_handles:
        participants.append(
            {
                "id": _slug(name_for_handle(handle) or handle),
                "display": name_for_handle(handle) or handle,
                "role": "other",
                "handle": handle,
            }
        )

    service = session.messages[0].service if session.messages else "iMessage"
    channel = "sms" if service.upper() == "SMS" else "im"

    metadata: dict = {
        "conversation_id": session.conversation_id,
        "date": session.date,
        "source": "imessage" if channel == "im" else "sms",
        "channel": channel,
        "started_at": session.started_at,
        "ended_at": session.ended_at,
        "source_session_id": session.chat_id,
        "capture_source": "cm040_imessage",
        "participants": participants,
        # iMessage-specific keys -> CM048 adapter folds into frontmatter
        "chat_identifier": session.chat_id,
        "service": service,
        "is_group_chat": session.is_group,
    }
    if privacy_level:
        metadata["privacy_level"] = privacy_level
    return metadata
