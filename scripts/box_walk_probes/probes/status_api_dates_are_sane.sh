#!/usr/bin/env bash
# status_api_dates_are_sane -- no date field the customer status API serves parses past now + 10 years
# (BLOCKING.) CM051 #966: the status API served a year-2318 sentinel as a date. No probe read any date field.
#
# GETs the two customer-facing status endpoints on the box's Doctor, /api/v1/sources and /doctor/api/status,
# through box_run (the BOX's loopback), and walks every date field (ISO strings; numbers under *_at, *_ts,
# timestamp, epoch, expires, until, deadline). FAIL: any date past now + 10 years, naming the field.
# CANNOT-RUN: an endpoint that is not 200 JSON, or one that served no date field (a blind zero).
# Negative control: --self-test judges bodies carrying a year-2318 string, date-only, epoch seconds and
# epoch millis sentinel, each of which must FAIL.
#
# WALK_READ_ONLY: two GETs.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="status_api_dates_are_sane"
PROBE_QUESTION="does any date field the customer status API serves (/api/v1/sources, /doctor/api/status) parse past now + 10 years?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_LIB="${_HERE}/lib/status_dates.py"
DOCTOR_URL="${OSTLER_DOCTOR_URL:-http://127.0.0.1:8089}"

self_test() {
    if python3 -I "${_LIB}" --self-test >/dev/null; then
        probe_examined 17 "judge cases (year-2318 sentinel as string, date, epoch s, epoch ms, nested; blind controls)"
        probe_fail "negative control behaved: a year-2318 sentinel in every date shape was FAIL and a 404, non-JSON or date-less body was CANNOT-RUN"
    fi
    probe_examined 17 "judge cases"
    probe_pass "SELF-TEST BROKEN: the status-date judge put a known case on the wrong verdict"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; the status API was not read"
    local d f1 f2 out rc n
    d="$(mktemp -d)"; f1="${d}/sources"; f2="${d}/status"
    box_run "curl -s --noproxy '*' --max-time 8 -w '\n%{http_code}' '${DOCTOR_URL}/api/v1/sources'" > "${f1}"
    box_run "curl -s --noproxy '*' --max-time 8 -w '\n%{http_code}' '${DOCTOR_URL}/doctor/api/status'" > "${f2}"
    out="$(python3 -I "${_LIB}" judge "/api/v1/sources=${f1}" "/doctor/api/status=${f2}")"; rc=$?
    rm -rf "${d}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "status endpoints"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "no date field on /api/v1/sources or /doctor/api/status is past now + 10 years" ;;
        78) probe_cannot_run "a status endpoint could not be read as dated JSON (see the CANNOT line above)" ;;
        *)  probe_fail "a status date is past now + 10 years (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
