#!/usr/bin/env bash
# probes/vm_size_survives_daemon_restart.sh
# ============================================================================
# QUESTION: after the daemon restarts colima, is the container VM still the
#           size the installer chose -- or has the restart shrunk it?
#
# THE DEFECT (measured 2026-11-14, Mini16): the installer sized the VM 3 CPU /
# 6 GiB and recorded it in ~/.ostler/state/vm_size, but the daemon's restart
# path ran a hard-coded `colima start --cpu 2 --memory 4`. Every daemon restart
# that had to start colima silently shrank the VM the customer was given.
#
# THE FIX IS TWO PRS: CM051 #3516 writes the record and persists colima.yaml;
# oa #689 makes the daemon start only the recorded size (no constant). This
# probe is the customer-side proof: it FORCES the restart path and reads back
# what colima actually runs, which is the only thing a customer can feel.
#
# WHAT IT DOES (mutating, on the walked box only, by design):
#   1. reads the installer's record (the expected size)
#   2. `colima stop`, then kickstarts the daemon, so ensure_colima_running
#      has to start colima through the code path under test
#   3. waits for the default VM to report Running (bounded)
#   4. reads the VM's cpus and memory back from `colima list --json`
#
# VERDICTS
#   PASS                   measured cpus and memory equal the record
#   FAIL-SHRUNK            measured is smaller than the record (the defect)
#   FAIL-DIFFERS           measured differs from the record, not smaller
#   CANNOT-RUN-NO-RECORD   no installer record: nothing to compare against
#   CANNOT-RUN-NOT-RUNNING colima did not come back within the wait
#   CANNOT-RUN-UNREADABLE  colima list gave no readable cpus/memory
#
# RED ON v1.0.132 is the expected result for a box that has the bug. That run
# needs a box slot; it has NOT been measured by the author of this probe.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="vm_size_survives_daemon_restart"
PROBE_QUESTION="after the daemon restarts colima, does the container VM still have the size the installer chose, or has the restart shrunk it?"

DAEMON_LABEL="${OSTLER_DAEMON_LABEL:-com.creativemachines.ostler.assistant}"
VM_WAIT_S="${OSTLER_VM_WAIT_S:-300}"

# _vm_size_classify <rec_cpus> <rec_mem_gib> <status> <cpus> <mem_gib>
# THE ONE DECISION FUNCTION. run_probe and self_test both call it, so a change
# to the logic breaks both in the same edit.
_vm_size_classify() {
    local rec_c="$1" rec_m="$2" status="$3" c="$4" m="$5"
    if [ -z "$rec_c" ] || [ -z "$rec_m" ]; then
        echo CANNOT-RUN-NO-RECORD
        return
    fi
    if [ "$status" != "Running" ]; then
        echo CANNOT-RUN-NOT-RUNNING
        return
    fi
    case "$c$m" in
        ''|*[!0-9]*) echo CANNOT-RUN-UNREADABLE; return ;;
    esac
    if [ "$c" -eq "$rec_c" ] && [ "$m" -eq "$rec_m" ]; then
        echo PASS
        return
    fi
    if [ "$c" -lt "$rec_c" ] || [ "$m" -lt "$rec_m" ]; then
        echo FAIL-SHRUNK
        return
    fi
    echo FAIL-DIFFERS
}

read_record() {
    # Prints "CPUS MEM_GIB" from the installer's record, or nothing.
    box_run "awk -F= '/^cpus=/{c=\$2} /^memory_gib=/{m=\$2} END{ if (c != \"\" && m != \"\") print c, m }' \"\$HOME/.ostler/state/vm_size\" 2>/dev/null"
}

