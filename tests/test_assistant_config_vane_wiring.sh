#!/usr/bin/env bash
#
# tests/test_assistant_config_vane_wiring.sh
#
# Locks the assistant-config wiring for the bundled Vane web_search
# tool in install.sh.
#
# Why this test exists:
#
#   CM051 #32 bundles the Vane container at localhost:3000.
#   ostler-assistant #17 added the Vane provider in the binary
#   (DEFAULT_WEB_SEARCH_PROVIDER = "vane"). Before this PR,
#   install.sh did not emit a [tools.web_search] block in the
#   generated config.toml, so the customer ended up with Vane
#   running AND the assistant supporting Vane, but the two were
#   not connected on disk -- a silent gap.
#
#   This test pins the wiring so the customer's first assistant
#   run uses the bundled Vane instance:
#     1. The TOML emitter unconditionally writes [tools.web_search]
#     2. provider = "vane"
#     3. vane_url = "http://localhost:3000"
#
#   "Unconditionally" matters: a future edit that wraps the block
#   in `if [[ "$CHANNEL_..." == true ]]` would silently disable
#   the wiring whenever the user skips channel config. Vane is
#   bundled by default; the wiring follows.
#
# Sister tests:
#   - test_vane_bundle.sh -- locks the compose-layer Vane bundle
#   - test_third_party_data_consent.sh -- locks Caveat 1 consent

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

# ── Block presence ──────────────────────────────────────────────
if ! grep -q '\[tools\.web_search\]' "$INSTALL_SCRIPT"; then
    echo "FAIL [tools-web-search-header]: install.sh does not emit [tools.web_search] header" >&2
    exit 1
fi
echo "PASS: install.sh emits [tools.web_search] header"

# ── provider = "vane" ───────────────────────────────────────────
if ! grep -q 'provider = \\"vane\\"' "$INSTALL_SCRIPT"; then
    echo "FAIL [provider-vane]: install.sh does not set provider = \"vane\"" >&2
    exit 1
fi
echo 'PASS: install.sh sets provider = "vane"'

# ── vane_url = "http://localhost:3000" ──────────────────────────
# Must match the loopback port the Vane compose service binds to
# (test_vane_bundle.sh asserts 127.0.0.1:3000:3000).
if ! grep -q 'vane_url = \\"http://localhost:3000\\"' "$INSTALL_SCRIPT"; then
    echo "FAIL [vane-url-localhost]: install.sh does not set vane_url = \"http://localhost:3000\"" >&2
    exit 1
fi
echo 'PASS: install.sh sets vane_url = "http://localhost:3000"'

# ── Block is emitted unconditionally ────────────────────────────
# The TOML emitter is the body of `{ ... } > "$ASSISTANT_CONFIG"`.
# Top-level statements inside the brace block are indented exactly
# 4 spaces. A statement nested inside `if [[ ... ]]; then` is
# indented 8+ spaces.
#
# So: the line that emits the [tools.web_search] header must have
# exactly 4 leading spaces. Anything deeper means a future edit
# wrapped the block in a channel-gated if and silently disabled
# the wiring whenever the user skipped channel config.
INDENT="$(grep -nE '^[[:space:]]+echo "\[tools\.web_search\]"$' "$INSTALL_SCRIPT" \
    | head -n 1 | sed -E 's/^[0-9]+:( +).*/\1/' | awk '{ print length }')"

if [[ -z "$INDENT" ]]; then
    echo "FAIL [emitter-header-missing]: could not locate the [tools.web_search] echo line" >&2
    exit 1
fi

if [[ "$INDENT" -ne 4 ]]; then
    echo "FAIL [tools-web-search-conditional]: [tools.web_search] is indented ${INDENT} spaces (expected 4)" >&2
    echo "      Vane is bundled by default; the wiring must be at the top level of the brace block." >&2
    exit 1
fi
echo "PASS: [tools.web_search] block is emitted unconditionally (top-level indent)"

echo ""
echo "ALL ASSISTANT-CONFIG VANE WIRING TESTS PASSED"
