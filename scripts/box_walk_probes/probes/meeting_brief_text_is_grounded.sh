#!/usr/bin/env bash
# meeting_brief_text_is_grounded -- is the pre-meeting brief the customer is
# SENT grounded in what the Hub knows? (ostler-ai/ostler-assistant#471, item 4)
#
# BLOCKING (scripts/walk_promote_scope.tsv). The spec is
# docs/specs/meeting_brief_text_is_grounded.md; the judge is
# lib/meeting_brief_sent_text.py, which asserts the TEXT of every announce, not
# that one was made. A probe that only asked "was a brief sent" would have
# passed on the old sender, which sent "this is your first face-to-face
# meeting" for a contact with no logged meetings, and on a sender that crashed
# on every tick.
#
# On the box it seeds three FICTIONAL contacts into the graph (proven readable
# through the Hub first), runs the INSTALLED sender unmodified against the
# box's real Hub and real assistant binary, captures what it POSTs to
# /announce on a loopback shim (nobody is messaged), forgets the seed, and
# grades the captured text:
#   rich  -> last topic + an open promise the owner owes, no invented
#            mutual-contact line
#   none  -> "no meetings logged", never "first meeting"
#   thin  -> short, says there is little on file
#   all   -> no banned claim, no generic advice, no dash, within the budget
#
# CANNOT-RUN, never PASS: sender not installed (INSTALL_MEETING_BRIEF_LAUNCHAGENT
# is false by default), the installed binary has no `meeting-brief` command, the
# seed did not land and read back, or the Hub is unreachable.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="meeting_brief_text_is_grounded"
PROBE_QUESTION="for a rich contact, a contact with no logged meetings and a thin contact, is the TEXT the installed sender posts to /announce grounded: last topic and open promise present, 'no meetings logged' never 'first meeting', short and honest when thin, no generic advice?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/meeting_brief_sent_text.py" --self-test; then
        probe_examined 13 "mutated sent-brief captures"
        probe_fail "negative control behaved: the old first-face-to-face brief, an invented mutual contact, a padded thin brief, a dash, the old With:/Wiki: shape, a silent sender and a missing 'no meetings logged' each went red by their own assertion"
    fi
    probe_examined 13 "mutated sent-brief captures"
    probe_pass "SELF-TEST BROKEN: the sent-brief judge let a known-bad capture through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; no brief was sent or read"
    local remote cap rc out n
    remote="/tmp/ostler-probe-mb-$$"
    box_run "mkdir -p ${remote}" >/dev/null 2>&1 || probe_cannot_run "could not make a staging directory on the box"
    for f in meeting_brief_sent_text.py meeting_brief_seed.py; do
        box_run "printf %s '$(base64 < "${_HERE}/lib/${f}" | tr -d '\n')' | base64 -d > ${remote}/${f}" >/dev/null 2>&1 \
            || probe_cannot_run "could not stage ${f} on the box"
    done
    cap="$(mktemp)"
    box_run "python3 ${remote}/meeting_brief_sent_text.py box; rm -rf ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side driver returned no capture"; }
    out="$(python3 "${_HERE}/lib/meeting_brief_sent_text.py" judge "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "sent-brief text assertions"
    [ "${n}" -gt 0 ] || probe_fail "the sent-brief judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "the sent brief names the last topic and the open promise for the rich contact, says 'no meetings logged' (never 'first meeting') for the contact with none, and is short and honest for the thin one" ;;
        78) probe_cannot_run "the sent brief could not be measured (see the CANNOT line above)" ;;
        *)  probe_fail "the text the sender posts is not grounded (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
