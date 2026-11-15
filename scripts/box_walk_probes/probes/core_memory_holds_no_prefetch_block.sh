#!/usr/bin/env bash
# core_memory_holds_no_prefetch_block -- does any core_ memory on the box carry the daemon's graph-prefetch block? (#2436)
# The daemon appends "[Looked up in the user's own data before answering (...)" to the user turn; it can carry L3 and
# is never something the customer said. ostler-assistant #644 strips it inside memory consolidation. This reads every
# core entry the daemon holds (GET /api/memory?category=core, admin bearer) after the chat probes have run.
# RED shape: any core entry whose content carries the block's opening words (keys printed, never content).
# ZERO core entries is CANNOT-RUN, never PASS: nothing was consolidated, so nothing was examined.
# Runs after the assistant_* chat probes by name (C sort: "c" after "a"); consolidation is written asynchronously, so
# entries from the opening probes are on disk by then. Details and NOT INSTRUMENTED: lib/core_memory_prefetch.py.
# The core read is POLLED until an entry exists, bounded by OSTLER_CORE_MEMORY_WAIT_S (default 300, every
# OSTLER_CORE_MEMORY_POLL_S=15): a zero after the budget is CANNOT-RUN with the waited time, never PASS.
#
# READ-ONLY: writes nothing to the box beyond its own temp driver, removed on the same call. Prints no secret.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="core_memory_holds_no_prefetch_block"
PROBE_QUESTION="does any core_ memory the daemon holds carry the graph-prefetch block ([Looked up in the user's own data ...)?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_LIB="${_HERE}/lib/core_memory_prefetch.py"

self_test() {
    local out rc
    out="$(python3 "${_LIB}" --self-test 2>&1)"; rc=$?
    printf '%s\n' "${out}"
    probe_examined 12 "judge, marker and reader cases (leak, zero denominator, unreadable, ignored filter, paraphrase)"
    if [ "${rc}" -eq 0 ]; then
        probe_fail "negative control behaved: a capture with a core entry carrying the block was FAIL and every blind case was CANNOT-RUN"
    fi
    probe_pass "SELF-TEST BROKEN: the core-memory judge put a known case on the wrong verdict"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was run"
    local remote cap out rc n
    remote="/tmp/ostler-probe-coremem-$$.py"
    box_run "printf %s '$(base64 < "${_LIB}" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the core-memory driver on the box"
    cap="$(mktemp)"
    box_run "python3 ${remote} box; rm -f ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side driver returned no capture"; }
    n="$(python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print((c.get('core') or {}).get('n', 0))" "${cap}" 2>/dev/null)"
    out="$(python3 "${_LIB}" judge "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    probe_examined "${n:-0}" "core_ memory entries (GET /api/memory?category=core)"
    case "${rc}" in
        0)  probe_pass "${n} core_ memories examined, none carries the graph-prefetch block" ;;
        78) probe_cannot_run "see the CANNOT line above; no core_ memory was judged" ;;
        *)  probe_fail_or_advisory "see the FAIL line above: a core_ memory holds the daemon's own lookup text" ;;
    esac
}

probe_main "$@"
