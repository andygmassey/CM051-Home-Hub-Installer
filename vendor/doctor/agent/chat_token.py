"""Chat-token issuance gateway endpoint logic (CM031 PR #43 sister).

Sister piece to CM031's ``Services/ChatTokenService.swift``. The iOS
chat tab calls ``POST /api/v1/auth/chat-token`` after pairing; the
Doctor proxies that request through ZeroClaw's pairing-code flow to
mint a fresh device-bearer token, then returns it together with the
LAN-reachable chat gateway URL.

ZeroClaw exposes two relevant endpoints
(``crates/zeroclaw-gateway/src/api_pairing.rs``):

* ``POST /api/pairing/initiate`` -- admin-authenticated, returns a
  short-lived pairing code.
* ``POST /api/pair`` -- public + rate-limited, exchanges a valid code
  for a long-lived bearer token recorded in
  ``gateway.paired_tokens``.

The Doctor authenticates to ZeroClaw using a pre-seeded admin token
written by the CM051 installer (see CM051 PR opening alongside this
one). The token lives at ``$OSTLER_CHAT_ADMIN_TOKEN_FILE`` (default
``~/.ostler/secrets/zeroclaw_admin_token``, mode 0600) AND is
mirrored into ZeroClaw's ``[gateway].paired_tokens`` array so that
the admin token is recognised at boot.

Public chat-base-URL handling:
   The URL returned to iOS in ``chat_base_url`` is what the iOS
   device will dial directly for ``/ws/chat``. Two strategies, in
   priority order:

   1. ``OSTLER_CHAT_GATEWAY_URL`` env var -- explicit override.
      Useful when ZeroClaw lives on a different host or behind a
      reverse proxy.
   2. Derived from the inbound request's ``Host`` header by swapping
      the port from the Doctor's port (8089) to ZeroClaw's port
      (default 42617, override via ``OSTLER_CHAT_GATEWAY_PORT``).

   Strategy 2 is the v0.1 default: iOS reaches the Doctor at e.g.
   ``http://192.0.2.10:8089``, so it can also reach ZeroClaw at
   ``http://192.0.2.10:42617``.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

import httpx

# Default ZeroClaw gateway port from
# crates/zeroclaw-config/src/schema.rs default_gateway_port().
DEFAULT_ZEROCLAW_PORT = 42617

# Default path the CM051 installer writes the admin token to.
DEFAULT_ADMIN_TOKEN_FILE = Path.home() / ".ostler" / "secrets" / "zeroclaw_admin_token"


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

@dataclass
class TokenIssueError(Exception):
    """Carries an HTTP status code so the FastAPI handler can map it
    cleanly. ``status`` 503 = ZeroClaw unreachable / not configured;
    502 = ZeroClaw reachable but rejected the call."""

    status: int
    detail: str

    def __str__(self) -> str:
        return self.detail


# ---------------------------------------------------------------------------
# Admin-token loader
# ---------------------------------------------------------------------------

def _admin_token_path() -> Path:
    raw = os.environ.get("OSTLER_CHAT_ADMIN_TOKEN_FILE")
    return Path(raw) if raw else DEFAULT_ADMIN_TOKEN_FILE


def read_admin_token() -> str:
    """Read the pre-seeded ZeroClaw admin token from disk.

    Surfaces a 503 when the file is missing -- that means CM051 hasn't
    seeded the token yet (or the user wiped ``~/.ostler/secrets``).
    The Doctor cannot mint a chat token without it, and there is no
    safe fallback.
    """
    path = _admin_token_path()
    if not path.exists():
        raise TokenIssueError(
            503,
            "chat admin token not seeded; re-run the Ostler installer",
        )
    try:
        token = path.read_text().strip()
    except OSError as exc:
        raise TokenIssueError(
            503,
            f"chat admin token unreadable at {path}: {exc}",
        ) from exc
    if not token:
        raise TokenIssueError(
            503,
            f"chat admin token at {path} is empty",
        )
    return token


# ---------------------------------------------------------------------------
# Gateway URL resolution
# ---------------------------------------------------------------------------

def _zeroclaw_port() -> int:
    raw = os.environ.get("OSTLER_CHAT_GATEWAY_PORT")
    if not raw:
        return DEFAULT_ZEROCLAW_PORT
    try:
        return int(raw)
    except ValueError:
        # Fall back to default rather than 500 -- the env override is
        # an operator escape hatch and a mistyped value should not
        # break chat for everyone.
        return DEFAULT_ZEROCLAW_PORT


def _internal_gateway_url() -> str:
    """The URL the Doctor uses to call ZeroClaw. Always localhost
    plus ZeroClaw's port -- the Doctor and ZeroClaw run on the same
    host."""
    return f"http://127.0.0.1:{_zeroclaw_port()}"


def resolve_public_chat_url(request_host: Optional[str]) -> str:
    """Return the chat URL iOS should dial.

    Priority:
      1. ``OSTLER_CHAT_GATEWAY_URL`` env override.
      2. Derived from the inbound ``Host`` header by replacing the
         port with ZeroClaw's. e.g. ``192.0.2.10:8089`` ->
         ``http://192.0.2.10:42617``.
      3. Localhost fallback (suitable only for development).
    """
    override = os.environ.get("OSTLER_CHAT_GATEWAY_URL", "").strip()
    if override:
        return override.rstrip("/")

    if request_host:
        host_only = request_host.rsplit(":", 1)[0]
        if host_only:
            return f"http://{host_only}:{_zeroclaw_port()}"

    return _internal_gateway_url()


# ---------------------------------------------------------------------------
# ZeroClaw driver
# ---------------------------------------------------------------------------

def _initiate_pairing(
    *, base_url: str, admin_token: str, http_client: httpx.Client
) -> str:
    """Call ZeroClaw's ``POST /api/pairing/initiate`` and return the
    short-lived pairing code. Raises ``TokenIssueError`` on any
    failure path."""
    try:
        resp = http_client.post(
            f"{base_url}/api/pairing/initiate",
            headers={"Authorization": f"Bearer {admin_token}"},
        )
    except httpx.HTTPError as exc:
        raise TokenIssueError(
            503, f"ZeroClaw unreachable at {base_url}: {exc}"
        ) from exc

    if resp.status_code == 401:
        raise TokenIssueError(
            502,
            "ZeroClaw rejected the admin token; "
            "re-run the installer to re-seed",
        )
    if resp.status_code == 503:
        raise TokenIssueError(
            503, "ZeroClaw refused -- pairing disabled or not ready",
        )
    if resp.status_code >= 400:
        raise TokenIssueError(
            502,
            f"ZeroClaw /api/pairing/initiate returned "
            f"{resp.status_code}: {resp.text[:200]}",
        )

    try:
        code = resp.json()["pairing_code"]
    except (KeyError, ValueError) as exc:
        raise TokenIssueError(
            502, f"ZeroClaw /api/pairing/initiate response malformed: {exc}",
        ) from exc

    if not isinstance(code, str) or not code:
        raise TokenIssueError(
            502, "ZeroClaw returned empty pairing code",
        )
    return code


def _exchange_code_for_token(
    *, base_url: str, code: str, http_client: httpx.Client
) -> str:
    """Call ZeroClaw's ``POST /api/pair`` (no auth required) with the
    pairing code and return the device-bearer token."""
    try:
        resp = http_client.post(
            f"{base_url}/api/pair",
            json={
                "code": code,
                "device_name": "Ostler Companion (iOS)",
                "device_type": "ios",
            },
        )
    except httpx.HTTPError as exc:
        raise TokenIssueError(
            503, f"ZeroClaw unreachable during /api/pair: {exc}",
        ) from exc

    if resp.status_code == 400:
        # Pairing code expired or already redeemed -- ZeroClaw enforces
        # single-use codes. The next request will get a fresh code, so
        # surface as 502 not 400 (the iOS caller did nothing wrong).
        raise TokenIssueError(
            502,
            "ZeroClaw rejected the freshly-minted pairing code; "
            "may indicate clock skew or a race",
        )
    if resp.status_code == 429:
        raise TokenIssueError(
            429, "ZeroClaw is rate-limiting /api/pair; retry shortly",
        )
    if resp.status_code >= 400:
        raise TokenIssueError(
            502,
            f"ZeroClaw /api/pair returned {resp.status_code}: "
            f"{resp.text[:200]}",
        )

    try:
        token = resp.json()["token"]
    except (KeyError, ValueError) as exc:
        raise TokenIssueError(
            502, f"ZeroClaw /api/pair response malformed: {exc}",
        ) from exc

    if not isinstance(token, str) or not token:
        raise TokenIssueError(
            502, "ZeroClaw returned empty bearer token",
        )
    return token


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def issue_chat_token(
    *,
    request_host: Optional[str] = None,
    http_client: Optional[httpx.Client] = None,
) -> Dict[str, Any]:
    """Mint a fresh ZeroClaw bearer token for the iOS chat tab.

    ``request_host`` is the ``Host`` header from the inbound request;
    the public ``chat_base_url`` is derived from it unless
    ``OSTLER_CHAT_GATEWAY_URL`` overrides.

    ``http_client`` lets tests inject an in-memory transport. Defaults
    to a fresh short-lived ``httpx.Client`` per call -- chat-token
    issuance is rare and the connection overhead is negligible
    compared to the two ZeroClaw round-trips.
    """
    admin_token = read_admin_token()
    internal = _internal_gateway_url()
    public = resolve_public_chat_url(request_host)

    own_client = http_client is None
    client = http_client or httpx.Client(timeout=30.0)
    try:
        code = _initiate_pairing(
            base_url=internal,
            admin_token=admin_token,
            http_client=client,
        )
        device_token = _exchange_code_for_token(
            base_url=internal,
            code=code,
            http_client=client,
        )
    finally:
        if own_client:
            client.close()

    return {
        "token": device_token,
        "expires_at": None,            # ZeroClaw issues non-expiring tokens
        "chat_base_url": public,
    }
