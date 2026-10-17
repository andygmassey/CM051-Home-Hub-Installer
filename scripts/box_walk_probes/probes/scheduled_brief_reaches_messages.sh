#!/usr/bin/env bash
# scheduled_brief_reaches_messages -- did the morning brief and evening wrap
# actually arrive in Messages, or only say they did?
#
# Walk #27: cron_runs said `ok` for the 01:00Z brief and chat.db held nothing
# near it. `ok` is written for a delivered run, a run the settle grace withheld
# and (best_effort) a run whose delivery failed, so on its own it proves
# nothing. This joins each ok run to the daemon's own `delivery=` line and to
# an assistant-marked is_from_me row in chat.db inside the delivery window.
# See lib/brief_delivery_probe.py for the per-run rule.
#
# CANNOT-RUN, never PASS, when it cannot look: no jobs.db, chat.db unreadable,
# no runs in the window, a run with neither a message nor a disposition line,
# or every run withheld by design (delivery not yet shown to work).
#
# WALK_READ_ONLY: read-only sqlite opens (mode=ro) of jobs.db and chat.db and a read of ostler-assistant.err; writes nothing on the box beyond its own staged script under /tmp, which it removes. Counts only leave the box.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="scheduled_brief_reaches_messages"
PROBE_QUESTION="for every ok morning-brief / evening-wrap run in the last 7 days, is there an assistant-marked message in chat.db, or a daemon line saying it was withheld on purpose?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_LIB="${_HERE}/lib/brief_delivery_probe.py"

decide() {
    local cap="$1" out rc n
    out="$(python3 "${_LIB}" judge "${cap}")"; rc=$?
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT|note) ')"
    probe_examined "${n}" "delivery census lines"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed nothing; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "every ok brief/wrap run in the window reached chat.db or was withheld by design, and at least one reached it" ;;
        78) probe_cannot_run "brief delivery could not be observed (see the CANNOT line above)" ;;
        *)  probe_fail_or_advisory "a run the daemon logged as delivered or failed has no message in chat.db" ;;
    esac
}

self_test() {
    python3 "${_LIB}" --self-test >/dev/null || {
        probe_examined 8 "judge cases"
        probe_pass "SELF-TEST BROKEN: the judge put a known case on the wrong verdict"
    }
    # Known-bad capture through the SAME decide() run_probe uses: one run the
    # daemon logged DELIVERED, nothing in chat.db. Must come back FAIL.
    local cap
    cap="$(mktemp)"
    printf '%s\n' '{"jobs_db": "found", "chat_db_readable": true, "log_readable": true, "runs": [{"seen": 0, "disposition": "DELIVERED"}], "window_days": 7}' > "${cap}"
    ( OSTLER_PROMOTE_SCOPE_FILE=/dev/null decide "${cap}" ) >/dev/null; local rc=$?
    rm -f "${cap}"
    probe_examined 1 "known-bad capture"
    [ "${rc}" -eq 1 ] && probe_fail "negative control behaved: a DELIVERED run with no chat.db message was FAIL, and every judge case landed on its own verdict"
    probe_pass "SELF-TEST BROKEN: the known-bad capture came back rc=${rc}, not FAIL"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was read"
    local remote cap
    remote="/tmp/ostler-probe-brief-delivery-$$.py"
    box_run "printf %s '$(base64 < "${_LIB}" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the brief delivery reader on the box"
    cap="$(mktemp)"
    box_run "/usr/bin/python3 ${remote} box; rm -f ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side reader returned no capture"; }
    trap 'rm -f "${cap}"' EXIT
    decide "${cap}"
}

probe_main "$@"
