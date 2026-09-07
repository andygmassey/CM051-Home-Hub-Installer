#!/usr/bin/env bash
# The orphan-gate harnesses must not lose the SIGPIPE race when the gate is wordy.
#
# WHY THIS EXISTS. On 2026-09-07 at 17:46:49Z this class killed the v1.0.75 cut
# in the cut job, after preflight had passed for the first time under that
# version number. scripts/orphan_gate_selftest.sh asserted containment with
#
#     ! printf '%s' "$out" | grep -q "$needle"
#
# and under `set -o pipefail` that is a RACE, not a test. grep -q exits the
# instant it matches, closing the pipe under a still-writing printf, which
# takes SIGPIPE and makes the PIPELINE non-zero -- so the `!` fires BECAUSE THE
# NEEDLE WAS FOUND. The step reported
#
#     [FAIL] closed-unmerged PR, no replacement -> RED
#            -- output did not contain 'fix/genuinely-orphaned'
#
# and printed 'T:fix/genuinely-orphaned' in its own diagnostic three lines
# below. Nothing about the gate was wrong. The expiry ratchet had grown to 424
# baselined refs, the gate's output crossed the 64KB pipe buffer, and the
# assertion inverted.
#
# THE DANGEROUS PART IS THAT IT IS SIZE-DEPENDENT. The same harnesses passed on
# this machine, on the same /bin/bash 3.2, minutes earlier and minutes later,
# because the local output fit in the buffer. A re-run reads as transient. That
# is exactly what tests/test_orphan_gate_cannot_verify.sh:38 recorded on
# 2026-08-18 after it cost the v1.0.34 dry run, warning in as many words that a
# green re-run "leaves the other seven sites armed". Six of those seven were
# still armed on 2026-09-07 and one of them spent a cut.
#
# So this test does what a one-line fix cannot: it fails if the construct comes
# back ANYWHERE in the family, and it exercises the real function at a size that
# loses the race.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELFTEST="$HERE/scripts/orphan_gate_selftest.sh"
pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1)); }

echo "== orphan-gate assertions survive a wordy gate =="

# ---------------------------------------------------------------------------
# 1. THE REAL FUNCTION, at a size that loses the race.
# Extracted from the shipping file rather than retyped, so reverting that file
# to `grep -q` fails this test on BEHAVIOUR and not on a text match.
# ---------------------------------------------------------------------------
fn="$(awk '/^check\(\) \{/{s=1} s{print} s&&/^\}/{exit}' "$SELFTEST")"
if [ -z "$fn" ]; then
    bad "could not extract check() from $SELFTEST -- cannot test what I cannot read"
    echo; echo "$pass passed, $fail failed"; exit 2
fi
eval "$fn"

# 300KB, needle FIRST so grep -q would exit immediately with the pipe full.
big="fix/genuinely-orphaned
$(head -c 300000 < /dev/zero | tr '\0' 'x')"

out_len=${#big}
# The extracted check() writes to the SAME pass/fail counters this test uses,
# so they are saved and restored around every call: its verdict is the thing
# under test, never a contribution to this file's own score.
pass_before=$pass; fail_before=$fail
check "wordy gate, needle present -> the case still passes" RED "$big" 1 "fix/genuinely-orphaned" >/dev/null 2>&1
inner_pass=$(( pass - pass_before )); pass=$pass_before; fail=$fail_before
if [ "$inner_pass" -gt 0 ]; then
    ok "real check() finds a needle in ${out_len} bytes of gate output"
else
    bad "real check() LOST THE RACE at ${out_len} bytes -- this is the v1.0.75 cut killer"
fi

# NEGATIVE CONTROL. The fix must not simply always say "contained": a needle
# that is genuinely absent must still be reported absent, at the same size.
pass_before=$pass; fail_before=$fail
check "control: absent needle must still be reported absent" RED "$big" 1 "zzz-this-is-not-in-the-output" >/dev/null 2>&1
inner_fail=$(( fail - fail_before )); pass=$pass_before; fail=$fail_before
if [ "$inner_fail" -gt 0 ]; then
    ok "CONTROL: a genuinely absent needle is still reported absent at ${out_len} bytes"
else
    bad "CONTROL DID NOT FIRE: an absent needle read as present, so this test proves nothing"
fi

# ---------------------------------------------------------------------------
# 2. THE CONSTRUCT MUST NOT COME BACK, anywhere in the family.
# Comments are allowed -- three files explain the race in prose and must keep
# being able to. Only executable lines are counted.
# ---------------------------------------------------------------------------
family="scripts/orphan_gate_selftest.sh
tests/test_no_orphaned_fixes_gate.sh
tests/test_orphan_gate_cannot_verify.sh
tests/test_orphan_gate_pr_skip_is_per_label.sh
tests/test_orphan_gate_empty_pr_list_needs_a_control.sh
tests/test_orphan_gate_failed_fetch_is_not_truth.sh"

code_sites=0; files_read=0; named=""
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    f="$HERE/$rel"
    [ -f "$f" ] || continue
    files_read=$((files_read + 1))
    while IFS=: read -r ln _; do
        [ -n "$ln" ] || continue
        first="$(sed -n "${ln}p" "$f" | sed 's/^[[:space:]]*//' | cut -c1)"
        if [ "$first" != "#" ]; then
            code_sites=$((code_sites + 1)); named="${named} ${rel}:${ln}"
        fi
    done < <(grep -nE '(printf|echo)[^|]*\|[[:space:]]*grep -q' "$f" 2>/dev/null)
done <<< "$family"

# A zero is only meaningful if the scan actually read the files.
if [ "$files_read" -lt 6 ]; then
    bad "only read ${files_read} of 6 family files -- a zero here would be a false absence"
elif [ "$code_sites" -eq 0 ]; then
    ok "0 executable 'printf | grep -q' sites across ${files_read} orphan-gate files"
else
    bad "${code_sites} executable 'printf | grep -q' site(s) are armed again:${named}"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
