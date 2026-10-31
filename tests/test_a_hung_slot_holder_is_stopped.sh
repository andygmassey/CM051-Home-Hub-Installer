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

# Every process this test starts carries TAG on its command line (the probe is
# launched as `bash probe.sh TAG`, so every subshell it forks shows TAG), and
# each probe runs as its own process group (set -m), so the whole payload tree
# can be reaped by PGID. NEGATIVE-CONTROL payloads are SUPPOSED to stay alive,
# so nothing else ever stops them: without the reap they leak at 100% cpu,
# reparented to PID 1 (measured: load average past 400 on a build box).
TAG="ostler-slot-test-$$"
CASE_PGIDS=""

reap_group() {
    local pg="$1" pids
    [ -n "$pg" ] || return 0
    # Only pids whose pgid is the one WE created for this case.
    pids="$(ps -axo pid=,pgid= | awk -v g="$pg" '$2==g{print $1}')"
    [ -n "$pids" ] || return 0
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null
    sleep 1
    pids="$(ps -axo pid=,pgid= | awk -v g="$pg" '$2==g{print $1}')"
    # shellcheck disable=SC2086
    [ -z "$pids" ] || kill -9 $pids 2>/dev/null
    return 0
}

reap_all() {
    local g
    for g in $CASE_PGIDS; do reap_group "$g"; done
}
trap reap_all EXIT
trap 'reap_all; exit 130' INT
trap 'reap_all; exit 143' TERM

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
    # Own process group per case (set -m), recorded BEFORE it can leak.
    set -m
    bash "$ws/probe.sh" "$TAG" >"$ws/out.log" 2>/dev/null &
    local ppid=$!
    set +m
    CASE_PGIDS="$CASE_PGIDS $ppid"
    wait "$ppid" 2>/dev/null
    local got; got="$(tail -1 "$ws/out.log" 2>/dev/null)"
    reap_group "$ppid"
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

# SELF-CHECK: nothing tagged with this run's TAG, and nothing left in any case's
# process group, may survive. A reap that silently did nothing fails here.
reap_all
left="$(ps -axo pid=,command= | grep -F -- "$TAG" | grep -v -F 'grep -F')"
for g in $CASE_PGIDS; do
    left="$left$(ps -axo pid=,pgid=,command= | awk -v g="$g" '$2==g')"
done
if [ -n "$left" ]; then
    echo "  FAIL self-check: leaked processes survive this test:"; echo "$left"
    fails=$((fails+1))
else
    echo "  ok   self-check: 0 processes survive this test"
fi

echo
[ "$fails" = "0" ] && { echo "All cases passed."; exit 0; }
echo "$fails case(s) failed."; exit 1
