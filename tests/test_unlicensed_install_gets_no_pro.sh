#!/usr/bin/env bash
#
# tests/test_unlicensed_install_gets_no_pro.sh
#
# v1.0.108 Leak B, end to end through the REAL components.
#
# The --allow-unlicensed / OSTLER_DEV=1 escape used to grant the full
# 30-day Ostler Pro free month: the licence gate was skipped, tier_state
# was "unverified", and activate_first_month_free wrote status=active
# anyway. The developer escape hatch was a free-Pro switch.
#
# This test lifts the ACTUAL first-month-free activation snippet out of the
# shipped install.sh (not a copy, not a generator) and runs it against the
# real subscription_gate.py, BOTH directions:
#
#   unverified  -> status inactive, source unlicensed_install, gate paused
#   verified    -> status active, gate running
#
# A gate that always refused would be as wrong as one that always granted,
# so the verified direction is a first-class assertion, not a footnote.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 99
REPO_ROOT="$(pwd)"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no $PY on PATH"; exit 99; }
test -f install.sh || { echo "FAIL: install.sh not found from $REPO_ROOT"; exit 99; }
GATE_SRC="vendor/cm041/assistant_api/subscription_gate.py"
test -f "$GATE_SRC" || { echo "FAIL: $GATE_SRC not found"; exit 99; }

fails=0
pass() { echo "PASS [$1]: $2"; }
fail() { echo "FAIL [$1]: $2"; fails=$((fails + 1)); }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Extract the shipped activation snippet: the python body of the unique
# `python3 -c "..."` that imports activate_first_month_free, with
# ${SCRIPT_DIR} resolved to the repo root so its _dev path lands on the
# vendored gate. Written to a file and run per direction.
EXTRACT="$TMPROOT/activate_snippet.py"
"$PY" - "$REPO_ROOT" "$EXTRACT" <<'EXTRACTOR'
import sys
repo_root, out_path = sys.argv[1], sys.argv[2]
src = open("install.sh", encoding="utf-8").read()
needle = "from subscription_gate import activate_first_month_free"
i = src.index(needle)
start = src.rindex('if python3 -c "', 0, i) + len('if python3 -c "')
end = src.index('" 2>&1; then', i)
body = src[start:end].replace("${SCRIPT_DIR}", repo_root)
open(out_path, "w", encoding="utf-8").write(body)
print("extracted %d bytes" % len(body))
EXTRACTOR
test -s "$EXTRACT" || { echo "FAIL: could not extract the activation snippet from install.sh"; exit 99; }

run_direction() {
    # $1 = tier_state, $2 = tier (may be empty)
    local tier_state="$1" tier="$2"
    local state="$TMPROOT/state_${tier_state}.json"
    OSTLER_SUBSCRIPTION_STATE="$state" \
    OSTLER_LICENCE_TIER_STATE="$tier_state" \
    OSTLER_LICENCE_TIER="$tier" \
    OSTLER_LICENCE_EXPIRES_AT="" \
        "$PY" "$EXTRACT" >/dev/null 2>&1
    # Read status + whether the gate says active, via the real module.
    OSTLER_SUBSCRIPTION_STATE="$state" "$PY" - "$REPO_ROOT" <<'READER'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "vendor", "cm041", "assistant_api"))
import subscription_gate as sg
snap = sg.state_dict()
print("%s|%s|%s" % (snap.get("status"), snap.get("source"),
                    "active" if sg.is_active_or_grace() else "paused"))
READER
}

# ── Direction 1: unlicensed install gets NO free month ──
out="$(run_direction unverified "")"
status="${out%%|*}"; rest="${out#*|}"; source="${rest%%|*}"; gate="${rest##*|}"
if [ "$status" = "inactive" ] && [ "$gate" = "paused" ]; then
    pass "unverified" "escape install writes status=inactive (source=$source), gate paused"
else
    fail "unverified" "escape install got Pro: status=$status source=$source gate=$gate (want inactive/paused)"
fi
if [ "$source" = "unlicensed_install" ]; then
    pass "unverified.source" "withheld state is recorded for Doctor/support"
else
    fail "unverified.source" "source=$source (want unlicensed_install)"
fi

# ── Direction 2: a VERIFIED licence still gets the month ──
out="$(run_direction known hub)"
status="${out%%|*}"; rest="${out#*|}"; gate="${rest##*|}"
if [ "$status" = "active" ] && [ "$gate" = "active" ]; then
    pass "verified" "verified (known/hub) install still gets the free month"
else
    fail "verified" "verified install did NOT get Pro: status=$status gate=$gate (want active/active)"
fi

# ── Direction 2b: a legacy verified licence with no tier field (absent) ──
out="$(run_direction absent "")"
status="${out%%|*}"; rest="${out#*|}"; gate="${rest##*|}"
if [ "$status" = "active" ] && [ "$gate" = "active" ]; then
    pass "verified.absent" "legacy verified (absent tier) install still gets the month"
else
    fail "verified.absent" "absent-tier install did NOT get Pro: status=$status gate=$gate"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS: the escape grants no Pro; a verified licence still does."
    exit 0
fi
echo "FAILURES: $fails"
exit 1
