#!/usr/bin/env bash
#
# tests/test_companion_pairing_reachable.sh
#
# Fail-closed gate for the iOS Companion (CM031) pairing path on a
# CLEAN install: "fresh install -> companion completes the §3.3 pair
# on a clean box".
#
# Why this test exists (the P0 it locks shut):
#
#   The [gateway] section pinned `port = 8000` but left `host` at
#   zeroclaw's default `127.0.0.1` and wrote no [gateway.tls]. So the
#   ostler-assistant daemon bound LOOPBACK-ONLY and served PLAIN HTTP.
#   The gateway's pairing-QR builder, seeing a loopback bind, still
#   advertised the discovered LAN IP, so the QR handed the phone
#   `https://<lan-ip>:8000/auth/pair/init` -- an address nothing was
#   listening on, over a scheme (https) the daemon did not speak. iOS
#   pairing could never complete on a clean install. The iOS Local
#   Network permission was a red herring.
#
#   The fix has three load-bearing parts, all asserted here:
#     1. [gateway] host = "0.0.0.0"        -> LAN-reachable bind
#     2. [gateway.tls] enabled + cert/key  -> https:// scheme matches
#     3. a self-signed cert is generated   -> the cert files exist
#   plus the off-LAN path: `tailscale serve` covers :8000.
#
#   SHARED_AUTH_SPEC.md §3.6: HTTPS is mandatory; the Companion
#   trust-on-first-use-pins the Hub's self-signed leaf SPKI. The
#   /auth/pair/* handlers are gated by the one-time pairing_token, so
#   the LAN-reachable bind is the designed posture (Appendix A: a LAN
#   attacker cannot read plaintext under TLS + pinning).
#
# Sister tests:
#   - test_assistant_config_vane_wiring.sh -- locks the Vane wiring
#   - test_tailscale_signin_hoisted.sh     -- locks the Tailscale hoist

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── 1. LAN-reachable bind (host = "0.0.0.0") ────────────────────────
# Must be emitted unconditionally inside the `{ ... } > "$ASSISTANT_CONFIG"`
# brace block (exactly 4 leading spaces). A deeper indent means a future
# edit wrapped the bind in a channel-gated `if` and silently reverted to
# the loopback default whenever that branch is skipped.
if ! grep -q 'echo "host = \\"0.0.0.0\\""' "$INSTALL_SCRIPT"; then
    echo "FAIL [gateway-host-bind]: install.sh does not bind the gateway to 0.0.0.0" >&2
    echo "      A loopback bind makes the pairing QR address unreachable from the phone." >&2
    exit 1
fi
HOST_INDENT="$(grep -nE '^[[:space:]]+echo "host = \\"0\.0\.0\.0\\""$' "$INSTALL_SCRIPT" \
    | head -n 1 | sed -E 's/^[0-9]+:( +).*/\1/' | awk '{ print length }')"
if [[ -z "$HOST_INDENT" || "$HOST_INDENT" -ne 4 ]]; then
    echo "FAIL [gateway-host-conditional]: gateway host bind is not at the top level of the config emitter (indent='${HOST_INDENT}', expected 4)" >&2
    exit 1
fi
echo 'PASS: install.sh binds the gateway to 0.0.0.0 (LAN-reachable), unconditionally'

# ── 2. Public-bind opt-in (silences the daemon warning) ─────────────
if ! grep -q 'echo "allow_public_bind = true"' "$INSTALL_SCRIPT"; then
    echo "FAIL [allow-public-bind]: install.sh does not set allow_public_bind = true" >&2
    exit 1
fi
echo 'PASS: install.sh sets allow_public_bind = true'

# ── 3. TLS enabled so the https:// scheme matches ───────────────────
if ! grep -q '\[gateway\.tls\]' "$INSTALL_SCRIPT"; then
    echo "FAIL [gateway-tls-header]: install.sh does not emit a [gateway.tls] block" >&2
    echo "      Without TLS the daemon serves plain HTTP; iOS forces https:// and the handshake fails." >&2
    exit 1
fi
if ! grep -qE '^[[:space:]]+echo "enabled = true"' "$INSTALL_SCRIPT"; then
    echo "FAIL [gateway-tls-enabled]: [gateway.tls] does not set enabled = true" >&2
    exit 1
fi
if ! grep -q 'echo "cert_path = ' "$INSTALL_SCRIPT" \
        || ! grep -q 'echo "key_path = ' "$INSTALL_SCRIPT"; then
    echo "FAIL [gateway-tls-paths]: [gateway.tls] does not set cert_path/key_path" >&2
    exit 1
fi
echo 'PASS: install.sh enables [gateway.tls] with cert_path + key_path'

# ── 4. A self-signed cert is actually generated ─────────────────────
# iOS trust-on-first-use-pins the leaf SPKI, so the cert just has to
# exist and be stable across restarts (persisted under assistant-config).
if ! grep -q 'openssl req -x509' "$INSTALL_SCRIPT"; then
    echo "FAIL [cert-gen]: install.sh does not generate a self-signed gateway certificate" >&2
    exit 1
fi
if ! grep -q 'GATEWAY_TLS_DIR=' "$INSTALL_SCRIPT" \
        || ! grep -q 'GATEWAY_TLS_CERT=' "$INSTALL_SCRIPT" \
        || ! grep -q 'GATEWAY_TLS_KEY=' "$INSTALL_SCRIPT"; then
    echo "FAIL [cert-paths]: gateway TLS cert/key paths are not defined" >&2
    exit 1
fi
# The cert path emitted into config.toml must be the same variable the
# generator writes to -- otherwise the daemon points at a missing file.
if ! grep -q 'echo "cert_path = \\"\${GATEWAY_TLS_CERT}\\""' "$INSTALL_SCRIPT" \
        || ! grep -q 'echo "key_path = \\"\${GATEWAY_TLS_KEY}\\""' "$INSTALL_SCRIPT"; then
    echo "FAIL [cert-path-binding]: config.toml cert/key paths do not reference the generated cert variables" >&2
    exit 1
fi
echo 'PASS: install.sh generates a persistent self-signed cert and points config.toml at it'

# ── 5. Off-LAN path: tailscale serve covers :8000 ───────────────────
# The pairing QR encodes the gateway port (8000); the Tailscale tunnel
# must forward that same port or off-LAN pairing/chat breaks.
if ! grep -qE 'for _ts_port in[^;]*\b8000\b' "$INSTALL_SCRIPT"; then
    echo "FAIL [tailscale-serve-8000]: tailscale serve does not forward port 8000 (the pairing/chat API)" >&2
    exit 1
fi
echo 'PASS: tailscale serve forwards port 8000 for the off-LAN pairing path'

echo ""
echo "ALL COMPANION PAIRING REACHABILITY TESTS PASSED"
