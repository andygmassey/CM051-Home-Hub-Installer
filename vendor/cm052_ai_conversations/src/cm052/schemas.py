"""Conversation + Message schemas.

Source-agnostic. Adapters yield ``Conversation`` objects with a list of
``Message`` rows. The unifier merges streams from all registered
adapters into one chronologically-ordered list using
``Conversation.last_activity`` as the merge key.

Per-message timestamps are optional. The hub channel JSONLs carry no
per-line timestamps, so adapters fall back to file mtime + line index
(see PLAN.md, recommendation b). When ``Message.timestamp`` is
``None``, ``Message.line_index`` provides within-conversation ordering.

The CM048 wire converts each ``Conversation`` into the
``transcript.md + metadata.json`` pair CM048 expects, with
``metadata.channel`` set per the seven-field cross-repo PR coordinated
with CM046 Phase 3.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Literal

from .provenance import ConversationProvenance


Role = Literal["user", "assistant", "system", "tool"]
Channel = Literal["spoken", "email", "im", "sms", "manual"]


@dataclass
class Message:
    """One turn in a conversation. Keep narrow: role, content, and the
    minimal chronology signals available across all sources.

    ``timestamp``: ISO8601 if the source provides it (gateway DB rows
    via ``created_at``), else ``None``. The unifier and downstream
    consumers must tolerate ``None`` and fall back to ``line_index``
    for within-conversation ordering.

    ``line_index``: 0-based position within the conversation, set by
    the adapter regardless of timestamp availability. Stable across
    re-reads of the same source.
    """

    role: Role
    content: str
    timestamp: str | None = None
    line_index: int = 0

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class Conversation:
    """A unified conversation thread, regardless of source.

    Identity:
    - ``conversation_id`` is unifier-assigned, deterministic, derived
      from ``(source_kind, source_subtype, original_session_id)``.
      Re-reads of the same source produce the same id.

    Chronology:
    - ``last_activity`` drives the unified inbox sort order. Adapters
      derive this from the best signal available (file mtime for
      JSONLs, ``session_metadata.last_activity`` for the gateway DB).
    - ``created_at`` is best-effort; some sources don't expose it.

    Participants:
    - ``participants`` is a free-form list of identifiers (phone,
      email, handle). The unifier does not resolve identity; that is
      CM041's job. Each entry is normalised by the adapter (strip
      whitespace, lowercase emails) but otherwise opaque.
    """

    conversation_id: str
    provenance: ConversationProvenance
    channel: Channel
    participants: list[str]
    messages: list[Message]
    last_activity: str
    created_at: str | None = None
    name: str | None = None
    metadata: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "conversation_id": self.conversation_id,
            "provenance": self.provenance.to_dict(),
            "channel": self.channel,
            "participants": self.participants,
            "messages": [m.to_dict() for m in self.messages],
            "last_activity": self.last_activity,
            "created_at": self.created_at,
            "name": self.name,
            "metadata": self.metadata,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Conversation":
        return cls(
            conversation_id=data["conversation_id"],
            provenance=ConversationProvenance.from_dict(data["provenance"]),
            channel=data["channel"],
            participants=list(data.get("participants") or []),
            messages=[
                Message(
                    role=m["role"],
                    content=m["content"],
                    timestamp=m.get("timestamp"),
                    line_index=int(m.get("line_index", 0)),
                )
                for m in data.get("messages") or []
            ],
            last_activity=data["last_activity"],
            created_at=data.get("created_at"),
            name=data.get("name"),
            metadata=dict(data.get("metadata") or {}),
        )
