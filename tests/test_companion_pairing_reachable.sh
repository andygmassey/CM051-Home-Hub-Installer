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
#   The fix gives the phone its OWN reachable, TLS-terminated listener
#   rather than putting TLS on the loopback-shared :8000 (which would
#   break the same-host Hub UI, the Doctor's pairing-QR panel and the
#   chat-token mint -- all plain-HTTP consumers of :8000). Asserted here:
#     1. [gateway] companion_enabled = true        -> dedicated listener
#     2. companion_host = 0.0.0.0 + companion_port  -> LAN/tailnet bind
#     3. companion_cert_path/key_path               -> https:// scheme
#     4. a self-signed cert is generated            -> the cert exists
#   plus the off-LAN path: `tailscale serve` covers the companion port.
#
#   SHARED_AUTH_SPEC.md §3.6: HTTPS is mandatory; the Companion
#   trust-on-first-use-pins the Hub's self-signed leaf SPKI. The
#   /auth/pair/* handlers are gated by the one-time pairing_token, so
#   the LAN-reachable companion listener is the designed posture
#   (Appendix A: a LAN attacker cannot read plaintext under TLS +
#   pinning). Requires the ostler-assistant companion-listener support
#   (GatewayConfig.companion_*).
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

# ── 1. Dedicated companion listener is enabled ──────────────────────
# Must be emitted unconditionally inside the `{ ... } > "$ASSISTANT_CONFIG"`
# brace block (exactly 4 leading spaces). A deeper indent means a future
# edit wrapped it in a channel-gated `if` and silently disabled the
# companion listener whenever that branch is skipped.
if ! grep -q 'echo "companion_enabled = true"' "$INSTALL_SCRIPT"; then
    echo "FAIL [companion-enabled]: install.sh does not enable the companion listener" >&2
    echo "      Without it the gateway advertises its own loopback :8000 in the QR, which the phone cannot reach." >&2
    exit 1
fi
CE_INDENT="$(grep -nE '^[[:space:]]+echo "companion_enabled = true"$' "$INSTALL_SCRIPT" \
    | head -n 1 | sed -E 's/^[0-9]+:( +).*/\1/' | awk '{ print length }')"
if [[ -z "$CE_INDENT" || "$CE_INDENT" -ne 4 ]]; then
    echo "FAIL [companion-conditional]: companion_enabled is not at the top level of the config emitter (indent='${CE_INDENT}', expected 4)" >&2
    exit 1
fi
echo 'PASS: install.sh enables the companion listener, unconditionally'

# ── 2. Companion listener binds a routable interface + port ─────────
if ! grep -q 'echo "companion_host = \\"0.0.0.0\\""' "$INSTALL_SCRIPT"; then
    echo "FAIL [companion-host]: companion_host is not 0.0.0.0 (LAN/tailnet-reachable)" >&2
    exit 1
fi
if ! grep -qE 'echo "companion_port = [0-9]+"' "$INSTALL_SCRIPT"; then
    echo "FAIL [companion-port]: companion_port is not set" >&2
    exit 1
fi
echo 'PASS: install.sh binds the companion listener to 0.0.0.0:<port>'

# ── 3. TLS cert/key wired so the https:// scheme matches ────────────
if ! grep -q 'echo "companion_cert_path = ' "$INSTALL_SCRIPT" \
        || ! grep -q 'echo "companion_key_path = ' "$INSTALL_SCRIPT"; then
    echo "FAIL [companion-tls-paths]: companion_cert_path/companion_key_path not set" >&2
    echo "      Without TLS the companion listener could not satisfy iOS's https-only pairing." >&2
    exit 1
fi
echo 'PASS: install.sh wires companion_cert_path + companion_key_path'

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
if ! grep -q 'echo "companion_cert_path = \\"\${GATEWAY_TLS_CERT}\\""' "$INSTALL_SCRIPT" \
        || ! grep -q 'echo "companion_key_path = \\"\${GATEWAY_TLS_KEY}\\""' "$INSTALL_SCRIPT"; then
    echo "FAIL [cert-path-binding]: config.toml companion cert/key paths do not reference the generated cert variables" >&2
    exit 1
fi
echo 'PASS: install.sh generates a persistent self-signed cert and points config.toml at it'

# ── 5. Off-LAN path: tailscale serve covers the companion port ──────
# The pairing QR advertises the companion port (8443); the Tailscale
# tunnel must forward that same port or off-LAN pairing breaks.
if ! grep -qE 'for _ts_port in[^;]*\b8443\b' "$INSTALL_SCRIPT"; then
    echo "FAIL [tailscale-serve-8443]: tailscale serve does not forward the companion port 8443" >&2
    exit 1
fi
echo 'PASS: tailscale serve forwards the companion port 8443 for the off-LAN pairing path'

echo ""
echo "ALL COMPANION PAIRING REACHABILITY TESTS PASSED"
