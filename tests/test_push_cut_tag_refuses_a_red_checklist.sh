#!/usr/bin/env bash
# A cut tag must not be pushed while the tag-time checklist gate is red.
# Red arm: a checker that exits 1 must produce a refusal and NO push line.
# Green arm: a checker that exits 0 must produce exactly the push line.
# Mutant arm: a copy of the script with the gate call removed must fail the
# red arm, proving this test can see the gate go missing.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
S=scripts/push_cut_tag.sh
V=v0.0.0-pretag-test   # never a real tag; the version guard rejects it...
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }
head_sha=$(git rev-parse HEAD)

# The version guard itself.
out=$(bash "$S" "$V" "$head_sha" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "non-cut version refused (rc=2)" || no "non-cut version not refused (rc=$rc)"

# Use a version that cannot exist on origin.
V=v1.0.99999
run(){ OSTLER_PRETAG_DRY_RUN=1 OSTLER_PRETAG_CHECKER="$1" bash "$2" "$V" "$head_sha" 2>&1; }

out=$(run "exit 1" "$S"); rc=$?
if [ "$rc" -ne 0 ] && grep -q REFUSED <<<"$out" && ! grep -q "DRY-RUN" <<<"$out"; then ok "red checklist refuses and pushes nothing"; else no "red checklist did not refuse (rc=$rc)"; fi

out=$(run "exit 0" "$S"); rc=$?
if [ "$rc" -eq 0 ] && grep -q "DRY-RUN: git tag $V $head_sha" <<<"$out"; then ok "green checklist reaches the push"; else no "green checklist did not reach the push (rc=$rc)"; fi

# printenv rather than a $-expansion: this file ASSERTS what the wrapper sets,
# it is not itself a cut gate (test_a_cut_gate_is_reachable_in_the_cut.py).
out=$(run 'printenv OSTLER_CUT_IN_PROGRESS | grep -qx 1' "$S"); rc=$?
[ "$rc" -eq 0 ] && ok "checker runs in tag mode (OSTLER_CUT_IN_PROGRESS=1)" || no "checker not run in tag mode"

m=$(mktemp); sed 's/^( cd "\$wt" && OSTLER_CUT_IN_PROGRESS=1 bash -c "\$checker" )$/true/' "$S" > "$m"
if cmp -s "$S" "$m"; then no "mutant did not apply"; else
  out=$(run "exit 1" "$m"); rc=$?
  if [ "$rc" -eq 0 ]; then ok "mutant without the gate call is caught by the red arm"; else no "mutant survived"; fi
fi
rm -f "$m"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
