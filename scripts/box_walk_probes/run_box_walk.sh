#!/usr/bin/env bash
# scripts/box_walk_probes/run_box_walk.sh
# ============================================================================
# THE BOX WALK RUNNER
#
# Runs every probe against a freshly installed Hub and reports four counts,
# never one. Usage:
#
#   ./run_box_walk.sh                        # run on this machine
#   OSTLER_BOX_HOST=andy@192.168.1.215 ./run_box_walk.sh
#   ./run_box_walk.sh --list                 # what each probe asks
#   ./run_box_walk.sh --only pair_state      # single probe, substring match
#
# WHAT MAKES THIS DIFFERENT FROM A TEST RUNNER
#
# Phase 1 tries to BREAK every probe before trusting any of them. Each probe is
# invoked with --self-test, which runs its body against a known-bad fixture.
# A probe that does not come back FAIL is marked BROKEN and its real result is
# discarded, because a probe that cannot produce a FAIL has not earned a PASS.
#
# This is the direct lesson of the stub that used to be the entire QA estate:
#
#     echo "STUB -- full probe deferred"; exit 0
#
# Under this runner that file is caught in phase 1, not believed in phase 2.
#
# THE HEADLINE IS NEVER "ALL GREEN". It is four numbers. A run with 9 passes
# and 3 CANNOT-RUN measured nine things and did not measure three, and an
# operator who reads that as "green" has been misled by the report, not by the
# box. So CANNOT-RUN is printed in its own block with the missing prerequisite
# named, every time.
#
# EXIT: 0 only when FAIL=0 and BROKEN=0. CANNOT-RUN does not fail the run --
# it is a coverage statement, not a defect -- but it is always shown.
#
# BASH 3.2 (macOS system bash). No associative arrays, no mapfile.
# ============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_DIR="$HERE/probes"

EX_CANNOT_RUN=78

ONLY=""
LIST_ONLY=0
SKIP_SELFTEST=0

while [ $# -gt 0 ]; do
    case "$1" in
        --only) ONLY="${2:-}"; shift 2 ;;
        --list) LIST_ONLY=1; shift ;;
        --no-self-test)
            # Present so that a human debugging a single probe can bypass
            # phase 1. It prints a loud banner because a run without the
            # negative controls is exactly the kind of green this suite
            # exists to distrust.
            SKIP_SELFTEST=1; shift ;;
        -h|--help) sed -n '3,40p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1"; exit 2 ;;
    esac
done

if [ ! -d "$PROBE_DIR" ]; then
    printf 'FATAL: no probe directory at %s\n' "$PROBE_DIR"
    printf 'That is an empty suite, which would otherwise report a perfect score.\n'
    exit 2
fi

