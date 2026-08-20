#!/usr/bin/env bash
# UNDER `set -o pipefail`, PIPING INTO A SHORT-CIRCUITING CONSUMER INVERTS A
# SUCCESSFUL MATCH INTO A REPORTED FAILURE.
#
# ============================================================================
# WHAT WAS BROKEN, AND HOW IT SURFACED
# ============================================================================
#
# appcast-ship-wiring went RED on CM051 #890, on this step:
#
#     Control A goes RED when a prerequisite is dropped (a swap, count unchanged)
#
# Its own output NAMED the dropped prerequisite:
#
#     MISSING -- ship: no longer names these, so the cut no longer runs them:
#       - verify-stapling
#
# and the very next lines were:
#
#     .../<step>.sh: line 17: printf: write error: Broken pipe
#     The failure did not NAME the dropped prerequisite.
#
# Line 17 was:
#
#     if ! printf '%s\n' "$out" | grep -q -- '- verify-stapling'; then
#
# THE MECHANISM. `grep -q` exits 0 the instant it matches. That closes the
# pipe while `printf` is still writing, so printf dies with EPIPE. `pipefail`
# makes the PIPELINE's status the rightmost NON-ZERO status, which is now
# printf's. The `!` inverts it, and a SUCCESSFUL match is reported as a failed
# one.
#
# It is a race, not a constant: it only fires when the consumer exits before
# the producer finishes writing. Small output, or a match near the end, and
# printf completes first and everything looks fine. That is exactly why this
# was green on main and red on one PR whose output was slightly longer, and it
# is why "it passed on re-run" is not evidence that it is fixed.
#
# WORSE THAN THE ONE THAT FIRED. The same file had the construct at line 182
# guarding "did the mutation actually apply":
#
#     if grep '^ship:' "$MUT/Makefile" | grep -q 'verify-stapling'; then
#         echo "MUTATION DID NOT APPLY"; exit 1
#     fi
#
# There, the inversion is a FALSE PASS. If the mutation silently failed to
# apply, grep -q MATCHES, the pipeline reads non-zero, the condition is FALSE,
# and the guard against a vacuous proof is itself vacuous.
#
# ============================================================================
# WHAT THIS TEST ASSERTS
# ============================================================================
#
# 1. POSITIVE CONTROL: the OLD construct really does invert. If this stops
#    failing, the bug is gone from bash itself and assertion 2 proves nothing.
# 2. The NEW construct (herestring, no pipe) reports the match correctly.
# 3. The workflow no longer contains a condition-bearing pipe into `grep -q`.
#
# Assertion 3 is the one that binds this test to the artefact. 1 and 2 would
# pass forever against a file nobody uses.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

printf '\n=== pipefail + short-circuiting consumer ===\n\n'

# A match at the START, then enough trailing output that the producer is still
# writing when the consumer exits. The size is what makes the race reliable.
build_haystack() {
    printf -- '- verify-stapling\n'
    local i
    for i in $(seq 1 200000); do echo "filler $i padding padding padding padding"; done
}
HAY="$(build_haystack)"

# Ground truth, computed WITHOUT either construct under test.
OCC="$(grep -c -- '- verify-stapling' <<< "$HAY")"
if [ "$OCC" -eq 1 ]; then
    ok "ground truth: the needle occurs exactly once in the haystack"
else
    bad "haystack is malformed: expected 1 occurrence, got ${OCC}. Both assertions below are void."
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi

# --- 1. POSITIVE CONTROL: the old construct inverts ---------------------------
if ( set -o pipefail; printf '%s\n' "$HAY" | grep -q -- '- verify-stapling' ) 2>/dev/null; then
    bad "POSITIVE CONTROL: the OLD construct did NOT invert here. This test can no longer distinguish the fix from the bug, so assertion 2 proves nothing. Investigate before trusting any green from this file."
else
    ok "POSITIVE CONTROL: 'printf | grep -q' under pipefail reports FAILURE on a needle that IS present"
fi

# --- 2. the fixed construct is correct ---------------------------------------
if ( set -o pipefail; grep -q -- '- verify-stapling' <<< "$HAY" ); then
    ok "FIXED: 'grep -q <<< \$var' reports the match correctly under pipefail"
else
    bad "FIXED construct reported NO match on a needle that IS present. The replacement is wrong."
fi

# --- 3. the workflow no longer carries the construct -------------------------
# This is the limb that ties the test to the shipped artefact. A pipe whose
# LAST stage short-circuits and whose status is consumed as a condition.
WF='.github/workflows/appcast-ship-wiring.yml'
if [ ! -f "$WF" ]; then
    bad "${WF} is missing; this test examined no workflow at all"
else
    HITS="$(grep -nE '^\s*if.*\|[[:space:]]*grep [^|]*-q' "$WF" || true)"
    if [ -z "$HITS" ]; then
        ok "${WF} has no condition-bearing pipe into a short-circuiting grep"
    else
        bad "${WF} still pipes into 'grep -q' inside a condition:"
        printf '%s\n' "$HITS" | sed 's/^/          /'
    fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
