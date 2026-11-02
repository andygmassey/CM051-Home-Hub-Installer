#!/usr/bin/env bash
# chat_reminder_routes_to_home -- a chat reminder is delivered to the explicit home target, never silent and never to the first announcing job, and making it sends nothing
# (BLOCKING.) CM051 #2397 (home was "the first announcing config job", so job order decided where a reminder went)
# + #2398 (a model-sent delivery mode "none" was stored silent and fired to nobody).
#
# HOW IT AVOIDS A REAL SEND: the same sandbox as cron_run_makes_no_sends (lib/send_safety.py): the
# INSTALLED binary as a second instance under a throwaway HOME/config/OSTLER_DIR, loopback gateway,
# loopback scripted model, recording osascript shim proven before it is trusted, 555-01xx handles.
# The sandbox config has two announcing jobs that disagree (the FIRST at the wrong handle) and an
# explicit [cron] home target naming the SECOND. The scripted model calls cron_add twice from an owner
# chat turn (delivery omitted; delivery mode "none"). Read back from the sandbox gateway's /api/cron.
# The CONTROL is the daemon's own reply to the owner turn, recorded by the shim; if the shim shows none the
# verdict is CANNOT-RUN. (This daemon build offers no poll tool, so send_safety's poll-send control is gone.)
# LIVE negative control: OSTLER_REMINDER_PROBE_NEGATIVE=no-home drops the home target; the daemon then stores
# the reminder silent and this probe must FAIL against the real binary.
# RED shapes: a reminder stored mode none (#2398); a reminder on the first job's handle (#2397).
#
# WALK_READ_ONLY: writes only a private mktemp sandbox and runs one loopback process it kills and
# deletes on every exit path; it opens none of the box's databases and reaches no store, token or
# channel of the box under test.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="chat_reminder_routes_to_home"
PROBE_QUESTION="with two announcing cron jobs present and an explicit home target, does a chat reminder (delivery omitted, and delivery none) land on the home target, never silent, never on the first job, with 0 sends at creation?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_LIB="${_HERE}/lib/reminder_routing.py"

self_test() {
    if python3 -I "${_LIB}" --self-test >/dev/null; then
        probe_examined 22 "judge cases (#2398-shaped, #2397-shaped, one mutant per assertion, blind control)"
        probe_fail "negative control behaved: a none-stored-silent reminder and a first-job-routed reminder were each FAIL and a blind instrument was CANNOT-RUN"
    fi
    probe_examined 22 "judge cases"
    probe_pass "SELF-TEST BROKEN: the reminder-routing judge put a known case on the wrong verdict"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was run"
    local rdir cap out rc n
    rdir="/tmp/ostler-probe-reminder-$$"
    box_run "mkdir -p ${rdir} && printf %s '$(base64 < "${_HERE}/lib/send_safety.py" | tr -d '\n')' | base64 -d > ${rdir}/send_safety.py && printf %s '$(base64 < "${_LIB}" | tr -d '\n')' | base64 -d > ${rdir}/reminder_routing.py" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the reminder driver on the box"
    cap="$(mktemp)"
    box_run "OSTLER_REMINDER_PROBE_NEGATIVE='${OSTLER_REMINDER_PROBE_NEGATIVE:-}' python3 -I ${rdir}/reminder_routing.py box; rm -rf ${rdir}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side driver returned no capture"; }
    out="$(python3 -I "${_LIB}" judge "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "assertions"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "both chat reminders landed on the home target (none refused or rerouted), no outward send at creation, control visible" ;;
        78) probe_cannot_run "a prerequisite was missing (see the CANNOT line above)" ;;
        *)  probe_fail "see the FAIL lines above" ;;
    esac
}

probe_main "$@"
