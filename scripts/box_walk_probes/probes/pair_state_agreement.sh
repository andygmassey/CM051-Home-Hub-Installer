#!/usr/bin/env bash
# probes/pair_state_agreement.sh
# ============================================================================
# QUESTION: do all available pairing signals on this box tell the same story?
#
# WHY IT MATTERS. Task #265 was the root cause of an entire failed box walk,
# and task #208 was its most customer-visible face: Doctor displayed "Paired:
# Your phone is connected" while devices.db held ZERO rows. The daemon's
# /health returned paired:true from a different source of truth than the table
# that actually stores devices.
#
# A LIE IN THE AFFIRMATIVE DIRECTION IS THE WORST POSSIBLE FAILURE HERE.
# An honest "not paired" sends the customer to the pair flow. A false "paired"
# sends them to support, because every feature that depends on the phone then
# fails for reasons the UI insists are impossible.
#
# THE ASSERTION IS AGREEMENT, NOT A PARTICULAR STATE. An unpaired box is a
# perfectly good result on a fresh install. What must never happen is two
# signals disagreeing.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="pair_state_agreement"
PROBE_QUESTION="do the daemon health flag, devices.db, and pair-state file all agree on whether a phone is paired?"

DEVICES_DB="${OSTLER_DEVICES_DB:-\$HOME/.ostler/devices.db}"
HEALTH_URL="${OSTLER_HEALTH_URL:-http://127.0.0.1:8089/doctor/api/health}"

# --- signal readers. Each prints  true | false | UNAVAILABLE ---------------

signal_health_flag() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        printf '%s' "${FAKE_HEALTH:-UNAVAILABLE}"; return
    fi
    local body
    body="$(box_run "curl -sS -m 5 '$HEALTH_URL' 2>/dev/null")"
    if [ -z "$body" ]; then printf 'UNAVAILABLE'; return; fi
    case "$body" in
        *'"paired"'*'true'*) printf 'true' ;;
        *'"paired"'*'false'*) printf 'false' ;;
        *) printf 'UNAVAILABLE' ;;
    esac
}

signal_devices_rows() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        printf '%s' "${FAKE_DEVICES:-UNAVAILABLE}"; return
    fi
    local n
    n="$(box_run "sqlite3 \"$DEVICES_DB\" 'SELECT COUNT(*) FROM devices;' 2>/dev/null")"
    case "$n" in
        ''|*[!0-9]*) printf 'UNAVAILABLE' ;;
        0) printf 'false' ;;
        *) printf 'true' ;;
    esac
}

signal_pair_marker() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        printf '%s' "${FAKE_MARKER:-UNAVAILABLE}"; return
    fi
    local out
    # 🔴 MEASURED 2026-08-26 on the live box: ~/.ostler/paired_devices DOES NOT
    # EXIST. The old body was `ls .../*.json 2>/dev/null | wc -l`, and a failed
    # `ls` still feeds `wc` an empty stream -- so an ABSENT DIRECTORY counted 0
    # and this signal returned a confident `false`, meaning "no device is
    # paired". That is a different fact from "I could not look", and it was the
    # ONE answer that could not be right: the same box carries 35 issued bearer
    # tokens in config.toml. Because the other two signals were UNAVAILABLE,
    # this fail-open `false` was the sole readable signal, and a single signal
    # cannot contradict itself -- so the probe could only ever say INSUFFICIENT
    # while sitting on top of a real split-brain.
    #
    # Ask whether the directory exists BEFORE counting inside it.
    out="$(box_run "if [ -d \"\$HOME/.ostler/paired_devices\" ]; then ls \$HOME/.ostler/paired_devices/*.json 2>/dev/null | wc -l | tr -d ' '; else printf ABSENT; fi")"
    case "$out" in
        ABSENT) printf 'UNAVAILABLE' ;;
        ''|*[!0-9]*) printf 'UNAVAILABLE' ;;
        0) printf 'false' ;;
        *) printf 'true' ;;
    esac
}

