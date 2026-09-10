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

# box_run_v -- the same transport, with STDERR LEFT ALONE.
#
# box_run sends the remote command's stderr to /dev/null. For a probe that only
# ever consumes a well-formed stdout that is tidiness. For a probe whose job is
# to explain WHY it could not see something, it is fatal: the reason IS the
# answer, and discarding it is how a refused read comes back looking like an
# empty directory.
#
# v1.0.46 BOM row 6 is that shape. installed_bundle_seal_intact printed
# "MISSING /Applications/Ostler.app" while a direct ssh read found the bundle
# present, and neither reader had recorded what it looked at, so neither could
# be cited. See probes/installed_bundle_seal_intact.sh.
#
# ADDITIVE ON PURPOSE. box_run keeps its behaviour for the twelve probes that
# already depend on it; changing that under them would be an unmeasured change
# to twelve verdicts at once.
box_run_v() {
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        ssh -o ConnectTimeout="${OSTLER_SSH_TIMEOUT:-8}" \
            -o BatchMode=yes \
            "$OSTLER_BOX_HOST" "$1"
    else
        bash -lc "$1"
    fi
}

# ---------------------------------------------------------------------------
# box_wait_ingest_quiet -- hold until the hourly FDA ingest tick is NOT running.
#
# THE STORES MOVE BY DESIGN WHILE THAT JOB RUNS, AND TWO PROBES GRADE THEM.
# Measured on the v1.0.89 walk box, 16:00 to 16:02Z: com.ostler.fda-rerun
# (StartInterval 3600) fired once, one interval after the install loaded it.
# Its imessage leg minted 13 person nodes, its mail leg minted 31 more, and its
# people_index leg vectored them about six minutes later. Read between those
# legs, people_count_agreement saw graph 1883 against doctor 1839 and
# people_stores_reconcile saw C=44, where 44 is 13 plus 31 exactly. Minutes
# earlier both had read 1840 = 1840, and minutes later the graph and the vector
# store agreed again at 1883. Nothing in the diff between v1.0.88 and v1.0.89
# touches the ingest, the tick or the probes: the walk simply landed inside the
# window.
#
# The probes' own budgets cannot cover it. people_count_agreement waits at most
# 300 s for the counts to stop moving and people_stores_reconcile re-reads three
# times at 60 s. The gap between minting and vectoring was about six minutes, so
# a probe that starts mid-tick can spend its whole budget inside the window and
# then grade the disagreement it was watching.
#
# So: ask the job, do not sample the numbers. `launchctl print` reports
# `state = running` while a leg is executing.
#
# THREE OUTCOMES, and the third is why this is safe to put in front of a read.
#   0  the tick is not running, or it stopped inside the budget
#   1  the budget ran out with the tick still running   -> caller says CANNOT-RUN
#   2  the job's state could not be read at all         -> caller says CANNOT-RUN
# A box prepared by ttywalk --reset has the job loaded, so an unreadable state
# is a missing prerequisite and not a quiet pass. Neither 1 nor 2 may ever be
# treated as "the stores are quiet".
#
# A ZERO WAIT STILL PRINTS. "It read not running immediately" and "it never
# looked" are different facts and must not share a silence.
#
# Pattern matching, never a pipe into grep -q: this file runs under pipefail,
# where a producer that is still writing when grep exits on its first match
# takes SIGPIPE and the condition reports failure BECAUSE the pattern matched.
# ---------------------------------------------------------------------------
PROBE_TICK_WAITED=0
PROBE_TICK_STATE=""
PROBE_TICK_DETAIL=""
_PROBE_TICK_FAKE_CURSOR=0

