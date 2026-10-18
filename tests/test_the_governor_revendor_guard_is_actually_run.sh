#!/usr/bin/env bash
# THE GOVERNOR RE-VENDOR GUARD HAS NEVER BEEN RUN BY ANYTHING (#1164).
#
# scripts/verify_doctor_governor_revendor.sh has been in the tree since the
# #282 graft. Its only "wiring" is a sentence in a comment. Measured: the only
# occurrences of its name anywhere outside itself are cut-manifest rows - the
# SAME row, carried forward through 28 manifests from v1.0.72 to v1.0.99,
# reporting every time that it has no callers. Nothing in .github/workflows,
# no script, no Makefile ever invokes it. A positive control on that same
# search finds verify_test_wiring.sh named in four workflow files, so the
# search shape can find a wired script; this one is genuinely unwired.
#
# WHY IT WAS NEVER SIMPLY WIRED, which is the interesting part and the reason
# the row survived 28 cuts: the script EXITS 1 ON A HEALTHY TREE, by design.
# Its own SCOPE note says so. The #282 re-vendor has not happened, the pin is
# still b0b3831, and the config_panel half was deliberately not adopted, so
# exactly ONE of its nine checks fails and that single FAIL is the honest
# state of the tree. Adding `run: bash scripts/verify_...` to a workflow would
# paint CI permanently red, and the next person would delete it.
#
# So it is wired as a RATCHET over its output instead of over its exit code:
# the known residue is pinned, and CI speaks up when the residue CHANGES in
# either direction.
#
#   more than one FAIL  -> a real regression in the vendored governor
#   zero FAILs          -> good news: the re-vendor landed. The guard and its
#                          recipe then need updating, and that must not pass
#                          silently or the script goes back to asserting
#                          nothing.
#   exactly the one     -> the documented state, green.
#
# This is the "a probe never graded" failure mode: the probe existed, ran
# correctly, and no one read its answer.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; [ $# -gt 1 ] && printf '         %s\n' "$2"; FAIL=$((FAIL+1)); }

GUARD=scripts/verify_doctor_governor_revendor.sh
EXPECTED_FAIL='config-env-bridge'

printf '\n=== THE GOVERNOR RE-VENDOR GUARD IS ACTUALLY RUN ===\n\n'

if [ -x "$GUARD" ]; then
    ok "the guard exists and is executable"
else
    bad "$GUARD is missing or not executable"
    printf '\n== %d pass / %d fail ==\n' "$PASS" "$FAIL"; exit 1
fi

# Run it. It is EXPECTED to exit non-zero; that is not this test's verdict.
out="$(bash "$GUARD" 2>&1)"; guard_rc=$?

if [ -n "$out" ]; then
    ok "the guard produced output to grade ($(printf '%s\n' "$out" | wc -l | tr -d ' ') lines, rc=${guard_rc})"
else
    bad "the guard produced NO output; there is nothing to grade and a silent pass would be meaningless"
fi

# grep -c, never a pipe into a quiet grep: under pipefail that inverts.
n_fail=$(printf '%s\n' "$out" | grep -c '^  FAIL' || true)
n_ok=$(printf '%s\n'   "$out" | grep -c '^  ok'   || true)

# The denominator, stated rather than implied.
if [ "$n_ok" -ge 1 ]; then
    ok "the guard actually checked things: ${n_ok} ok, ${n_fail} FAIL, denominator $((n_ok + n_fail))"
else
    bad "the guard reported ZERO ok lines; a zero denominator reads as success and must not" "$out"
fi

case "$n_fail" in
    1)
        line="$(printf '%s\n' "$out" | grep '^  FAIL' || true)"
        if [ "$(printf '%s\n' "$line" | grep -cF "$EXPECTED_FAIL")" -gt 0 ]; then
            ok "exactly the ONE documented residue, and it is the expected one (${EXPECTED_FAIL})"
        else
            bad "one FAIL, but not the documented one; the vendored governor has changed" "$line"
        fi
        ;;
    0)
        bad "ZERO failures: the #282 re-vendor appears to have LANDED" \
            "This is good news and still a stop. Update ${GUARD}'s SCOPE note and this ratchet's expectation to the new state, and close #1164."
        ;;
    *)
        bad "${n_fail} failures, expected 1; the vendored governor has regressed" \
            "$(printf '%s\n' "$out" | grep '^  FAIL' || true)"
        ;;
esac

# ---------------------------------------------------------------------------
# CONTROLS. Without these the classifier above could accept anything.
# ---------------------------------------------------------------------------
classify() { printf '%s\n' "$1" | grep -c '^  FAIL' || true; }

ctl_two="$(printf '  ok   a\n  FAIL config-env-bridge x\n  FAIL something-else y\n')"
[ "$(classify "$ctl_two")" -eq 2 ] \
    && ok "CONTROL: a two-failure output is counted as two, so a regression cannot read as the known residue" \
    || bad "CONTROL: the counter did not see two failures"

ctl_zero="$(printf '  ok   a\n  ok   b\n')"
[ "$(classify "$ctl_zero")" -eq 0 ] \
    && ok "CONTROL: a clean output is counted as zero, so 're-vendor landed' is distinguishable" \
    || bad "CONTROL: the counter did not see zero failures"

# And the discriminator that matters: the expected-name check must reject a
# DIFFERENT single failure, or arm 3 would pass on any one-failure output.
ctl_other="$(printf '  FAIL daemon_cron MISSING\n')"
if [ "$(printf '%s\n' "$ctl_other" | grep -cF "$EXPECTED_FAIL")" -eq 0 ]; then
    ok "CONTROL: a different single failure is NOT accepted as the documented residue"
else
    bad "CONTROL: the name check accepts any failure, so it discriminates nothing"
fi

printf '\n== %d pass / %d fail / %d total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
