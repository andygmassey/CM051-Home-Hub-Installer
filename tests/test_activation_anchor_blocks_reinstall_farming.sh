#!/usr/bin/env bash
#
# tests/test_activation_anchor_blocks_reinstall_farming.sh
#
# v1.0.108 Leak A: deleting ~/.ostler and reinstalling must NOT mint a fresh
# 30-day free month. The free-month purchase date is a durable login-keychain
# ANCHOR that survives ~/.ostler deletion, so a reinstall reuses the original
# (already-expired) window.
#
# macOS only (uses `security`). Self-skips on non-Darwin -- the anchor is
# macOS-specific install.sh code; the gate behaviour it feeds is covered
# cross-platform by test_subscription_gate.py.
#
# Proof, end to end through the SHIPPED install.sh:
#   A durability: the anchor function returns the SAME date on a second call
#     (the "reinstall") -- a fresh ~/.ostler finds the prior anchor.
#   B leak closed: with an anchor dated 31 days ago, the shipped activation
#     snippet writes an already-expired window -> gate inactive.
#   C first install still works: a brand-new anchor (now) -> gate active.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 99
REPO_ROOT="$(pwd)"

case "$(uname -s)" in
    Darwin) ;;
    *) echo "SKIP: activation anchor is macOS-only (uname=$(uname -s)); the gate it feeds is covered by test_subscription_gate.py"; exit 0 ;;
esac
command -v security >/dev/null 2>&1 || { echo "SKIP: no 'security' CLI"; exit 0; }
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no $PY"; exit 99; }

fails=0
pass() { echo "PASS [$1]: $2"; }
fail() { echo "FAIL [$1]: $2"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
KC="$TMP/anchor.keychain"
security create-keychain -p "" "$KC" >/dev/null 2>&1 || { echo "CANNOT-RUN: cannot create temp keychain"; exit 99; }
cleanup() { security delete-keychain "$KC" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

export OSTLER_ANCHOR_KEYCHAIN="$KC"
export OSTLER_ANCHOR_SERVICE="com.ostler.test-anchor.$$"
export USER_ID="anchor-tester"

# Lift the shipped anchor function out of install.sh and source it.
awk '/^# --- Ostler activation anchor \(v1\.0\.108 Leak A\)/,/^# --- end activation anchor/' install.sh > "$TMP/anchor.sh"
grep -q "_ostler_activation_anchor_date" "$TMP/anchor.sh" || { echo "CANNOT-RUN: could not extract anchor function"; exit 99; }
# shellcheck disable=SC1090
. "$TMP/anchor.sh"

# ── A: durability across a "reinstall" (same keychain, ~/.ostler gone) ──
first="$(_ostler_activation_anchor_date)"
second="$(_ostler_activation_anchor_date)"
if [ -n "$first" ] && [ "$first" = "$second" ]; then
    pass "durable" "second activation reused the prior anchor ($first), did not mint a new one"
else
    fail "durable" "anchor not durable: first='$first' second='$second'"
fi

# Lift the shipped activation snippet (the python -c body that calls
# activate_first_month_free) and resolve ${SCRIPT_DIR} to the repo root, whose
# vendor/cm041/assistant_api is the gate the snippet's _dev path imports.
"$PY" - "$REPO_ROOT" "$TMP/activate.py" <<'EX'
import sys
repo, out = sys.argv[1], sys.argv[2]
src = open("install.sh", encoding="utf-8").read()
i = src.index("from subscription_gate import activate_first_month_free")
s = src.rindex('if python3 -c "', 0, i) + len('if python3 -c "')
e = src.index('" 2>&1; then', i)
open(out, "w").write(src[s:e].replace("${SCRIPT_DIR}", repo))
EX

run_snippet() {  # $1 = purchase date, $2 = tier_state ; echoes active|paused
    local state="$TMP/state_$2_${RANDOM}.json"
    OSTLER_SUBSCRIPTION_STATE="$state" \
    OSTLER_FREE_MONTH_PURCHASE_DATE="$1" \
    OSTLER_LICENCE_TIER_STATE="$2" \
    OSTLER_LICENCE_TIER="hub" \
    OSTLER_LICENCE_EXPIRES_AT="" \
        "$PY" "$TMP/activate.py" >/dev/null 2>&1
    OSTLER_SUBSCRIPTION_STATE="$state" "$PY" - "$REPO_ROOT/vendor/cm041/assistant_api" <<'RD'
import sys, os
sys.path.insert(0, sys.argv[1])
import subscription_gate as sg
print("active" if sg.is_active_or_grace() else "paused")
RD
}

# ── B: reinstalling trialist (anchor 31 days ago) gets no fresh month ──
old="$("$PY" -c "from datetime import datetime,timezone,timedelta;print((datetime.now(timezone.utc)-timedelta(days=31)).isoformat().replace('+00:00','Z'))")"
verdict="$(run_snippet "$old" known)"
if [ "$verdict" = "paused" ]; then
    pass "reinstall" "an anchor dated 31 days ago yields an expired window (gate paused) -- no farmed month"
else
    fail "reinstall" "reinstall with a 31-day-old anchor still granted Pro (gate=$verdict)"
fi

# ── C: first-ever install (anchor = now) still gets the month ──
verdict="$(run_snippet "$first" known)"
if [ "$verdict" = "active" ]; then
    pass "first-install" "a fresh anchor (now) grants the free month (gate active)"
else
    fail "first-install" "a first install did NOT get the free month (gate=$verdict)"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS: the free-month window is anchored durably; reinstall cannot farm a new one."
    exit 0
fi
echo "FAILURES: $fails"; exit 1
