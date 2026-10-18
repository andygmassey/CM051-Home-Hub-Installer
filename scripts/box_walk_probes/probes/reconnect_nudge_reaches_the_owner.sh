#!/usr/bin/env bash
# reconnect_nudge_reaches_the_owner -- does the weekly "people to get back in
# touch with" nudge actually reach the owner? (wow gate item 3, v1.0.108)
#
# ADVISORY until it has run once on a box (scripts/walk_promote_scope.tsv): a
# blocking probe that has never executed against a real install can only refuse
# a promote for its own defects. Promote to blocking once a walk record shows it
# completing on a box.
#
# The spec is lib/reconnect_nudge_probe.py's header. On the box it runs the
# INSTALLED sender unmodified, twice, against a SYNTHETIC chat.db, a loopback
# stub Hub and a loopback /announce shim (nobody is messaged; the real chat.db
# and the real nudge state are never touched), and grades what was posted:
#   run 1 -> exactly one reconnect_nudge on a brief channel, naming the
#            synthetic drifted contact, with a draft, saying nothing was sent
#   run 2 -> nothing (the delivery was recorded: weekly budget and repeat guard)
# It first checks the three halves exist together: the sender, its LaunchAgent
# and the installed assistant's `reconnect-nudge` command.
#
# CANNOT-RUN, never PASS: the box is not on Ostler Pro (the nudge is correctly
# paused), or the real Hub's People-list screen cannot be read.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="reconnect_nudge_reaches_the_owner"
PROBE_QUESTION="does the installed weekly reconnect nudge deliver one grounded, drafted nudge on the owner's brief channel, record it, and stay quiet on the second run?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/reconnect_nudge_probe.py" --self-test; then
        probe_examined 15 "mutated nudge captures"
        probe_fail "negative control behaved: a missing sender, plist or daemon command, no post, the wrong kind, an unnamed contact, no draft, no 'nothing was sent', a dash, a failed first run, a repost, nothing recorded and a degraded Hub screen each FAIL; a box off Pro and an unreadable Hub screen are CANNOT-RUN"
    fi
    probe_examined 15 "mutated nudge captures"
    probe_pass "SELF-TEST BROKEN: the nudge judge let a known-bad capture through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; no nudge was composed or read"
    local remote cap rc out n
    remote="/tmp/ostler-probe-rn-$$"
    box_run "mkdir -p ${remote}" >/dev/null 2>&1 || probe_cannot_run "could not make a staging directory on the box"
    box_run "printf %s '$(base64 < "${_HERE}/lib/reconnect_nudge_probe.py" | tr -d '\n')' | base64 -d > ${remote}/reconnect_nudge_probe.py" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the driver on the box"
    cap="$(mktemp)"
    box_run "python3 ${remote}/reconnect_nudge_probe.py box; rm -rf ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side driver returned no capture"; }
    out="$(python3 "${_HERE}/lib/reconnect_nudge_probe.py" judge "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "nudge delivery assertions"
    [ "${n}" -gt 0 ] || probe_fail "the nudge judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "the installed weekly nudge delivered one grounded, drafted nudge on the brief channel, recorded it, and stayed quiet on the second run" ;;
        78) probe_cannot_run "the nudge could not be measured (see the CANNOT line above)" ;;
        *)  probe_fail "the weekly nudge does not reach the owner (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
