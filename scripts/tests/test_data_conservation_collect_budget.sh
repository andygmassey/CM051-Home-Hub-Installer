#!/usr/bin/env bash
# scripts/tests/test_data_conservation_collect_budget.sh
# OS003 #420: the data_conservation collect had no time budget (2h, 45 min, killed by hand).
# Drives the REAL probe with a fake lib whose `collect` is slow, and checks:
#   1. slow collect, tiny budget -> CANNOT-RUN-BUDGET (rc 78) within budget+slack, and NO live child
#   2. fast collect -> its normal verdict (PASS, rc 0), no budget claim
#   3. MUTANT: the same probe with the kill removed -> overrun or orphan (this test goes RED on it)
#   4. a non-numeric budget is CANNOT-RUN, not a silent default
# Every process started carries a unique marker (sleep arg); only that marker is killed.
# EXIT: 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBES="${REPO}/scripts/box_walk_probes"
PROBE="${DC_BUDGET_PROBE:-${PROBES}/probes/data_conservation.sh}"
REAL_LIB="${PROBES}/lib/data_conservation.py"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
for f in "$PROBE" "$REAL_LIB"; do [ -r "$f" ] || { echo "CANNOT-RUN: $f unreadable" >&2; exit 2; }; done
for c in perl python3 pgrep; do command -v "$c" >/dev/null || { echo "CANNOT-RUN: no $c" >&2; exit 2; }; done
W="$(mktemp -d)"
MARK="3$(date +%s)$$"   # unique sleep argument, seen by pgrep -f
cleanup() { pkill -9 -f "sleep ${MARK}" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

# Fake lib: slow collect spawns a child (unique marker) and itself sleeps (self-expires at 45s
# so a mutant orphan cannot outlive the test); fast collect prints facts; adjudicate is the REAL one.
cat > "$W/fake_lib.py" <<PY
import sys, os, time, subprocess
mode = sys.argv[1]
if mode == "collect":
    if os.environ.get("FAKE_SLOW") == "1":
        subprocess.Popen(["sleep", "${MARK}"])
        time.sleep(45)
    else:
        print('{"facts":{"i":10,"s":10,"w":10}}')
else:
    os.execv(sys.executable, [sys.executable, "${REAL_LIB}"] + sys.argv[1:])
PY
cat > "$W/exp.json" <<'J'
{"profiles":{"chain":{"rows":[
 {"id":"a/x","source":"a","category":"x","expected":{"in":10,"stored":10,"shown":10},"facts":{"in":"i","stored":"s","shown":"w"}}]}}}
J
# The fake lib is fed as the heredoc payload, so the box command is `perl wrapper python3 - collect`.
# FAKE_SLOW must reach the remote shell: box_run in local mode is bash -lc, which inherits env.

run_probe() { # $1 probe path, $2 budget, $3 slow(1/0) -> out in $W/out, rc in RC, elapsed in EL
    local t0; t0=$(date +%s)
    FAKE_SLOW="$3" OSTLER_CONSERVATION_LIB="$W/fake_lib.py" OSTLER_CONSERVATION_EXPECTED="$W/exp.json" \
      OSTLER_CONSERVATION_COLLECT_BUDGET_S="$2" \
      perl -e 'alarm 30; exec @ARGV' bash "$1" > "$W/out" 2>&1
    RC=$?; EL=$(( $(date +%s) - t0 ))
}
alive() { pgrep -f "sleep ${MARK}" >/dev/null 2>&1; }
settle() { sleep 1; }

# 1. slow collect, budget 3s
run_probe "$PROBE" 3 1; settle
if [ "$RC" -eq 78 ] && grep -q 'CANNOT-RUN-BUDGET' "$W/out"; then ok "1a: slow collect -> CANNOT-RUN-BUDGET rc 78 (elapsed ${EL}s)"; else bad "1a: rc=$RC $(tail -2 "$W/out")"; fi
{ [ "$EL" -ge 3 ] && [ "$EL" -le 12 ]; } && ok "1b: returned within budget+slack (${EL}s for a 3s budget)" || bad "1b: elapsed ${EL}s for a 3s budget"
if alive; then bad "1c: a child of the collect is STILL ALIVE after the budget"; pkill -9 -f "sleep ${MARK}"; else ok "1c: no live child (pgrep on the unique marker is empty)"; fi
grep -q 'VERDICT: PASS\|VERDICT: FAIL' "$W/out" && bad "1d: a budget hit must not claim PASS or FAIL" || ok "1d: no PASS/FAIL verdict on a budget hit"

# 2. fast collect, generous budget: normal verdict
run_probe "$PROBE" 60 0
{ [ "$RC" -eq 0 ] && grep -q 'VERDICT: PASS' "$W/out" && ! grep -q 'BUDGET' "$W/out"; } && ok "2: fast collect -> its normal PASS, no budget claim" || bad "2: rc=$RC $(tail -2 "$W/out")"

# 4. bad budget value
run_probe "$PROBE" abc 0
{ [ "$RC" -eq 78 ] && grep -q 'must be a positive integer' "$W/out"; } && ok "4: a non-numeric budget is CANNOT-RUN" || bad "4: rc=$RC $(tail -2 "$W/out")"

# 3. MUTANT: strip the kill from a copy of the probe tree; the SAME checks must go red.
if [ -z "${DC_BUDGET_PROBE:-}" ]; then
    cp -R "$PROBES" "$W/mut"
    perl -0pi -e 's/kill\("TERM", -\$p\); select\(undef,undef,undef,2\); kill\("KILL", -\$p\);//' "$W/mut/probes/data_conservation.sh"
    if cmp -s "$PROBE" "$W/mut/probes/data_conservation.sh"; then bad "3: mutation did not apply"; else
        run_probe "$W/mut/probes/data_conservation.sh" 3 1; settle
        if [ "$RC" -ne 78 ] || [ "$EL" -gt 12 ] || alive; then ok "3: MUTANT (no kill) is caught: rc=$RC elapsed=${EL}s orphan_alive=$(alive && echo yes || echo no)"; else bad "3: mutant (no kill) still came out clean; test cannot catch a missing kill"; fi
        pkill -9 -f "sleep ${MARK}" 2>/dev/null
    fi
fi
echo; echo "== ${PASS} pass / ${FAIL} fail =="; [ "$FAIL" -eq 0 ]
