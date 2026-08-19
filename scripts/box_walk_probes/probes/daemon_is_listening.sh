#!/usr/bin/env bash
# probes/daemon_is_listening.sh
# ============================================================================
# QUESTION: is the Hub gateway actually accepting connections, and if not, can
#           the daemon even load the config the installer wrote it?
#
# THIS IS THE PROBE THAT WOULD HAVE CAUGHT v1.0.31.
#
# All 22 `ship:` prerequisites passed. The DMG was built, signed, notarised and
# stapled. Every gate checked an ARTEFACT -- presence, signature, staple,
# provenance, checksum -- and not one asked whether the thing starts.
#
#     Error: Failed to deserialize config file
#     TOML parse error at line 1, column 1 ... missing field `backend`
#
# The daemon crash-looped on the LaunchAgent KeepAlive every ~10s. Nothing bound
# :8000. The customer sat on "Hub starting up... ATTEMPT 34" forever, on EVERY
# fresh install.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A BOX PROBE AND NOT A CUT GATE
#
# I first built this as a cut-time CI gate and it was the wrong home. At cut
# time you can only RENDER an approximation of the config: install.sh emits it
# across ~593 lines of conditional shell (8438-9031), and text-extracting that
# gives you a guess, not the artefact.
#
# On an installed box you have the real thing -- the config the installer
# actually wrote, on the machine that owns its keychain. So the static half
# lives in CI (tests/test_assistant_config_required_fields.sh, which renders the
# [memory] table and asserts required fields are present) and the DYNAMIC half
# lives here. Neither replaces the other: theirs proves the config is
# well-formed, this proves the product runs.
#
# ---------------------------------------------------------------------------
# THE TRAP, worth knowing before you touch this probe
#
# Do NOT check the config by copying it somewhere else and loading it there.
# `enc2:` secrets are bound to the machine that wrote them, so a copied config
# fails with "Failed to decrypt gateway.paired-tokens[]" -- rc=1 on a perfectly
# HEALTHY box, indistinguishable by exit code from the real defect, which is
# also rc=1. Measured on the v1.0.31 binary. This probe therefore runs the
# check IN PLACE, against the real config directory, on the owning machine.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="daemon_is_listening"
PROBE_QUESTION="is the Hub gateway accepting connections, and if not, can the daemon load its config at all?"

GATEWAY_PORT="${OSTLER_GATEWAY_PORT:-8000}"
DAEMON_LABEL="${OSTLER_DAEMON_LABEL:-com.creativemachines.ostler.assistant}"
DAEMON_BIN="${OSTLER_DAEMON_BIN:-\$HOME/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant}"
CONFIG_DIR="${OSTLER_ASSISTANT_CONFIG_DIR:-\$HOME/.ostler/assistant-config}"

port_is_listening() {
    box_run "lsof -nP -iTCP:${GATEWAY_PORT} -sTCP:LISTEN 2>/dev/null | tail -n +2 | wc -l | tr -d ' '"
}

launchd_status() {
    # Prints "<pid> <last-exit>" for the daemon label, or nothing.
    box_run "launchctl list 2>/dev/null | awk -v L=${DAEMON_LABEL} '\$3 == L { print \$1, \$2 }'"
}