# Collect probes. nullglob so a non-matching glob yields nothing rather than a
# literal "*.sh" -- and an explicit count check below, because an empty list
# must be a hard failure and not a clean run.
#
# THIS GLOB IS THE WHOLE SUITE. A probe file that is not in PROBE_DIR does not
# exist as far as a box walk is concerned, however good it is, and nothing
# anywhere prints the names of files it skipped. people_seed_and_retrieval.sh
# spent its whole life one level up on exactly that basis: 735 lines, graded
# exit codes, the only assertion in the estate that semantic people search
# actually works, and eleven probes reported over the top of it every time.
shopt -s nullglob
PROBES=""
for f in "$PROBE_DIR"/*.sh; do
    b="$(basename "$f" .sh)"
    if [ -n "$ONLY" ]; then
        case "$b" in *"$ONLY"*) ;; *) continue ;; esac
    fi
    PROBES="$PROBES $f"
done
shopt -u nullglob

PROBE_COUNT=0
for _ in $PROBES; do PROBE_COUNT=$((PROBE_COUNT + 1)); done

if [ "$PROBE_COUNT" -eq 0 ]; then
    printf 'FATAL: 0 probes matched.\n'
    printf 'An empty suite passes every assertion it does not make. Refusing to report a result.\n'
    exit 2
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    printf 'BOX WALK PROBES (%s)\n\n' "$PROBE_COUNT"
    for p in $PROBES; do
        bash "$p" --describe 2>/dev/null || printf '%s: (no --describe)\n' "$(basename "$p" .sh)"
    done
    exit 0
fi

printf '============================================================\n'
printf 'BOX WALK -- %s probes\n' "$PROBE_COUNT"
if [ -n "${OSTLER_BOX_HOST:-}" ]; then
    printf 'TARGET: %s\n' "$OSTLER_BOX_HOST"
else
    printf 'TARGET: this machine (OSTLER_BOX_HOST unset)\n'
fi
printf '============================================================\n\n'

# -------------------------------------------------------------------------
# PHASE 1 -- negative controls. Try to make every probe fail.
# -------------------------------------------------------------------------
BROKEN_LIST=""
BROKEN=0

if [ "$SKIP_SELFTEST" -eq 1 ]; then
    printf '!! PHASE 1 SKIPPED (--no-self-test).\n'
    printf '!! No probe in this run has demonstrated it can return FAIL.\n'
    printf '!! Treat every PASS below as unverified.\n\n'
else
    printf -- '--- PHASE 1: negative controls (each probe must be able to FAIL) ---\n'
    for p in $PROBES; do
        b="$(basename "$p" .sh)"
        out="$(bash "$p" --self-test 2>&1)"
        rc=$?
        # THE EXIT CODE IS NOT THE ONLY SIGNAL, and reading it alone is how a
        # broken probe passes phase 1.
        #
        # probe_fail() and the contract's own refusals BOTH exit 1. So a probe
        # that reports a verdict without a denominator prints
        #   VERDICT: BROKEN -- <name> reported a verdict without calling
        #   probe_examined.
        # and exits 1, and an rc-only test counts that as "goes red on
        # known-bad input". The framework catches the fault, announces it, and
        # is then overruled by its own caller.
        #
        # Found 2026-08-20 by tripping it while writing fda_tick_can_import:
        # its self_test omitted probe_examined, the contract refused, and this
        # loop was about to award it an ok. Same class as CM051 #897, where the
        # swift namer and counter disagreed and the exit code was believed.
        #
        # No pipe into a short-circuiting consumer here: under pipefail that
        # inverts a successful match (#895). grep -q on a herestring is safe.
        if grep -q 'VERDICT: BROKEN' <<< "$out"; then
            printf '  BROKEN   %s  (self-test exited %s but its own output says BROKEN)\n' "$b" "$rc"
            printf '%s\n' "$out" | sed 's/^/             /'
            BROKEN_LIST="$BROKEN_LIST $b"
            BROKEN=$((BROKEN + 1))
        elif [ "$rc" -eq 1 ]; then
            printf '  ok       %s  (goes red on known-bad input)\n' "$b"
        else
            printf '  BROKEN   %s  (self-test returned %s, expected 1)\n' "$b" "$rc"
            printf '%s\n' "$out" | sed 's/^/             /'
            BROKEN_LIST="$BROKEN_LIST $b"
            BROKEN=$((BROKEN + 1))
        fi
    done
    printf '\n'
fi

# -------------------------------------------------------------------------
# PHASE 2 -- the real measurements.
# -------------------------------------------------------------------------
printf -- '--- PHASE 2: measurements ---\n'
PASS=0
FAIL=0
CANNOT=0
FAIL_LIST=""
CANNOT_LIST=""

# WHY A PROBE DID NOT RUN, NOT ONLY WHICH ONE DID NOT.
#
# lib/probe.sh's probe_cannot_run() prints
#     VERDICT: CANNOT-RUN -- <the missing prerequisite>
# and its own comment says it MUST name that prerequisite "so the operator can
# fix it rather than guess". The header of THIS file promises the same thing:
# "CANNOT-RUN is printed in its own block with the missing prerequisite named,
# every time". It was not. Only the basename reached CANNOT_LIST, and the
# reason was discarded here.
#
# MEASURED 2026-08-29 on walks/v1.0.50.tsv: 6 probes did not run, and no
# reason for any of them is recoverable -- not from the record, not from the
# summary. Dispositioning those six took a hand audit of four probe sources.
#
# bash 3.2 (macOS system bash) has no associative arrays, so the name/reason
# pairs go to a file rather than a map.
CANNOT_REASONS="$(mktemp)"
# WHY A PROBE FAILED, NOT ONLY WHICH ONE DID. The same defect as the block
# above, on the other verdict class: FAIL_LIST carried basenames and the
# VERDICT line was discarded here, so the summary an operator scrolls to and
# copies named the probe and not the finding. Recovering it costs a whole walk
# -- a published DMG, a box and a reset -- which is what assistant_answers_
# grounded cost across walks 9 and 10, red both times and undiagnosed both
# times.
FAIL_REASONS="$(mktemp)"
trap 'rm -f "$CANNOT_REASONS" "$FAIL_REASONS"' EXIT

for p in $PROBES; do
    b="$(basename "$p" .sh)"

    case " $BROKEN_LIST " in
        *" $b "*)
            printf '\n[%s]\n  SKIPPED -- probe failed its own negative control in phase 1.\n' "$b"
            continue
            ;;
    esac

    printf '\n[%s]\n' "$b"
    out="$(bash "$p" 2>&1)"
    rc=$?
    printf '%s\n' "$out" | sed 's/^/  /'

    if [ "$rc" -eq 0 ]; then
        PASS=$((PASS + 1))
    elif [ "$rc" -eq "$EX_CANNOT_RUN" ]; then
        CANNOT=$((CANNOT + 1)); CANNOT_LIST="$CANNOT_LIST $b"
        # Everything from the marker to the END of the probe's output is the
        # reason: probe_cannot_run() prints it last and exits immediately. A
        # reason can span lines ($detail is passed whole by several probes),
        # so this takes the tail rather than one line, then flattens it.
        _why="$(printf '%s\n' "$out" \
                | awk '/^VERDICT: CANNOT-RUN -- /{sub(/^VERDICT: CANNOT-RUN -- /, ""); f=1} f' \
                | tr '\n' ' ' | sed 's/  */ /g; s/ *$//')"
        # An unparseable reason is ANNOUNCED, never left blank. A blank here
        # would read as "no reason was given" when what it means is "this
        # probe exited 78 without going through probe_cannot_run", which is a
        # contract breach and a different problem entirely.
        [ -n "$_why" ] || _why="UNRECORDED -- exited ${EX_CANNOT_RUN} with no 'VERDICT: CANNOT-RUN --' line, so it bypassed probe_cannot_run and named no prerequisite"
        printf '%s\t%s\n' "$b" "$_why" >> "$CANNOT_REASONS"
    else
        FAIL=$((FAIL + 1)); FAIL_LIST="$FAIL_LIST $b"
        # Same extraction as CANNOT-RUN above: probe_fail() prints its detail
        # last and exits, and several probes pass a multi-line $detail, so take
        # the tail from the marker and flatten it.
        _why="$(printf '%s\n' "$out" \
                | awk '/^VERDICT: FAIL -- /{sub(/^VERDICT: FAIL -- /, ""); f=1} f' \
                | tr '\n' ' ' | sed 's/  */ /g; s/ *$//')"
        # Blank is ANNOUNCED, never left empty: a probe that exits non-zero
        # without a 'VERDICT: FAIL --' line bypassed probe_fail and asserted
        # nothing, which is a contract breach, not a finding without a reason.
        [ -n "$_why" ] || _why="UNRECORDED -- exited ${rc} with no 'VERDICT: FAIL --' line, so it bypassed probe_fail and named no finding"
        printf '%s\t%s\n' "$b" "$_why" >> "$FAIL_REASONS"
    fi
