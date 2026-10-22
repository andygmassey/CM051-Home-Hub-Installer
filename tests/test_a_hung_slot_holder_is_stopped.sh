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

# 🔴 BURNERS MUST NOT OUTLIVE THIS TEST. MEASURED 2026-10-22: six orphaned
# `while :; do :; done` burners from this file pushed the Mac to load ~600.
# Three layers, because a SIGKILL cannot be trapped:
#   1. every payload runs in its OWN process group (set -m) and the probe's
#      EXIT/INT/TERM/HUP trap kills that group, so the `( loop ) | cat`
#      grandchildren die with their parent (killing only $! leaked them);
#   2. this script traps the same signals and kills the probe's group;
#   3. every burner stops itself after BURN_MAX_SECS even if orphaned.
# tests/test_hung_slot_test_leaves_no_burners.sh proves all three.
BURN_MAX_SECS=40
PROBE_PID=""
WS=""
cleanup() {
    [ -n "$PROBE_PID" ] && kill -TERM -- "-$PROBE_PID" 2>/dev/null
    [ -n "$WS" ] && rm -rf "$WS"
    return 0
}
trap cleanup EXIT
trap 'cleanup; exit 143' INT TERM HUP

run_case() {
    local label="$1" payload="$2" want="$3"
    local ws; ws="$(mktemp -d)" || return 1
    WS="$ws"
    cat > "$ws/probe.sh" <<PROBE
export OSTLER_STATE_DIR="$ws"
export OSTLER_SLOT_STALL_SECS=6
export OSTLER_SLOT_POLL_SECS=1
export OSTLER_SLOT_MAX_HOLD_SECS=3600
. "$PWD/$LIB"
set -m
work=""; wd=""
probe_cleanup() {
    [ -n "\$work" ] && kill -KILL -- "-\$work" 2>/dev/null
    [ -n "\$wd" ] && kill -KILL -- "-\$wd" 2>/dev/null
    return 0
}
trap 'probe_cleanup; exit 143' INT TERM HUP
ostler_slot_acquire "holder" >/dev/null 2>&1 || exit 9
# acquire installs its own EXIT trap (release), which would silently replace
# ours. Re-install after it, chaining the release so the slot is still freed.
trap 'probe_cleanup; ostler_slot_release' EXIT
$payload &
work=\$!
_ostler_slot_watchdog "\$work" >"$ws/wd.log" 2>&1 &
wd=\$!
sleep 12 & wait \$!   # not a foreground sleep: bash defers a trap until a foreground child exits
if kill -0 "\$work" 2>/dev/null; then echo ALIVE; else echo STOPPED; fi
PROBE
    # Own process group (set -m) so cleanup can signal the probe and all it spawned.
    set -m
    bash "$ws/probe.sh" >"$ws/out" 2>/dev/null &
    PROBE_PID=$!
    set +m
    wait "$PROBE_PID" 2>/dev/null
    PROBE_PID=""
    local got; got="$(tail -1 "$ws/out")"
    if [ "$got" = "$want" ]; then echo "  ok   $label (got $got)"
    else echo "  FAIL $label: expected $want, got ${got:-nothing}"; fails=$((fails+1)); fi
    rm -rf "$ws"; WS=""
}

# Burns no cpu at all. Nobody is waiting. It must still be stopped.
run_case "a payload burning zero cpu is stopped, with no waiter present" \
         'sleep '"$BURN_MAX_SECS" STOPPED

# NEGATIVE CONTROL: busy payload, same duration, must survive.
run_case "NEGATIVE CONTROL: a payload actually burning cpu is left alone" \
         'while [ $SECONDS -lt '"$BURN_MAX_SECS"' ]; do :; done' ALIVE

# 🔴 THE CONTROL THAT BLOCKED THE FIRST VERSION OF THIS FIX, and the reason it
# measures a TREE. ostler_slot_run backgrounds the pipeline, which does its real
# work by shelling out (subprocess.run with capture_output). The PARENT then
# blocks on a pipe read and burns no cpu while the CHILD works. Reading the
# parent alone, that is indistinguishable from a hang, so the first version
# would have killed healthy ingest on a customer box on every tick.
run_case "NEGATIVE CONTROL: a parent idle on a pipe while its CHILD works is left alone" \
         'bash -c "(while [ \$SECONDS -lt '"$BURN_MAX_SECS"' ]; do :; done) | cat >/dev/null"' ALIVE

echo
[ "$fails" = "0" ] && { echo "All cases passed."; exit 0; }
echo "$fails case(s) failed."; exit 1
