#!/bin/bash
# tests/test_grounding_reports_who_fetched.sh
#
# ostler-assistant #428 (CM051 row 2220, Andy 2026-09-27): the daemon now looks
# a named person up ITSELF before asking the model, and marks that call
# origin=daemon_prefetch. Archie's ruling: that counts as grounded only if the
# probes can SEE it. So:
#   1. both /ws/chat clients emit FRAME tool_origin <tool> <origin>;
#   2. the opening-turn probe counts model_called and daemon_prefetched
#      SEPARATELY and prints both in its summary;
#   3. the verdict is still on the ANSWER: a prefetch the reply ignored is
#      fact_missing_in_reply, and one it used is grounded (the probe's own
#      self-test arms, checked here by name so they cannot be dropped).
# On origin/main before this change, 1 and 2 fail.
set -u
cd "$(dirname "$0")/.." || exit 2
P=scripts/box_walk_probes/probes
pass=0; fail=0
ok()  { echo "  [PASS] $1"; pass=$((pass + 1)); }
bad() { echo "  [FAIL] $1"; fail=$((fail + 1)); }

for f in assistant_grounds_the_opening_turn assistant_answers_grounded; do
    n="$(grep -c 'print("FRAME tool_origin %s %s"' "$P/$f.sh")"
    [ "$n" -eq 1 ] && ok "$f emits FRAME tool_origin" || bad "$f emits FRAME tool_origin (found $n)"
done

O="$P/assistant_grounds_the_opening_turn.sh"
n="$(grep -c 'model_called=${_model_called} daemon_prefetched=${_daemon_prefetched}' "$O")"
[ "$n" -eq 1 ] && ok "opening-turn summary reports model_called and daemon_prefetched" || bad "summary counts (found $n)"
n="$(grep -c "daemon_prefetch\$' \"\$_raw\"" "$O")"
[ "$n" -eq 1 ] && ok "daemon_prefetch calls are counted per opening" || bad "per-opening daemon count (found $n)"

out="$(bash "$O" --self-test 2>&1)"
for arm in "daemon prefetch, answer used it -> grounded" "daemon prefetch, answer ignored -> fact_missing_in_reply"; do
    n="$(printf '%s\n' "$out" | grep -cF "arm OK: classify_opening/$arm")"
    [ "$n" -eq 1 ] && ok "self-test arm: $arm" || bad "self-test arm: $arm (found $n)"
done

# CONTROL: the same count on a copy without the origin line must fail, so a
# pass above is a measurement and not a grep that cannot miss.
tmp="$(mktemp)"; grep -v 'FRAME tool_origin' "$O" > "$tmp"
n="$(grep -c 'print("FRAME tool_origin %s %s"' "$tmp")"; rm -f "$tmp"
[ "$n" -eq 0 ] && ok "CONTROL: a copy without the origin frame counts 0" || bad "CONTROL could not fail"

echo "== $pass pass / $fail fail =="
[ "$fail" -eq 0 ]
