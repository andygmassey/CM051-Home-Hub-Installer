#!/usr/bin/env bash
#
# tests/test_gateway_web_dist_dir_configured.sh
#
# Locks the gateway web-dashboard wiring in install.sh, and (in
# RUNTIME mode) asserts the live gateway serves the dashboard
# rather than returning the recurring 503.
#
# Why this test exists:
#
#   .158 cold-install walk (2026-06-18) found the iOS pairing QR
#   panel missing and the Channels tab returning:
#     "API 503: Web dashboard not available. Set gateway.web_dist_dir
#      in your config and build the frontend"
#
#   Root cause: the gateway serves the SPA dashboard + the static
#   /_app/* assets (which the QR + Channels panes load) from a
#   filesystem directory resolved from gateway.web_dist_dir
#   (ostler-assistant crates/zeroclaw-gateway/src/static_files.rs
#   handle_spa_fallback -> 503 when web_dist_dir is None). The
#   daemon's auto-detect only probes web/dist relative to the binary
#   (current_exe()/web/dist) plus Docker/AUR/XDG paths -- none of
#   which match the macOS .app layout -- and install.sh never set
#   web_dist_dir. So the dashboard was dead on every fresh install.
#   This is the same web_dist_dir miss as #667; it keeps recurring
#   because nothing pinned it, so this test pins it.
#
#   The fix has two halves:
#     1. (THIS REPO, CM051) install.sh emits
#        web_dist_dir = "<OstlerAssistant.app>/Contents/Resources/web/dist"
#        in the [gateway] block.
#     2. (ostler-assistant, ostler-ai org) the .app build bundles
#        web/dist into Contents/Resources/web/dist (build-binary.sh
#        + wrap-in-app-bundle.sh), and the gateway auto-detect adds
#        the bundle-relative candidate so it is also zero-config.
#
#   Half 1 is inert until half 2 ships the dist, but it makes the
#   install side correct the instant the bundling lands. The RUNTIME
#   probe below is the black-box gate that catches a regression in
#   EITHER half on a real install.
#
# Modes:
#   (default)  static source check of install.sh -- runs in CI, no
#              live Hub needed.
#   RUNTIME=1  additionally probe a live gateway (default
#              http://localhost:8000): the SPA dashboard root and a
#              static-asset request must NOT return 503. Set
#              GATEWAY_URL to override the base URL.
#
# Sister tests:
#   - test_assistant_config_vane_wiring.sh -- same [gateway]/config
#     block, same indent-discipline pattern.
#   - HR015 scripts/verify_hub_surfaces.sh check 1 (/ready != 503).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8000}"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── web_dist_dir is emitted ─────────────────────────────────────
if ! grep -q 'echo "web_dist_dir = ' "$INSTALL_SCRIPT"; then
    echo "FAIL [web-dist-dir-missing]: install.sh does not emit web_dist_dir in the generated config" >&2
    echo "      Without it the gateway 503s 'Web dashboard not available' and the iOS pairing QR + Channels tab are dead." >&2
    exit 1
fi
echo "PASS: install.sh emits web_dist_dir"

# ── It points at the bundled dist inside the .app ───────────────
# Must be the Resources/web/dist path the daemon build bundles into
# OstlerAssistant.app. If a future edit points it at a bare
# ~/.ostler/web/dist or the binary-relative MacOS/web/dist, the
# dashboard stays 503 because the dist does not ship there.
if ! grep -q 'web_dist_dir = .*OstlerAssistant\.app/Contents/Resources/web/dist' "$INSTALL_SCRIPT"; then
    echo "FAIL [web-dist-dir-path]: web_dist_dir does not point at OstlerAssistant.app/Contents/Resources/web/dist" >&2
    echo "      That is where the daemon build bundles the dashboard; any other path 503s." >&2
    exit 1
fi
echo "PASS: web_dist_dir points at the bundled Contents/Resources/web/dist"

# ── Emitted unconditionally, in the [gateway] block ─────────────
# The TOML emitter is the body of `{ ... } > "$ASSISTANT_CONFIG"`.
# Top-level statements inside the brace block are indented exactly
# 4 spaces; a statement nested inside `if [[ ... ]]; then` is 8+.
# The dashboard wiring must be top-level: a future channel-gated if
# wrapping would silently disable it whenever the user skips a step.
INDENT="$(grep -nE '^[[:space:]]+echo "web_dist_dir = ' "$INSTALL_SCRIPT" \
    | head -n 1 | sed -E 's/^[0-9]+:( +).*/\1/' | awk '{ print length }')"

