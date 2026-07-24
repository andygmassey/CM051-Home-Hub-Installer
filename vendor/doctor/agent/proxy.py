"""Reverse proxy from the Doctor to the local CM019 gateway.

CM019 clean-house PR 8 (design doc Section 8 item 8). iOS's
``pwgAPIBaseURL`` is being repointed from the CM019 gateway
directly to the Doctor's tailnet IP. The Doctor forwards any
iOS-initiated CM019 path (starting with ``/api/safari/ingest``,
extensible via the ``DOCTOR_PROXY_PATHS`` env var) to the local
gateway over loopback (``http://127.0.0.1:8000`` by default).

Why this is the clean-house posture:

- One auth boundary (the Doctor on ``:8089``) instead of two
  externally-reachable ports.
- One bind decision to audit -- CM019 services become
  localhost-only.
- iOS already attaches the bearer per CM031 PR #66; the Doctor
  forwards the ``Authorization`` header untouched and the gateway
  verifies it locally per CM019 PR 4.

Configuration:

- ``DOCTOR_PROXY_PATHS`` -- comma-separated list of paths to
  proxy. Defaults to ``/api/safari/ingest``. Adding a new path
  later is a config change, not a code change.
- ``DOCTOR_GATEWAY_URL`` -- base URL of the local CM019 gateway.
  Defaults to ``http://127.0.0.1:8000`` to match the
  ``docker-compose.apps.yml`` gateway port and the 127.0.0.1 bind
  decision in design doc Section 4.

The proxy does NOT mint, mutate, or strip the bearer token. iOS
mints it via ``/api/v1/auth/chat-token`` (Doctor) and CM019
verifies it via the shared ``auth.require_auth`` (CM019 PR 1).
The Doctor is plumbing between those two trust boundaries.

BW4 Item 1/2 (v1.0.10 security lockdown) -- ical-server auth
boundary:

When the upstream is the loopback ical-server (the customer
install sets ``DOCTOR_GATEWAY_URL=http://127.0.0.1:8090`` and
proxies the ``/api/v1/*`` data surfaces through it), that server's
auth boundary requires the per-install ``PWG_SERVICE_TOKEN``
(``install.sh`` seeds it into the Doctor's launchd env), NOT the
client's ``zeroclaw_token`` bearer. The Doctor is the single
client-facing auth boundary: when a service token is configured it
VALIDATES the incoming client bearer against the ZeroClaw gateway's
paired-token store and only THEN substitutes the service token on
the forwarded request. The two halves ship together -- substituting
the service token without validating the client bearer would let any
loopback process that reaches ``:8089`` inherit ical-server access.

When no service token is configured the Doctor stays a transparent
pass-through (the original CM019 Safari-ingest posture, whose
upstream verifies the bearer itself).
"""
from __future__ import annotations

import hashlib
import logging
import os
import tomllib
from pathlib import Path
from typing import Iterable, Optional

import httpx
from fastapi import FastAPI, Request, Response


logger = logging.getLogger(__name__)


DEFAULT_GATEWAY_URL = "http://127.0.0.1:8000"
DEFAULT_PROXY_PATHS = ("/api/safari/ingest",)

# Hop-by-hop headers (RFC 7230 section 6.1) plus a few that httpx
# computes fresh on the upstream request / response. Anything in
# this set is stripped from both directions of the proxy.
_HOP_BY_HOP_HEADERS = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "transfer-encoding",
        "upgrade",
        # Set per-request by httpx; passing through would corrupt
        # the upstream call.
        "host",
        "content-length",
    }
)

# Upstream forward timeout. Generous because Safari ingest is the
# canonical proxied surface today and the gateway runs the ingest
# pipeline synchronously.
_UPSTREAM_TIMEOUT_SECONDS = 30.0


