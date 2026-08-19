#!/usr/bin/env bash
# test_comment_strip_is_quote_aware.sh
# ============================================================================
# CONTROLS FOR scripts/lib/strip_comments.sh
#
# The stripper decides what the wiring gates are allowed to see. Get it wrong
# in one direction and a real invocation disappears (false RED, noisy). Get it
# wrong in the other and a COMMENT becomes an invocation (false GREEN), which
# is #688 rebuilt by hand.
#
# So these arms come in two families and BOTH are load-bearing:
#
#   arms 1,2,5,7  the fix. A `#` inside a quoted string is not a comment.
#                 RED BEFORE THE FIX: the old `sed 's/#.*$//'` truncates.
#   arms 3,4,6,8  the bias. Real comments still die, and an ambiguous line
#                 strips MORE, never less.
#
# Arm 9 is the one that stops the rest being decorative: it asserts the OLD
# implementation actually disagrees on the fix arms. Without it, arms 1/2/5/7
# could pass against a stripper that does nothing at all, and nobody would
# know the test never had the power to fail.
#
# The library is SOURCED, not reimplemented. A test that carries its own copy
# of the thing it tests passes happily while the shipped copy rots.
# ============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${HERE}/scripts/lib/strip_comments.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; printf '        expected: [%s]\n        actual:   [%s]\n' "$2" "$3"; }

if [ ! -r "$LIB" ]; then
    echo "CANNOT-RUN: cannot read $LIB. Nothing was checked; this is not a pass." >&2
    exit 3
fi
# shellcheck source=../lib/strip_comments.sh
. "$LIB"
if ! command -v strip_comments_file >/dev/null 2>&1; then
    echo "CANNOT-RUN: $LIB did not define strip_comments_file. Nothing was checked." >&2
    exit 3
fi

TMP="$(mktemp -d -t stripctl_XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# strip_line <text> -> stripped text, via the real file-based entry point
strip_line() {
    printf '%s\n' "$1" > "${TMP}/line"
    strip_comments_file "${TMP}/line"
}

# old_strip_line <text> -> what #857/#858 shipped, kept ONLY so arm 9 can
# prove the new arms are not vacuous.
old_strip_line() {
    printf '%s\n' "$1" > "${TMP}/oldline"
    sed 's/#.*$//' "${TMP}/oldline"
}

expect() {  # expect <label> <input> <expected output>
    local label="$1" in="$2" want="$3" got
    got="$(strip_line "$in")"
    if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "$want" "$got"; fi
}

echo "controls for strip_comments_file"
echo ""

# ── THE FIX ────────────────────────────────────────────────────────────────
# Archie's exact example from the #857 merge review.
expect "1  # inside DOUBLE quotes is not a comment" \
    'run: echo "a#b" && bash scripts/tests/test_thing.sh' \
    'run: echo "a#b" && bash scripts/tests/test_thing.sh'

expect "2  # inside SINGLE quotes is not a comment" \
    "run: grep '#!/bin/sh' f && bash scripts/tests/test_thing.sh" \
    "run: grep '#!/bin/sh' f && bash scripts/tests/test_thing.sh"

# The case that defeats a naive quote-tracker: the apostrophe in "don't" opens
# a quote that never closes, but it sits AFTER the comment marker, so scanning
# must already have stopped.
expect "5  trailing comment containing an apostrophe still strips" \
    "bash scripts/tests/test_thing.sh   # don't wire test_other.sh" \
    "bash scripts/tests/test_thing.sh   "

expect "7  escaped quote inside double quotes does not end the string" \
    'echo "he said \"a#b\"" && bash t.sh' \
    'echo "he said \"a#b\"" && bash t.sh'

# ── THE BIAS ───────────────────────────────────────────────────────────────
expect "3  ordinary trailing comment is stripped" \
    'bash scripts/tests/test_thing.sh  # not this one' \
    'bash scripts/tests/test_thing.sh  '

expect "4  whole-line comment is stripped to nothing" \
    '# bash scripts/tests/test_thing.sh' \
    ''

# THE ARM THAT PROTECTS AGAINST A FALSE GREEN.
# An unterminated quote makes the quote analysis untrustworthy. The stripper
# must fall back to the blunt cut rather than trusting itself, because
# trusting itself here turns a comment into an invocation.
expect "6  UNBALANCED quote falls back to the aggressive cut" \
    'echo "unclosed    # bash scripts/tests/test_thing.sh' \
    'echo "unclosed    '

expect "8  no # at all leaves the line untouched" \
    'run: bash scripts/tests/test_thing.sh' \
    'run: bash scripts/tests/test_thing.sh'

# ── ARM 9: THE ARMS ABOVE ARE NOT VACUOUS ──────────────────────────────────
# Prove the OLD stripper disagrees on every fix arm. If this arm ever fails,
# the fix arms have stopped discriminating and are no longer evidence of
# anything.
echo ""
NOT_VACUOUS=0
for fixture in \
    'run: echo "a#b" && bash scripts/tests/test_thing.sh' \
    "run: grep '#!/bin/sh' f && bash scripts/tests/test_thing.sh" \
    'echo "he said \"a#b\"" && bash t.sh'
do
    new="$(strip_line "$fixture")"
    old="$(old_strip_line "$fixture")"
    if [ "$new" != "$old" ]; then
        NOT_VACUOUS=$((NOT_VACUOUS + 1))
    else
        printf '  FAIL  9  old and new agree on a fix fixture, so it proves nothing: [%s]\n' "$fixture"
        FAIL=$((FAIL + 1))
    fi
done
if [ "$NOT_VACUOUS" -eq 3 ]; then
    ok "9  all 3 fix fixtures are RED under the pre-fix stripper (${NOT_VACUOUS}/3)"
fi

# ── ARM 10: line count is preserved ────────────────────────────────────────
printf 'a\n# b\nc "d#e"\n' > "${TMP}/multi"
LINES_IN=3
LINES_OUT="$(strip_comments_file "${TMP}/multi" | wc -l | tr -d ' ')"
if [ "$LINES_OUT" = "$LINES_IN" ]; then
    ok "10 one line in, one line out (${LINES_OUT}/${LINES_IN})"
else
    bad "10 line count preserved" "$LINES_IN" "$LINES_OUT"
fi

echo ""
echo "passed: ${PASS}   failed: ${FAIL}"

# FLOOR. A run that checked nothing must not report success -- the exact defect
# found in my own self-test while reading the #218 log.
EXPECTED_ARMS=10
if [ "$((PASS + FAIL))" -lt "$EXPECTED_ARMS" ]; then
    echo "CANNOT-RUN: only $((PASS + FAIL)) of ${EXPECTED_ARMS} arms executed. Not a pass." >&2
    exit 3
fi

[ "$FAIL" -eq 0 ] || exit 1
exit 0