if [[ -z "$INDENT" ]]; then
    echo "FAIL [emitter-line-missing]: could not locate the web_dist_dir echo line" >&2
    exit 1
fi

if [[ "$INDENT" -ne 4 ]]; then
    echo "FAIL [web-dist-dir-conditional]: web_dist_dir is indented ${INDENT} spaces (expected 4)" >&2
    echo "      The dashboard wiring must be at the top level of the brace block, not channel-gated." >&2
    exit 1
fi
echo "PASS: web_dist_dir is emitted unconditionally (top-level indent)"

# ── It lives under the [gateway] header (not a stray block) ─────
# Find the line number of the [gateway] echo and of the next section
# header echo after it; web_dist_dir must fall between them.
gw_line="$(grep -nE '^[[:space:]]+echo "\[gateway\]"$' "$INSTALL_SCRIPT" | head -n1 | cut -d: -f1)"
wd_line="$(grep -nE '^[[:space:]]+echo "web_dist_dir = ' "$INSTALL_SCRIPT" | head -n1 | cut -d: -f1)"
next_hdr="$(awk -v gw="$gw_line" 'NR>gw && /echo "\[/ { print NR; exit }' "$INSTALL_SCRIPT")"
if [[ -z "$gw_line" || -z "$wd_line" ]]; then
    echo "FAIL [gateway-header-missing]: could not locate [gateway] header and/or web_dist_dir line" >&2
    exit 1
fi
if [[ "$wd_line" -le "$gw_line" ]] || { [[ -n "$next_hdr" ]] && [[ "$wd_line" -ge "$next_hdr" ]]; }; then
    echo "FAIL [web-dist-dir-misplaced]: web_dist_dir (line ${wd_line}) is not inside the [gateway] block ([gateway]=${gw_line}, next header=${next_hdr:-none})" >&2
    exit 1
fi
echo "PASS: web_dist_dir is inside the [gateway] block"

# ── RUNTIME probe (black-box, opt-in) ───────────────────────────
# Catches the regression on a real install regardless of which half
# (config vs bundling) broke. The SPA dashboard root and a static
# asset request must NOT return 503. A 200 (served) is the pass; a
# 401/404 still proves the dashboard is wired (auth/route, not the
# missing-dist 503), so only 503 fails.
if [[ "${RUNTIME:-0}" == "1" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
        echo "FAIL [runtime-no-curl]: RUNTIME=1 set but curl is not available" >&2
        exit 1
    fi

    # SPA dashboard root: handle_spa_fallback returns 503 when
    # web_dist_dir is None or index.html is unreadable.
    root_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${GATEWAY_URL}/" 2>/dev/null || echo 000)"
    if [[ "$root_code" == "503" ]]; then
        echo "FAIL [runtime-spa-503]: ${GATEWAY_URL}/ = 503 -- 'Web dashboard not available' (web_dist_dir unset OR dist not bundled)" >&2
        exit 1
    elif [[ "$root_code" == "000" ]]; then
        echo "WARN [runtime-spa-unreachable]: ${GATEWAY_URL}/ unreachable (gateway down?) -- cannot prove the dashboard serves" >&2
    else
        echo "PASS: ${GATEWAY_URL}/ = ${root_code} (not 503 -- dashboard wired)"
    fi

    # A static asset path (/_app/*) also routes through the dist dir.
    # serve_fs_file returns 404 for a missing file but NEVER 503; a
    # 503 anywhere in this surface is the missing-dist signature.
    app_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${GATEWAY_URL}/_app/" 2>/dev/null || echo 000)"
    if [[ "$app_code" == "503" ]]; then
        echo "FAIL [runtime-static-503]: ${GATEWAY_URL}/_app/ = 503 -- static asset surface dead (dashboard dist missing)" >&2
        exit 1
    elif [[ "$app_code" == "000" ]]; then
        echo "WARN [runtime-static-unreachable]: ${GATEWAY_URL}/_app/ unreachable"
    else
        echo "PASS: ${GATEWAY_URL}/_app/ = ${app_code} (not 503)"
    fi
else
    echo "SKIP: RUNTIME probe (set RUNTIME=1 with a live gateway to black-box the dashboard surface)"
fi

echo ""
echo "ALL GATEWAY WEB_DIST_DIR TESTS PASSED"
