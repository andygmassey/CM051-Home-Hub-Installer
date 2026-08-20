#!/usr/bin/env bash
#
# verify_swift_tests_ran.sh <xcodebuild-log>
#
# Reads an `xcodebuild test` log and answers ONE question: did the Swift suite
# actually run, and did it pass?
#
#   0  ran, met the declared floor, zero failures
#   1  ran and FAILED, or ran fewer tests than the floor
#   2  CANNOT-RUN -- the log does not contain a result line at all
#
# ============================================================================
# WHY THIS EXISTS AS A SEPARATE PREDICATE, RATHER THAN TRUSTING xcodebuild's rc
# ============================================================================
#
# 36 Swift test files sat in this repo carrying 283 passing tests and NOTHING
# ran them. They were not scored UNWIRED, because no register enumerated Swift
# at all: they were UNENUMERABLE, which prints as nothing rather than as a
# problem. That is the fourth population found the same week as three others,
# and the shape is always identical -- absence of a row reads exactly like
# absence of the thing.
#
# Wiring a runner fixes that once. It does not stay fixed, because there are
# two silent ways for the new gate to go green having proved nothing:
#
#   THE SUITE SHRINKS. Someone drops a file from the target, or a build setting
#   stops compiling a group, and 283 quietly becomes 12. xcodebuild exits 0.
#   Twelve passing tests and 283 passing tests print the same colour.
#
#   THE SUITE DOES NOT RUN AT ALL. A destination mismatch, a scheme rename, a
#   test bundle that fails to load: several of these produce a log with no
#   result line, and depending on the shape, an exit code that is not obviously
#   fatal. A run that executed ZERO tests is not a pass. It is the purest form
#   of the zero-denominator failure -- a verdict about a population nobody
#   looked at.
#
# So the floor is DECLARED, in a file next to the suite, and compared to what
# the log says actually executed. Same shape as the PII library's declared
# built-in count: a static property of the source, compared against a runtime
# property of the run.
#
# THE FLOOR IS A FLOOR, NOT AN EQUALITY. Adding tests must never fail the gate,
# or the gate taxes exactly the behaviour it exists to encourage. Removing them
# below the declared line must fail, loudly, and the fix is a deliberate edit to
# the declared number in the same commit that removes them.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

FLOOR_FILE_DEFAULT="gui/OstlerInstallerTests/.test-count-floor"

usage() {
    echo "usage: $0 <xcodebuild-log> [floor-file]" >&2
    echo "       $0 --self-test" >&2
    exit 2
}

# Parse the "Executed N tests, with M failures" line. xcodebuild prints it once
# per test bundle and once as a summary, so take the LAST one and be explicit
# that that is the choice being made.
verify() {
    local log="$1" floor_file="$2"

    [ -f "$log" ] || { echo "CANNOT-RUN: no log at '$log'" >&2; return 2; }

    local line
    line="$(grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$log" | tail -1)"
    if [ -z "$line" ]; then
        echo "CANNOT-RUN: the log has no 'Executed N tests' line." >&2
        echo "  Nothing was counted. This is not a verdict about the suite, it is" >&2
        echo "  the absence of one. Common causes: the scheme has no test action," >&2
        echo "  the destination did not resolve, or the test bundle failed to load." >&2
        return 2
    fi

    local executed failures
    executed="$(printf '%s' "$line" | sed -E 's/Executed ([0-9]+) tests?.*/\1/')"
    failures="$(printf '%s' "$line" | sed -E 's/.*with ([0-9]+) failures?.*/\1/')"

    local floor=0
    if [ -f "$floor_file" ]; then
        floor="$(grep -vE '^[[:space:]]*#' "$floor_file" | tr -dc '0-9')"
    fi
    [ -n "$floor" ] || floor=0

    echo "swift-tests: executed=$executed failures=$failures declared-floor=$floor"

    if [ "$executed" -eq 0 ]; then
        echo "FAIL: zero tests executed. A suite that runs nothing is not a pass." >&2
        return 1
    fi
    if [ "$failures" -ne 0 ]; then
        # NAME THEM HERE, in the same place that counted them.
        #
        # This used to say "See the log above" and the log above said nothing.
        # swift-tests run 32351291319 reported `executed=288 failures=1` and
        # never named the test, because the workflow's diagnostic grep was
        # `^Test Case .* failed` -- ANCHORED -- while this counter's pattern is
        # not. xcodebuild indents those lines, so the anchor matched zero while
        # the count matched one. The suite told us a test failed and refused to
        # say which, and I merged that PR on a re-run green having explained
        # only one of its two reds.
        #
        # No `^`. And no pipe into a short-circuiting consumer: `grep -c` must
        # read all input to count, so it cannot invert under pipefail (#895).
        local named
        named="$(grep -E "Test Case .* (failed|error)" "$log" | head -40)"
        if [ -n "$named" ]; then
            echo "FAIL: $failures test failure(s):" >&2
            printf '%s\n' "$named" | sed 's/^/    /' >&2
        else
            # THE TWO PATTERNS DISAGREE, and that is its own finding. One of
            # them is wrong about this log, and until we know which, neither
            # number can be trusted.
            echo "FAIL: $failures test failure(s), and NONE could be named." >&2
            echo "  The counter matched 'Executed N tests, with M failures' and the" >&2
            echo "  namer matched no 'Test Case ... failed' line in the same file." >&2
            echo "  Two patterns reading one artefact disagree. Do not treat either" >&2
            echo "  number as settled: read the uploaded swift-test-log artefact." >&2
        fi
        return 1
    fi
    if [ "$executed" -lt "$floor" ]; then
        echo "FAIL: the suite SHRANK. $executed executed, floor declares $floor." >&2
        echo "  Tests were removed from the target, or stopped being compiled into" >&2
        echo "  it. Both are silent under a plain green tick, which is why the" >&2
        echo "  floor exists. If the removal is deliberate, lower the number in" >&2
        echo "  $floor_file IN THE SAME COMMIT and say why." >&2
        return 1
    fi

    echo "  PASS -- $executed test(s) ran, none failed, floor of $floor met."
    return 0
}

