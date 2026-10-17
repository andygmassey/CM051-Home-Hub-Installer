#!/usr/bin/env bash
# followup_keys_match_chat_threads -- can "mark a reminder done when the owner
# follows up" (ostler-assistant #509) ever fire on this box?
#
# The daemon completes a pushed reminder when the owner messages the
# reminder's own thread, matching CM048's thread_key (CM051 #2802) against the
# same hash of each chat.db chat's handles. If the keys were built from
# display names instead of handles, nothing ever matches and the feature is
# silently dead. The daemon (which has Full Disk Access) measures the match
# every tick and publishes counts in GET /api/status -> followup; this probe
# reads that over loopback. Counts only leave the box: no key, handle or name.
#
# Never seeds. A seed would mean sending an iMessage from the owner's account
# or writing into the owner's chat.db, and both are forbidden. The ADVISORY
# line is real activity only.
#
# WALK_READ_ONLY: one authenticated GET of the daemon's /api/status and a plain open() of the chat.db header (never sqlite, so no -wal or -shm is created); writes nothing on the box beyond its own staged script under /tmp, which it removes
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="followup_keys_match_chat_threads"
PROBE_QUESTION="do the reminders map's CM048 thread keys match chat.db threads, so a reminder can be completed when the owner follows up (and is the daemon able to read chat.db at all)?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_LIB="${_HERE}/lib/followup_keys_probe.py"

# ONE decision, shared by run_probe and self_test: judge a capture file.
decide() {
    local cap="$1" out rc n
    out="$(python3 "${_LIB}" judge "${cap}")"; rc=$?
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT|ADVISORY|note) ')"
    probe_examined "${n}" "follow-up census lines"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed nothing; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "the daemon reads chat.db and at least one reminder thread key matches a chat (see the denominator above)" ;;
        78) probe_cannot_run "the follow-up census could not be measured (see the CANNOT line above)" ;;
        *)  probe_fail "see the FAIL line above" ;;
    esac
}

self_test() {
    python3 "${_LIB}" --self-test >/dev/null || {
        probe_examined 13 "judge cases"
        probe_pass "SELF-TEST BROKEN: the judge put a known case on the wrong verdict"
    }
    # Known-bad capture through the SAME decide() run_probe uses: five keyed
    # rows, none matching (the display-name case). Must come back FAIL.
    local cap
    cap="$(mktemp)"
    printf '%s\n' '{"available": true, "measured": true, "enabled": true, "chat_db_readable": true, "keyed_rows": 5, "keys_matching_one_to_one": 0, "keys_matching_group": 0, "completed_by_followup": 0, "reopened": 0}' > "${cap}"
    ( decide "${cap}" ) >/dev/null; local rc=$?
    rm -f "${cap}"
    probe_examined 1 "known-bad capture"
    [ "${rc}" -eq 1 ] && probe_fail "negative control behaved: five keyed rows with no chat match was FAIL, and every judge case landed on its own verdict"
    probe_pass "SELF-TEST BROKEN: the known-bad capture came back rc=${rc}, not FAIL"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was read"
    local remote cap
    remote="/tmp/ostler-probe-followup-$$.py"
    box_run "printf %s '$(base64 < "${_LIB}" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the follow-up census reader on the box"
    cap="$(mktemp)"
    box_run "/usr/bin/python3 ${remote} box; rm -f ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side reader returned no capture"; }
    trap 'rm -f "${cap}"' EXIT
    decide "${cap}"
}

probe_main "$@"
