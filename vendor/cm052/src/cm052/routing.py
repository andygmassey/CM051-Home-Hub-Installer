"""Continuation router.

When the user says "continue this chat" in the unified chat history
UI, the router decides which LLM endpoint receives the prior history
plus the new prompt.

v0.1 (launch): always the user's local assistant. Whether the
conversation originated from iMessage, WhatsApp, the gateway, or
anywhere else, continuation goes to the local-assistant endpoint via
ZeroClaw's ``/ws/chat``.

v0.2: consult a BYOM-keys registry (see ``HR015/INSTALLER_BYO_KEYS.md``)
keyed by ``provenance.external_provider``. If the user has registered
an Anthropic key and the source provenance points at Anthropic, route
back to the Anthropic API directly. Else fall back to the local
assistant. The UI exposes a per-conversation override.

Continuation is **history + new prompt → chosen LLM**, NOT session
resumption and NOT credentials-stealing. Original session state stays
where it lives.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

from .schemas import Conversation


@dataclass
class Route:
    """The endpoint the continuation should be sent to."""

    provider: str  # local_assistant | anthropic | openai | google | ...
    endpoint: str  # URL the caller will POST history + prompt to
    reason: str  # human-readable explanation, surfaced in UI


def _local_assistant_endpoint() -> str:
    return (
        os.environ.get("CM052_LOCAL_ASSISTANT_WS_URL")
        or "ws://localhost:8089/ws/chat"
    )


def route(_conversation: Conversation, _new_prompt: str) -> Route:
    """v0.1 always-local-assistant stub.

    Deliberately ignores both arguments so callers in the v0.2 router
    don't have to be rewired when BYOM lookup lands. The signature is
    the load-bearing contract; the body fills in.
    """
    return Route(
        provider="local_assistant",
        endpoint=_local_assistant_endpoint(),
        reason="v0.1 launch: continuation always routed to the local assistant",
    )