def _load_proxy_paths() -> list[str]:
    """Return the list of paths to proxy from the env var, falling
    back to the default. Empty values are filtered."""
    raw = os.environ.get("DOCTOR_PROXY_PATHS", "").strip()
    if not raw:
        return list(DEFAULT_PROXY_PATHS)
    return [p.strip() for p in raw.split(",") if p.strip()]


def _gateway_base_url() -> str:
    return os.environ.get(
        "DOCTOR_GATEWAY_URL", DEFAULT_GATEWAY_URL
    ).rstrip("/")


def _filter_request_headers(headers) -> dict[str, str]:
    """Drop hop-by-hop headers. Preserve everything else, including
    Authorization, which is the whole point of this proxy."""
    return {
        key: value
        for key, value in headers.items()
        if key.lower() not in _HOP_BY_HOP_HEADERS
    }


def _filter_response_headers(headers) -> dict[str, str]:
    return {
        key: value
        for key, value in headers.items()
        if key.lower() not in _HOP_BY_HOP_HEADERS
    }


# ---------------------------------------------------------------------------
# BW4 Item 1/2: client-bearer validation + service-token substitution
# ---------------------------------------------------------------------------
#
# Validation mirrors the ZeroClaw gateway's own
# ``PairingGuard::is_authenticated`` / ``hash_token``
# (``crates/zeroclaw-config/src/pairing.rs``): SHA-256 the bearer
# (unsalted, lowercase hex) and test membership of the
# ``[gateway].paired_tokens`` set in the assistant ``config.toml``. Config
# entries are accepted in both forms -- plaintext (hashed on read) or an
# already-hashed 64-char hex string -- matching ``PairingGuard::new``. If
# ``[gateway].require_pairing`` is false the gateway authenticates
# everyone, so the Doctor mirrors that and passes. Keep this byte-for-byte
# aligned with the gateway hashing or validation silently diverges.

# Env var names install.sh may seed the ical-server service token under.
# OSTLER_SERVICE_TOKEN takes precedence over the legacy PWG_SERVICE_TOKEN.
_SERVICE_TOKEN_ENV_VARS = ("OSTLER_SERVICE_TOKEN", "PWG_SERVICE_TOKEN")

# Default assistant config.toml location on a customer install
# (``${OSTLER_DIR}/assistant-config/config.toml``).
_DEFAULT_ASSISTANT_CONFIG = (
    Path.home() / ".ostler" / "assistant-config" / "config.toml"
)


def _resolve_service_token() -> Optional[str]:
    """Return the ical-server service token from the environment, or
    ``None`` if unset. Presence of a token is also the signal that the
    upstream is the ical-server and the validate-then-substitute path
    applies; absence keeps the proxy a transparent pass-through."""
    for name in _SERVICE_TOKEN_ENV_VARS:
        raw = os.environ.get(name, "").strip()
        if raw:
            return raw
    return None


def _assistant_config_path() -> Path:
    """Resolve the ZeroClaw assistant ``config.toml`` the same way the
    gateway does: an explicit ``OSTLER_ASSISTANT_CONFIG`` override first
    (used by tests), then the gateway's own ``ZEROCLAW_WORKSPACE`` /
    ``ZEROCLAW_CONFIG_DIR`` env vars, then the default install
    location."""
    override = os.environ.get("OSTLER_ASSISTANT_CONFIG", "").strip()
    if override:
        return Path(override)
    workspace = os.environ.get("ZEROCLAW_WORKSPACE", "").strip()
    if workspace:
        return Path(workspace) / "config.toml"
    config_dir = os.environ.get("ZEROCLAW_CONFIG_DIR", "").strip()
    if config_dir:
        return Path(config_dir) / "config.toml"
    return _DEFAULT_ASSISTANT_CONFIG


