#!/usr/bin/env bash
# tests/ wrapper around vendor/cm041/assistant_api/test_vendor_import.sh.
#
# CX-P0A (2026-05-26). Calls the byte-by-byte regression test that
# pins the iOS-endpoint wire-shape (ical-server.py routes + install.sh
# launch block + Doctor proxy paths + loopback bind + env-overridable
# port). See the wrapped script for the full failure-shape rationale.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VENDOR_TEST="$REPO_ROOT/vendor/cm041/assistant_api/test_vendor_import.sh"
if [[ ! -x "$VENDOR_TEST" ]]; then
    echo "FAIL: vendor regression test not found / not executable at $VENDOR_TEST" >&2
    exit 1
fi

exec "$VENDOR_TEST"
