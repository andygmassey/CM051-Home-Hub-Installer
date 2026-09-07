#!/usr/bin/env bash
#
# tests/test_identity_mismatch_shows_the_difference.sh
#
# ttywalk's identity refusal printed two strings that render IDENTICALLY.
#
# 🔴 THE EXAMPLE NAME IS DELIBERATELY GENERIC. CM051 is a PUBLIC repo and
# bin/pii_name_guard.py refuses a real person's name anywhere in the tree --
# it caught my first draft, which used the operator's actual ComputerName
# because that is what the bug was found on. Do NOT restore it for realism:
# the defect is the apostrophe, not whose Mac it is.
#
# MEASURED 2026-09-07. The walk box's ComputerName carries U+2019 (curly
# apostrophe, bytes e2 80 99). ttywalk.sh's own usage example carries U+0027
# (straight, byte 27) -- confirmed with `od -c` on the doc line. Copy the
# documented example and the walk refuses with:
#
#     IDENTITY MISMATCH. Expected ComputerName 'Studio's Mac mini',
#     the host at <host> answers 'Studio's Mac mini'. DHCP moves this address.
#
# Both quoted strings look the same, and the next sentence blames DHCP, which
# sends the operator to the network -- the one place the fault is not. It cost a
# real walk attempt.
#
# 🗿 A REFUSAL THAT CANNOT BE ACTED ON GETS WORKED AROUND. Same failure mode as
# a gate that cannot go green: the operator stops believing the instrument.
#
# ARM 4 IS THE LOAD-BEARING ONE: it asserts the hint actually NAMES the bytes.
# A hint that said only "these differ" would pass a weaker test and still leave
# the operator with nothing to act on.
#
# Exit 0 pass / 1 a check failed / 2 could not run.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../scripts/lib_identity_lookalike.sh"
WALK="${HERE}/../scripts/ttywalk.sh"

[[ -f "$LIB" ]] || { echo "CANNOT-RUN: no lib at ${LIB} (exit 2)" >&2; exit 2; }
# shellcheck source=scripts/lib_identity_lookalike.sh
source "$LIB"

for _fn in identity_lookalike_verdict identity_bytes identity_mismatch_hint; do
    declare -F "$_fn" >/dev/null || { echo "CANNOT-RUN: ${LIB} lacks ${_fn}() (exit 2)" >&2; exit 2; }
done

CURLY="Studio$(printf '\342\200\231')s Mac mini"
STRAIGHT="Studio's Mac mini"

_fails=0; _total=0
arm() {
    local _n="$1" _want="$2" _got="$3"
    _total=$((_total + 1))
    if [ "$_want" = "$_got" ]; then printf '  ok    %s\n' "$_n"
    else printf '  FAIL  %s (wanted %s, got %s)\n' "$_n" "$_want" "$_got"; _fails=$((_fails + 1)); fi
}

echo "identity look-alike verdicts"
arm "1 curly vs straight is LOOKALIKE"        LOOKALIKE "$(identity_lookalike_verdict "$CURLY" "$STRAIGHT")"
arm "2 a string equals itself"                IDENTICAL "$(identity_lookalike_verdict "$CURLY" "$CURLY")"
arm "3 a real mismatch is DIFFERENT"          DIFFERENT "$(identity_lookalike_verdict "$CURLY" "a completely different host")"

# 4. THE POINT. The hint must name the BYTES, not merely say they differ.
_hint="$(identity_mismatch_hint "$CURLY" "$STRAIGHT")"
_total=$((_total + 1))
# The FULL computed sequence, not the substring 'e2 80 99' -- that substring
# also appears in the hint's own explanatory sentence, so checking for it alone
# passed even with the byte dump redacted. Caught by mutation, not by reading.
_want_e="$(identity_bytes "$CURLY")"
_want_a="$(identity_bytes "$STRAIGHT")"
if grep -qF "$_want_e" <<< "$_hint" && grep -qF "$_want_a" <<< "$_hint"; then
    printf '  ok    4 the hint prints BOTH FULL computed byte sequences\n'
else
    printf '  FAIL  4 the hint does not name the differing bytes\n'
    _fails=$((_fails + 1))
fi

# 5. and it must say the DHCP explanation is wrong here, since that is what
#    misdirected the operator.
_total=$((_total + 1))
if grep -qi 'NOT a DHCP' <<< "$_hint"; then
    printf '  ok    5 the hint contradicts the misleading DHCP sentence above it\n'
else
    printf '  FAIL  5 the hint leaves the DHCP misdirection unanswered\n'
    _fails=$((_fails + 1))
fi

# 6. a GENUINE mismatch must NOT claim look-alike punctuation -- that would be a
#    false explanation, which is worse than none.
_total=$((_total + 1))
_out_diff="$(identity_mismatch_hint "$CURLY" "a completely different host")"
if ! grep -qi 'LOOK-ALIKE' <<< "$_out_diff"; then
    printf '  ok    6 a genuine mismatch is not mislabelled as look-alike\n'
else
    printf '  FAIL  6 a genuine mismatch claimed look-alike punctuation\n'
    _fails=$((_fails + 1))
fi

# 7. ttywalk must actually CALL it, at both identity sites.
_total=$((_total + 1))
if [ -f "$WALK" ] && [ "$(grep -c 'identity_mismatch_hint "' "$WALK")" -ge 2 ]; then
    printf '  ok    7 ttywalk.sh calls the hint at both identity sites\n'
else
    printf '  FAIL  7 ttywalk.sh does not call identity_mismatch_hint twice\n'
    _fails=$((_fails + 1))
fi

echo
if [ "$_fails" -eq 0 ]; then echo "PASS: ${_total}/${_total}"; exit 0; fi
echo "FAIL: ${_fails} of ${_total}"; exit 1