def _hash_token(token: str) -> str:
    """Unsalted lowercase-hex SHA-256. Mirror of the gateway's
    ``hash_token`` -- must stay byte-for-byte identical."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _looks_like_token_hash(value: str) -> bool:
    """True when ``value`` is already a stored hash (64 lowercase-hex
    chars), mirroring the gateway's ``is_token_hash``. Anything else is
    treated as plaintext and hashed on read."""
    if len(value) != 64:
        return False
    return all(c in "0123456789abcdef" for c in value)


def _load_gateway_pairing(
    config_path: Optional[Path] = None,
) -> tuple[bool, frozenset[str]]:
    """Read ``[gateway].require_pairing`` and the normalised
    ``[gateway].paired_tokens`` hash set from the assistant
    ``config.toml``.

    Returns ``(require_pairing, token_hashes)``. On any read/parse
    failure returns ``(True, frozenset())`` -- fail CLOSED: pairing
    required, no tokens accepted, so validation rejects. A broken or
    unreadable config must never silently grant ical-server access.
    """
    path = config_path or _assistant_config_path()
    try:
        with open(path, "rb") as fh:
            data = tomllib.load(fh)
    except FileNotFoundError:
        logger.warning(
            "Doctor proxy: assistant config not found at %s; "
            "failing client-bearer validation closed",
            path,
        )
        return True, frozenset()
    except (OSError, tomllib.TOMLDecodeError) as exc:
        logger.warning(
            "Doctor proxy: could not read assistant config at %s: %s; "
            "failing client-bearer validation closed",
            path,
            exc,
        )
        return True, frozenset()

    gateway = data.get("gateway") or {}
    require_pairing = bool(gateway.get("require_pairing", True))
    raw_tokens = gateway.get("paired_tokens") or []
    hashes: set[str] = set()
    for entry in raw_tokens:
        if not isinstance(entry, str) or not entry:
            continue
        hashes.add(
            entry if _looks_like_token_hash(entry) else _hash_token(entry)
        )
    return require_pairing, frozenset(hashes)


def _extract_bearer_token(headers) -> str:
    """Return the bearer credential from the Authorization header, or
    ``''`` if absent/malformed. Mirror of the gateway's extractor."""
    raw = headers.get("authorization") or headers.get("Authorization") or ""
    prefix = "Bearer "
    if raw.startswith(prefix):
        return raw[len(prefix):].strip()
    return ""


def _is_paired_bearer(
    token: str, config_path: Optional[Path] = None
) -> bool:
    """Mirror ``PairingGuard::is_authenticated``: ``True`` iff pairing is
    not required, or the bearer's SHA-256 hash is in the gateway's paired
    token set."""
    require_pairing, hashes = _load_gateway_pairing(config_path)
    if not require_pairing:
        return True
    if not token:
        return False
    return _hash_token(token) in hashes


