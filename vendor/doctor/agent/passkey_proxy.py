"""Passkey mint proxy (task 133). The Doctor does NOT touch WebAuthn.

Two unauthenticated routes in web_ui.py relay to the gateway, which owns the
challenge, the signature check and the token. Nothing is verified here and no
crypto lives here. The gateway's status and body are relayed unchanged: a 403 is
never rewritten into a 200. A gateway that cannot be reached is a 503 with a
reason, never a 200.

One side effect: a mint refused as ``repair_needed`` writes a marker the Pair
panel reads (pair_status.REPAIR_ROW_TEXT), so the owner is told, never silently.
A successful mint clears it. The marker holds a timestamp only, no credential.
"""
from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import Callable, Optional

import httpx

log = logging.getLogger(__name__)

_TIMEOUT_SECONDS = 5.0
CHALLENGE_PATH = "/auth/passkey/challenge"
MINT_PATH = "/auth/passkey/mint"

# Tests replace this to inject httpx.MockTransport. Production leaves it None.
_transport_factory: Optional[Callable[[], httpx.AsyncBaseTransport]] = None


def gateway_base_url() -> str:
    from proxy import _validator_base_url  # the gateway (:8000), not the ical-server
    return _validator_base_url()


def repair_marker() -> Path:
    base = os.environ.get("OSTLER_DIR") or str(Path.home() / ".ostler")
    return Path(base) / "state" / "passkey_repair_needed.json"


def repair_needed() -> bool:
    try:
        return repair_marker().is_file()
    except OSError:
        return False


def _set_repair_marker() -> None:
    p = repair_marker()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({"at": int(time.time())}))
        os.chmod(p, 0o600)
    except OSError as exc:
        log.warning("could not record the re-pair marker: %s", exc)


def static_bearer_marker() -> Path:
    base = os.environ.get("OSTLER_DIR") or str(Path.home() / ".ostler")
    return Path(base) / "state" / "static_bearer_seen.json"


def static_bearer_seen() -> bool:
    try:
        return static_bearer_marker().is_file()
    except OSError:
        return False


def note_static_bearer_accepted(route: str) -> None:
    """A STATIC credential was accepted on a deprecated route (task 133, one release).

    Logs the use and records the marker that shows the "Re-pair your iPhone" row.
    Accepted for one release only: TODO(2026-11-15) refuse these in release 134.
    """
    log.warning(
        "static credential accepted on %s: deprecated, refused from release 134; "
        "re-pair your iPhone", route)
    p = static_bearer_marker()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({"at": int(time.time()), "route": route}))
        os.chmod(p, 0o600)
    except OSError as exc:
        log.warning("could not record the static-credential marker: %s", exc)


def _clear_repair_marker() -> None:
    try:
        repair_marker().unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        log.warning("could not clear the re-pair marker: %s", exc)


def _unreachable(exc: Exception) -> tuple[int, bytes]:
    return 503, json.dumps(
        {"error": "gateway_unreachable", "reason": type(exc).__name__}
    ).encode()


def _client() -> httpx.AsyncClient:
    if _transport_factory is not None:
        return httpx.AsyncClient(transport=_transport_factory(), timeout=_TIMEOUT_SECONDS)
    return httpx.AsyncClient(timeout=_TIMEOUT_SECONDS)


async def fetch_challenge() -> tuple[int, bytes]:
    url = gateway_base_url() + CHALLENGE_PATH
    try:
        async with _client() as c:
            resp = await c.get(url)
    except (httpx.HTTPError, OSError) as exc:
        return _unreachable(exc)
    return resp.status_code, resp.content


async def mint(body: bytes) -> tuple[int, bytes]:
    url = gateway_base_url() + MINT_PATH
    try:
        async with _client() as c:
            resp = await c.post(url, content=body, headers={"content-type": "application/json"})
    except (httpx.HTTPError, OSError) as exc:
        return _unreachable(exc)
    status, content = resp.status_code, resp.content
    try:
        parsed = json.loads(content)
    except ValueError:
        parsed = None
    if status == 200:
        if isinstance(parsed, dict) and parsed.get("token"):
            _clear_repair_marker()
            return status, content
        # A 200 that carries no token is not a mint. Never pass it as one.
        return 502, json.dumps({"error": "gateway_malformed"}).encode()
    if isinstance(parsed, dict) and parsed.get("error") == "repair_needed":
        _set_repair_marker()
    return status, content
