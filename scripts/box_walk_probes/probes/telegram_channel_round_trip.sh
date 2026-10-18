#!/usr/bin/env bash
# telegram_channel_round_trip -- does the INSTALLED assistant answer its owner on
# Telegram, and nobody else? (public-launch Telegram)
#
# The shipped daemon is driven against a fake Telegram Bot API and a stub model
# on loopback, in a throwaway HOME, with the token read from a 0600 secrets
# file, so no real Telegram account, token or customer state is touched:
#   (a) a message queued before the daemon starts gets no reply
#   (b) the owner's private message gets exactly one reply, and the seen
#       reaction is 👀 (never a random pick, never 👍)
#   (c) a stranger's message gets no reply, reaction or typing indicator
#   (d) the owner writing in a GROUP gets no reply there
#   (e) the daemon's status file (the Doctor tile's source) says connected and
#       counts 2 ignored messages
# Judged by lib/telegram_channel_probe.py. A channel that never connects is
# CANNOT-RUN, never a quiet pass.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="telegram_channel_round_trip"
PROBE_QUESTION="against a fake Telegram Bot API, does the installed assistant answer its owner once with a 👀 seen reaction, and ignore and count a stranger and a group message?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON_BIN="${OSTLER_DAEMON_BIN:-\$HOME/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant}"

self_test() {
    # Known-bad fixtures: every mutant of the facts must go red by its own
    # assertion. The helper exits 1 when they all did.
    local out rc
    out="$(nice -n 19 python3 "${_HERE}/lib/telegram_channel_probe.py" --self-test 2>&1)"; rc=$?
    printf '%s\n' "${out}"
    probe_examined 14 "mutated telegram-channel fact sets"
    if [ "${rc}" -eq 1 ]; then
        probe_fail "negative control behaved: a mutant that answered a stranger, a group or a queued message, picked a non-👀 reaction, or lost the drop count, each went red by its own assertion"
    fi
    probe_pass "SELF-TEST BROKEN: the telegram judge let a known-bad fixture through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; the telegram channel was never driven"
    local remote facts rc n out
    remote="/tmp/ostler-probe-telegram-channel-$$.py"
    box_run "printf %s '$(base64 < "${_HERE}/lib/telegram_channel_probe.py" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the telegram loopback driver on the box"
    box_run "test -x ${DAEMON_BIN}" >/dev/null 2>&1 \
        || { box_run "rm -f ${remote}" >/dev/null 2>&1; probe_cannot_run "the installed daemon binary is not executable at ${DAEMON_BIN}"; }
    facts="$(mktemp)"
    # Capped: the driver bounds itself (~3 min worst case); the outer cap is a
    # backstop so a wedged daemon cannot hold the walk.
    box_run "nice -n 19 python3 ${remote} run --daemon ${DAEMON_BIN} ; rm -f ${remote}" > "${facts}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${facts}" 2>/dev/null \
        || { rm -f "${facts}"; probe_cannot_run "the box-side driver returned no facts"; }
    out="$(python3 "${_HERE}/lib/telegram_channel_probe.py" judge "${facts}")"; rc=$?
    rm -f "${facts}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^(PASS|FAIL|CANNOT-RUN)')"
    probe_examined "${n}" "telegram-channel assertions"
    [ "${n}" -gt 0 ] || probe_fail "the telegram judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "the installed assistant answered its owner once on Telegram with a 👀 seen reaction, and ignored and counted a stranger and a group message" ;;
        78) probe_cannot_run "the telegram channel could not be measured (see the CANNOT-RUN line above)" ;;
        *)  probe_fail "the telegram channel misbehaved (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