force_restart_and_measure() {
    # Stops colima, kickstarts the daemon, then waits for the default VM and
    # prints "STATUS CPUS MEM_GIB". Bounded by VM_WAIT_S. Prints the last
    # reading it saw, so a VM that never came up is named, not hidden.
    box_run "colima stop >/dev/null 2>&1; launchctl kickstart -k \"gui/\$(id -u)/${DAEMON_LABEL}\" >/dev/null 2>&1; \
i=0; last=''; while [ \$i -lt $((VM_WAIT_S / 5)) ]; do \
last=\$(colima list --json 2>/dev/null </dev/null | python3 -c 'import json,sys
row=\"\"
for l in sys.stdin:
    try: d=json.loads(l)
    except Exception: continue
    if d.get(\"name\")==\"default\":
        m=int(d.get(\"memory\",0)); row=\"%s %s %s\" % (d.get(\"status\",\"\"), d.get(\"cpus\",\"\"), (m + 536870912) // 1073741824)
print(row)' 2>/dev/null); \
case \"\$last\" in Running*) break ;; esac; i=\$((i+1)); sleep 5; done; echo \"\${last:-NONE}\""
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; nothing inspected"
    fi

    local rec rec_c rec_m reading status cpus mem verdict
    rec="$(read_record)"
    rec_c="${rec%% *}"
    rec_m="${rec##* }"
    [ -n "$rec" ] || { rec_c=""; rec_m=""; }
    probe_note "installer record ~/.ostler/state/vm_size : ${rec:-<none>}"

    if [ -z "$rec" ]; then
        probe_examined 1 "installer size record (no VM was restarted: nothing to compare against)"
        probe_cannot_run "no installer size record at ~/.ostler/state/vm_size, so there is no chosen size to compare the VM against. A VM without an Ostler record is not one this probe can judge."
    fi

    reading="$(force_restart_and_measure)"
    probe_note "after forced colima stop + daemon kickstart : ${reading}"
    # shellcheck disable=SC2086
    set -- $reading
    status="${1:-NONE}"; cpus="${2:-}"; mem="${3:-}"
    [ "$status" = "NONE" ] && status=""

    probe_examined 2 "signals: the installer record and the default VM's cpus and memory after a forced colima start"

    verdict="$(_vm_size_classify "$rec_c" "$rec_m" "$status" "$cpus" "$mem")"
    case "$verdict" in
        PASS)
            probe_pass "the VM after a forced daemon restart is ${cpus} CPU / ${mem} GiB, the size the installer recorded" ;;
        FAIL-SHRUNK)
            probe_fail "the daemon restart SHRANK the VM: the installer chose ${rec_c} CPU / ${rec_m} GiB and colima now runs ${cpus} CPU / ${mem} GiB. Every restart that has to start colima does this to the customer's VM." ;;
        FAIL-DIFFERS)
            probe_fail "the VM after a forced daemon restart is ${cpus} CPU / ${mem} GiB, not the installer's recorded ${rec_c} CPU / ${rec_m} GiB." ;;
        CANNOT-RUN-NOT-RUNNING)
            probe_cannot_run "colima did not report Running within ${VM_WAIT_S}s of a forced restart (last reading: ${reading}). The restart path never reached a VM, so no size was measured." ;;
        *)
            probe_cannot_run "colima list gave no readable cpus and memory for the default VM (reading: ${reading}). No size was measured." ;;
    esac
}

self_test() {
    # NEGATIVE CONTROL on the adjudication. The live restart needs a box, so the
    # control drives _vm_size_classify with readings known to be right or wrong.
    PROBE_SELF_TEST=1
    probe_examined 6 "synthetic reading sets (negative control)"

    # 1. Sizes equal -> PASS. Anything else and the probe reds a healthy VM.
    if [ "$(_vm_size_classify 3 6 Running 3 6)" != "PASS" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: an unchanged 3 CPU / 6 GiB VM adjudicated as $(_vm_size_classify 3 6 Running 3 6), not PASS."
    fi

    # 2. The v1.0.132 shape: recorded 3/6, restart left it at colima's 2/4 -> FAIL-SHRUNK.
    if [ "$(_vm_size_classify 3 6 Running 2 4)" != "FAIL-SHRUNK" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a VM shrunk from 3/6 to 2/4 adjudicated as $(_vm_size_classify 3 6 Running 2 4), not FAIL-SHRUNK. The probe cannot see the defect it exists for."
    fi

    # 3. Larger than recorded is still a mismatch, not a PASS.
    if [ "$(_vm_size_classify 3 6 Running 5 10)" != "FAIL-DIFFERS" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a 5/10 VM against a 3/6 record adjudicated as $(_vm_size_classify 3 6 Running 5 10), not FAIL-DIFFERS."
    fi

    # 4. A VM that did not come back is CANNOT-RUN, never PASS or FAIL.
    if [ "$(_vm_size_classify 3 6 Stopped 3 6)" != "CANNOT-RUN-NOT-RUNNING" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a stopped VM adjudicated as $(_vm_size_classify 3 6 Stopped 3 6), not CANNOT-RUN-NOT-RUNNING."
    fi

    # 5. No record -> CANNOT-RUN-NO-RECORD, whatever colima says.
    if [ "$(_vm_size_classify "" "" Running 2 4)" != "CANNOT-RUN-NO-RECORD" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: no record adjudicated as $(_vm_size_classify "" "" Running 2 4), not CANNOT-RUN-NO-RECORD. A VM with no chosen size must not be compared to a guess."
    fi

    # 6. Unreadable measurement -> CANNOT-RUN-UNREADABLE, never a size.
    if [ "$(_vm_size_classify 3 6 Running "" "")" != "CANNOT-RUN-UNREADABLE" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: an empty measurement adjudicated as $(_vm_size_classify 3 6 Running "" ""), not CANNOT-RUN-UNREADABLE."
    fi

    probe_fail "negative control behaved correctly on all 6 reading sets (equal passes; a shrink, a mismatch, a stopped VM, a missing record and an unreadable measurement each get their own verdict)."
}

probe_main "$@"