# --- the comparison, shared by run_probe and self_test ---------------------

adjudicate() {
    # adjudicate <health> <devices> <marker>
    # Prints a verdict token on stdout: AGREE | DISAGREE | INSUFFICIENT
    # followed by a space and a human-readable detail string.
    local h="$1" d="$2" m="$3"
    local seen="" n=0

    for v in "$h" "$d" "$m"; do
        if [ "$v" != "UNAVAILABLE" ]; then
            seen="$seen $v"
            n=$((n + 1))
        fi
    done

    # ONE signal is not agreement. Two signals agreeing is the minimum that
    # means anything, because a single reading cannot contradict itself and
    # would therefore pass forever.
    if [ "$n" -lt 2 ]; then
        printf 'INSUFFICIENT only %s of 3 pairing signals were readable' "$n"
        return
    fi

    local t=0 f=0
    for v in $seen; do
        if [ "$v" = "true" ]; then t=$((t + 1)); else f=$((f + 1)); fi
    done

    if [ "$t" -gt 0 ] && [ "$f" -gt 0 ]; then
        printf 'DISAGREE %s of %s signals say paired and %s say not paired' "$t" "$n" "$f"
        return
    fi
    printf 'AGREE all %s readable signals say paired=%s' "$n" "$([ "$t" -gt 0 ] && echo true || echo false)"
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; no pairing signals read"
    fi

    local h d m
    h="$(signal_health_flag)"
    d="$(signal_devices_rows)"
    m="$(signal_pair_marker)"

    probe_note "daemon health paired flag : $h"
    probe_note "devices.db row count      : $d"
    probe_note "paired_devices/*.json     : $m"

    local readable=0
    for v in "$h" "$d" "$m"; do
        [ "$v" != "UNAVAILABLE" ] && readable=$((readable + 1))
    done
    probe_examined "$readable" "of 3 pairing signals readable"

    local result
    result="$(adjudicate "$h" "$d" "$m")"
    local token="${result%% *}"
    local detail="${result#* }"

    case "$token" in
        DISAGREE)
            probe_fail "pairing state is split-brain: $detail (tasks #265, #208). A false 'paired' is worse than an honest 'not paired'."
            ;;
        INSUFFICIENT)
            probe_cannot_run "$detail -- one signal cannot contradict itself, so this would pass forever. Is the daemon running?"
            ;;
        *)
            probe_pass "$detail"
            ;;
    esac
}

self_test() {
    SELF_TEST_LOCAL=1
    probe_examined 4 "synthetic signal combinations (negative control)"

    # 1. The #208 shape: health says paired, devices.db is empty. MUST disagree.
    local r
    r="$(adjudicate true false UNAVAILABLE)"
    if [ "${r%% *}" != "DISAGREE" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: health=true vs devices=false adjudicated as '${r%% *}', not DISAGREE. This probe cannot detect task #208."
    fi

    # 2. Honest unpaired box. MUST agree.
    r="$(adjudicate false false false)"
    if [ "${r%% *}" != "AGREE" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: a consistently unpaired box adjudicated as '${r%% *}'. It would fail every fresh install."
    fi

    # 3. Honest paired box. MUST agree.
    r="$(adjudicate true true true)"
    if [ "${r%% *}" != "AGREE" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: a consistently paired box adjudicated as '${r%% *}'."
    fi

    # 4. Only one signal readable. MUST refuse rather than pass, because a
    #    lone signal agrees with itself by construction.
    r="$(adjudicate true UNAVAILABLE UNAVAILABLE)"
    if [ "${r%% *}" != "INSUFFICIENT" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a single readable signal adjudicated as '${r%% *}'. One signal cannot contradict itself, so this probe would report agreement forever."
    fi

    probe_fail "negative control behaved correctly on all 4 combinations (split-brain caught, consistent states passed, single-signal refused)"
}

probe_main "$@"