# --- self-test ---------------------------------------------------------------
#
# The controls are the three ways this predicate could be wrong, not three
# variations of the way it is right. (4) is the one that matters most: a log
# with no result line must be CANNOT-RUN, never a quiet pass.
if [ "${1:-}" = "--self-test" ]; then
    p=0; f=0
    ok() { printf '  PASS  %s\n' "$1"; p=$((p+1)); }
    no() { printf '  FAIL  %s\n' "$1"; f=$((f+1)); }
    d="$(mktemp -d -t swifttests-XXXXXX)"; trap 'rm -rf "$d"' EXIT
    printf '283\n' > "$d/floor"

    printf 'noise\n\t Executed 283 tests, with 0 failures (0 unexpected) in 3.2 seconds\n' > "$d/green.log"
    verify "$d/green.log" "$d/floor" >/dev/null 2>&1
    [ $? -eq 0 ] && ok "(1) 283 executed, 0 failures, floor 283 -> 0" \
                 || no "(1) a healthy run did not pass"

    printf '\t Executed 283 tests, with 2 failures (0 unexpected) in 3.2 seconds\n' > "$d/red.log"
    verify "$d/red.log" "$d/floor" >/dev/null 2>&1
    [ $? -eq 1 ] && ok "(2) real failures -> 1" \
                 || no "(2) a failing run did not fail"

    # THE SHRINK CONTROL. All green, zero failures, and the suite lost 271 tests.
    printf '\t Executed 12 tests, with 0 failures (0 unexpected) in 0.2 seconds\n' > "$d/shrunk.log"
    verify "$d/shrunk.log" "$d/floor" >/dev/null 2>&1
    [ $? -eq 1 ] && ok "(3) suite shrank 283 -> 12 with 0 failures -> still 1" \
                 || no "(3) a shrunken suite passed, which is the whole defect"

    printf 'xcodebuild: error: could not resolve destination\n' > "$d/nolines.log"
    verify "$d/nolines.log" "$d/floor" >/dev/null 2>&1
    [ $? -eq 2 ] && ok "(4) no result line -> CANNOT-RUN 2, never a quiet pass" \
                 || no "(4) a log that counted nothing did not report CANNOT-RUN"

    printf '\t Executed 0 tests, with 0 failures (0 unexpected) in 0.0 seconds\n' > "$d/zero.log"
    verify "$d/zero.log" "$d/floor" >/dev/null 2>&1
    [ $? -eq 1 ] && ok "(5) zero executed with zero failures -> 1" \
                 || no "(5) an empty run passed"

    verify "$d/definitely-not-here.log" "$d/floor" >/dev/null 2>&1
    [ $? -eq 2 ] && ok "(6) missing log -> CANNOT-RUN 2" \
                 || no "(6) a missing log did not report CANNOT-RUN"

    # (8) and (9) ARE THE 32351291319 DEFECT. The failing test must be NAMED,
    # and xcodebuild INDENTS those lines -- which is exactly what defeated the
    # workflow's `^Test Case` anchor while this file's unanchored counter saw
    # the failure. So the fixture is indented on purpose.
    {
        printf "  Test Case '-[OstlerInstallerTests testLicenceDropAccepts]' started.\n"
        printf "  Test Case '-[OstlerInstallerTests testLicenceDropAccepts]' failed (0.004 seconds).\n"
        printf '\t Executed 288 tests, with 1 failure (0 unexpected) in 6.1 seconds\n'
    } > "$d/named.log"
    out="$(verify "$d/named.log" "$d/floor" 2>&1)"
    printf '%s' "$out" | grep -q 'testLicenceDropAccepts' \
        && ok "(8) an INDENTED failing test is NAMED, not just counted" \
        || no "(8) the failing test was counted and not named. That is run 32351291319 exactly: 'executed=288 failures=1' with nothing to act on. Output: ${out}"

    # (9) THE PATTERNS MUST BE CROSS-CHECKED. A count with no nameable line is
    # two patterns disagreeing about one file, and that must be said out loud
    # rather than passed off as "see the log above" when the log says nothing.
    printf '\t Executed 288 tests, with 1 failure (0 unexpected) in 6.1 seconds\n' > "$d/counted-only.log"
    out="$(verify "$d/counted-only.log" "$d/floor" 2>&1)"
    printf '%s' "$out" | grep -q 'NONE could be named' \
        && ok "(9) counted-but-unnameable is reported as the patterns disagreeing" \
        || no "(9) a failure count with no nameable line was not flagged as a disagreement. Output: ${out}"

    # A run ABOVE the floor must pass: the floor must not tax adding tests.
    printf '\t Executed 400 tests, with 0 failures (0 unexpected) in 4.0 seconds\n' > "$d/grew.log"
    verify "$d/grew.log" "$d/floor" >/dev/null 2>&1
    [ $? -eq 0 ] && ok "(7) suite GREW to 400 -> 0, the floor is a floor" \
                 || no "(7) adding tests failed the gate"

    echo
    echo "=== $p passed / $f failed ==="
    [ "$f" -eq 0 ]; exit $?
fi

[ $# -ge 1 ] || usage
verify "$1" "${2:-$FLOOR_FILE_DEFAULT}"
exit $?
