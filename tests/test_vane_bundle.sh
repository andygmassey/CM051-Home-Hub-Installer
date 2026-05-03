#!/usr/bin/env bash
#
# tests/test_vane_bundle.sh
#
# Locks the Vane (local web search) bundling in install.sh.
#
# Why this test exists:
#
#   The customer-facing comparison pages on ostler.ai (privacy.html,
#   why-local.html, vs-perplexity, vs-poke, vs-zo, vs-gemini, compare)
#   all promise "Web search: Yes (local via SearXNG)". Before this
#   PR, install.sh did NOT actually install Vane / SearXNG -- they
#   only ran on Andy's dev Gaming PC. Customers would install Ostler,
#   look for web search, and find it missing -- a credibility gap.
#
#   This test pins the wiring so the promise stays kept:
#     1. The compose heredoc declares the `vane` service with the
#        right image tag (pinned, not :latest), container name,
#        port, volume, and Ollama-host gateway.
#     2. Phase 3.8b brings the container up in its own isolated
#        block (so a registry hiccup never breaks the data layer).
#     3. The user-facing copy + uninstaller mention Vane.
#
#   A future heredoc edit that drops any of these would silently
#   re-introduce the credibility gap; this test traps it at CI.
#
# Pure shell + grep / awk. No docker.
#
# Sister tests:
#   - test_wiki_compose_paths.sh -- locks wiki-site / wiki-compiler
#   - test_third_party_data_consent.sh -- locks Caveat 1 consent screen

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

# 1. Parse check
if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# Extract the docker-compose heredoc body (between <<'DCEOF' and DCEOF).
COMPOSE="$(mktemp)"
trap 'rm -f "$COMPOSE"' EXIT

awk '
    /<<'\''DCEOF'\''/ { capture = 1; next }
    /^DCEOF$/         { capture = 0 }
    capture           { print }
' "$INSTALL_SCRIPT" > "$COMPOSE"

if [[ ! -s "$COMPOSE" ]]; then
    echo "FAIL: docker-compose heredoc body is empty" >&2
    echo "      (heredoc markers in install.sh may have changed shape)" >&2
    exit 1
fi

assert_contains() {
    local label="$1"
    local needle="$2"
    if ! grep -qF -- "$needle" "$COMPOSE"; then
        echo "FAIL [$label]: heredoc missing expected line:" >&2
        echo "  $needle" >&2
        exit 1
    fi
}

# ── Compose: vane service declared ──────────────────────────────
assert_contains "vane-service-key" \
    "  vane:"
echo "PASS: compose heredoc declares the vane service"

# ── Compose: pinned image tag (not :latest) ─────────────────────
# Pin matters for productisation -- :latest can silently change
# behaviour mid-flight. Slim variant requires external SearXNG
# and would defeat the single-container productisation goal.
assert_contains "vane-image-pinned" \
    "image: itzcrazykns1337/vane:v1.12.2"
echo "PASS: vane image is pinned to v1.12.2 (full variant, bundles SearXNG)"

if grep -qE 'image: itzcrazykns1337/vane:latest' "$COMPOSE"; then
    echo "FAIL [vane-image-not-latest]: vane image must be a pinned tag, not :latest" >&2
    exit 1
fi
echo "PASS: vane image is not pinned to :latest"

# ── Compose: container name matches uninstaller list ────────────
assert_contains "vane-container-name" \
    "container_name: ostler-vane"
echo "PASS: vane container_name is ostler-vane"

# ── Compose: port mapping is loopback-only ──────────────────────
# Same shape as the rest of the stack: nothing on the LAN reaches
# Vane without Tailscale. Locking 127.0.0.1: prevents a future
# edit that drops the loopback prefix and accidentally exposes
# the search history to the LAN.
assert_contains "vane-port-loopback" \
    "- \"127.0.0.1:3000:3000\""
echo "PASS: vane port mapping is loopback-only (127.0.0.1:3000:3000)"

# ── Compose: vane_data volume mount + declaration ───────────────
assert_contains "vane-volume-mount" \
    "- vane_data:/home/vane/data"
echo "PASS: vane mounts vane_data:/home/vane/data"

assert_contains "vane-volume-decl" \
    "  vane_data:"
echo "PASS: vane_data volume is declared at the top level"

# ── Compose: host.docker.internal gateway for Ollama ────────────
# Without extra_hosts, the container cannot reach the host's
# Ollama at :11434 on macOS. This is the macOS / Colima-friendly
# way to surface the host gateway into the container.
assert_contains "vane-host-gateway" \
    "- \"host.docker.internal:host-gateway\""
echo "PASS: vane has host.docker.internal:host-gateway extra_hosts entry"

# ── Compose: restart policy ─────────────────────────────────────
# Verify vane has its own restart: unless-stopped declaration.
# Awk extracts the vane block (from "  vane:" to next service-
# level key or end of services), then checks the policy.
VANE_BLOCK="$(mktemp)"
trap 'rm -f "$COMPOSE" "$VANE_BLOCK"' EXIT
awk '
    /^  vane:$/        { capture = 1; print; next }
    capture && /^  [a-z]/ && !/^  vane:$/ { capture = 0 }
    capture && /^volumes:$/ { capture = 0 }
    capture            { print }
' "$COMPOSE" > "$VANE_BLOCK"

