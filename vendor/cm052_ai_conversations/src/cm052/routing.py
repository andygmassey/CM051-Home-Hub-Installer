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
from pathlib import Path

from .schemas import Conversation


@dataclass
class Route:
    """The endpoint the continuation should be sent to."""

    provider: str  # local_assistant | anthropic | openai | google | ...
    endpoint: str  # URL the caller will POST history + prompt to
    reason: str  # human-readable explanation, surfaced in UI
    auth_token: str = ""  # bearer the endpoint requires, "" if none


# Contract sweep 2026-10-07 (CM052 section): this used to default to
# ``ws://localhost:8089/ws/chat``. Port 8089 is the Doctor's FastAPI app
# (confirmed: 34 REST routes, no WebSocket route at all). ``/ws/chat`` is
# served by the ZeroClaw gateway
# (ostler-assistant crates/zeroclaw-gateway/src/lib.rs:1061,
# ``.route("/ws/chat", get(ws::handle_ws_chat))``).
#
# The gateway binary's own compiled-in default port is 42617
# (ostler-assistant crates/zeroclaw-config/src/schema.rs:2354
# ``fn default_gateway_port() -> u16 { 42617 }``), but the SHIPPED,
# installed config pins it to 8000
# (CM051-Home-Hub-Installer/install.sh:16179, ``echo "port = 8000"``,
# comment at :16171 "CX-59 (DMG #34, 2026-05-24): pin the gateway port
# to 8000" -- without that pin, Ostler.app's own polling and the iOS
# pairing flow already hit "connection refused" on the binary default).
# 8000 is therefore the correct default here too: it is the port the
# gateway actually listens on on every customer Hub, not a guess.
_LOCAL_ASSISTANT_DEFAULT_PORT = 8000


def _local_assistant_endpoint() -> str:
    override = os.environ.get("CM052_LOCAL_ASSISTANT_WS_URL")
    if override:
        return override
    return f"ws://127.0.0.1:{_LOCAL_ASSISTANT_DEFAULT_PORT}/ws/chat"


# The gateway's own default admin-token path (mirrors
# ostler-assistant crates/zeroclaw-gateway/src/lib.rs:549
# ``admin_token_file_path``, and CM051 vendor/doctor/agent/chat_token.py
# ``DEFAULT_ADMIN_TOKEN_FILE`` -- same file, same override env var, so
# all three readers agree). install.sh seeds this file unconditionally
# (install.sh:14927 onward, "Chat admin token seed") and mirrors its
# value into the gateway's own ``paired_tokens`` set at boot
# (lib.rs:570 ``mirror_admin_token_into_pairing`` ->
# zeroclaw-config/src/pairing.rs:304 ``trust_plaintext_token``), which
# is the exact set ``/ws/chat``'s auth check reads
# (zeroclaw-gateway/src/ws.rs:303 ``handle_ws_chat`` ->
# ``state.pairing.is_authenticated``). No installer change is needed:
# CM052 just has to read the same file.
def _default_admin_token_file() -> Path:
    # Resolved per call (not at import time) so HOME overrides in tests
    # (and in any re-exec'd process) take effect, matching wire.py's
    # ``_service_token()`` file-fallback pattern.
    return Path.home() / ".ostler" / "secrets" / "zeroclaw_admin_token"


def _local_assistant_token() -> str:
    """The bearer the gateway's ``/ws/chat`` demands for a loopback
    caller, or "" if the file is absent (a missing file is a no-op,
    matching the gateway's own mirror; the connect attempt is what
    surfaces the failure, loudly, never a silent empty-auth success).
    """
    override = os.environ.get("OSTLER_CHAT_ADMIN_TOKEN_FILE")
    path = Path(override) if override else _default_admin_token_file()
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


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
        auth_token=_local_assistant_token(),
    )
