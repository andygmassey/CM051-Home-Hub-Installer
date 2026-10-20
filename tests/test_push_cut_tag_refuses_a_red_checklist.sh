#!/usr/bin/env bash
# A cut tag must not be pushed unless the tag run's own preflight, rehearsed at
# the SAME SHA, concluded success (scripts/push_cut_tag.sh).
# Arms: failure refuses; success at another SHA refuses; success at this SHA
# reaches the push; a mutant that ignores the conclusion is caught.
# CANDIDATE ARMS (v1.0.109, v1.0.110 spent their tags without one): no green
# cut/<version> candidate build at this SHA refuses; one at another SHA
# refuses; one whose cut job failed refuses; a mutant ignoring the candidate's
# conclusion is caught. The rehearsal arms all run with a green candidate.
# The PR-age lookahead is held green here (OSTLER_PRETAG_PRAGE=true); it has
# its own test, test_push_cut_tag_refuses_a_pr_crossing_48h_soon.sh.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
S=scripts/push_cut_tag.sh
H=$(git rev-parse HEAD); O=$(git rev-parse HEAD~1)
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }; no(){ echo "  FAIL $1"; fail=$((fail+1)); }
run(){ OSTLER_PRETAG_PRAGE=true OSTLER_PRETAG_DRY_RUN=1 OSTLER_PRETAG_CANDIDATE="echo success $H https://example.invalid/cand" OSTLER_PRETAG_REHEARSE="echo $1 https://example.invalid/run" bash "$2" v1.0.99999 "$H" 2>&1; }
cand(){ OSTLER_PRETAG_PRAGE=true OSTLER_PRETAG_DRY_RUN=1 OSTLER_PRETAG_CANDIDATE="echo $1 https://example.invalid/cand" OSTLER_PRETAG_REHEARSE="echo success $H https://example.invalid/run" bash "$2" v1.0.99999 "$H" 2>&1; }
out=$(bash "$S" v0.0.0 "$H" 2>&1); [ $? -eq 2 ] && ok "non-cut version refused" || no "non-cut version accepted"
out=$(run "failure $H" "$S"); rc=$?
[ $rc -ne 0 ] && grep -q REFUSED <<<"$out" && ! grep -q DRY-RUN <<<"$out" && ok "failed rehearsal refuses, pushes nothing" || no "failed rehearsal did not refuse"
out=$(run "success $O" "$S"); rc=$?
[ $rc -ne 0 ] && ! grep -q DRY-RUN <<<"$out" && ok "green rehearsal at ANOTHER sha refuses" || no "green rehearsal at another sha accepted"
out=$(run "success $H" "$S"); rc=$?
[ $rc -eq 0 ] && grep -q "DRY-RUN: git tag v1.0.99999 $H" <<<"$out" && ok "green rehearsal at this sha reaches the push" || no "green rehearsal at this sha did not reach the push"
m=$(mktemp); sed 's/if \[ "\$conclusion" != "success" \]; then/if false; then/' "$S" > "$m"
if cmp -s "$S" "$m"; then no "mutant did not apply"; else
  out=$(run "failure $H" "$m"); [ $? -eq 0 ] && ok "mutant ignoring the conclusion is caught" || no "mutant survived"; fi
rm -f "$m"
out=$(cand "none - no-completed-candidate-build" "$S"); rc=$?
[ $rc -ne 0 ] && grep -q "REFUSED. No candidate build" <<<"$out" && ! grep -q DRY-RUN <<<"$out" && ok "no candidate build refuses, pushes nothing" || no "no candidate build did not refuse"
out=$(cand "success $O" "$S"); rc=$?
[ $rc -ne 0 ] && ! grep -q DRY-RUN <<<"$out" && ok "green candidate at ANOTHER sha refuses" || no "green candidate at another sha accepted"
out=$(cand "failure $H" "$S"); rc=$?
[ $rc -ne 0 ] && grep -q "candidate build's cut job concluded 'failure'" <<<"$out" && ! grep -q DRY-RUN <<<"$out" && ok "candidate whose cut job failed refuses" || no "failed candidate did not refuse"
out=$(cand "cancelled $H" "$S"); rc=$?
[ $rc -ne 0 ] && ! grep -q DRY-RUN <<<"$out" && ok "cancelled candidate (the v1.0.109 shape) refuses" || no "cancelled candidate accepted"
m=$(mktemp); sed 's/if \[ "\$cand_conclusion" != "success" \]; then/if false; then/' "$S" > "$m"
if cmp -s "$S" "$m"; then no "candidate mutant did not apply"; else
  out=$(cand "failure $H" "$m"); [ $? -eq 0 ] && ok "mutant ignoring the candidate conclusion is caught" || no "candidate mutant survived"; fi
rm -f "$m"; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