if ! grep -qF "restart: unless-stopped" "$VANE_BLOCK"; then
    echo "FAIL [vane-restart-policy]: vane service missing restart: unless-stopped" >&2
    exit 1
fi
echo "PASS: vane has restart: unless-stopped policy"

# ── Phase 3.8b: dedicated bring-up section header ───────────────
# Must be its own phase so a registry hiccup or port collision
# does not break Phase 3.8 (data services). Mirrors the wiki-site
# isolation pattern.
if ! grep -qE '^# ── 3\.8b Local web search \(Vane\)' "$INSTALL_SCRIPT"; then
    echo "FAIL [phase-3.8b-header]: Phase 3.8b section header not found" >&2
    exit 1
fi
echo "PASS: Phase 3.8b (Local web search) section header present"

# ── Phase 3.8b: VANE_OK flag is initialised + checked ──────────
# Locks the contract that downstream phases (next-steps banner,
# health check) can read VANE_OK to decide whether to surface
# the localhost:3000 link.
if ! grep -q 'VANE_OK=false' "$INSTALL_SCRIPT"; then
    echo "FAIL [vane-ok-init]: VANE_OK=false initialisation not found" >&2
    exit 1
fi
if ! grep -q 'VANE_OK=true' "$INSTALL_SCRIPT"; then
    echo "FAIL [vane-ok-set]: VANE_OK=true success branch not found" >&2
    exit 1
fi
echo "PASS: VANE_OK flag is initialised and set on health-check success"

# ── Phase 3.8b: brings vane up via docker compose ──────────────
if ! grep -q 'docker compose up -d vane' "$INSTALL_SCRIPT"; then
    echo "FAIL [vane-bringup]: install.sh does not invoke docker compose up -d vane" >&2
    exit 1
fi
echo "PASS: install.sh brings vane up via docker compose"

# ── Phase 3.8b: HTTP health check polls localhost:3000 ─────────
# The image bundles SearXNG which warms after Next.js binds the
# port. A retry loop rather than a single curl is the difference
# between "works on slow Macs" and "looks broken on slow Macs".
if ! grep -q 'curl -sf -o /dev/null -m 3 http://localhost:3000' "$INSTALL_SCRIPT"; then
    echo "FAIL [vane-health-poll]: install.sh does not poll http://localhost:3000 in 3.8b" >&2
    exit 1
fi
echo "PASS: install.sh polls http://localhost:3000 for Vane readiness"

# ── Port conflict pre-check includes 3000 ──────────────────────
if ! grep -q '_check_port 3000' "$INSTALL_SCRIPT"; then
    echo "FAIL [port-3000-precheck]: install.sh does not pre-check port 3000" >&2
    exit 1
fi
echo "PASS: install.sh pre-checks port 3000 for conflicts"

# ── Health check: phase 4 surfaces vane ────────────────────────
# The phase-4 health-check block must mention vane. We require
# the human-readable label "Vane healthy" so a refactor that
# replaces the curl with a different probe still has to update
# the user-facing wording.
if ! grep -q 'Vane healthy' "$INSTALL_SCRIPT"; then
    echo "FAIL [phase-4-health]: phase-4 health check does not surface Vane" >&2
    exit 1
fi
echo "PASS: phase-4 health check surfaces Vane"

# ── User-facing copy: --help text mentions Vane ────────────────
# The --help screen is the customer's first read of what the
# installer will do. Must match the privacy/why-local promises.
if ! grep -q 'bundled Vane + SearXNG container' "$INSTALL_SCRIPT"; then
    echo "FAIL [help-copy]: --help screen does not mention 'bundled Vane + SearXNG container'" >&2
    exit 1
fi
echo "PASS: --help screen mentions the bundled Vane + SearXNG container"

# ── User-facing copy: no leftover "optional web search" without context ─
# The earlier copy said "optional web search via SearXNG" but
# never installed it. Either the phrase is gone, or it is paired
# with a Vane mention in the same line / paragraph.
if grep -nE 'optional web search via' "$INSTALL_SCRIPT" >/dev/null; then
    # Permitted only if the same screen also names Vane.
    if ! grep -nE 'optional web search via.*(Vane|vane)' "$INSTALL_SCRIPT" >/dev/null; then
        echo "FAIL [stale-search-copy]: 'optional web search via' present without Vane context" >&2
        exit 1
    fi
fi
echo "PASS: no stale 'optional web search via SearXNG' copy without Vane context"

# ── Uninstaller mentions ostler-vane in the container list ─────
if ! grep -q 'ostler-wiki-site, ostler-wiki-compiler, ostler-vane' "$INSTALL_SCRIPT"; then
    echo "FAIL [uninstaller-list]: uninstaller container list does not include ostler-vane" >&2
    exit 1
fi
echo "PASS: uninstaller container list includes ostler-vane"

# ── Next-steps banner: gated on VANE_OK ────────────────────────
# Show "your local web search at :3000" only when Vane actually
# came up. Hard-coding the URL would lie when the image pull
# failed and the user is staring at a "what's running?" list.
if ! grep -q 'Local web search:' "$INSTALL_SCRIPT"; then
    echo "FAIL [next-steps-vane]: next-steps banner does not surface 'Local web search:'" >&2
    exit 1
fi
echo "PASS: next-steps banner surfaces 'Local web search:' (when VANE_OK)"

echo ""
echo "ALL VANE BUNDLE TESTS PASSED"
