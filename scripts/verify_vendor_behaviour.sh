#!/usr/bin/env bash
# verify_vendor_behaviour.sh -- run the vendor-BEHAVIOUR gate.
# ===========================================================
#
# Companion to verify_vendor_fresh.sh. Freshness proves the vendored BYTES
# match source@pinned_sha + divergence patch; THIS gate proves the
# load-bearing GRAFTS still FUNCTION, by running golden cases against the
# vendored code in-process (SPARQL/HTTP seams stubbed -- no services needed).
# A re-vendor whose patch "applied cleanly" but neutralised a graft (the
# dropped-register_person / #657 class) goes RED here in seconds instead of
# surfacing at box-walk.
#
# The gate itself is tests/test_vendor_behaviour_gate.py. It needs httpx +
# phonenumbers (the vendored resolver's own imports). If the invoking
# python3 lacks them, this wrapper bootstraps a small cached venv (needs
# network the first time) rather than silently skipping.
#
# Exit codes:
#   0 = GREEN (every graft behaves)
#   1 = RED   (a graft was dropped/regressed -- do NOT cut)
#   3 = COULD NOT VERIFY (no python3 / deps unbootstrappable) -- callers must
#       surface this loudly (WARN), never treat it as a pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GATE="${REPO_ROOT}/tests/test_vendor_behaviour_gate.py"

if [ ! -f "$GATE" ]; then
    echo "verify_vendor_behaviour: gate missing at $GATE" >&2
    exit 3
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "verify_vendor_behaviour: COULD NOT VERIFY -- python3 not found." >&2
    exit 3
fi

PY=python3
if ! python3 -c "import httpx, phonenumbers" >/dev/null 2>&1; then
    # Bootstrap a cached throwaway venv with the two deps. Cache it outside
    # the repo so it never pollutes the payload rsync.
    VENV="${OSTLER_VENDOR_GATE_VENV:-${TMPDIR:-/tmp}/cm051-vendor-behaviour-venv}"
    if [ ! -x "${VENV}/bin/python3" ]; then
        echo "verify_vendor_behaviour: bootstrapping venv at ${VENV} (httpx + phonenumbers)..."
        if ! python3 -m venv "$VENV" >/dev/null 2>&1; then
            echo "verify_vendor_behaviour: COULD NOT VERIFY -- venv creation failed." >&2
            exit 3
        fi
    fi
    if ! "${VENV}/bin/python3" -c "import httpx, phonenumbers" >/dev/null 2>&1; then
        if ! "${VENV}/bin/python3" -m pip install -q httpx phonenumbers >/dev/null 2>&1; then
            echo "verify_vendor_behaviour: COULD NOT VERIFY -- pip install of httpx/phonenumbers failed (offline?)." >&2
            echo "                         Install them into any python3 and re-run; do NOT treat this as a pass." >&2
            exit 3
        fi
    fi
    PY="${VENV}/bin/python3"
fi

exec "$PY" "$GATE"
