#!/usr/bin/env bash
# #888. cut_hygiene_gate.sh tested ONLY for CONFLICTING/DIRTY, so an UNKNOWN
# mergeability fell through and the row PASSED. GitHub computes mergeability
# LAZILY -- for a window after any push, to the PR or to its base, the API
# answers UNKNOWN -- and the gate's own jq (`.mergeable//""`) turns a null into
# an empty string, which also fell through. Absence read as clean.
#
# MEASURED LIVE 2026-08-27: three PRs polled seconds apart returned
# #1130=UNKNOWN #1131=UNKNOWN #1132=MERGEABLE, then all three resolved. The
# window is real and it is short, which is exactly why it is easy to ship past.
#
# 🔴 WHY A CUT GATE IS THE WORST PLACE FOR IT. A human acting on an UNKNOWN has
# a backstop: the merge API returns 405 on a real conflict, so the mistake
# announces itself. Andy hit that merging #1103 an hour before this file was
# written -- the reading gated nothing and the API caught it. NOTHING
# DOWNSTREAM RE-ASKS FOR A CUT GATE. An UNKNOWN it waves through is never
# checked by anything, ever.
#
# THIS FILE IS THE CONTROL PAIR. A guard that reds on UNKNOWN is worthless if
# it also reds on MERGEABLE -- that would silence the gate rather than narrow
# it, which is the mistake this whole family keeps producing. So both
# directions are asserted, not just the new one.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

GATE="scripts/cut_hygiene_gate.sh"
[ -f "$GATE" ] || { bad "CANNOT-RUN: ${GATE} not found -- nothing to measure. Not a pass."; printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1; }

# Source ONLY the function, without running the gate: pull it out by line range
# rather than sourcing the whole script, which would parse args and exit.
FN="$(mktemp)"; trap 'rm -f "$FN"' EXIT
awk '/^mergeability_verdict\(\) \{/,/^\}/' "$GATE" > "$FN"
if [ ! -s "$FN" ]; then
    bad "CANNOT-RUN: mergeability_verdict() not found in ${GATE}. Either it was renamed or the gate reverted to the two-state test -- #888 is back."
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi
# shellcheck disable=SC1090
. "$FN"

printf '\n=== #888: UNKNOWN mergeability is not clean ===\n\n'

check() {  # $1 label  $2 mergeable  $3 mstate  $4 expected
    local got; got="$(mergeability_verdict "$2" "$3")"
    if [ "$got" = "$4" ]; then
        ok "$1: ($2, $3) -> $got"
    else
        bad "$1: ($2, $3) -> got '$got', expected '$4'"
    fi
}

# --- THE DEFECT: every one of these used to reach the gate's happy path -----
check "UNKNOWN is unmeasured"        "UNKNOWN"     ""       unmeasured
check "empty (jq //\"\" on null)"    ""            ""       unmeasured
check "literal null"                 "null"        ""       unmeasured
check "lower-case unknown"           "unknown"     ""       unmeasured

# --- CONTROL A: the state it always caught must STILL red ------------------
# Without this, a guard that reds on everything would pass the four above and
# have narrowed nothing.
check "CONFLICTING still conflicting" "CONFLICTING" ""      conflicting
check "DIRTY still conflicting"       "MERGEABLE"   "DIRTY" conflicting
check "lower-case conflicting"        "conflicting" ""      conflicting

# --- CONTROL B: a genuinely clean PR must STILL pass -----------------------
# This is the load-bearing one. If it fails, the fix has silenced the gate.
check "MERGEABLE is clean"            "MERGEABLE"   "CLEAN"    clean
check "MERGEABLE + UNSTABLE is clean" "MERGEABLE"   "UNSTABLE" clean
check "MERGEABLE + BLOCKED is clean"  "MERGEABLE"   "BLOCKED"  clean

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
