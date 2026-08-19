#!/usr/bin/env bash
#
# tests/test_v1010_wiki_not_tailscale_served.sh
#
# FIX 5 (v1.0.10 security lockdown -- wiki served unauthenticated
# over Tailscale).
#
# The wiki on :8044 has no identity gate of its own; a raw
# `tailscale serve --tcp=8044` passthrough exposed the customer's
# ENTIRE personal graph unauthenticated to any tailnet peer. Only
# :8089 (the Doctor API, which has device-pairing bearer auth) may be
# tailscale-served. The wiki is on-device only.
#
# Pure shell + grep / awk. No tailscale.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SCRIPT" ]] || fail "install.sh not found"

# 1. The tailscale-serve loop must iterate 8089 only, never 8044.
if grep -Eq 'for _ts_port in .*8044' "$INSTALL_SCRIPT"; then
    fail "tailscale-serve loop still includes 8044 (wiki exposed unauthenticated on the tailnet)"
fi
grep -Eq 'for _ts_port in 8089;' "$INSTALL_SCRIPT" \
    || fail "tailscale-serve loop no longer serves 8089 (Doctor API) -- iOS Companion would break"

# 2. Belt-and-braces: no `serve ... --tcp=8044` / `--tcp=$port` where
#    the port list contains 8044.
if grep -Eq 'tailscale.*serve.*--tcp=8044' "$INSTALL_SCRIPT" \
   || grep -Eq 'serve --bg --tcp="8044"' "$INSTALL_SCRIPT"; then
    fail "an explicit tailscale serve of :8044 remains"
fi

# 3. The on-device-only intent is surfaced to the operator.
grep -q 'on-device only' "$INSTALL_SCRIPT" \
    || fail "operator is not told the wiki is on-device only"

echo "PASS: only :8089 is tailscale-served; the wiki (:8044) is on-device only."
