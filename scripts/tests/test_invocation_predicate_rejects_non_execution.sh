#!/usr/bin/env bash
# test_invocation_predicate_rejects_non_execution.sh
# ============================================================================
# CONTROLS FOR is_invoked_in_corpus() in scripts/lib/strip_comments.sh
#
# That one function decides, for BOTH wiring gates, whether a critical test is
# still being RUN. #860 deliberately made the two share it so they cannot drift
# into disagreeing about what "invoked" means. The cost of sharing is that a
# weakness in it is now duplicated by construction, so it needs its own
# controls rather than being exercised only indirectly.
#
# TWO FALSE GREENS THIS PINS, both mine from #858, both measured on the real
# tree before the fix was written:
#
#   `bash -n tests/x.sh`  is a PARSE. It never runs the file. It already sits
#                         in hydrate-sentinel.yml beside three of the five
#                         register entries, so deleting the real invocation
#                         left the gate saying "ALL CRITICAL TESTS STILL
#                         INVOKED" at exit 0.
#
#   `echo "shipping ..."` matched because the verb alternation was unanchored,
#                         so the `sh` inside "shipping" counted as a shell.
#
# THE ARMS COME IN TWO FAMILIES AND BOTH ARE LOAD-BEARING:
#
#   POSITIVE  real invocations must still count. Without these, a predicate
#             that rejects EVERYTHING passes the whole file, and the register
#             goes permanently and silently red until someone deletes it.
#             Arms 2 and 5 are the ones a naive fix breaks.
#
#   NEGATIVE  the two false greens above, plus the mention-shaped lines the
#             gates existed to reject in the first place.
#
# Arm 11 is what stops the negative arms being decorative: it asserts the OLD
# predicate ACCEPTED the two fixture lines the fix now rejects. If that ever
# stops being true, these arms have lost their power to fail and are no longer
# evidence of anything.
# ============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${HERE}/scripts/lib/strip_comments.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         wanted %s\n' "$1" "$2"; }

if [ ! -r "$LIB" ]; then
    echo "CANNOT-RUN: cannot read $LIB. Nothing was checked; this is not a pass." >&2
    exit 3
fi
# shellcheck source=../lib/strip_comments.sh
. "$LIB"
if ! command -v is_invoked_in_corpus >/dev/null 2>&1; then
    echo "CANNOT-RUN: $LIB did not define is_invoked_in_corpus. Nothing was checked." >&2
    exit 3
fi

TMP="$(mktemp -d -t invpred_XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

TESTPATH="scripts/tests/test_thing.sh"

# verdict <corpus-line> -> INVOKED | DARK
verdict() {
    printf '%s\n' "$1" > "${TMP}/corpus"
    if is_invoked_in_corpus "$TESTPATH" "${TMP}/corpus"; then echo INVOKED; else echo DARK; fi
}

# The pre-#861 predicate, kept ONLY so arm 11 can prove the fix arms are not
# vacuous. Do not "tidy" this into the shipped one.
old_verdict() {
    printf '%s\n' "$1" > "${TMP}/oldcorpus"
    if grep -E "(bash|sh|pytest|python3 -m|\./)[^#]*($(printf '%s' "$TESTPATH" | sed 's/[.[\*^$/]/\\&/g')|$(printf '%s' "$(basename "$TESTPATH")" | sed 's/[.[\*^$/]/\\&/g'))" \
        "${TMP}/oldcorpus" >/dev/null 2>&1; then echo INVOKED; else echo DARK; fi
}

expect() { # expect <label> <line> <INVOKED|DARK>
    local label="$1" line="$2" want="$3" got
    got="$(verdict "$line")"
    if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "$want, got $got"; fi
}

echo "controls for is_invoked_in_corpus"
echo ""

# ── POSITIVE: real invocations must still count ────────────────────────────
expect "1  plain 'bash <path>' is an invocation" \
    "        run: bash ${TESTPATH}" INVOKED

# The form a naive anchor breaks. Two of the five register entries use it.
expect "2  PATH-PREFIXED '/bin/bash <path>' is an invocation" \
    "        run: /bin/bash ${TESTPATH}" INVOKED

expect "3  './<path>' is an invocation" \
    "          ./${TESTPATH}" INVOKED

expect "4  'python3 -m pytest <path>' is an invocation" \
    "        run: python3 -m pytest ${TESTPATH}" INVOKED

# The exclusion below is scoped to shells on purpose. pytest -n is xdist.
expect "5  'pytest -n 4 <path>' is an invocation, -n is not a parse here" \
    "        run: pytest -n 4 ${TESTPATH}" INVOKED

expect "6  a later invocation on the line still counts" \
    "        run: echo ${TESTPATH} && bash ${TESTPATH}" INVOKED

# ── NEGATIVE: the two false greens, and the mention shapes ─────────────────
expect "7  'bash -n <path>' is a PARSE, not a run" \
    "          bash -n ${TESTPATH}" DARK

expect "8  'sh' inside an English word is not a shell" \
    "        run: echo \"shipping notes about ${TESTPATH}\"" DARK

expect "9  'shellcheck <path>' is static analysis, not a run" \
    "        run: shellcheck ${TESTPATH}" DARK

expect "10 a paths: trigger entry is not an invocation" \
    "      - '${TESTPATH}'" DARK

# ── ARM 11: THE NEGATIVE ARMS ARE NOT VACUOUS ─────────────────────────────
echo ""
NOT_VACUOUS=0
VACUITY_FIXTURES=(
    "          bash -n ${TESTPATH}"
    "        run: echo \"shipping notes about ${TESTPATH}\""
)
for fixture in "${VACUITY_FIXTURES[@]}"; do
    if [ "$(old_verdict "$fixture")" = "INVOKED" ] && [ "$(verdict "$fixture")" = "DARK" ]; then
        NOT_VACUOUS=$((NOT_VACUOUS + 1))
    else
        printf '  FAIL  11 fixture no longer discriminates old vs new: [%s]\n' "$fixture"
        FAIL=$((FAIL + 1))
    fi
done
if [ "$NOT_VACUOUS" -eq "${#VACUITY_FIXTURES[@]}" ]; then
    ok "11 both false-green fixtures were INVOKED under the OLD predicate (${NOT_VACUOUS}/${#VACUITY_FIXTURES[@]})"
fi

echo ""
echo "passed: ${PASS}   failed: ${FAIL}"

# FLOOR. A run that checked nothing must not report success.
EXPECTED_ARMS=11
if [ "$((PASS + FAIL))" -lt "$EXPECTED_ARMS" ]; then
    echo "CANNOT-RUN: only $((PASS + FAIL)) of ${EXPECTED_ARMS} arms executed. Not a pass." >&2
    exit 3
fi

[ "$FAIL" -eq 0 ]
