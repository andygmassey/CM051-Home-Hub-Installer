#!/usr/bin/env bash
# assistant_sends_over_whatsapp_and_email -- the assistant's outbound send
# path for WhatsApp and email. (v1.0.107, FLOW_CENSUS gaps #3 and #5:
# "NOT INSTRUMENTED by any automated walk")
#
# WHAT THIS PROBE COVERS, AND WHAT IT DOES NOT, STATED HERE SO THE VERDICT IS
# NEVER READ AS MORE THAN IT MEASURED:
#
#   COVERED: given what this box's install actually captured (read from the
#   real config.toml, never assumed), did install.sh resolve and WRITE a
#   non-empty channel + non-empty recipient for whichever channel the
#   customer enabled? That is the exact shape of the #446/CX-68 defect: a
#   WhatsApp-only customer got ZERO [[cron.jobs]] written at all. Also:
#   v1.0.107 has no "email" delivery channel in the cron/announce system at
#   all; if custom-IMAP/SMTP email is configured, its fields are confirmed
#   present in the file.
#
#   NOT COVERED, by design and said here rather than discovered later: an
#   actual dispatched send. install.sh's own comment says the assistant's
#   /announce HTTP target "does not exist yet" for v1.0; the only delivery
#   mechanism is internal to the closed-source ostler-assistant daemon, not
#   vendored in this repo. WhatsApp Web needs a human to pair a real phone
#   (no typeable pair code exists); email needs a live external mailbox. A
#   fresh walk box has neither, and manufacturing either would mean either an
#   unsafe real external credential on a public CI runner, or an impossible
#   automated pairing. So this probe asserts up to the last hop the product
#   actually controls on this box: the configured channel and recipient the
#   daemon would receive, not what it does with them.
#
# ADVISORY, not blocking: a FAIL here is a real config-correctness defect
# worth fixing, but a CANNOT-RUN here is not console-closeable either (no
# console click grants a WhatsApp Web pairing or a live mailbox), so it is
# not scored against a clean walk the way a TCC/GUI item is.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="assistant_sends_over_whatsapp_and_email"
PROBE_QUESTION="given what this box's install actually enabled, did install.sh resolve and write a non-empty outbound channel and recipient, and does v1.0.107 correctly have no email delivery channel at all? (does NOT measure an actual dispatched send -- see the file header)"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/brief_channel_probe.py" --self-test; then
        probe_examined 3 "mutated config.toml fixtures"
        probe_fail "negative control behaved: an empty WhatsApp recipient, a bogus 'email' delivery channel, and an unreadable config each caught by their own assertion"
    fi
    probe_examined 3 "mutated config.toml fixtures"
    probe_pass "SELF-TEST BROKEN: the brief-channel judge let a known-bad fixture through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; config.toml was never read"
    local remote cfg_path facts out rc n
    remote="/tmp/ostler-probe-briefchan-$$.py"
    box_run "printf %s '$(base64 < "${_HERE}/lib/brief_channel_probe.py" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the brief-channel reader on the box"
    cfg_path="$(box_run 'printf %s "${OSTLER_DIR:-$HOME/.ostler}/assistant-config/config.toml"')"
    [ -n "${cfg_path}" ] || cfg_path="\$HOME/.ostler/assistant-config/config.toml"

    facts="$(mktemp)"
    box_run "python3 ${remote} box --config '${cfg_path}'; rm -f ${remote}" > "${facts}" 2>/dev/null

    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${facts}" 2>/dev/null \
        || { rm -f "${facts}"; probe_cannot_run "the box-side reader returned no facts (config.toml missing or unreadable at ${cfg_path})"; }
    out="$(python3 "${_HERE}/lib/brief_channel_probe.py" judge "${facts}")"; rc=$?
    rm -f "${facts}"
    printf '%s\n' "${out}"
    probe_note "NOT COVERED: an actual dispatched send (SMTP delivery, WhatsApp Web dispatch) -- see this file's header."
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT|N/A) ')"
    probe_examined "${n}" "outbound-channel assertions"
    [ "${n}" -gt 0 ] || probe_fail "the brief-channel judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "every channel the customer enabled resolved a non-empty channel and recipient, and no 'email' delivery channel exists where none should" ;;
        78) probe_cannot_run "no channel was enabled on this box to measure (see the CANNOT lines above); nothing about this is a defect" ;;
        *)  probe_fail "a channel the customer enabled resolved with no recipient, or an 'email' delivery channel exists where it should not (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
