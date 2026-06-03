"""Doctor-side surface for the Pair iOS device panel (DFA-002 + §3.3).

Reads the §3.3 pairing envelope from the ostler-assistant gateway's
``/admin/paircode`` endpoint, re-serialises it into the compact JSON
string the QR carries, and exposes a small structured shape the Doctor
UI consumes via ``/api/v1/pair/status`` and ``/api/v1/pair/regenerate``.

The QR encodes the full envelope JSON (``{v, hub_addr, rp_id,
pairing_token, expires_at}``) so CM031's ``PairingTokenQR.parse`` can
strict-decode it. The legacy 6-digit ``pairing_code`` is still in the
gateway's response (TUI + web-dashboard consumers) but never surfaced
on the customer-facing panel.

The gateway is the canonical source for the envelope. Earlier audit
notes referenced a ``pair-payload.json`` on disk; the v0.3.1 gateway
does write that file at boot, but the HTTP path is preferred here
because it returns the freshest mint (the disk file is written once at
boot and only refreshed when the gateway proactively rotates).

Single-machine architecture (HR015 §0.5): Doctor and the gateway live
on the same Mac. The gateway listens on ``127.0.0.1:<port>`` with
localhost-only enforcement on ``/admin/*`` routes, so Doctor's outbound
is loopback and the same-host invariant satisfies the server-side
gate.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from typing import Optional

import httpx
import qrcode
import qrcode.image.svg

# zeroclaw-config's ``default_gateway_port``. Kept in sync deliberately:
# both sides read ``ZEROCLAW_GATEWAY_PORT`` then ``PORT`` then the default.
_DEFAULT_GATEWAY_PORT = 42617

# Loopback round-trip; anything past three seconds means the gateway is
# wedged and a friendly empty-state beats a hung dashboard.
_HTTP_TIMEOUT_SECS = 3.0

# Spec-mandated key set per ``SHARED_AUTH_SPEC.md §3.2`` and CM031's
# ``PairingTokenQR.swift:56``. iOS strict-decodes; any extra or missing
# field is a hard reject. Doctor validates here so a gateway-side drift
# surfaces as a friendly empty state rather than a silent unscannable QR.
_REQUIRED_ENVELOPE_KEYS = frozenset(
    {"v", "hub_addr", "rp_id", "pairing_token", "expires_at"},
)

log = logging.getLogger(__name__)


@dataclass
class PairStatus:
    """Structured result a Doctor route can JSON-serialise directly."""

    available: bool
    hub_addr: Optional[str]
    expires_at: Optional[int]
    qr_svg: Optional[str]
    error: Optional[str]
    error_kind: Optional[str]

    def to_dict(self) -> dict:
        return {
            "available": self.available,
            "hub_addr": self.hub_addr,
            "expires_at": self.expires_at,
            "qr_svg": self.qr_svg,
            "error": self.error,
            "error_kind": self.error_kind,
        }


def gateway_port() -> int:
    """Resolve the gateway port from env, mirroring zeroclaw-config's order."""
    for var in ("ZEROCLAW_GATEWAY_PORT", "PORT"):
        raw = os.environ.get(var)
        if raw:
            try:
                return int(raw)
            except ValueError:
                log.warning("Ignoring non-integer %s=%r", var, raw)
    return _DEFAULT_GATEWAY_PORT


def _admin_paircode_url(port: int, fresh: bool) -> str:
    suffix = "/admin/paircode/new" if fresh else "/admin/paircode"
    return f"http://127.0.0.1:{port}{suffix}"


def envelope_to_qr_payload(envelope: dict) -> str:
    """Re-serialise the §3.3 envelope into the compact JSON the QR carries.

    Preserves the dict's insertion order (which Python ``json.loads``
    inherits from the gateway's serde output), so the encoded string is
    byte-identical to what the gateway prints at boot. iOS doesn't care
    about field order (``JSONSerialization`` parses to a dict), but
    keeping the order stable makes the test parity assertions tighter.
    """
    return json.dumps(envelope, separators=(",", ":"), ensure_ascii=False)


def render_qr_svg(payload: str) -> str:
    """Encode ``payload`` as an inline SVG path. Pure stdlib XML, no PIL.

    ``box_size`` and ``border`` are tuned so the rendered SVG looks
    crisp at ~280 px square on the Doctor page without overwhelming a
    smaller viewport. The §3.3 envelope JSON is ~150 bytes, so QR
    capacity at error-correction level M handles it comfortably.
    """
    factory = qrcode.image.svg.SvgPathImage
    img = qrcode.make(
        payload,
        image_factory=factory,
        box_size=10,
        border=2,
        error_correction=qrcode.constants.ERROR_CORRECT_M,
    )
    return img.to_string(encoding="unicode")


