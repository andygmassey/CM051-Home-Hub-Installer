#!/usr/bin/env bash
# morning_brief_catches_me_up -- v1.0.108 wow moment (launch/WOW_MOMENTS_GATE.md).
#
# The box-side half (lib/wow_moments.py morning-box) talks to the installed Hub
# and daemon over loopback only, grades the customer-visible text ON the box,
# and returns counts and yes/no answers: no names, facts or answer prose leave
# the box. The judge (lib/wow_moments.py judge-morning) turns them into a verdict.
#
# CANNOT-RUN, never PASS, when a prerequisite is missing (no token, no brief
# channel configured, the seed not served back by the Hub, the job not run in
# time). --self-test drives the judge over known-bad captures: each must FAIL.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="morning_brief_catches_me_up"
PROBE_QUESTION="run the installed morning-brief job (an undelivered copy) with a synthetic owner promise and a synthetic promise someone else owes: does the brief name the owner's promise, not the other one, the people waiting on a reply and today's meetings, and does the shipped prompt cover today?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/wow_moments.py" --self-test; then
        probe_examined 6 "mutated captures"
        probe_fail "negative control behaved: every known-bad capture went red by its own assertion"
    fi
    probe_examined 6 "mutated captures"
    probe_pass "SELF-TEST BROKEN: the judge let a known-bad capture through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was asked"
    local remote cap rc out n
    remote="/tmp/ostler-probe-wow-$$"
    box_run "mkdir -p ${remote}" >/dev/null 2>&1 || probe_cannot_run "could not make a staging directory on the box"
    box_run "printf %s '$(base64 < "${_HERE}/lib/wow_moments.py" | tr -d '\n')' | base64 -d > ${remote}/wow_moments.py" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage wow_moments.py on the box"
    cap="$(mktemp)"
    # The Hub venv's python has tomllib; /usr/bin/python3 is the fallback.
    box_run "PY=\$HOME/.ostler/.venv/bin/python3; [ -x \$PY ] || PY=python3; \$PY ${remote}/wow_moments.py morning-box; rm -rf ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side half returned no capture"; }
    out="$(python3 "${_HERE}/lib/wow_moments.py" judge-morning "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "assertions"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "every assertion held" ;;
        78) probe_cannot_run "a prerequisite was missing (see the CANNOT line above)" ;;
        *)  probe_fail "see the FAIL lines above" ;;
    esac
}

probe_main "$@"
