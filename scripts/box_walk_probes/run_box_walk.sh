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
    else
        FAIL=$((FAIL + 1)); FAIL_LIST="$FAIL_LIST $b"
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
fi

if [ -n "$CANNOT_LIST" ]; then
    printf '\nNOT MEASURED (prerequisite absent -- this is coverage lost, not a pass):\n'
    for b in $CANNOT_LIST; do printf '  %s\n' "$b"; done
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
