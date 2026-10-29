#!/usr/bin/env bash
# l3_not_prefetched -- is a synthetic L3 person withheld from the surface the daemon's graph prefetch reads? (#2435)
# (ADVISORY for one cut per Archie's #2435 ruling; see scripts/walk_promote_scope.tsv.) ostler-assistant #428 prefetches
# pwg_people for a question that names a person; it makes the same loopback call as the model tool, so what GET
# /api/v1/people/search returns is what gets injected. vendor/cm041/assistant_api/ical-server.py:2245-2251 drops an L3
# person there. RED shape: the seeded L3 person is returned on any of three query shapes (name, organisation, email).
# CONTROL: an L1 person seeded identically MUST be found on all three, else CANNOT-RUN (blind instrument).
# Details, and what is NOT INSTRUMENTED (Oxigraph context leg, chat-level reply, core_ memory): lib/l3_prefetch.py.
#
# WALK_WRITES: two synthetic points (reserved .example data) in the Qdrant people collection, deleted and verified
# deleted on every exit path. Reads the box's own service token and store curl config; prints neither.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="l3_not_prefetched"
PROBE_QUESTION="is a seeded synthetic L3 person withheld from people/search (the surface the daemon prefetch reads), with an L1 control found?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_LIB="${_HERE}/lib/l3_prefetch.py"

self_test() {
    local out rc
    out="$(python3 "${_LIB}" --self-test 2>&1)"; rc=$?
    printf '%s\n' "${out}"
    probe_examined 9 "judge cases (L3 leak shapes, blind control, degraded, 401, cleanup, cannot)"
    if [ "${rc}" -eq 0 ]; then
        probe_fail "negative control behaved: a capture with the L3 person returned by people/search was FAIL and every blind case was CANNOT-RUN"
    fi
    probe_pass "SELF-TEST BROKEN: the L3 judge put a known case on the wrong verdict"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was run"
    local remote cap out rc
    remote="/tmp/ostler-probe-l3prefetch-$$.py"
    box_run "printf %s '$(base64 < "${_LIB}" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the L3 driver on the box"
    cap="$(mktemp)"
    box_run "python3 ${remote} box; rm -f ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side driver returned no capture"; }
    out="$(python3 "${_LIB}" judge "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    probe_examined 6 "people/search queries (3 shapes x L3 subject and L1 control)"
    case "${rc}" in
        0)  probe_pass "the L3 person was returned on none of 3 query shapes while the L1 control was found on all 3; cleanup verified" ;;
        78) probe_cannot_run "see the CANNOT line above; nothing about L3 was measured" ;;
        *)  probe_fail "see the FAIL lines above" ;;
    esac
}

probe_main "$@"