def _classify_request_error(exc: Exception) -> tuple[str, str]:
    """Map an httpx exception to (error_kind, customer-safe error string)."""
    if isinstance(exc, httpx.ConnectError):
        return "gateway_down", "Hub not ready yet"
    if isinstance(exc, httpx.TimeoutException):
        return "gateway_timeout", "Hub is taking too long to respond"
    return "gateway_unreachable", "Could not reach the Hub"


def _validate_envelope(envelope: object) -> Optional[str]:
    """Return None if ``envelope`` looks like a §3.3 payload, else a reason."""
    if not isinstance(envelope, dict):
        return "qr_payload is not an object"
    keys = set(envelope.keys())
    missing = _REQUIRED_ENVELOPE_KEYS - keys
    if missing:
        return f"qr_payload missing fields: {sorted(missing)}"
    extra = keys - _REQUIRED_ENVELOPE_KEYS
    if extra:
        return f"qr_payload has unexpected fields: {sorted(extra)}"
    if envelope.get("v") != 1:
        return f"qr_payload version is not 1: {envelope.get('v')!r}"
    if envelope.get("rp_id") != "creativemachines.ai":
        return f"qr_payload rp_id is wrong: {envelope.get('rp_id')!r}"
    if not isinstance(envelope.get("hub_addr"), str) or not envelope["hub_addr"]:
        return "qr_payload hub_addr is not a non-empty string"
    if not isinstance(envelope.get("pairing_token"), str):
        return "qr_payload pairing_token is not a string"
    if not isinstance(envelope.get("expires_at"), int):
        return "qr_payload expires_at is not an integer"
    return None


def _build_status_from_envelope(envelope: dict) -> PairStatus:
    qr_json = envelope_to_qr_payload(envelope)
    try:
        qr_svg = render_qr_svg(qr_json)
    except Exception:
        log.exception("QR encoding failed for §3.3 envelope")
        return PairStatus(
            available=False,
            hub_addr=None,
            expires_at=None,
            qr_svg=None,
            error="QR encoding failed",
            error_kind="qr_render_failed",
        )
    return PairStatus(
        available=True,
        hub_addr=envelope["hub_addr"],
        expires_at=int(envelope["expires_at"]),
        qr_svg=qr_svg,
        error=None,
        error_kind=None,
    )


def fetch_pair_status(
    *,
    client: Optional[httpx.Client] = None,
    fresh: bool = False,
) -> PairStatus:
    """Fetch the current (or fresh) pair envelope from the gateway.

    Pass ``fresh=True`` to POST ``/admin/paircode/new`` and rotate the
    envelope; otherwise GET the current value. ``client`` is for tests
    that need to inject ``httpx.MockTransport``; production calls leave
    it ``None`` and the function owns a short-lived client.
    """
    port = gateway_port()
    url = _admin_paircode_url(port, fresh=fresh)
    method = "POST" if fresh else "GET"
    owned = client is None
    http = client or httpx.Client(timeout=_HTTP_TIMEOUT_SECS)
    try:
        try:
            resp = http.request(method, url)
        except Exception as exc:
            kind, friendly = _classify_request_error(exc)
            return PairStatus(
                available=False,
                hub_addr=None,
                expires_at=None,
                qr_svg=None,
                error=friendly,
                error_kind=kind,
            )
        if resp.status_code != 200:
            return PairStatus(
                available=False,
                hub_addr=None,
                expires_at=None,
                qr_svg=None,
                error=f"Gateway returned HTTP {resp.status_code}",
                error_kind="gateway_http_error",
            )
        try:
            body = json.loads(resp.content.decode("utf-8", errors="replace"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return PairStatus(
                available=False,
                hub_addr=None,
                expires_at=None,
                qr_svg=None,
                error="Gateway returned a malformed response",
                error_kind="gateway_malformed",
            )
        if not isinstance(body, dict):
            return PairStatus(
                available=False,
                hub_addr=None,
                expires_at=None,
                qr_svg=None,
                error="Gateway returned an unexpected response",
                error_kind="gateway_malformed",
            )

        pairing_required = bool(body.get("pairing_required"))
        envelope_raw = body.get("qr_payload")

        if envelope_raw is None:
            if not pairing_required:
                return PairStatus(
                    available=False,
                    hub_addr=None,
                    expires_at=None,
                    qr_svg=None,
                    error=None,
                    error_kind="pairing_disabled",
                )
            return PairStatus(
                available=False,
                hub_addr=None,
                expires_at=None,
                qr_svg=None,
                error=None,
                error_kind="no_code_active",
            )

        validation_error = _validate_envelope(envelope_raw)
        if validation_error is not None:
            log.warning("Gateway envelope failed validation: %s", validation_error)
            return PairStatus(
                available=False,
                hub_addr=None,
                expires_at=None,
                qr_svg=None,
                error="Gateway returned an envelope the iOS app cannot read",
                error_kind="gateway_envelope_invalid",
            )

        return _build_status_from_envelope(envelope_raw)
    finally:
        if owned:
            http.close()
