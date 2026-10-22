#!/usr/bin/env bash
# tests/test_send_safety_probes.sh
# ============================================================================
# The three BLOCKING send-safety walk probes (ostler-assistant #626 S4 and #627
# C1), driven END TO END: the real probe scripts, the real box-side driver
# (lib/send_safety.py: sandbox, recording osascript shim, scripted loopback
# model, sandbox chat.db) and the real judge, against a STAND-IN daemon
# (tests/fixtures/send_safety/fake_ostler_assistant.py) in each of these builds:
#
#   v117               pre-#626: the send goes through. All three probes must
#                      go RED (FAIL, never CANNOT-RUN).
#   intended           #626 + #627 as merged. All three must PASS.
#   one defect each    stranger_prompted, tainted_sends, no_prompt_body,
#                      release_twice, prompt_via_model, cron_sends: only the
#                      probe that owns the defect may go red. cron_announce (the
#                      job would announce) must be CANNOT-RUN, never PASS.
#
# WHAT THE STAND-IN CANNOT PROVE, said once: that the REAL installed binary boots
# in the sandbox, logs these lines and honours these rules. That is the probe on a
# walk box, and until it has read a box its first verdict may be CANNOT-RUN naming
# the missing prerequisite. No real message is sent here: osascript is the shim.
#
# Exit 0 pass, 1 fail, 2 cannot-run. Bash 3.2.
# ============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBES="$REPO/scripts/box_walk_probes/probes"
STUB="$REPO/tests/fixtures/send_safety/fake_ostler_assistant.py"
command -v python3 >/dev/null 2>&1 && [ -f "$STUB" ] || { echo "CANNOT-RUN: python3 or the stand-in daemon is missing"; exit 2; }
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
echo "test_send_safety_probes"

N1=stranger_cannot_trigger_send
N2=tainted_owner_send_needs_exact_approval
N3=cron_run_makes_no_sends

# speed knobs only: the stand-in cron fires after 4s, the channel baseline needs 3s
export OSTLER_SENDSAFETY_DAEMON="$STUB" OSTLER_SENDSAFETY_SETTLE_S=3 OSTLER_SENDSAFETY_CRON_WAIT_S=60 OSTLER_SENDSAFETY_BOOT_S=20
unset OSTLER_BOX_HOST OSTLER_PROMOTE_SCOPE_FILE

# run <mode> <probe> -> prints the exit code
run() { OSTLER_STUB_MODE="$1" bash "$PROBES/$2.sh" >"$WORK/out.$1.$2" 2>&1; echo $?; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "--- every probe carries a self-test that behaves (exit 1, the negative control) ---"
for n in $N1 $N2 $N3; do
    bash "$PROBES/$n.sh" --self-test >"$WORK/st" 2>&1; rc=$?
    [ "$rc" -eq 1 ] && grep -q '^VERDICT: FAIL -- negative control behaved' "$WORK/st" && ok "$n self-test behaves" || bad "$n self-test rc=$rc"
done

expect() { # mode probe want
    local rc; rc="$(run "$1" "$2")"
    [ "$rc" = "$3" ] && ok "$1 / $2 -> rc $rc" || { bad "$1 / $2 -> rc $rc, wanted $3"; sed 's/^/        /' "$WORK/out.$1.$2" | tail -12; }
}

echo "--- v117-shaped daemon: all three RED (1), none CANNOT-RUN (78) ---"
for n in $N1 $N2 $N3; do expect v117 $n 1; done

echo "--- intended daemon: all three PASS ---"
for n in $N1 $N2 $N3; do expect intended $n 0; done

echo "--- one defect each: only the owning probe goes red ---"
expect stranger_prompted $N1 1; expect stranger_prompted $N2 0; expect stranger_prompted $N3 0
expect tainted_sends     $N1 0; expect tainted_sends     $N2 1; expect tainted_sends     $N3 0
expect no_prompt_body    $N2 1
expect release_twice     $N2 1
expect prompt_via_model  $N2 1
expect cron_sends        $N1 0; expect cron_sends        $N3 1
expect cron_announce     $N3 78

echo "--- no sandbox process or directory is left behind ---"
left="$(ps -axo command | grep -c '[f]ake_ostler_assistant.py daemon')"
[ "$left" -eq 0 ] && ok "no stand-in daemon still running" || bad "$left stand-in daemon(s) left running"
dirs="$(ls -d "${TMPDIR:-/tmp}"/ostler-sendsafety-* 2>/dev/null | wc -l | tr -d ' ')"
[ "$dirs" -eq 0 ] && ok "no sandbox directory left" || bad "$dirs sandbox dir(s) left"

echo "--- the verdict text names what was measured (not a bare PASS) ---"
grep -q 'VERDICT: PASS -- every assertion held, with the control visible' "$WORK/out.intended.$N1" && ok "PASS carries its reason" || bad "PASS text"
grep -q 'EXAMINED: [1-9]' "$WORK/out.intended.$N2" && ok "denominator printed and non-zero" || bad "no denominator"

echo "---"
echo "passed $pass failed $fail"
[ "$fail" -eq 0 ]
