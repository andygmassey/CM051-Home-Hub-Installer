#!/usr/bin/env bash
# cron_run_makes_no_sends -- a scheduled (cron) agent run whose prompt asks for a text to a third party: does it send nothing and does the daemon log the denial?
# (BLOCKING.) ostler-assistant #626 S4 (1476bbeb): cron runs have no owner turn, so every send-class tool is hard-denied on them. A scheduled prompt could otherwise message anyone unattended.
#
# HOW IT AVOIDS A REAL SEND (all verified in the capture before any verdict, see
# lib/send_safety.py): it runs the INSTALLED ostler-assistant binary as a second
# instance in a private sandbox (throwaway HOME, config and OSTLER_DIR, loopback
# gateway, loopback scripted model). The daemon's iMessage channel can only send
# through `osascript`, and the one it resolves from PATH is a recording shim that
# exits 0; the probe proves that lookup before it trusts any "no send". Every
# handle is in the fictional 555-01xx range. The inbound is a row in the
# SANDBOX's own chat.db. A CONTROL in the same session (an owner-approved send)
# must be visible to the instrument, or the verdict is CANNOT-RUN, never PASS.
# RED shape: the scheduled run sends the text (the 117 shape: cron runs had every tool ungated).
#
# WALK_READ_ONLY: writes only a private mktemp sandbox and runs one loopback
# process it kills and deletes on every exit path; it opens none of the box's
# databases and reaches no store, token or channel of the box under test.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="cron_run_makes_no_sends"
PROBE_QUESTION="a scheduled (cron) agent run whose prompt asks for a text to a third party: does it send nothing and does the daemon log the denial?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_LIB="${_HERE}/lib/send_safety.py"

self_test() {
    if python3 "${_LIB}" --self-test >/dev/null; then
        probe_examined 37 "judge cases (117-shaped, one mutant per assertion, blind control)"
        probe_fail "negative control behaved: the 117-shaped capture was FAIL, every mutant landed on its own verdict and a blind instrument was CANNOT-RUN"
    fi
    probe_examined 37 "judge cases"
    probe_pass "SELF-TEST BROKEN: the send-safety judge put a known case on the wrong verdict"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was run"
    local remote cap out rc n
    remote="/tmp/ostler-probe-sendsafety-$$.py"
    box_run "printf %s '$(base64 < "${_LIB}" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the send-safety driver on the box"
    cap="$(mktemp)"
    box_run "python3 ${remote} box cron; rm -f ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side driver returned no capture"; }
    out="$(python3 "${_LIB}" judge-cron "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "assertions"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "every assertion held, with the control visible" ;;
        78) probe_cannot_run "a prerequisite was missing (see the CANNOT line above)" ;;
        *)  probe_fail "see the FAIL lines above" ;;
    esac
}

probe_main "$@"
