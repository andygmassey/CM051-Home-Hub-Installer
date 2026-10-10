#!/usr/bin/env bash
# memory_correction_round_trip -- when the owner forgets or corrects a fact,
# does every surface that reads it stop saying the old thing? (v1.0.108 wow #9)
#
# iOS & Pin's seven-step design, implemented in lib/memory_correction.py:
# assert two synthetic owner facts; CONTROL that each is in all three readers
# (GET /api/v1/memory, /people/context?name=<owner>, CONTEXT.md after a
# refresh); forget one and correct the other through the owner path
# (POST /api/v1/memory/correct/<id>); then the forgotten fact must be absent
# from all three and the corrected one must show the new value and not the
# old in all three.
#
# EXPECTED RED until the CM041 person_context overlay fix is grafted: steps 5
# and 6 (and the matching step-7 rows) FAIL, because /people/context and the
# digest generator read the source triple and not the corrections overlay.
# That is a measured FAIL, not CANNOT-RUN: the control proved each reader
# could see the fact first.
#
# A WRITER. It runs the round trip only when the runner exports
# OSTLER_WALK_READ_ONLY=0; unset or 1 is CANNOT-RUN, never PASS. The facts it
# writes are synthetic, carry a per-run nonce, and are deleted from the graph
# by URI at the end. Only booleans leave the box.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="memory_correction_round_trip"
PROBE_QUESTION="after the owner forgets or corrects a fact through the owner path, do the memory list, /people/context and CONTEXT.md all stop showing the old value (and show the correction), given that all three showed the fact first?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/memory_correction.py" --self-test; then
        probe_examined 14 "fake-box round trips and graded fixtures"
        probe_fail "negative control behaved: every mutant reader that ignores a correction went red by its own row, and every blind control was CANNOT-RUN"
    fi
    probe_examined 14 "fake-box round trips and graded fixtures"
    probe_pass "SELF-TEST BROKEN: the memory-correction judge let a known-bad reader through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was written or read"
    local write remote facts rc n out
    write=0
    [ "${OSTLER_WALK_READ_ONLY:-1}" = "0" ] && write=1
    remote="/tmp/ostler-probe-memory-correction-$$.py"
    box_run "printf %s '$(base64 < "${_HERE}/lib/memory_correction.py" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the round-trip runner on the box"
    facts="$(mktemp)"
    box_run "python3 ${remote} box --write-allowed ${write}; rm -f ${remote}" > "${facts}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${facts}" 2>/dev/null \
        || { rm -f "${facts}"; probe_cannot_run "the box-side runner returned no facts"; }
    out="$(python3 "${_HERE}/lib/memory_correction.py" judge "${facts}")"; rc=$?
    rm -f "${facts}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "memory-correction assertions"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "a forgotten fact left all three readers and a corrected one shows only its new value in all three" ;;
        78) probe_cannot_run "a memory-correction assertion could not be measured (see the CANNOT lines above)" ;;
        *)  probe_fail_or_advisory "a reader still shows what the owner forgot or corrected (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