done

# -------------------------------------------------------------------------
# REPORT -- four numbers, never one.
# -------------------------------------------------------------------------
printf '\n============================================================\n'
printf 'RESULT\n'
printf '  PASS        %s\n' "$PASS"
printf '  FAIL        %s\n' "$FAIL"
printf '  CANNOT-RUN  %s\n' "$CANNOT"
printf '  BROKEN      %s\n' "$BROKEN"
printf '  ----------------\n'
printf '  of          %s probes\n' "$PROBE_COUNT"
printf '============================================================\n'

if [ -n "$FAIL_LIST" ]; then
    printf '\nFAILED:\n'
    for b in $FAIL_LIST; do printf '  %s\n' "$b"; done

    # A SEPARATE BLOCK, FOR THE SAME TWO REASONS AS THE ONE UNDER NOT MEASURED.
    #
    # post_walk_qa.sh parses the list above with an awk that accepts only
    # `^  [A-Za-z0-9._-]+$` and EXITS on the first line that is not a bare
    # probe name. A reason printed under each name would end that parse at the
    # first one and walks/<version>.tsv would carry a single failed_probe row,
    # silently dropping the rest. The blank line printf'd below terminates the
    # parse before this block starts, and this header does not contain the
    # string section_names() keys on ("FAILED:").
    #
    # CONSOLE ONLY. probe_fail details interpolate ${OSTLER_BOX_HOST}, store
    # URLs, ~/.ostler/... paths and record counts. walks/ is committed to a
    # PUBLIC repo -- which is why box_fp is a hash and why the record carries
    # names and never probe output. These belong in front of the operator
    # running the walk, and nowhere else.
    printf '\nWHAT EACH FAILURE FOUND (console only -- never written to walks/):\n'
    while IFS="$(printf '\t')" read -r _b _why; do
        [ -n "$_b" ] || continue
        printf '  %s\n      %s\n' "$_b" "$_why"
    done < "$FAIL_REASONS"
