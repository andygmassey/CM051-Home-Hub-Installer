#!/usr/bin/env bash
# scripts/box_walk_probes/lib/probe.sh
# ============================================================================
# THE PROBE CONTRACT
#
# Every probe in this suite is an executable that answers ONE question about a
# freshly installed Hub, and answers it in a way that cannot be mistaken for an
# answer it did not produce.
#
# WHY THIS FILE EXISTS. Four release tags burnt in a row, one gate each: a gate
# that grepped inside a container that never started, a test that skipped on a
# runner with no docker and reported SUCCESS, a bash 4 builtin on a bash 3.2
# runner, a function that returned 127 and was inverted into "refuse
# everything". In every case an instrument returned a confident verdict from a
# measurement that never ran.
#
# Not one of those gates had a negative control. None had ever been observed to
# produce a FAIL. The same was true of people_seed_and_retrieval.sh, which used
# to sit one level up rather than in probes/ -- a real implementation, not a
# stub, but with nothing proving it could go red, and one level up is a
# directory run_box_walk.sh does not glob, so it had never run at all. It now
# lives in probes/ with a --self-test like everything else.
#
#   A ZERO THAT MEANS "DID NOT LOOK" IS INDISTINGUISHABLE FROM A ZERO THAT
#   MEANS "FOUND NOTHING".
#
# So this framework is built around one rule: a probe does not get to be
# believed until it has demonstrated, in the same invocation, that it is
# capable of returning FAIL. See self_test below.
#
# EXIT CODES
#   0   PASS         the assertion held, and the probe says what it examined
#   1   FAIL         the assertion did not hold
#   78  CANNOT_RUN   a prerequisite was absent (EX_CONFIG)
#
# CANNOT_RUN IS NOT A PASS AND IS NOT A SKIP. It is a third outcome, counted
# and reported separately, because "we did not measure this" is information the
# operator needs and a skip destroys it.
#
# EVERY PROBE MUST:
#   1. call probe_examined  with the size of what it actually inspected
#   2. call probe_pass / probe_fail / probe_cannot_run with text that NAMES THE
#      ARTEFACT MEASURED, not the abstract condition
#   3. implement  self_test()  which runs the probe body against a known-bad
#      fixture and MUST come back FAIL
#
# Requirement 3 is what makes the stub shape impossible. A stub that exits 0
# also exits 0 under --self-test, its negative control does not go red, and the
# runner marks it BROKEN rather than counting it green.
#
# BASH 3.2. macOS ships bash 3.2 and the installed box runs it. No associative
# arrays, no mapfile, no ${var,,}. A syntax error here means the probe never
# ran, which is the exact failure this suite exists to prevent.
# ============================================================================

set -uo pipefail

PROBE_EX_PASS=0
PROBE_EX_FAIL=1
PROBE_EX_CANNOT_RUN=78

# Set by probe_examined. Starts unset ON PURPOSE: a probe that reports a
# verdict without ever declaring a denominator is refused below, because an
# unstated denominator is how "0 of 0" reads as success.
PROBE_EXAMINED_SET=0

probe_examined() {
    # probe_examined <count> <unit>
    # The denominator. Print what was actually inspected, always, including
    # when the count is zero -- ESPECIALLY when the count is zero, because a
    # zero denominator is the thing most likely to be misread as clean.
    PROBE_EXAMINED_SET=1
    printf 'EXAMINED: %s %s\n' "$1" "$2"
}

_probe_require_denominator() {
    if [ "$PROBE_EXAMINED_SET" -eq 0 ]; then
        printf 'VERDICT: BROKEN -- %s reported a verdict without calling probe_examined.\n' "${PROBE_NAME:-probe}"
        printf '  A verdict with no denominator cannot be audited. Refusing to report it.\n'
        exit "$PROBE_EX_FAIL"
    fi
}

probe_pass() {
    _probe_require_denominator
    printf 'VERDICT: PASS -- %s\n' "$1"
    exit "$PROBE_EX_PASS"
}

probe_fail() {
    _probe_require_denominator
    printf 'VERDICT: FAIL -- %s\n' "$1"
    exit "$PROBE_EX_FAIL"
}

probe_cannot_run() {
    # Deliberately does NOT require a denominator: the whole point is that
    # there was nothing to count because a prerequisite was missing. But it
    # MUST name the missing prerequisite, so the operator can fix it rather
    # than guess.
    printf 'VERDICT: CANNOT-RUN -- %s\n' "$1"
    exit "$PROBE_EX_CANNOT_RUN"
}

probe_note() {
    printf '  %s\n' "$1"
}

# ---------------------------------------------------------------------------
# Remote execution against the box under test.
#
# OSTLER_BOX_HOST unset means "this machine". That is the common case when a
# probe runs on the box itself, and it must not be mistaken for a missing
# prerequisite.
# ---------------------------------------------------------------------------
box_run() {
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        ssh -o ConnectTimeout="${OSTLER_SSH_TIMEOUT:-8}" \
            -o BatchMode=yes \
            "$OSTLER_BOX_HOST" "$1" 2>/dev/null
    else
        bash -lc "$1" 2>/dev/null
    fi
}

box_reachable() {
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        return 0
    fi
    box_run 'echo ok' | grep -q '^ok$'
}

# ---------------------------------------------------------------------------
# probe_main -- the entry point every probe ends with.
#
#   probe_main "$@"
#
# Dispatches to run_probe (the real measurement) or self_test (the negative
# control). Both must be defined by the probe.
# ---------------------------------------------------------------------------
probe_main() {
    case "${1:-}" in
        --self-test)
            if ! type self_test >/dev/null 2>&1; then
                printf 'VERDICT: BROKEN -- %s defines no self_test.\n' "${PROBE_NAME:-probe}"
                printf '  A probe that cannot demonstrate a FAIL has not earned a PASS.\n'
                exit "$PROBE_EX_FAIL"
            fi
            self_test
            # A self_test that returns instead of exiting has not asserted
            # anything. Treat that as broken rather than letting it fall
            # through to exit 0.
            printf 'VERDICT: BROKEN -- %s self_test returned without a verdict.\n' "${PROBE_NAME:-probe}"
            exit "$PROBE_EX_FAIL"
            ;;
        --describe)
            printf '%s: %s\n' "${PROBE_NAME:-probe}" "${PROBE_QUESTION:-(no question declared)}"
            exit 0
            ;;
        *)
            if ! type run_probe >/dev/null 2>&1; then
                printf 'VERDICT: BROKEN -- %s defines no run_probe.\n' "${PROBE_NAME:-probe}"
                exit "$PROBE_EX_FAIL"
            fi
            run_probe
            printf 'VERDICT: BROKEN -- %s returned without a verdict.\n' "${PROBE_NAME:-probe}"
            exit "$PROBE_EX_FAIL"
            ;;
    esac
}