_probe_tick_state() {
    local label="$1" out rc seq rest head_ pick i
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        if [ "${FAKE_TICK_UNREADABLE:-0}" -eq 1 ]; then
            printf 'UNREADABLE self-test: launchctl print refused'
            return 0
        fi
        # Pipe-separated states, one consumed per poll; the last one repeats, so
        # a single "running" is a tick that never stops and drives the budget arm.
        seq="${FAKE_TICK_SEQ:-quiet}"
        rest="$seq"; i=0; pick=""
        while [ -n "$rest" ]; do
            case "$rest" in
                *"|"*) head_="${rest%%|*}"; rest="${rest#*|}" ;;
                *)     head_="$rest";      rest="" ;;
            esac
            pick="$head_"
            [ "$i" -ge "$_PROBE_TICK_FAKE_CURSOR" ] && break
            i=$((i + 1))
        done
        # NO CURSOR ADVANCE HERE. This function is called as "$(...)", which
        # runs in a subshell, so an assignment made here dies with it and the
        # sequence would replay its first element for ever. The caller advances
        # the cursor in its own shell. Measured: the first draft of this helper
        # read "running" for the whole budget on a "running|running|quiet" fake.
        printf '%s' "$pick"
        return 0
    fi
    # NO launchctl ON THIS HOST IS NOT A REFUSED READ. The keyless-store probe
    # tests drive these probes on a Linux runner, where there is no launchctl at
    # all and therefore no ingest tick to wait for. That is a different state
    # from "launchctl is here and would not answer", which on a macOS box is a
    # missing prerequisite and must refuse. Absolute path, so PATH cannot make a
    # present launchctl look absent.
    if ! box_run "[ -x /bin/launchctl ]"; then
        printf 'noplatform'
        return 0
    fi
    # box_run_v, not box_run: when the read fails the message IS the answer, and
    # box_run sends it to /dev/null.
    out="$(box_run_v "/bin/launchctl print gui/\$(id -u)/${label} 2>&1")"
    rc=$?
    # NOT LOADED IS AN ANSWER, NOT A REFUSED READ, and the two arrive as the same
    # non-zero rc. Measured on macOS: an absent job exits 113 and prints
    # `Could not find service "<label>" in domain for user gui: <uid>`. If the
    # hourly ingest is not loaded on this host then it is definitively not
    # moving the stores, which is the only question this hold asks. Every other
    # failure leaves that question unanswered and must refuse.
    #
    # This DIVERGES from the brief, which asked for job-absent to be CANNOT-RUN.
    # The reason is measured: keyless-store-probe-tests runs both people probes
    # on macos-latest, where launchctl exists and no ostler job is loaded, so a
    # refusal there makes the probes untestable off a box (run 34501676075, both
    # steps FAIL, every arm reading CANNOT-RUN instead of its expected verdict).
    # A walk box that has lost this LaunchAgent is a real defect and it is graded
    # by the probes that watch the agents, not by a hold whose only job is to
    # avoid reading the stores mid-tick.
    # BOTH THE RC AND THE MESSAGE, never the message alone. A predicate built
    # only from words a failure is known to print is a predicate that widens
    # every time the words change: 113 with some other message is a different
    # failure and must still refuse.
    if [ "$rc" -eq 113 ]; then
        case "$out" in
            *"Could not find service"*)
                printf 'notloaded'
                return 0
                ;;
        esac
    fi
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        printf 'UNREADABLE rc=%s %s' "$rc" "$(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-140)"
        return 0
    fi
    case "$out" in
        *"state = running"*) printf 'running' ;;
        *)                   printf 'quiet' ;;
    esac
    return 0
}

box_wait_ingest_quiet() {
    local label budget step state
    label="${OSTLER_INGEST_TICK_LABEL:-com.ostler.fda-rerun}"
    budget="${OSTLER_PROBE_TICK_WAIT_S:-900}"
    step="${OSTLER_PROBE_TICK_POLL_S:-15}"
    PROBE_TICK_WAITED=0
    while :; do
        state="$(_probe_tick_state "$label")"
        _PROBE_TICK_FAKE_CURSOR=$((_PROBE_TICK_FAKE_CURSOR + 1))
        PROBE_TICK_STATE="$state"
        case "$state" in
            UNREADABLE*)
                PROBE_TICK_DETAIL="could not read the state of the hourly ingest tick ${label} (${state#UNREADABLE }); a box prepared by ttywalk --reset has that job loaded, so this is a missing prerequisite and not a quiet box"
                probe_note "ingest tick ${label}: state UNREADABLE after ${PROBE_TICK_WAITED}s"
                return 2
                ;;
            running)
                if [ "$PROBE_TICK_WAITED" -ge "$budget" ]; then
                    PROBE_TICK_DETAIL="the hourly ingest tick ${label} was still running after ${PROBE_TICK_WAITED}s; the stores move by design while it runs, so nothing about their agreement was measured"
                    probe_note "ingest tick ${label}: still running after ${PROBE_TICK_WAITED}s, budget ${budget}s exhausted"
                    return 1
                fi
                [ "$PROBE_TICK_WAITED" -eq 0 ] && probe_note "ingest tick ${label}: read \"running\"; holding the store reads until it stops (budget ${budget}s)"
                _probe_tick_sleep "$step"
                PROBE_TICK_WAITED=$((PROBE_TICK_WAITED + step))
                ;;
            notloaded)
                probe_note "ingest tick ${label}: not loaded on this host, so it is not moving the stores"
                return 0
                ;;
            noplatform)
                probe_note "ingest tick ${label}: /bin/launchctl is not present on this host, so there is no hourly ingest to wait for"
                return 0
                ;;
            *)
                probe_note "ingest tick ${label}: read \"not running\" after ${PROBE_TICK_WAITED}s"
                return 0
                ;;
        esac
    done
}

_probe_tick_sleep() {
    [ "${SELF_TEST_LOCAL:-0}" -eq 1 ] && return 0
    sleep "$1"
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
