"""Continuation WebSocket handshake (contract sweep 2026-10-07).

``routing.route()`` is a v0.1 stub -- nothing in this repo opens the
WebSocket yet, so there was no code at all exercising the one thing the
contract sweep found broken: the port, the path, and the auth. This
module is the minimal real client for that handshake, stdlib only, no
framing library pulled in ahead of the feature that will actually chat
over it.

Auth matches ``zeroclaw-gateway/src/ws.rs:83`` (``extract_ws_token``):
the Authorization header is checked first, before the
``Sec-WebSocket-Protocol: bearer.<token>`` subprotocol or the ``?token=``
query param, so this client uses the header -- the simplest of the three
and the one every other local Hub caller (the Doctor's chat-token mint,
``vendor/doctor/agent/chat_token.py``) already uses.
"""
from __future__ import annotations

import base64
import os
import socket
from urllib.parse import urlsplit

from .routing import Route


class ContinuationConnectError(RuntimeError):
    """The WebSocket upgrade to the continuation endpoint failed.

    Raised for both a transport failure (wrong port, nothing
    listening, DNS failure) and a rejected handshake (wrong or missing
    auth) -- both cases that must fail loudly rather than return a
    socket the caller would then read garbage from.
    """


def open_continuation_socket(route: Route, timeout: float = 5.0) -> socket.socket:
    """Perform the WebSocket upgrade handshake against ``route.endpoint``.

    Returns the connected, upgraded socket on a 101 response. Raises
    ``ContinuationConnectError`` on anything else: connection refused,
    timeout, or a non-101 status line (a 401 from the gateway when
    ``route.auth_token`` is wrong or missing).
    """
    parsed = urlsplit(route.endpoint)
    scheme = "https" if parsed.scheme == "wss" else "http"
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or (443 if scheme == "https" else 80)
    path = parsed.path or "/"
    if parsed.query:
        path = f"{path}?{parsed.query}"

    try:
        sock = socket.create_connection((host, port), timeout=timeout)
    except OSError as exc:
        raise ContinuationConnectError(
            f"could not reach continuation endpoint {route.endpoint}: {exc}"
        ) from exc

    try:
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        header_lines = [
            f"GET {path} HTTP/1.1",
            f"Host: {host}:{port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
        ]
        if route.auth_token:
            header_lines.append(f"Authorization: Bearer {route.auth_token}")
        request = "\r\n".join(header_lines) + "\r\n\r\n"
        sock.sendall(request.encode("ascii"))

        sock.settimeout(timeout)
        response = sock.recv(4096).decode("iso-8859-1", errors="replace")
    except OSError as exc:
        sock.close()
        raise ContinuationConnectError(
            f"continuation handshake to {route.endpoint} failed: {exc}"
        ) from exc

    status_line = response.split("\r\n", 1)[0]
    if " 101 " not in status_line:
        sock.close()
        raise ContinuationConnectError(
            f"continuation handshake to {route.endpoint} rejected: {status_line!r}"
        )
    return sock
