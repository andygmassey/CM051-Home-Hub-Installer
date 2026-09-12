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
    # Echoes a COUNT, or the literal string UNREADABLE.
    #
    # The `2>/dev/null` that used to be here is gone on principle: never
    # discard a probe's stderr. But MEASURE BEFORE CLAIMING A FIX -- on macOS
    # this one does not fire, and saying otherwise would be inventing a cause:
    #
    #     lsof -nP -iTCP:8000 -sTCP:LISTEN   (as archie, andy's socket bound)
    #       rc = 1        stdout = 0 lines        stderr = 0 BYTES
    #
    # There is no permission error to preserve. macOS lsof simply OMITS what
    # the caller may not see. And rc=1 does not discriminate either: it is also
    # what a genuinely empty port returns.
    #
    # ⇒ NEITHER stderr NOR the exit code can tell a foreign-owned socket from
    # an empty port here. The CONNECT TEST below is the only discriminator, and
    # it is what actually caught this. This stderr capture is correct hygiene
    # and a real signal on other platforms; it is not the load-bearing half.
    box_run "lsof -nP -iTCP:${GATEWAY_PORT} -sTCP:LISTEN 2>\"\$TMPDIR/ostler_probe_lsof.err\" | tail -n +2 | wc -l | tr -d ' '; if [ -s \"\$TMPDIR/ostler_probe_lsof.err\" ]; then echo UNREADABLE; fi"
}

port_answers() {
    # Does ANYTHING serve this port? Echoes an HTTP status, or nothing.
    #
    # `lsof` above runs AS THE WALKED ACCOUNT and cannot see a socket owned by
    # ANOTHER USER. So "listeners: 0" means "none this account may see", which
    # is not the same claim as "the port is free" -- and on a shared Mac they
    # come apart completely.
    box_run "curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 6 http://127.0.0.1:${GATEWAY_PORT}/ 2>/dev/null"
}

