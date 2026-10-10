#!/usr/bin/env bash
# assistant_self_description_is_clean -- BLOCKING (scripts/walk_promote_scope.tsv). Scale-walk gate, v1.0.107 #17.
#
# Box side: lib/assistant_chat.py selfdesc-box asks the installed assistant over
# /ws/chat and grades ON the box; only verdicts, tool-name tokens and timings
# leave it, never the reply prose. Names and the model are read from the box's
# ~/.ostler/assistant-config/config.toml. Judge: lib/assistant_chat.py judge-selfdesc.
# CANNOT-RUN, never PASS, when the assistant cannot be asked. --self-test runs
# the judges over canned replies (leaky -> red, clean -> green, "I'm <Name>" ->
# green).
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="assistant_self_description_is_clean"
PROBE_QUESTION="asked 'What can you do?' and 'Who are you?', does the assistant answer without internal tool names (pwg_, memory_store/recall/forget, cron_, web_fetch, HTTP request) and without addressing the user by its own configured name?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/assistant_chat.py" --self-test; then
        probe_examined 10 "canned replies"
        probe_fail "negative control behaved: every leaky or vocative reply went red, clean and self-naming replies stayed green"
    fi
    probe_examined 10 "canned replies"
    probe_pass "SELF-TEST BROKEN: the judge let a known-bad reply through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was asked"
    local remote cap rc out n
    remote="/tmp/ostler-probe-chat-$$"
    box_run "mkdir -p ${remote}" >/dev/null 2>&1 || probe_cannot_run "could not make a staging directory on the box"
    box_run "printf %s '$(base64 < "${_HERE}/lib/assistant_chat.py" | tr -d '\n')' | base64 -d > ${remote}/assistant_chat.py" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage assistant_chat.py on the box"
    cap="$(mktemp)"
    box_run "python3 ${remote}/assistant_chat.py selfdesc-box; rm -rf ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side half returned no capture"; }
    out="$(python3 "${_HERE}/lib/assistant_chat.py" judge-selfdesc "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "lines"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed nothing; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "see the lines above" ;;
        78) probe_cannot_run "see the CANNOT line above" ;;
        *)  probe_fail "see the FAIL lines above" ;;
    esac
}

probe_main "$@"