fi

if [ -n "$CANNOT_LIST" ]; then
    printf '\nNOT MEASURED (prerequisite absent -- this is coverage lost, not a pass):\n'
    for b in $CANNOT_LIST; do printf '  %s\n' "$b"; done

    # A SEPARATE BLOCK, AND THAT IS DELIBERATE -- DO NOT FOLD IT INTO THE ONE
    # ABOVE.
    #
    # post_walk_qa.sh parses the block above with an awk that accepts only
    # `^  [A-Za-z0-9._-]+$` and EXITS on the first line that is not a bare
    # probe name. Printing a reason underneath each name would end that parse
    # at the first one, so walks/<version>.tsv would carry a single
    # not_measured_probe row and silently drop the rest -- the exact blindness
    # this estate exists to prevent, reintroduced by the fix for it. The blank
    # line printf'd below terminates that parse before this block begins, and
    # this header does not contain the string it keys on.
    #
    # CONSOLE ONLY. These strings interpolate ${OSTLER_BOX_HOST}, $LOG_PATH,
    # ~/.ostler/... and in one case raw transport stderr. walks/ is committed
    # to a PUBLIC repo -- which is why box_fp is a hash and why the record
    # carries names and never probe output. Measured across the 90
    # probe_cannot_run call sites in 21 of 21 probes: the reasons are
    # saturated with operator paths and private addresses. They belong in
    # front of the operator running the walk, and nowhere else.
    printf '\nPREREQUISITES THAT WERE ABSENT (console only -- never written to walks/):\n'
    while IFS="$(printf '\t')" read -r _b _why; do
        [ -n "$_b" ] || continue
        printf '  %s\n      %s\n' "$_b" "$_why"
    done < "$CANNOT_REASONS"
fi

if [ -n "$BROKEN_LIST" ]; then
    printf '\nBROKEN (probe could not demonstrate a FAIL, so its result is not trusted):\n'
    for b in $BROKEN_LIST; do printf '  %s\n' "$b"; done
fi

if [ "$FAIL" -eq 0 ] && [ "$BROKEN" -eq 0 ] && [ "$CANNOT" -gt 0 ]; then
    printf '\nNOTE: nothing failed, but %s of %s probes did not run.\n' "$CANNOT" "$PROBE_COUNT"
    printf 'This is NOT a clean box walk. It is a partial one. Fix the prerequisites and re-run.\n'
fi

if [ "$FAIL" -gt 0 ] || [ "$BROKEN" -gt 0 ]; then
    exit 1
fi
exit 0