async def proxy_request(
    request: Request,
    path: str,
    gateway_url: Optional[str] = None,
    client: Optional[httpx.AsyncClient] = None,
) -> Response:
    """Forward ``request`` to the gateway at the request's
    concrete URL path, return the upstream response back to the
    caller.

    The ``path`` argument is the route template the caller
    registered (e.g. ``/api/v1/people/{slug}/forget``). It is used
    only for logging. The actual forwarded URL is built from
    ``request.url.path`` so that path-parameter routes substitute
    correctly: a request to ``/api/v1/people/alice/forget``
    forwards to ``{gateway_url}/api/v1/people/alice/forget`` (not
    the literal template). This is the CX-P0A fix
    (2026-05-26): pre-fix the proxy sent the literal template
    upstream and every path-parameter route 404'd.

    The ``gateway_url`` and ``client`` parameters exist for tests
    that need to inject their own destination / mocked transport.
    Production callers pass neither and get the env-configured
    defaults.
    """
    upstream_base = (gateway_url or _gateway_base_url()).rstrip("/")
    # Forward the concrete request path, not the registered template.
    # FastAPI puts the substituted path on request.url.path.
    upstream_url = upstream_base + request.url.path
    query = request.url.query
    if query:
        upstream_url = f"{upstream_url}?{query}"

    headers = _filter_request_headers(request.headers)

    # BW4 Item 1/2 (v1.0.10 security lockdown): when a service token is
    # configured the upstream is the loopback ical-server, whose auth
    # boundary requires PWG_SERVICE_TOKEN rather than the client's
    # zeroclaw_token bearer. VALIDATE the client bearer against the
    # gateway's paired-token store FIRST, then substitute the service
    # token. Validation + substitution ship together: substituting
    # without validating would let any loopback caller that reaches
    # :8089 inherit ical-server access. With no service token set the
    # Doctor stays a transparent pass-through (e.g. the CM019
    # Safari-ingest surface, whose upstream verifies the bearer itself).
    service_token = _resolve_service_token()
    if service_token:
        client_bearer = _extract_bearer_token(request.headers)
        if not _is_paired_bearer(client_bearer):
            logger.warning(
                "Doctor proxy: rejecting unpaired client bearer for %s %s",
                request.method,
                path,
            )
            return Response(
                content="unauthorized: client bearer is not a paired token",
                status_code=401,
                media_type="text/plain",
            )
        headers["authorization"] = f"Bearer {service_token}"

    body = await request.body()

    async def _do_request(http_client: httpx.AsyncClient) -> httpx.Response:
        return await http_client.request(
            method=request.method,
            url=upstream_url,
            headers=headers,
            content=body,
        )

    try:
        if client is not None:
            upstream_resp = await _do_request(client)
        else:
            async with httpx.AsyncClient(
                timeout=_UPSTREAM_TIMEOUT_SECONDS
            ) as new_client:
                upstream_resp = await _do_request(new_client)
    except httpx.RequestError as exc:
        # Network-layer failure: connect refused, DNS, timeout etc.
        # Surface as 502 so iOS sees an unambiguous upstream failure
        # rather than a 500 that could be confused with a Doctor
        # bug.
        logger.warning(
            "Doctor proxy: upstream gateway unreachable for %s %s: %s",
            request.method,
            path,
            exc,
        )
        return Response(
            content=f"upstream gateway unreachable: {exc.__class__.__name__}",
            status_code=502,
            media_type="text/plain",
        )

    response_headers = _filter_response_headers(upstream_resp.headers)
    return Response(
        content=upstream_resp.content,
        status_code=upstream_resp.status_code,
        headers=response_headers,
        media_type=upstream_resp.headers.get("content-type"),
    )


def register_proxy_routes(
    app: FastAPI,
    paths: Optional[Iterable[str]] = None,
    gateway_url: Optional[str] = None,
) -> list[str]:
    """Register a reverse-proxy handler on ``app`` for each path
    in ``paths`` (or the env-configured default if not given).

    Returns the list of paths actually registered, so callers can
    log them. Each path is registered for GET / POST / PUT /
    DELETE / PATCH so iOS-initiated calls that switch verb (e.g.
    polling the ingest status route via GET) work without a code
    change here.
    """
    actual_paths = (
        list(paths) if paths is not None else _load_proxy_paths()
    )

    for path in actual_paths:
        # Closure-capture the path so each registered handler
        # forwards to the correct upstream route. ``_path`` and
        # ``_gateway_url`` default-arg captures freeze the values
        # at registration time so a later env-var change does NOT
        # change behaviour for already-registered routes.
        async def _handler(  # noqa: D401
            request: Request,
            _path: str = path,
            _gateway_url: Optional[str] = gateway_url,
        ) -> Response:
            return await proxy_request(
                request, _path, gateway_url=_gateway_url
            )

        # Name the route from the path so FastAPI's url_for /
        # OpenAPI emission don't collide if multiple paths are
        # registered.
        route_name = "doctor_proxy" + path.replace("/", "_")
        app.add_api_route(
            path,
            _handler,
            methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
            name=route_name,
        )
        logger.info(
            "Doctor proxy registered: %s -> %s%s",
            path,
            (gateway_url or _gateway_base_url()),
            path,
        )

    return actual_paths
