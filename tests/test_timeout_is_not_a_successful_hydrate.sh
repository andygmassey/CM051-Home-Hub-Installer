#!/usr/bin/env bash
# ============================================================================
# test_timeout_is_not_a_successful_hydrate.sh -- no hydrate source may treat a
# TIMEOUT as a successful run.
#
# THE DEFECT (#774, mechanism found 2026-08-19)
#
# The v1.0.36 walk reported hydrate sources timing out (rc=124) while STEP_END
# recorded status=ok. #839 had already made the sentinel recorder the step's
# status source, so the two could not disagree -- which meant the fault had to
# be that the timeout never REACHED the recorder. It did not, for exactly one
# source:
#
#     if [[ "$_HYDRATE_IMESSAGE_TIMED_OUT" != "true" ]] && [[ "$rc" -ne 0 ]]
#
# rc=124 took the ELSE arm and wrote a SUCCESS sentinel. Consequences, in
# increasing order of how much they cost:
#
#   1. STEP_END said ok over a step gtimeout had killed
#   2. the success sentinel DEDUPES RE-RUNS FOR 7 DAYS, so the retry that
#      would have finished the job never happened -- #711/#712's harm,
#      re-introduced by a conjunct those tickets did not remove
#   3. no rc folded, so nothing downstream could tell
#
# ============================================================================
# WHY IT WAS FIVE-OF-SIX, WHICH IS THE PART THAT MAKES A GATE WORTH BUILDING
# ============================================================================
#
# whatsapp, browsing, email_preferences, apple_notes and people ALL guard their
# error recorder on a bare `rc -ne 0`, so a timeout reaches it. Only iMessage
# carried the extra `TIMED_OUT != true` conjunct. That is a one-line divergence
# in a family of six, invisible to anything that checks "does this source have
# an error recorder" -- it has one; it just cannot be reached by the failure
# that matters. This gate asserts the SHAPE OF THE GUARD, not the presence of
# the call.
#
# THE JUSTIFICATION THAT WAS THERE, AND WHY IT DID NOT SURVIVE
#
# The comment argued "the work carries on". TRUE -- the imessage-bundle tick
# recurs and dispatches. But that is an argument about what to TELL THE
# CUSTOMER, not about what to RECORD. Every other source shows the same calm
# message AND records honestly. Buying calm by writing something untrue is the
# trade this gate refuses.
#
# EXIT CODES   0 all controls pass   1 a control failed   2 CANNOT-RUN
# ============================================================================
set -uo pipefail

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
INSTALL_SH="${REPO_ROOT}/install.sh"

PASS=0
FAIL=0
cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ -f "$INSTALL_SH" ]] || cannot_run "install.sh not found at $INSTALL_SH"

# Every guard line that decides whether a source records an ERROR. Found by
# looking one line ABOVE each recorder call, because that is where the decision
# lives -- the call itself is identical in the broken and fixed versions, which
# is why "does it call the recorder" could never have caught this.
GUARDS="$(grep -n -B1 '^\s*_hydrate_sentinel_record_error ' "$INSTALL_SH" \
          | grep -E '^\s*[0-9]+-.*if \[\[' || true)"

[[ -n "$GUARDS" ]] || cannot_run \
    "found no 'if [[ ... ]]' guard directly above any _hydrate_sentinel_record_error call. Either the recorder was renamed or the shape changed; refusing rather than reporting clean."

GUARD_COUNT="$(printf '%s\n' "$GUARDS" | wc -l | tr -d ' ')"

# A floor. #774 was found across six guarded recorders; fewer than that means
# coverage was removed rather than corrected.
FLOOR=6

echo "hydrate timeout honesty (install.sh: $INSTALL_SH)"
echo "  examined ${GUARD_COUNT} error-recorder guard(s)"

# (1) THE DEFECT. No guard may exclude the timeout case from error recording.
#     Matches the variable FAMILY, not one source's spelling, so the next
#     source to grow a _TIMED_OUT flag is covered on the day it is written.
c1() {
    local hits
    hits="$(printf '%s\n' "$GUARDS" | grep -E '_TIMED_OUT" *!= *"true"' || true)"
    if [[ -n "$hits" ]]; then
        printf '%s\n' "$hits" | sed 's/^/         /' >&2
        return 1
    fi
    return 0
}

# (2) FLOOR, so deleting recorders is not a way to pass.
c2() { [[ "$GUARD_COUNT" -ge "$FLOOR" ]]; }

# (3) Every guard still actually tests rc. A guard that stopped testing rc
#     would pass (1) trivially and record errors never or always -- both worse
#     than the defect.
c3() {
    local n
    n="$(printf '%s\n' "$GUARDS" | grep -cE 'rc(:-0\})? *" *-ne *0|-ne 0' || true)"
    [[ "$n" -eq "$GUARD_COUNT" ]]
}

# (4) ANTI-VACUITY. Fire the predicate at the exact guard that shipped. If this
#     does not match, control (1) is measuring nothing and its pass is empty.
c4() {
    printf '%s\n' '    if [[ "$_HYDRATE_IMESSAGE_TIMED_OUT" != "true" ]] && [[ "$rc" -ne 0 ]]; then' \
        | grep -qE '_TIMED_OUT" *!= *"true"'
}

if c1; then pass "no error-recorder guard excludes the timeout case"
       else failure "a guard excludes rc=124/137 from error recording. A timeout then writes a SUCCESS sentinel, STEP_END says ok, and the 7-day dedupe suppresses the retry. Offending guard(s) above."; fi
if c2; then pass "guard floor holds (${GUARD_COUNT} >= ${FLOOR})"
       else failure "only ${GUARD_COUNT} guarded recorder(s), floor is ${FLOOR}. Coverage shrank rather than improved."; fi
if c3; then pass "every guard still tests rc"
       else failure "a guard no longer tests rc, so it records errors never or always. Passing (1) that way is not a fix."; fi
if c4; then pass "ANTI-VACUITY: the predicate fires on the exact guard that shipped"
       else failure "the predicate does NOT match the guard this gate exists to ban. It is measuring nothing."; fi

echo
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILED: ${FAIL} of $((PASS + FAIL)) controls"
    exit 1
fi
echo "PASSED: ${PASS} of ${PASS} controls"
exit 0
