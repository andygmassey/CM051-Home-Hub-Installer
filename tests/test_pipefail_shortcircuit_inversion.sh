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
# It is a race, not a constant: it fires only when the consumer exits before
# the producer finishes writing. Small output and printf completes first, and
# everything looks fine. That is why this was green on main and red on one PR,
# and it is why "it passed on the re-run" is not evidence that it is fixed.
#
# WORSE THAN THE ONE THAT FIRED. The same file had the construct at line 182
# guarding "did the mutation actually apply":
#
#     if grep '^ship:' "$MUT/Makefile" | grep -q 'verify-stapling'; then
#         echo "MUTATION DID NOT APPLY"; exit 1
#     fi
#
# There the inversion is a FALSE PASS. If the mutation silently failed to
# apply, grep -q MATCHES, the pipeline reads non-zero, the condition is FALSE,
# and the guard against a vacuous proof is itself vacuous.
#
# ============================================================================
# WHAT THIS TEST ASSERTS
# ============================================================================
#
#   1  the OLD construct really does invert (positive control on the premise)
#   2  the herestring replacement reports the match correctly
#   3  repo-wide: the scanner can see a KNOWN instance, and the population is
#      not growing
#
# 1 and 2 would pass forever against a file nobody uses. Limb 3 is what binds
# this to the tree.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

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
    bad "haystack is malformed: expected 1 occurrence, got ${OCC}. Limbs 1 and 2 are void."
    finish
fi

# --- 1. POSITIVE CONTROL ON THE PREMISE --------------------------------------
if ( set -o pipefail; printf '%s\n' "$HAY" | grep -q -- '- verify-stapling' ) 2>/dev/null; then
    bad "POSITIVE CONTROL: the OLD construct did NOT invert here. This file can no longer tell the fix from the bug, so limb 2 proves nothing. Investigate before trusting any green from it."
else
    ok "POSITIVE CONTROL: 'printf | grep -q' under pipefail reports FAILURE on a needle that IS present"
fi

# --- 2. the replacement is correct -------------------------------------------
if ( set -o pipefail; grep -q -- '- verify-stapling' <<< "$HAY" ); then
    ok "FIXED: 'grep -q PAT <<< \$var' reports the match correctly under pipefail"
else
    bad "the herestring reported NO match on a needle that IS present. The replacement is wrong."
fi

# --- 3. REPO-WIDE, WITH A POSITIVE CONTROL AND A RATCHET ---------------------
# TNM's correction, and they were right: this started as a FILE fix for the
# file the symptom appeared in. The pattern is a CLASS. Scoped to one workflow,
# limb 3 would have reported CM051 clean while 70 other files carried it.
#
# POSITIVE CONTROL. tests/test_imessage_probe_cannot_hang.sh is a KNOWN
# instance, merged in #891, named by TNM. A scanner that cannot see a case we
# already know about cannot be trusted to find one we do not, so its absence
# voids the ratchet rather than passing it.
#
# RATCHET, NOT A BIG BANG. Most of the population will never fire: the
# inversion needs the producer still writing when the consumer exits, so a
# short producer is safe in practice. That is a reason to stop the count
# GROWING, not to rewrite every file on the eve of a cut. Ratcheting BOTH ways
# means a fix that forgets to lower the baseline is also caught, so the number
# cannot rot in either direction.
CONSTRUCT='^[[:space:]]*(if|elif|while)[[:space:]].*\|[[:space:]]*(grep [^|]*-q|grep [^|]*-m1|head( |$)|read )'
BASELINE_FILE='tests/pipefail_shortcircuit_baseline.txt'

# Only files that ALSO set pipefail can invert. Without it the pipeline status
# is the LAST command's, which is grep's own verdict, and nothing is wrong.
# `grep -c` is deliberately NOT in CONSTRUCT: it must consume all input to
# count, so it cannot short-circuit.
population() {
    local f
    for f in $(grep -rlE "$CONSTRUCT" --include='*.sh' --include='*.yml' . 2>/dev/null | grep -v '/\.git/' | sort); do
        grep -qE 'set -o pipefail|set -[a-z]+o[a-z]* pipefail' "$f" 2>/dev/null && echo "$f"
    done
}
POP="$(population)"
POP_N="$(printf '%s\n' "$POP" | grep -c . || true)"
printf '        population examined: %s files (construct in a condition AND pipefail set)\n' "$POP_N"

CONTROL='./tests/test_imessage_probe_cannot_hang.sh'
if printf '%s\n' "$POP" | grep -qxF "$CONTROL"; then
    ok "POSITIVE CONTROL: the scanner sees ${CONTROL#./}, a known instance (TNM, merged in #891)"
else
    bad "POSITIVE CONTROL FAILED: the scanner did NOT see ${CONTROL#./}, which IS an instance. The scanner is blind and the ratchet below is void."
fi

if [ ! -f "$BASELINE_FILE" ]; then
    bad "${BASELINE_FILE} is missing, so there is nothing to ratchet against and 'no new instances' would be unfounded"
else
    BASE_N="$(grep -vcE '^[[:space:]]*(#|$)' "$BASELINE_FILE" || true)"
    if [ "$POP_N" -gt "$BASE_N" ]; then
        bad "ratchet: ${POP_N} instances vs baseline ${BASE_N}. NEW:"
        comm -13 <(grep -vE '^[[:space:]]*(#|$)' "$BASELINE_FILE" | sort) <(printf '%s\n' "$POP" | sort) | sed 's/^/          /'
        printf '          Use a herestring: grep -q PAT <<< "$var", never printf | grep -q.\n'
    elif [ "$POP_N" -lt "$BASE_N" ]; then
        bad "ratchet: ${POP_N} instances, baseline still ${BASE_N}. Instances were FIXED without lowering the baseline, so the ratchet has slack and the next regression hides in it. Regenerate ${BASELINE_FILE}."
    else
        ok "ratchet: ${POP_N} instances, baseline ${BASE_N}, exact"
    fi
fi

finish
