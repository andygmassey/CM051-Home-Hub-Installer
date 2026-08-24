#!/usr/bin/env bash
#
# tests/test_expiry_needs_a_cut_version.sh
#
# WITHOUT A CUT VERSION, NOTHING CAN EXPIRE, AND THAT IS NOT THE SAME AS NOTHING
# HAVING EXPIRED.
#
# Every expiry comparison in the orphan gate is `until_cut < CUT_VERSION`, and
# CUT_VERSION is `${OSTLER_CUT_VERSION:-${GITHUB_REF_NAME:-}}`, which is empty on
# any run that is not tag-triggered. With it empty the expired set is empty BY
# CONSTRUCTION. The ratchet then read that as a measurement and printed, on a run
# whose header said `6 repo(s) checked, 0 NOT CHECKED`:
#
#     expiry ratchet: 0 expired now, 426 baselined, 6 repo(s) checked
#     426 baselined ref(s) no longer expire. Re-run with
#     --regenerate-expired-baseline and commit, so they cannot come back:
#
# Taking that advice writes a baseline containing nothing, deletes all 426 refs
# and retires the ratchet, and the pre-existing regeneration guard does not stop
# it because that guard only refuses when a repo went UNCHECKED. The most
# authoritative-looking run this script can produce was the one that disarmed it.
#
# WHY THE PREDICATE IS TESTED AND NOT THE WHOLE GATE. A full six-repo run makes a
# network call per ref and takes about four minutes. A guard that can only be
# exercised by the thing it lives inside is a guard nobody exercises, so the
# predicate is a function and this drives it in a second. The end-to-end run was
# done once by hand and its output is quoted in the PR that added this.
#
# Exit 0 all pass / 1 a check failed / 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_no_orphaned_fixes.sh"

[[ -f "$GATE" ]] || { echo "CANNOT-RUN: gate not found at $GATE (exit 2)" >&2; exit 2; }

FN="$(sed -n '/^expiry_is_evaluable() {$/,/^}$/p' "$GATE")"
if [[ -z "$FN" ]]; then
    echo "CANNOT-RUN: expiry_is_evaluable() not found in ${GATE}." >&2
    echo "  Renamed or inlined; this test is measuring nothing." >&2
    exit 2
fi
eval "$FN"
declare -F expiry_is_evaluable >/dev/null || {
    echo "CANNOT-RUN: the extracted text did not define expiry_is_evaluable (exit 2)" >&2
    exit 2
}

pass=0; fail=0
ok()  { printf '  [pass] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

want() {  # want <label> <input> <expect-evaluable 0|1>
    local label="$1" in="$2" expect="$3" got
    if expiry_is_evaluable "$in"; then got=0; else got=1; fi
    if [[ "$got" == "$expect" ]]; then
        ok "$label"
    else
        bad "$label  (expected $( [[ "$expect" == 0 ]] && echo evaluable || echo 'NOT evaluable'), got the other)"
    fi
}

echo "== a run with no cut version cannot evaluate expiry =="
want "(1) empty string is NOT evaluable"              ""                  1
want "(2) a branch name is NOT evaluable"             "main"              1
want "(3) a full branch ref is NOT evaluable"         "refs/heads/main"   1
want "(4) an incomplete version is NOT evaluable"     "v1.0"              1
want "(5) prose with no version is NOT evaluable"     "the next cut"      1

echo "== and a real cut version can =="
want "(6) a tag is evaluable"                         "v1.0.45"           0
want "(7) a full tag ref is evaluable"                "refs/tags/v1.0.45" 0
want "(8) a version with trailing prose is evaluable" "v1.0.45 -- launch" 0

echo "== the regeneration guard consults it, and BEFORE the unchecked guard =="
# Order is load-bearing. On the run that produced the 426-ref advice, unchecked
# was 0, so a cut-version check placed after the unchecked check would have been
# reached -- but if the unchecked guard ever exits first for a different reason
# the operator gets the wrong instruction. The cut-version fact is the more
# fundamental one: it says the SET is meaningless, not merely incomplete.
regen_line="$(grep -n 'REGEN_EXPIRED. -eq 1' "$GATE" | head -1 | cut -d: -f1)"
eval_line="$(awk -v s="${regen_line:-0}" 'NR>s && /EXPIRY_EVALUABLE. -eq 0/ {print NR; exit}' "$GATE")"
unchk_line="$(awk -v s="${regen_line:-0}" 'NR>s && /unchecked. -gt 0/ {print NR; exit}' "$GATE")"
if [[ -z "$regen_line" ]]; then
    bad "(9) could not find the regeneration block at all"
elif [[ -z "$eval_line" ]]; then
    bad "(9) the regeneration block does not consult EXPIRY_EVALUABLE"
elif [[ -z "$unchk_line" ]]; then
    bad "(9) the regeneration block does not consult unchecked -- has it moved?"
elif [[ "$eval_line" -lt "$unchk_line" ]]; then
    ok "(9) regeneration checks the cut version (line ${eval_line}) before unchecked (line ${unchk_line})"
else
    bad "(9) regeneration checks unchecked (${unchk_line}) before the cut version (${eval_line})"
fi

echo "== the report says NOT EVALUATED rather than a count of zero =="
if grep -q 'expiry ratchet: NOT EVALUATED' "$GATE"; then
    ok "(10) the not-evaluated branch exists and names itself"
else
    bad "(10) no NOT EVALUATED branch -- an empty set is still being printed as 0 expired"
fi

# The dangerous sentence is the regeneration advice. It must be unreachable when
# expiry was not evaluated, which means it has to sit AFTER the guard branch.
# Comment lines are excluded on purpose. The gate quotes the offending output in
# its own explanatory block, so a bare grep finds the PROSE first and compares
# the wrong line numbers. Grep the invariant, not the discussion of it.
advice_line="$(grep -n 'no longer expire' "$GATE" | grep -v ':[[:space:]]*#' | head -1 | cut -d: -f1)"
guard_line="$(grep -n 'expiry ratchet: NOT EVALUATED' "$GATE" | grep -v ':[[:space:]]*#' | head -1 | cut -d: -f1)"
if [[ -n "$advice_line" && -n "$guard_line" && "$guard_line" -lt "$advice_line" ]]; then
    ok "(11) the regenerate-and-commit advice sits behind the guard (${guard_line} < ${advice_line})"
else
    bad "(11) the regenerate-and-commit advice is not behind the not-evaluated guard"
fi

echo "== CONTROL: this test can fail =="
# If the predicate were `return 0` always, limbs 1-5 would pass wrongly. Prove
# the function actually discriminates by requiring BOTH answers from it.
yes_n=0; no_n=0
for v in "v1.0.45" "refs/tags/v9.9.99"; do expiry_is_evaluable "$v" && yes_n=$((yes_n+1)); done
for v in "" "main"; do expiry_is_evaluable "$v" || no_n=$((no_n+1)); done
if [[ "$yes_n" -eq 2 && "$no_n" -eq 2 ]]; then
    ok "(12) CONTROL: the predicate returns both answers (2 evaluable, 2 not)"
else
    bad "(12) CONTROL FAILED: yes=${yes_n}/2 no=${no_n}/2 -- a constant predicate would pass limbs 1-8"
fi

echo
echo "expiry needs a cut version: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]] || exit 1
exit 0
