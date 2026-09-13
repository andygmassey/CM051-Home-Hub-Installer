#!/bin/bash
# A holder that burns NO cpu is hung, not busy, and must be stopped even when
# nobody is waiting for the slot.
#
# WHY: the max-hold watchdog arms only when another feed is ENROLLED AND
# WAITING. That is deliberate -- a multi-hour backfill on an idle box must not
# be disturbed. But it made the bound unreachable in the case that actually
# hurt. MEASURED 2026-09-13 on a walked box: email-bundle/tick.sh held the
# shared Ollama slot for 8h49m with a ZERO-BYTE log, while the feeds that
# wanted the slot enrolled, died, and were reaped -- so "waiters present" was
# false on almost every poll and the watchdog never armed. A holder whose
# victims keep dying is protected BY starving them.
#
# CUMULATIVE CPU IS THE DISCRIMINATOR, never elapsed time. Elapsed says only
# that a process still exists. The negative control below is the whole point:
# a payload genuinely working must NOT be stopped, however long it runs.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
LIB="lib/ostler-ingest-slot.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB missing"; exit 1; }
fails=0

run_case() {
    local label="$1" payload="$2" want="$3"
    local ws; ws="$(mktemp -d)" || return 1
    cat > "$ws/probe.sh" <<PROBE
export OSTLER_STATE_DIR="$ws"
export OSTLER_SLOT_STALL_SECS=6
export OSTLER_SLOT_POLL_SECS=1
export OSTLER_SLOT_MAX_HOLD_SECS=3600
. "$PWD/$LIB"
ostler_slot_acquire "holder" >/dev/null 2>&1 || exit 9
$payload &
work=\$!
_ostler_slot_watchdog "\$work" >"$ws/wd.log" 2>&1 &
wd=\$!
sleep 12
if kill -0 "\$work" 2>/dev/null; then echo ALIVE; else echo STOPPED; fi
kill "\$work" "\$wd" 2>/dev/null
PROBE
    local got; got="$(bash "$ws/probe.sh" 2>/dev/null | tail -1)"
    if [ "$got" = "$want" ]; then echo "  ok   $label (got $got)"
    else echo "  FAIL $label: expected $want, got ${got:-nothing}"; fails=$((fails+1)); fi
    rm -rf "$ws"
}

# Burns no cpu at all. Nobody is waiting. It must still be stopped.
run_case "a payload burning zero cpu is stopped, with no waiter present" \
         'sleep 3600' STOPPED

# NEGATIVE CONTROL: busy payload, same duration, must survive.
run_case "NEGATIVE CONTROL: a payload actually burning cpu is left alone" \
         'while :; do :; done' ALIVE

# 🔴 THE CONTROL THAT BLOCKED THE FIRST VERSION OF THIS FIX, and the reason it
# measures a TREE. ostler_slot_run backgrounds the pipeline, which does its real
# work by shelling out (subprocess.run with capture_output). The PARENT then
# blocks on a pipe read and burns no cpu while the CHILD works. Reading the
# parent alone, that is indistinguishable from a hang, so the first version
# would have killed healthy ingest on a customer box on every tick.
run_case "NEGATIVE CONTROL: a parent idle on a pipe while its CHILD works is left alone" \
         'bash -c "(while :; do :; done) | cat >/dev/null"' ALIVE

echo
[ "$fails" = "0" ] && { echo "All cases passed."; exit 0; }
echo "$fails case(s) failed."; exit 1
