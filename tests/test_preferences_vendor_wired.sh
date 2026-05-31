#!/usr/bin/env bash
# tests/ wrapper around vendor/cm019_preferences/test_vendor_preferences.sh.
#
# Calls the regression + freshness test that pins the vendored CM019
# preferences ingest pipeline: the Ollama vectorizer swap (no torch),
# the `preferences` collection / 768-dim embedding lock-ins, and the
# trimmed dependency set. See the wrapped script for the full
# stale-vendor failure-shape rationale (CX-83 class).
#
# Piece 2 extends the wrapped script with install.sh hydrate_preferences
# wiring assertions once that sub-phase exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VENDOR_TEST="$REPO_ROOT/vendor/cm019_preferences/test_vendor_preferences.sh"
if [[ ! -x "$VENDOR_TEST" ]]; then
    echo "FAIL: vendor regression test not found / not executable at $VENDOR_TEST" >&2
    exit 1
fi

exec "$VENDOR_TEST"
