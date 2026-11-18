#!/bin/sh
# scripts/box_walk_probes/probes/derived_themes_still_learning.sh
# ============================================================================
# READ-ONLY. With no levelled records, GET /api/v1/preferences/derived must
# answer 200 with an empty items list and a "Still learning" state, never an
# error. Reached through the Doctor (:8089), the path the app and browser use.
#
# If the box DOES serve derived items, the no-levelled-records state is not what
# this box shows, and the verdict is CANNOT-RUN, not PASS.
# Defect it exists for: PWG #543, CB135-DERIVED-THEMES-EMPTY. The unit test
# tests/test_derived_still_learning_surface.py covers the server in isolation;
# this is the same answer read off the box.
# ============================================================================
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/walk134_common.sh"

PROBE_NAME="derived_themes_still_learning"
PROBE_QUESTION="with no levelled records, does GET /api/v1/preferences/derived answer 200 with items [] and a Still learning state, never an error?"
PROBE_UNIT="derived responses"

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing inspected"
    _raw="$(mktemp)"
    box_run "curl -s -i --noproxy '*' --max-time 8 '${DOCTOR_URL}/api/v1/preferences/derived'" > "${_raw}"
    if [ ! -s "${_raw}" ]; then
        rm -f "${_raw}"
        probe_examined 0 "derived responses"
        probe_cannot_run "no answer from ${DOCTOR_URL}/api/v1/preferences/derived on the box: nothing measured"
    fi
    walk134_judge_and_report themes "${_raw}"
}

self_test() {
    walk134_self_judge_selftest
    _raw="$(mktemp)"
    printf 'HTTP/1.1 200 OK\nContent-Type: application/json\n\n{"items": [], "error": "store unreachable"}\n' > "${_raw}"
    walk134_self_red themes "${_raw}"
    rm -f "${_raw}"
    probe_examined 1 "known-bad derived answer (error field, empty items)"
    probe_fail "negative control: an empty derived answer that carries an error is a FAIL"
}

probe_main "$@"