bind_refusals() {
    # The daemon's own confession, which needs no privilege to read.
    box_run "grep -c 'Address already in use' \"\$HOME/.ostler/logs/ostler-assistant.err\" 2>/dev/null | tr -d ' '"
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

# _daemon_classify -- THE ONE DECISION FUNCTION, used by run_probe AND self_test.
#
# 🔴 UNTIL THIS FIX, self_test drove its OWN local `classify()`, and run_probe's
# real adjudication was a separately written chain of `if`/`case` reaching
# probe_pass/probe_fail/probe_cannot_run directly. The two never touched. A
# regression that flipped run_probe's real chain -- for instance turning a FAIL
# into a PASS -- left the self-test output byte identical, because the
# negative control never executed that code. See tests/... mutation guard.
#
# This function IS the adjudication now. run_probe gathers the signals and
# calls it; self_test calls it too, with synthetic signals. A mutation to the
# logic below breaks BOTH in the same commit.
#
# _daemon_classify <signals> <lsof_readable> <listening> <config-answer> <port-http>
# Echoes one of:
#   PASS
#   CANNOT-RUN-NOSIGNAL       neither lsof nor launchctl answered
#   CANNOT-RUN-PORT-UNREADABLE  lsof's own enumeration errored
#   CANNOT-RUN-FOREIGN        port answers but this account owns no listener
#   FAIL-PARSE-THEN-DIE       config loads, nothing listening
#   FAIL-V1031                the v1.0.31 deserialise shape
#   FAIL-CONFIG-ERROR         daemon names a different config error
#   FAIL-CONFIG-UNKNOWN       not listening, config check gave no usable answer
_daemon_classify() {
    local signals="$1" lsof_readable="$2" listening="$3" cfg="$4" http="${5:-000}"

    # 🔴 THIS USED TO REQUIRE **BOTH** SIGNALS TO BE MISSING, and that
    # conjunction is what turned a permission boundary into a product FAIL on
    # the v1.0.66 artefact walk. launchctl answered happily (loaded,
    # last_exit=0), so `signals` was non-zero, this arm was skipped, and the
    # run fell through to a FAIL that named a defect nobody had. **The honest
    # verdict was one branch away and an AND closed it.**
    #
    # The two signals answer DIFFERENT questions -- "is a socket bound" and
    # "is the job loaded" -- so a second signal cannot stand in for the first.
    # An unreadable port enumeration is disqualifying ON ITS OWN.
    if [ "${signals:-0}" -eq 0 ]; then
        echo CANNOT-RUN-NOSIGNAL
        return
    fi
    if [ "${lsof_readable:-0}" -eq 0 ]; then
        echo CANNOT-RUN-PORT-UNREADABLE
        return
    fi

    if [ "${listening:-0}" -gt 0 ]; then
        # A bound socket is the end-state assertion. Nothing else is needed.
        echo PASS
        return
    fi

    # ── IS THE PORT EMPTY, OR MERELY NOT OURS? ───────────────────────────
    #
    # 🔴 MEASURED 2026-09-04 on the v1.0.66 artefact walk. This probe reported
    #
    #     FAIL -- config loads cleanly but NOTHING is listening on :8000
    #             (launchd last_exit=0). The daemon is failing after config parse.
    #
    # and every word of the diagnosis was wrong. Something WAS listening:
    #
    #     curl --noproxy '*' http://127.0.0.1:8000/  ->  HTTP 200
    #     ps  ->  andy 20075 ostler-assistant   (a DIFFERENT ACCOUNT's Hub,
    #                                            running since the day before)
    #     archie's own daemon log: 27x "Address already in use (os error 48)"
    #                              and ZERO successful binds
    #
    # `lsof` ran as the walked account and could not see another user's socket,
    # so it returned 0, and this probe read that PERMISSION BOUNDARY as
    # ABSENCE -- then blamed the product for a port collision it did not cause.
    # Ten sibling probes failed downstream of the same fact.
    #
    # A foreign occupant is not a product defect and it is not a clean port.
    # It is CANNOT-RUN: we could not measure OUR daemon, because we could not
    # get at the port to ask. Reporting FAIL there is the accusation form of a
    # false green, and it is exactly what "print remote_ip, do not trust an
    # enumeration you are not privileged to make" exists to prevent.
    case "${http:-000}" in
        000|"")
            : ;;   # genuinely nothing there -- fall through and adjudicate
        *)
            echo CANNOT-RUN-FOREIGN
            return
            ;;
    esac

    # Not listening, and nothing else answered either. Now find out WHETHER IT
    # IS THE v1.0.31 SHAPE, because "not listening" during a still-running
    # install is very different from "cannot parse its own config".
    case "$cfg" in
        OK)
            echo FAIL-PARSE-THEN-DIE ;;
        *"missing field"*|*"deserialize"*)
            echo FAIL-V1031 ;;
        *Error*|*FAILED*)
            echo FAIL-CONFIG-ERROR ;;
        *)
            echo FAIL-CONFIG-UNKNOWN ;;
    esac
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; nothing inspected"
    fi

    local listening_raw listening lsof_readable status pid last_exit
    listening_raw="$(port_is_listening)"
    case "$listening_raw" in
        *UNREADABLE*) lsof_readable=0 ;;
        *)            lsof_readable=1 ;;
    esac
    listening="$(printf '%s' "$listening_raw" | tr -dc '0-9' | head -c 6)"
    status="$(launchd_status)"
    pid="${status%% *}"
    last_exit="${status##* }"

    if [ "$lsof_readable" -eq 1 ]; then
        probe_note "listeners on :${GATEWAY_PORT} : ${listening:-0}"
    else
        probe_note "listeners on :${GATEWAY_PORT} : UNREADABLE (lsof wrote to stderr)"
    fi
    probe_note "launchd ${DAEMON_LABEL}"
    probe_note "  pid=${pid:-none} last_exit=${last_exit:-none}"

    # The denominator is the set of independent signals actually readable.
    # An enumeration that ERRORED is not a signal, whatever number it printed.
    local signals=0
    [ -n "$listening" ] && [ "$lsof_readable" -eq 1 ] && signals=$((signals + 1))
    [ -n "$status" ] && signals=$((signals + 1))
    probe_examined "$signals" "of 2 daemon liveness signals readable"

    # Gathered UNCONDITIONALLY (not lazily short-circuited past this point) so
    # that _daemon_classify -- the SAME function self_test drives -- always
    # receives real values for every parameter. The alternative (fetch these
    # only when the earlier signals leave the outcome undecided) would mean
    # run_probe and self_test call the function with differently-shaped inputs
    # depending on the branch, which is exactly the kind of divergence that let
    # the old copy rot unnoticed. The extra curl/grep/config-list calls this
    # costs on an already-listening box are read-only and cheap.
    local answered refusals cfg verdict
    answered="$(port_answers)"
    refusals="$(bind_refusals)"
    probe_note "  connect test on :${GATEWAY_PORT} : HTTP ${answered:-000} (000 = nothing answered)"
    probe_note "  daemon 'Address already in use' lines : ${refusals:-0}"
    cfg="$(config_loads)"
    probe_note "  config load (only decisive if nothing is listening): ${cfg:-<no answer>}"

    verdict="$(_daemon_classify "$signals" "$lsof_readable" "${listening:-0}" "$cfg" "${answered:-000}")"

    case "$verdict" in
        CANNOT-RUN-NOSIGNAL)
            probe_cannot_run "neither lsof nor launchctl returned anything; cannot tell a stopped daemon from an unreadable box"
            ;;
        CANNOT-RUN-PORT-UNREADABLE)
            probe_cannot_run "the port enumeration ERRORED (lsof wrote to stderr) and was therefore never made. On a shared Mac that is normally a socket owned by ANOTHER ACCOUNT, which this user may not see. launchctl answering is not a substitute: it says the job is loaded, not that a socket is bound. Nothing about :${GATEWAY_PORT} was measured."
            ;;
        PASS)
            probe_pass "Hub gateway is listening on :${GATEWAY_PORT} (launchd pid ${pid:-unknown})"
            ;;
        CANNOT-RUN-FOREIGN)
            probe_cannot_run "the port is OCCUPIED BY SOMETHING THIS ACCOUNT DOES NOT OWN: lsof (run as the walked user) saw 0 listeners, but a connect to :${GATEWAY_PORT} answered HTTP ${answered}, and this daemon logged ${refusals:-0} 'Address already in use' refusal(s). Our gateway cannot bind, so its health was NOT MEASURED. On a shared Mac this is another account's Hub holding the port; stop it and re-run. This is not a pass and it is not a product failure."
            ;;
        FAIL-PARSE-THEN-DIE)
            probe_fail "config loads cleanly but NOTHING is listening on :${GATEWAY_PORT} (launchd last_exit=${last_exit:-unknown}). The daemon is failing after config parse -- a different defect from v1.0.31, and it still means the Hub is down."
            ;;
        FAIL-V1031)
            probe_fail "THE v1.0.31 SHAPE: the daemon cannot deserialise the config the installer wrote it -- ${cfg}. The Hub will never start on this box, and it will never start on any customer's."
            ;;
        FAIL-CONFIG-ERROR)
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
    #
    # 🔴 THIS USED TO DRIVE A LOCAL classify() THAT WAS NOT run_probe's
    # DECISION LOGIC -- a separate, hand-maintained copy. run_probe now calls
    # _daemon_classify directly (defined above, once), and so does this
    # function. A regression to the real adjudication and a regression to this
    # control are now the SAME EDIT, which is the whole point: see
    # tests/test_a_probes_self_test_must_drive_its_own_decision.sh, which
    # mutates _daemon_classify and requires this self-test to go BROKEN.
    SELF_TEST_LOCAL=1
    probe_examined 8 "synthetic reading sets (negative control)"

    # 0. Neither signal readable -> CANNOT-RUN-NOSIGNAL.
    if [ "$(_daemon_classify 0 1 0 OK 000)" != "CANNOT-RUN-NOSIGNAL" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: zero readable signals adjudicated as $(_daemon_classify 0 1 0 OK 000), not CANNOT-RUN-NOSIGNAL."
    fi

    # 0b. The port enumeration itself errored -> CANNOT-RUN-PORT-UNREADABLE,
    #     even though launchctl answered (signals=1).
    if [ "$(_daemon_classify 1 0 0 OK 000)" != "CANNOT-RUN-PORT-UNREADABLE" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: an unreadable lsof enumeration adjudicated as $(_daemon_classify 1 0 0 OK 000), not CANNOT-RUN-PORT-UNREADABLE. launchctl answering must not stand in for a bound-socket check."
    fi

    # 1. Listening -> must PASS. Anything else and the probe reds a healthy box.
    if [ "$(_daemon_classify 2 1 1 OK 000)" != "PASS" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: a bound socket adjudicated as $(_daemon_classify 2 1 1 OK 000), not PASS. This probe would red every working Hub."
    fi

    # 2. The exact v1.0.31 shape -> must FAIL-V1031.
    if [ "$(_daemon_classify 2 1 0 'Error: Failed to deserialize config file' 000)" != "FAIL-V1031" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: no listener plus a deserialise error adjudicated as $(_daemon_classify 2 1 0 'Error: Failed to deserialize config file' 000), not FAIL-V1031. This probe cannot detect the defect it exists for."
    fi

    # 3. Config fine, still not listening -> must FAIL-PARSE-THEN-DIE. A
    #    daemon that parses and then dies is still a Hub that is down.
    if [ "$(_daemon_classify 2 1 0 OK 000)" != "FAIL-PARSE-THEN-DIE" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: no listener with a healthy config adjudicated as $(_daemon_classify 2 1 0 OK 000), not FAIL-PARSE-THEN-DIE. A parseable config is not a running product."
    fi

    # 4. Zero listeners must never be read as success just because the config
    #    check was inconclusive.
    if [ "$(_daemon_classify 2 1 0 '' 000)" != "FAIL-CONFIG-UNKNOWN" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: no listener and no config answer adjudicated as $(_daemon_classify 2 1 0 '' 000), not FAIL-CONFIG-UNKNOWN."
    fi

    # 5. MEASURED 2026-09-04: no listener THIS ACCOUNT can see, but the port
    #    answers -> CANNOT-RUN-FOREIGN. Another account's Hub held :8000, our
    #    gateway logged 29 "Address already in use" refusals and never bound
    #    once, and this probe called it a product defect. A foreign occupant
    #    is not an empty port and it is not our daemon failing.
    if [ "$(_daemon_classify 2 1 0 OK 200)" != "CANNOT-RUN-FOREIGN" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a port answering HTTP 200 with 0 visible listeners adjudicated as $(_daemon_classify 2 1 0 OK 200), not CANNOT-RUN-FOREIGN. The probe would blame the product for another account's service."
    fi

    # 6. MUST-MISS, and it is the important half of 5. The occupancy check
    #    must not swallow the genuine defect: nothing answering is still a FAIL.
    if [ "$(_daemon_classify 2 1 0 OK 000)" != "FAIL-PARSE-THEN-DIE" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: a genuinely dead port adjudicated as $(_daemon_classify 2 1 0 OK 000), not FAIL-PARSE-THEN-DIE. The occupancy check has disabled the defect this probe exists for."
    fi

    probe_fail "negative control behaved correctly on all 8 reading sets (a bound socket passes; the v1.0.31 shape, parse-then-die and inconclusive-config all fail; a foreign occupant and either unreadable signal are CANNOT-RUN; and a genuinely dead port is still FAIL)"
}

probe_main "$@"