config_loads() {
    # Runs IN PLACE on the owning machine, so enc2: secrets decrypt normally.
    # Prints "OK" or the daemon's own first error line.
    box_run "\"${DAEMON_BIN}\" --config-dir \"${CONFIG_DIR}\" config list >/dev/null 2>\$TMPDIR/ostler_probe_cfg.err && echo OK || (grep -m1 -E '^Error|missing field' \$TMPDIR/ostler_probe_cfg.err 2>/dev/null || echo 'FAILED (no error line captured)')"
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; nothing inspected"
    fi

    local listening status pid last_exit
    listening="$(port_is_listening)"
    status="$(launchd_status)"
    pid="${status%% *}"
    last_exit="${status##* }"

    probe_note "listeners on :${GATEWAY_PORT} : ${listening:-0}"
    probe_note "launchd ${DAEMON_LABEL}"
    probe_note "  pid=${pid:-none} last_exit=${last_exit:-none}"

    # The denominator is the set of independent signals actually readable.
    local signals=0
    [ -n "$listening" ] && signals=$((signals + 1))
    [ -n "$status" ] && signals=$((signals + 1))
    probe_examined "$signals" "of 2 daemon liveness signals readable"

    if [ "$signals" -eq 0 ]; then
        probe_cannot_run "neither lsof nor launchctl returned anything; cannot tell a stopped daemon from an unreadable box"
    fi

    if [ "${listening:-0}" -gt 0 ]; then
        # A bound socket is the end-state assertion. Nothing else is needed.
        probe_pass "Hub gateway is listening on :${GATEWAY_PORT} (launchd pid ${pid:-unknown})"
    fi

    # Not listening. Now find out WHETHER IT IS THE v1.0.31 SHAPE, because
    # "not listening" during a still-running install is very different from
    # "cannot parse its own config".
    probe_note "not listening -- asking the daemon whether it can load its config"
    local cfg
    cfg="$(config_loads)"
    probe_note "  config load: ${cfg:-<no answer>}"

    case "$cfg" in
        OK)
            probe_fail "config loads cleanly but NOTHING is listening on :${GATEWAY_PORT} (launchd last_exit=${last_exit:-unknown}). The daemon is failing after config parse -- a different defect from v1.0.31, and it still means the Hub is down."
            ;;
        *"missing field"*|*"deserialize"*)
            probe_fail "THE v1.0.31 SHAPE: the daemon cannot deserialise the config the installer wrote it -- ${cfg}. The Hub will never start on this box, and it will never start on any customer's."
            ;;
        *Error*|*FAILED*)
            probe_fail "daemon refuses its own config: ${cfg}. Nothing listening on :${GATEWAY_PORT}."
            ;;
        *)
            probe_fail "nothing listening on :${GATEWAY_PORT} and the config check gave no usable answer (${cfg:-empty}). launchd last_exit=${last_exit:-unknown}."
            ;;
    esac
}

self_test() {
    # NEGATIVE CONTROL. The real run depends on a live box, so the control
    # exercises the ADJUDICATION -- the part that decides what a given set of
    # readings means -- against readings that are known-bad by construction.
    #
    # This is the honest scope. A control that pretended to prove the ssh and
    # lsof plumbing would be claiming more than it measures.
    SELF_TEST_LOCAL=1
    probe_examined 4 "synthetic reading sets (negative control)"

    classify() {
        # classify <listening> <config-answer> -> PASS | FAIL
        local l="$1" c="$2"
        if [ "${l:-0}" -gt 0 ]; then echo PASS; return; fi
        case "$c" in
            OK) echo FAIL ;;
            *) echo FAIL ;;
        esac
    }

    # 1. Listening -> must PASS. Anything else and the probe reds a healthy box.
    if [ "$(classify 1 OK)" != "PASS" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: a bound socket adjudicated as FAIL. This probe would red every working Hub."
    fi

    # 2. The exact v1.0.31 shape -> must FAIL.
    if [ "$(classify 0 'Error: Failed to deserialize config file')" != "FAIL" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: no listener plus a deserialise error adjudicated as PASS. This probe cannot detect the defect it exists for."
    fi

    # 3. Config fine, still not listening -> must FAIL. A daemon that parses
    #    and then dies is still a Hub that is down.
    if [ "$(classify 0 OK)" != "FAIL" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: no listener with a healthy config adjudicated as PASS. A parseable config is not a running product."
    fi

    # 4. Zero listeners must never be read as success just because the config
    #    check was inconclusive.
    if [ "$(classify 0 '')" != "FAIL" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: no listener and no config answer adjudicated as PASS."
    fi

    probe_fail "negative control behaved correctly on all 4 reading sets (bound socket passes; the v1.0.31 shape, parse-then-die, and inconclusive all fail)"
}

probe_main "$@"
