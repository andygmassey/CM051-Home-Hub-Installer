#!/usr/bin/env bash
# probes/converge_kill_is_recorded.sh
# ============================================================================
# QUESTION: did this box's install-time dedupe converge finish, and if it was
#           killed, does the box say so?
#
# WHY IT MATTERS. install.sh runs the identity resolver with a 300s budget
# (OSTLER_DEDUPE_INSTALL_BUDGET_S) and, on exceeding it, sends SIGTERM, waits
# two seconds, then SIGKILL. `kill -9` cannot be trapped, so the resolver cannot
# finish the merge it is inside.
#
# identity_resolver merge_persons is EIGHT separate SPARQL updates. The
# identifiers move at step 1; the mergedInto tombstone that authorises the move
# is written at step 6. A kill in between leaves identifiers rehomed onto a
# keeper with nothing recording that a merge happened, and nothing in the
# resolver detects, completes or reverses that state.
#
# So a killed converge is not a tidy "we will finish later". It is a graph whose
# people counts are provisional, and every people-reading probe on this walk is
# then measuring a half-finished job. This probe makes that visible instead of
# leaving the reader to infer it from three other probes going red.
#
# WHAT IT DOES NOT CLAIM. It does not say the graph IS damaged, and it does not
# read the graph at all -- deliberately. The graph is the surface that has
# repeatedly misled this investigation; this reads a filesystem marker written
# by the installer at the moment it fired the signal.
#
# ADVISORY, NOT BLOCKING. A killed converge is a fact about this box and its
# data, not a defect in the DMG being walked. It belongs in the record and in
# front of the operator; it must not refuse a promote.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="converge_kill_is_recorded"
PROBE_QUESTION="did the install-time dedupe converge finish, and if it was killed does the box record it?"

STATE_DIR="${OSTLER_STATE_DIR:-\$HOME/.ostler/state}"
DONE_MARKER="${STATE_DIR}/dedupe-converge.done"
KILLED_MARKER="${STATE_DIR}/dedupe-converge.killed"

# Each reader prints one token, evaluated ON THE BOX so a local ~ cannot leak
# the operator's home into a path that only makes sense remotely.
marker_state() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_STATE:-NEITHER}"; return; fi
    box_run "
        if [ -f \"${KILLED_MARKER}\" ]; then printf 'KILLED'
        elif [ -f \"${DONE_MARKER}\" ]; then printf 'DONE'
        else printf 'NEITHER'; fi
    "
}

killed_detail() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_DETAIL:-}"; return; fi
    box_run "cat \"${KILLED_MARKER}\" 2>/dev/null | tr '\n' ' ' | cut -c1-200"
}

# adjudicate <state> -> verdict token + detail
#
# THE THIRD STATE IS THE WHOLE POINT. "No killed marker" means "not killed"
# ONLY on a build that can write one. #1515 added the marker AFTER the v1.0.68
# pin, so on any artefact predating it the absence is silence, not a clean bill.
# Reporting that silence as a PASS is exactly the shape this suite exists to
# refuse.
adjudicate() {
    case "$1" in
        KILLED)
            printf 'KILLED the install-time converge was SIGKILLed at the budget; people counts on this box are provisional' ;;
        DONE)
            printf 'DONE the converge ran to completion and marked itself done' ;;
        NEITHER)
            printf 'UNKNOWN neither marker is present: the converge did not complete AND no kill was recorded. On an artefact predating the kill-marker this is silence, not a clean run' ;;
        *)
            printf 'UNKNOWN the marker reader returned an unrecognised token' ;;
    esac
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)}; no converge markers were read"
    fi

    local st detail r tok
    st="$(marker_state)"
    probe_note "converge marker state : ${st:-<empty>}"
    probe_examined 1 "of 1 converge-completion marker pair readable"

    r="$(adjudicate "$st")"
    tok="${r%% *}"

    case "$tok" in
        DONE)
            probe_pass "${r#* }" ;;
        KILLED)
            detail="$(killed_detail)"
            [ -n "$detail" ] && probe_note "killed marker        : $detail"
            probe_fail "${r#* } (${detail:-marker present but unreadable}). See identity_resolver merge_persons: identifiers move at step 1, the authorising tombstone at step 6." ;;
        *)
            probe_cannot_run "${r#* }" ;;
    esac
}

# ---------------------------------------------------------------------------
# NEGATIVE CONTROLS. A probe that cannot demonstrate a FAIL has not earned a
# PASS, and one that cannot demonstrate its CANNOT-RUN has not earned either.
# ---------------------------------------------------------------------------
self_test() {
    SELF_TEST_LOCAL=1
    local r fail=0

    r="$(adjudicate KILLED)"
    [ "${r%% *}" = "KILLED" ] || { fail=1; probe_note "control: a KILLED marker did not adjudicate as KILLED (got '${r%% *}')"; }

    r="$(adjudicate DONE)"
    [ "${r%% *}" = "DONE" ] || { fail=1; probe_note "control: a DONE marker did not adjudicate as DONE (got '${r%% *}')"; }

    # THE ONE THAT MATTERS. Absence must NOT read as success.
    r="$(adjudicate NEITHER)"
    [ "${r%% *}" = "UNKNOWN" ] || { fail=1; probe_note "control: ABSENCE adjudicated as '${r%% *}', not UNKNOWN -- this probe would report a clean run on a build that cannot record a kill"; }

    r="$(adjudicate some-token-nobody-writes)"
    [ "${r%% *}" = "UNKNOWN" ] || { fail=1; probe_note "control: an unrecognised token adjudicated as '${r%% *}', not UNKNOWN"; }

    probe_examined 4 "of 4 adjudication controls (KILLED, DONE, absence, unrecognised)"

    if [ "$fail" -ne 0 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: adjudicate() misclassified one of KILLED / DONE / NEITHER / unrecognised, so a green from this probe would prove nothing"
    fi
    probe_fail "control fired: KILLED, DONE, absence and an unrecognised token are each classified, and absence is UNKNOWN rather than a pass"
}

probe_main "$@"
