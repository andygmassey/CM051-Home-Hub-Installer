#!/usr/bin/env bash
# email_channel_round_trip -- does the INSTALLED assistant answer email, and only
# the right email, once? (v1.0.107 #10)
#
# The shipped daemon is driven against a loopback IMAP + SMTP server (stdlib
# Python, one process, no Java, no VM) and a stub model, in a throwaway HOME,
# so the customer's own mailbox, config and state are never touched:
#   (a) 5 unread messages already present at first connect get no reply
#   (b) mail from the owner's address gets exactly one reply, "Re: <subject>",
#       with In-Reply-To and References
#   (c) mail from an address that is not allowed gets none
#   (d) an Auto-Submitted message gets none
#   (e) a message whose provider says dmarc=fail (a spoofed owner) gets none
#   (f) after a restart with every old message flipped to unread, nothing old is
#       re-answered and the one new message is
# Judged by lib/email_channel_probe.py from the replies the SMTP sink actually
# received. A channel that never connects is a FAIL, never a quiet zero.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="email_channel_round_trip"
PROBE_QUESTION="against a loopback mail server, does the installed assistant answer the owner once with a threaded reply, and answer no old, unlisted, automated or spoofed mail, including after a restart?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON_BIN="${OSTLER_DAEMON_BIN:-\$HOME/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant}"

self_test() {
    # Known-bad fixtures: every mutant of the facts must go red by its own
    # assertion. The helper exits 1 when they all did.
    local out rc
    out="$(nice -n 19 python3 "${_HERE}/lib/email_channel_probe.py" --self-test 2>&1)"; rc=$?
    printf '%s\n' "${out}"
    probe_examined 12 "mutated email-channel fact sets"
    if [ "${rc}" -eq 1 ]; then
        probe_fail "negative control behaved: a mutant answered, unthreaded, unlisted, automated, spoofed or re-answered mail, each went red by its own assertion"
    fi
    probe_pass "SELF-TEST BROKEN: the email judge let a known-bad fixture through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; the email channel was never driven"
    local remote facts rc n out
    remote="/tmp/ostler-probe-email-channel-$$.py"
    box_run "printf %s '$(base64 < "${_HERE}/lib/email_channel_probe.py" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the email loopback driver on the box"
    box_run "test -x ${DAEMON_BIN}" >/dev/null 2>&1 \
        || { box_run "rm -f ${remote}" >/dev/null 2>&1; probe_cannot_run "the installed daemon binary is not executable at ${DAEMON_BIN}"; }
    facts="$(mktemp)"
    # Capped: the driver bounds itself (~4 min worst case); the outer cap is a
    # backstop so a wedged daemon cannot hold the walk.
    box_run "nice -n 19 python3 ${remote} run --daemon ${DAEMON_BIN} ; rm -f ${remote}" > "${facts}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${facts}" 2>/dev/null \
        || { rm -f "${facts}"; probe_cannot_run "the box-side driver returned no facts"; }
    out="$(python3 "${_HERE}/lib/email_channel_probe.py" judge "${facts}")"; rc=$?
    rm -f "${facts}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "email-channel assertions"
    [ "${n}" -gt 0 ] || probe_fail "the email judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "the installed assistant answered the owner once with a threaded reply and answered no old, unlisted, automated or spoofed mail, before or after a restart" ;;
        78) probe_cannot_run "an email-channel assertion could not be measured (see the CANNOT lines above)" ;;
        *)  probe_fail "the email channel misbehaved (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
