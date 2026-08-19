"""Source-agnostic provenance contract for unified conversations.

The ``ConversationProvenance`` dataclass is the load-bearing interface
between the launch-source adapters (hub channels, gateway sessions DB)
and the post-launch external-LLM adapters. Launch sources populate the
two required fields (``source_kind``, ``source_subtype``) and leave the
external_* fields ``None``. External-LLM adapters fill all of them so
the continuation router can decide whether to route back to the
originating provider.

Locking the contract from v0.1 avoids a schema migration when v0.2
ships claude-code, chatgpt, and claude-desktop adapters.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Literal


SourceKind = Literal["zeroclaw_gateway", "channel", "external_llm"]


@dataclass
class ConversationProvenance:
    """Where a conversation came from and whether it can be continued
    at its origin.

    Field semantics:

    - ``source_kind``: the broad bucket. Drives unifier merge rules
      and downstream privacy gating.
    - ``source_subtype``: the specific source (``imessage``,
      ``whatsapp``, ``email``, ``telegram``, ``claude_code``,
      ``chatgpt``, ``claude_desktop``, ``kimi``, ...). String, not
      Literal, so post-launch adapters can register new subtypes
      without re-versioning this contract.
    - ``external_provider``: API provider for ``external_llm`` sources
      only. ``anthropic`` | ``openai`` | ``google`` | ... ``None`` for
      hub-channel sources (no notion of "the API behind iMessage").
    - ``external_model``: model identifier reported by the source
      (``claude-opus-4-7``, ``gpt-5``, ...). Informational; not
      authoritative for routing.
    - ``original_session_id``: source-native session identifier. For
      ``claude_code`` this is the JSONL filename UUID. For
      ``zeroclaw_gateway`` it is the ``session_key``. For channel
      JSONLs it is the parsed conversation_id. Used by the
      continuation router for deep-link routing in v0.2.
    - ``can_continue_at_origin``: only true for ``external_llm``
      sources where a BYOM API key has been registered for the
      provider. v0.1 always emits ``False``; v0.2 populates from the
      BYOM-keys registry.
    """

    source_kind: SourceKind
    source_subtype: str
    external_provider: str | None = None
    external_model: str | None = None
    original_session_id: str | None = None
    can_continue_at_origin: bool = False

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "ConversationProvenance":
        return cls(
            source_kind=data["source_kind"],
            source_subtype=data["source_subtype"],
            external_provider=data.get("external_provider"),
            external_model=data.get("external_model"),
            original_session_id=data.get("original_session_id"),
            can_continue_at_origin=bool(data.get("can_continue_at_origin", False)),
        )
