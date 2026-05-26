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
"""
from __future__ import annotations

import logging
import os
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
