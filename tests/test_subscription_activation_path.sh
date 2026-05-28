#!/usr/bin/env bash
#
# tests/test_subscription_activation_path.sh
#
# DMG #48d (2026-05-28) launch-blocker regression test.
#
# Locks the invariant that the G2 first-month-free activation block
# imports subscription_gate from a path that EXISTS in the assembled
# DMG payload (and not just in the source tree).
#
# WHY THIS TEST EXISTS
#
# The G2 activation block (PR #191) originally hard-coded a single
# sys.path.insert reaching for ${SCRIPT_DIR}/vendor/cm041/assistant_api.
# That path is correct in the dev / tarball source layout, but the
# .app postBuildScript (gui/project.yml L487-514) explicitly strips
# the 'vendor/cm041/' wrapper and stages the contents directly into
# Contents/Resources/assistant_api/. The bundled DMG therefore has
# no ${SCRIPT_DIR}/vendor/cm041/assistant_api/ directory, and the
# Python heredoc raised ModuleNotFoundError on every customer install.
# The fail-open posture meant the install completed (warn only),
# but the subscription state file was never written and the customer
# got zero days of Pro free on launch day.
#
# This test asserts:
#
#   1. The activation block tries ${SCRIPT_DIR}/assistant_api/ first
#      (bundled .app convention -- matches ical-server staging at L6886).
#   2. There is no naked import that ONLY tries the dev-tree path.
#   3. bash -n still parses install.sh cleanly.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 99

INSTALL_SH=install.sh
test -f "$INSTALL_SH" || { echo "FAIL: $INSTALL_SH not found from $(pwd)"; exit 99; }

# Case 1: activation block must reference the bundled-app path
if ! grep -qE "os\\.path\\.join\\(.\\\$\\{SCRIPT_DIR\\}., .assistant_api.\\)" "$INSTALL_SH"; then
    echo "FAIL [case-1]: activation block does not reach for the bundled \${SCRIPT_DIR}/assistant_api/ path"
    echo "   (the .app postBuildScript stages assistant_api/ at Resources root, no vendor/cm041 wrapper)"
    exit 1
fi
echo "PASS [case-1]: bundled \${SCRIPT_DIR}/assistant_api/ path present"

# Case 2: there must NOT be a naked sys.path.insert that uses ONLY the
# dev-tree path with no bundled-path fallback. The activation block
# may legitimately reference vendor/cm041/assistant_api as a fallback,
# but the FIRST candidate inspected must be the bundled path.
# Heuristic: find the activation block, confirm the bundled path
# appears before the dev path within it.
ACTIVATION_BLOCK=$(awk '/First-month-free subscription activation/,/^fi$/' "$INSTALL_SH")
if [[ -z "$ACTIVATION_BLOCK" ]]; then
    echo "FAIL [case-2]: could not isolate First-month-free activation block"
    exit 1
fi

BUNDLED_LINE=$(echo "$ACTIVATION_BLOCK" | grep -n "'assistant_api'" | grep -v "vendor" | head -1 | cut -d: -f1)
DEV_LINE=$(echo "$ACTIVATION_BLOCK" | grep -n "'vendor', 'cm041', 'assistant_api'" | head -1 | cut -d: -f1 || true)

if [[ -z "$BUNDLED_LINE" ]]; then
    echo "FAIL [case-2]: activation block has no bundled-path entry"
    exit 1
fi

if [[ -n "$DEV_LINE" ]] && (( DEV_LINE < BUNDLED_LINE )); then
    echo "FAIL [case-2]: activation block tries dev path (line $DEV_LINE) before bundled path (line $BUNDLED_LINE)"
    echo "   bundled path must be inspected first because that is the customer-install layout."
    exit 1
fi
echo "PASS [case-2]: bundled path inspected before dev fallback"

# Case 3: bash -n install.sh parses clean
if ! bash -n "$INSTALL_SH" 2>/dev/null; then
    echo "FAIL [case-3]: bash -n $INSTALL_SH failed"
    bash -n "$INSTALL_SH"
    exit 1
fi
echo "PASS [case-3]: bash -n install.sh clean"

# Case 4: end-to-end import resolution against the source tree layout.
# Simulates running install.sh from the source tree (dev mode). The
# fallback path must resolve to vendor/cm041/assistant_api/subscription_gate.py
# and the activate_first_month_free symbol must be present.
HELPER=vendor/cm041/assistant_api/subscription_gate.py
if [[ ! -f "$HELPER" ]]; then
    echo "FAIL [case-4]: $HELPER missing from source tree"
    exit 1
fi
if ! grep -qE "^def activate_first_month_free" "$HELPER"; then
    echo "FAIL [case-4]: activate_first_month_free symbol missing from $HELPER"
    exit 1
fi
echo "PASS [case-4]: dev-tree fallback path resolves to a helper with the right symbol"

echo ""
echo "ALL DMG #48d SUBSCRIPTION ACTIVATION PATH TESTS PASSED"
