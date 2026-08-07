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

import hmac
import logging
import os
from typing import Iterable, Optional

import httpx
from fastapi import FastAPI, Request, Response


logger = logging.getLogger(__name__)


DEFAULT_GATEWAY_URL = "http://127.0.0.1:8000"

# P0-α (2026-07-26): the paired-bearer oracle (/internal/validate-bearer) lives
# on the GATEWAY (:8000). Production install.sh overrides DOCTOR_GATEWAY_URL to
# the ical-server (:8090) for the /api/v1/* substitution FORWARD -- so
# validation must NOT reuse DOCTOR_GATEWAY_URL, or every validate POST lands on
# the ical-server, which 401s it -> every paired client rejected -> the
# "Reconnection paused" loop this fix was meant to close. Distinct knob, so the
# forward target and the validation target can never collide again.
DEFAULT_VALIDATOR_URL = "http://127.0.0.1:8000"
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

# Bearer-validation call timeout (BW2-5). A loopback round-trip to the
# gateway's /internal/validate-bearer oracle; a few seconds is generous, and
# a slow/wedged gateway must fail closed fast rather than hang every request.
_PAIR_VALIDATE_TIMEOUT_SECONDS = 3.0


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


def _validator_base_url() -> str:
    """Base URL of the gateway that answers ``/internal/validate-bearer``.

    P0-α: distinct from :func:`_gateway_base_url`. Production install.sh points
    ``DOCTOR_GATEWAY_URL`` at the ical-server (:8090) for the substitution
    forward, but the paired-bearer oracle lives on the gateway (:8000). Reading
    ``DOCTOR_GATEWAY_URL`` here (as the pre-fix code did) sent every validation
    POST to the ical-server, whose ``_guard`` returned 401, so the Doctor treated
    every paired client as unpaired and the Hub looped "Reconnection paused".
    """
    return os.environ.get(
        "DOCTOR_VALIDATOR_URL", DEFAULT_VALIDATOR_URL
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
# When a service token is configured the upstream is the ical-server, so the
# Doctor VALIDATES the caller's paired bearer before substituting the service
# token (substituting without validating would let any loopback caller inherit
# ical-server access).
#
# BW2-5 (2026-07-25): validation is DELEGATED to the gateway, not re-implemented
# here. The Doctor used to re-read ``[gateway].paired_tokens`` from
# ``config.toml`` and hash them itself -- but the v1.0.10 security lockdown made
# those tokens ``enc2:`` encrypted at rest, which the Doctor cannot decode, so
# it rejected every real client and the Hub looped "Reconnection paused". Two
# implementations of one auth predicate drifted. Now ``_is_paired_bearer`` calls
# the gateway's loopback-only ``POST /internal/validate-bearer`` oracle, which
# validates against the live ``PairingGuard`` (the single source of truth, which
# already decrypts ``enc2:`` on config load). One implementation, no drift.

# Env var names install.sh may seed the ical-server service token under.
# OSTLER_SERVICE_TOKEN takes precedence over the legacy PWG_SERVICE_TOKEN.
_SERVICE_TOKEN_ENV_VARS = ("OSTLER_SERVICE_TOKEN", "PWG_SERVICE_TOKEN")


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


def _extract_bearer_token(headers) -> str:
    """Return the bearer credential from the Authorization header, or
    ``''`` if absent/malformed. Mirror of the gateway's extractor."""
    raw = headers.get("authorization") or headers.get("Authorization") or ""
    prefix = "Bearer "
    if raw.startswith(prefix):
        return raw[len(prefix):].strip()
    return ""


# Whether the gateway has been observed NOT to serve the bearer-validation
# oracle. Set only by a 404/405 from that route, cleared by any real 401.
# Process-local and deliberately not persisted: it describes the daemon we are
# talking to right now, and must re-derive itself after a daemon swap.
_ORACLE_STATE = {"absent": False}


def _machine_admin_token() -> str:
    """The machine-local admin token, if this install has one."""
    for name in ("OSTLER_ADMIN_TOKEN", "OSTLER_MACHINE_ADMIN_TOKEN"):
        raw = os.environ.get(name, "").strip()
        if raw:
            return raw
    return ""


def _local_fallback_allowed(request, client_bearer: str) -> bool:
    """May this request proceed even though the gateway gave no auth verdict?

    ONLY when all of:
      * the bearer-validation oracle is absent (deployment skew, not denial),
      * the caller is on loopback -- never a remote or tunnelled client, and
      * the caller either presents the machine admin token, or is doing a
        read-only GET.

    The narrowness is the point. A missing endpoint must degrade to "the
    person sitting at this Mac can still read their own data", never to
    "anyone on the network is authenticated". On a daemon that serves the
    oracle this function is unreachable, because `absent` is never set.

    THE LOOPBACK ASSUMPTION, AND ITS EXPIRY DATE (Archie, 2026-08-08)
    ----------------------------------------------------------------
    This whole function rests on "arrived on loopback" meaning "is physically
    at this Mac". That holds for the SHIPPED wiring and was verified against
    it: Doctor's uvicorn binds loopback with no proxy_headers, nothing
    tailscale-serves :8089, and the Companion TLS listener terminates on the
    daemon, not here.

    It is an assumption about WIRING, not about this file, so this file cannot
    keep it true. The day someone puts a reverse proxy in front of Doctor,
    enables proxy_headers, or points `tailscale serve` at a Doctor loopback
    port -- exactly what CM051 #512 now does for the WIKI -- every remote
    caller starts presenting as 127.0.0.1 and this fallback silently widens
    from "the owner" to "the tailnet".

    Hence the kill switch below. It defaults ON, so behaviour is unchanged
    today. Its job is to be a thing that must be consciously kept on: a future
    PR that wires any of the above has to come past this env var and decide,
    at wire-time, whether the fallback is still safe -- rather than inheriting
    a decision nobody remembers making.
    """
    if os.environ.get("OSTLER_DOCTOR_ORACLE_FALLBACK", "1").strip().lower() in (
        "0", "false", "no", "off",
    ):
        return False

    if not _ORACLE_STATE["absent"]:
        return False

    host = ""
    try:
        if request.client and request.client.host:
            host = str(request.client.host)
    except Exception:  # pragma: no cover - defensive
        return False
    if host not in ("127.0.0.1", "::1", "localhost"):
        return False

    admin = _machine_admin_token()
    # compare_digest, not ==, so the comparison time does not depend on how
    # many leading characters matched. A loopback attacker who can make
    # repeated requests could otherwise recover the admin token one character
    # at a time. The window is narrow -- this path is only live on a daemon
    # that does not serve the oracle -- but the cost of closing it is one
    # import, and "narrow" is not "closed". (Archie, 2026-08-08.)
    # ...and compare BYTES, not str. compare_digest raises TypeError on str
    # operands containing non-ASCII, and client_bearer is attacker-controlled:
    # a bearer of "sekrité" would have crashed the proxy rather than being
    # rejected. Caught by test_non_ascii_bearer_does_not_crash on the first run
    # after the compare_digest swap -- the hardening introduced the bug and the
    # test written alongside it found it.
    if admin and client_bearer and hmac.compare_digest(
        client_bearer.encode("utf-8", "surrogatepass"),
        admin.encode("utf-8", "surrogatepass"),
    ):
        return True

    method = str(getattr(request, "method", "") or "").upper()
    return method in ("GET", "HEAD")


async def _is_paired_bearer(
    token: str,
    validator_url: Optional[str] = None,
    client: Optional[httpx.AsyncClient] = None,
) -> bool:
    """Return ``True`` iff the gateway considers ``token`` a currently-paired
    bearer.

    The gateway is the single source of pairing truth. It decrypts the
    ``enc2:``-encrypted ``[gateway].paired_tokens`` on config load and holds
    them in its live ``PairingGuard``. The Doctor used to re-read
    ``config.toml`` and hash the tokens itself, but it cannot decode the
    ``enc2:`` at-rest format the v1.0.10 security lockdown introduced, so it
    rejected every real client and the Hub looped "Reconnection paused /
    Getting things ready" (BW2-5). We now defer to the gateway's loopback-only
    ``POST /internal/validate-bearer`` oracle, whose ``204`` / ``401`` answer
    *is* the gateway's own auth decision -- one implementation, no drift.

    Fails CLOSED: any error (gateway unreachable, timeout, unexpected status)
    returns ``False`` so an unvalidated client bearer never inherits the
    ical-server service token.
    """
    base = (validator_url or _validator_base_url()).rstrip("/")
    url = f"{base}/internal/validate-bearer"
    payload = {"bearer": token or ""}
    try:
        if client is not None:
            resp = await client.post(
                url, json=payload, timeout=_PAIR_VALIDATE_TIMEOUT_SECONDS
            )
        else:
            async with httpx.AsyncClient() as ephemeral:
                resp = await ephemeral.post(
                    url, json=payload, timeout=_PAIR_VALIDATE_TIMEOUT_SECONDS
                )
    except (httpx.HTTPError, OSError) as exc:
        logger.warning(
            "Doctor proxy: bearer-validation call to the gateway failed "
            "(%s); failing closed",
            exc,
        )
        return False
    if resp.status_code == 204:
        return True
    # 404/405 is NOT an auth decision -- it means this daemon build does not
    # serve the oracle at all (deployment skew), and the gateway has therefore
    # expressed no opinion about the bearer. Treating "route absent" as "auth
    # denied" is what turned a missing endpoint into a TOTAL lockout on the
    # v1.0.14.1 box-walk: every /api/v1/* answered 401 and the Hub sat on
    # "Connecting..." for ever on a machine whose data layer was perfectly
    # healthy. Record the skew so the loopback fallback below can apply; the
    # flag is only ever set by these two statuses, so on a daemon that does
    # serve the oracle this branch never runs and nothing changes.
    if resp.status_code in (404, 405):
        if not _ORACLE_STATE["absent"]:
            # 405 is louder than 404 on purpose (Archie, 2026-08-08). 404 says
            # "no such route" -- an older daemon, the case this exists for. 405
            # says "route exists, wrong method", which is evidence the oracle
            # IS there and we are calling it incorrectly. Same handling, but
            # 405 is an API-shape drift we want visible in triage rather than
            # quietly absorbed as skew.
            logger.log(
                logging.ERROR if resp.status_code == 405 else logging.WARNING,
                "Doctor proxy: gateway does not serve /internal/validate-bearer "
                "(HTTP %s at %s). This is deployment skew, not an auth denial. "
                "Loopback callers will be admitted under the local fallback; "
                "remote callers stay denied.%s",
                resp.status_code,
                validator_url or "<default validator url>",
                " A 405 means the route EXISTS but rejected our method -- check"
                " the validator API shape, this is probably not skew."
                if resp.status_code == 405 else "",
            )
        _ORACLE_STATE["absent"] = True
        return False
    if resp.status_code != 401:
        logger.warning(
            "Doctor proxy: unexpected /internal/validate-bearer status %s; "
            "failing closed",
            resp.status_code,
        )
    # A real 401 means the oracle exists and rejected this bearer, so any
    # earlier skew observation is stale -- clear it rather than letting one
    # 404 during a restart permanently loosen the door.
    _ORACLE_STATE["absent"] = False
    return False


async def proxy_request(
    request: Request,
    path: str,
    gateway_url: Optional[str] = None,
    validator_url: Optional[str] = None,
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
        # BW2-5: ask the gateway (single source of pairing truth, which decrypts
        # the enc2: paired_tokens) rather than re-reading config.toml ourselves.
        authorized = await _is_paired_bearer(
            client_bearer, validator_url=validator_url, client=client
        )
        if not authorized and _local_fallback_allowed(request, client_bearer):
            # The gateway expressed no opinion because it does not serve the
            # oracle at all. Admit this narrow loopback case rather than
            # locking the owner out of their own machine. See
            # _local_fallback_allowed for why this cannot widen access.
            logger.warning(
                "Doctor proxy: admitting loopback %s %s under the local "
                "fallback (gateway serves no bearer-validation oracle)",
                request.method,
                path,
            )
            authorized = True
        if not authorized:
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
    validator_url: Optional[str] = None,
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
            _validator_url: Optional[str] = validator_url,
        ) -> Response:
            return await proxy_request(
                request,
                _path,
                gateway_url=_gateway_url,
                validator_url=_validator_url,
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
