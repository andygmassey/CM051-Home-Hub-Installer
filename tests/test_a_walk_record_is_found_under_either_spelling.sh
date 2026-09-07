#!/usr/bin/env bash
#
# tests/test_a_walk_record_is_found_under_either_spelling.sh
#
# CM051 #1744. `post_walk_qa.sh:362` names the record from the string it was
# TOLD. `verify_walk_record.sh` rebuilt the path from ITS OWN caller's argument
# and string-compared the version field. Nothing normalised the leading `v`, so
# a walk filed as `1.0.71` was invisible to a gate asked about `v1.0.71` and the
# gate said
#
#     [walk-gate] NO WALK RECORD for v1.0.71.
#
# about a walk that had happened. It has happened for real: two records for one
# release, 13 minutes apart, `walks/1.0.71.tsv` and `walks/v1.0.71.tsv`.
#
# The failure direction is safe -- it refuses to promote rather than promoting
# something bad -- so the cost is a wasted WALK CYCLE, which is the most
# expensive thing in this pipeline, plus a message that reads as "the walk never
# happened" rather than "I looked under the other name".
#
# ARM 3 IS THE ONE THAT KEEPS THIS HONEST. Widening a search is one character
# away from breaking the check it lives in: the gate exists so that "a stale
# v1.0.38 record would not clear the gate for a build it never touched". A
# record of a genuinely DIFFERENT version must still be refused.
#
# Exit 0 all pass / 1 a check failed / 2 could not run.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${HERE}/../scripts/verify_walk_record.sh"
LIB="${HERE}/../scripts/lib_walk_version_key.sh"

[[ -f "$GATE" ]] || { echo "CANNOT-RUN: no gate at ${GATE} (exit 2)" >&2; exit 2; }
[[ -f "$LIB"  ]] || { echo "CANNOT-RUN: no lib at ${LIB} (exit 2)" >&2; exit 2; }
# shellcheck source=scripts/lib_walk_version_key.sh
source "$LIB"

SHA64="$(printf 'a%.0s' $(seq 1 64))"

_fails=0; _total=0
ok()  { _total=$((_total+1)); printf '  ok    %s\n' "$1"; }
bad() { _total=$((_total+1)); _fails=$((_fails+1)); printf '  FAIL  %s\n' "$1"; }

mkrec() { # <dir> <filename-version> <version-field>
    mkdir -p "$1"
    printf 'version\t%s\n' "$3" > "$1/$2.tsv"
}

run_gate() { # <walkdir> <asked-version> -> stdout+stderr
    OSTLER_WALK_RECORD_DIR="$1" bash "$GATE" "$2" "$SHA64" 2>&1
}

echo "the key predicate"
[ "$(walk_version_key v1.0.73)" = "1.0.73" ] && ok "1 v1.0.73 keys to 1.0.73" || bad "1 key wrong"
[ "$(walk_version_key vane)"    = "vane"   ] && ok "2 'vane' is untouched (v not followed by a digit)" || bad "2 mangled a non-version"

# 3. THE GATE MUST STILL REFUSE A DIFFERENT VERSION. Run FIRST, because a
#    widened search that broke this would make every later arm meaningless.
D3="$(mktemp -d "${TMPDIR:-/tmp}/wr3.XXXXXX")"
mkrec "$D3" "v1.0.73" "v1.0.72"
_out3="$(run_gate "$D3" "v1.0.73")"
if grep -q 'is a record of' <<< \"$_out3\"; then
    ok "3 a record of a DIFFERENT version is still REFUSED"
else
    bad "3 a record of v1.0.72 was accepted for v1.0.73 -- the check was loosened"
fi
rm -rf "$D3"

echo "either spelling"
# 4. filed WITHOUT the v, asked WITH it
D4="$(mktemp -d "${TMPDIR:-/tmp}/wr4.XXXXXX")"
mkrec "$D4" "1.0.73" "1.0.73"
_out4="$(run_gate "$D4" "v1.0.73")"
if grep -q 'NO WALK RECORD' <<< \"$_out4\"; then
    bad "4 filed as 1.0.73, asked as v1.0.73 -> still NO WALK RECORD"
else
    ok "4 filed as 1.0.73, asked as v1.0.73 -> record found"
fi
if grep -q 'is a record of' <<< \"$_out4\"; then
    bad "5 the version field 1.0.73 was rejected for v1.0.73"
else
    ok "5 the version field is accepted across the spelling"
fi
rm -rf "$D4"

# 6. filed WITH the v, asked WITHOUT it
D6="$(mktemp -d "${TMPDIR:-/tmp}/wr6.XXXXXX")"
mkrec "$D6" "v1.0.73" "v1.0.73"
_out6="$(run_gate "$D6" "1.0.73")"
if grep -q 'NO WALK RECORD' <<< \"$_out6\"; then
    bad "6 filed as v1.0.73, asked as 1.0.73 -> still NO WALK RECORD"
else
    ok "6 filed as v1.0.73, asked as 1.0.73 -> record found"
fi
rm -rf "$D6"

# 7. genuinely absent must STILL say NO WALK RECORD, and name BOTH spellings.
#    Widening a search must not invent a record.
D7="$(mktemp -d "${TMPDIR:-/tmp}/wr7.XXXXXX")"
mkdir -p "$D7"
_out7="$(run_gate "$D7" "v1.0.73")"
if grep -q 'NO WALK RECORD' <<< \"$_out7\"; then
    if grep -q '/1.0.73.tsv' <<< \"$_out7\" && grep -q '/v1.0.73.tsv' <<< \"$_out7\"; then
        ok "7 a missing record still refuses, and names BOTH paths tried"
    else
        bad "7 refused but did not name both spellings -- the message still reads as 'never happened'"
    fi
else
    bad "7 an ABSENT record did not produce NO WALK RECORD"
fi
rm -rf "$D7"

# 8. BOTH spellings present must REFUSE, not pick. Widening the search created
#    this hazard: before the change, asking for v1.0.73 could only read
#    v1.0.73.tsv. #1744 saw two records for one release 13 minutes apart with
#    DIFFERENT content, so choosing either makes the verdict depend on how the
#    caller typed the version.
D8="$(mktemp -d "${TMPDIR:-/tmp}/wr8.XXXXXX")"
mkrec "$D8" "v1.0.73" "v1.0.73"
mkrec "$D8" "1.0.73"  "1.0.73"
_out8="$(run_gate "$D8" "v1.0.73")"
if grep -q 'AMBIGUOUS' <<< \"$_out8\"; then
    ok "8 both spellings present -> REFUSED as ambiguous, not silently picked"
else
    bad "8 both spellings present -> the gate chose one instead of refusing"
fi
rm -rf "$D8"

echo
if [[ $_fails -eq 0 ]]; then echo "PASS: ${_total}/${_total}"; exit 0; fi
echo "FAIL: ${_fails} of ${_total}"; exit 1
