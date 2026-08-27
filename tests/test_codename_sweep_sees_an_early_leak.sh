#!/usr/bin/env bash
# The CM0NN/HR0NN/OS0NN codename sweep must see a leak on line 1.
#
# THE DEFECT. test_v1_sweep_install_gating.sh sets `set -euo pipefail` and swept
# rendered customer copy with:
#
#     if grep -vE '"_meta"' "$jf" | grep -Eq '(CM|HR|OS)0[0-9]{2,3}'; then
#         failure "... a codename survives in a rendered value ..."
#     fi
#
# `grep -q` exits on its FIRST match, so `grep -v` dies of SIGPIPE and pipefail
# promotes that to a non-zero pipeline status. The `if` reads false and
# `failure` is NEVER CALLED -- a codename that IS present reports as absent.
#
# This is the silent-green direction. There is no error, no output, and the
# gate goes green while the leak ships in customer-visible copy.
#
# MEASURED, not theorised: a 27,681-byte copy file with a codename on line 1
# returns rc=141. The threshold is small -- around 24KB for this shape -- so it
# is NOT a "big file" problem, and the real ViewCopy.json is already 35,375 B.
#
# WHY THE EARLY POSITION MATTERS. The later the match, the more of the producer
# has already drained, so a leak near the END of a file is caught while a leak
# near the TOP is missed. A predicate whose answer depends on WHERE in the file
# the defect sits is worse than one that always fails.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$REPO_ROOT/tests/test_v1_sweep_install_gating.sh"
FAILED=0

fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

if [[ ! -f "$SWEEP" ]]; then
    echo "FAIL [sweep-missing]: $SWEEP not found -- nothing was checked. NOT a pass." >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- fixture: rendered copy with a codename on the FIRST line -------------
JF="$WORK/ViewCopy.json"
{
    echo '  "leaked_subtitle": "Evernote ingest (CM024) is ready",'
    i=0
    while [[ $i -lt 20000 ]]; do
        echo "  \"filler_key_$i\": \"ordinary customer copy with no codename in it at all\","
        i=$((i + 1))
    done
} > "$JF"

JF_BYTES=$(wc -c < "$JF" | tr -d ' ')
if [[ "$JF_BYTES" -lt 500000 ]]; then
    fail "fixture-too-small" "fixture is $JF_BYTES bytes; the inversion starts around 24KB and is MARGINAL there, so this test uses a large fixture to make the blindness reliably reachable rather than flaky"
fi

# ---- 1. the OLD shape must MISS it (proves the fixture reproduces) --------
# This is a RACE, so one sample is not evidence. Take several and report how
# many inverted. Note `set -e` is deliberately NOT used inside this subshell:
# with -e the shell exits on the non-zero pipeline BEFORE `echo $?` runs, and
# the captured value is EMPTY -- which then compares unequal to "0" and the
# assertion passes for entirely the wrong reason. That happened while writing
# this test.
INVERTED=0
SAMPLES=5
for _s in $(seq 1 $SAMPLES); do
    rc=$( set -uo pipefail
          grep -vE '"_meta"' "$JF" | grep -Eq '(CM|HR|OS)0[0-9]{2,3}'
          echo $? )
    if [[ -z "$rc" ]]; then
        fail "probe-broken" "the old-shape probe captured an EMPTY status; it measured nothing"
        break
    fi
    [[ "$rc" != "0" ]] && INVERTED=$((INVERTED + 1))
done
if [[ "$INVERTED" -eq 0 ]]; then
    fail "fixture-does-not-race" "the OLD piped shape found the codename in all $SAMPLES samples at $JF_BYTES bytes, so this fixture does not reproduce the defect and every assertion below is vacuous"
else
    pass "fixture reproduces the blindness: old shape missed a line-1 codename in $INVERTED of $SAMPLES samples"
fi

# ---- 2. the fixed shape must FIND it --------------------------------------
# The fix is `grep -c`, which consumes ALL of its input, so nothing takes
# EPIPE. Routing through `printf | grep -q` is NOT a fix: with multi-line
# content the read still exits early and it races exactly the same way. It
# returned 0 at 33KB and 141 at 60KB while this was being written, which is
# the signature of a race, not of a safe construct.
HITS="$(grep -vE '"_meta"' "$JF" | grep -cE '(CM|HR|OS)0[0-9]{2,3}')"
if [[ "${HITS:-0}" -lt 1 ]]; then
    fail "fixed-shape-blind" "the count form found $HITS hits; it must be at least 1 because CM024 is on line 1"
else
    pass "count form finds the line-1 codename ($HITS hit) with no dependence on position"
fi

# ---- 3. clean copy must still be clean (the fix must not cry wolf) --------
CLEAN="$WORK/Clean.json"
grep -vE 'CM024' "$JF" > "$CLEAN"
CLEAN_HITS="$(grep -vE '"_meta"' "$CLEAN" | grep -cE '(CM|HR|OS)0[0-9]{2,3}')"
if [[ "${CLEAN_HITS:-1}" -ne 0 ]]; then
    fail "false-positive" "copy with no codename counted $CLEAN_HITS hits; it must be 0, or the fix flags everything"
else
    pass "copy with no codename counts 0 (no false positive)"
fi

# ---- 4. the sweep must not carry the piped shape --------------------------
if [[ "$(grep -cE "grep -vE '\"_meta\"' \"\\\$jf\" \| grep -Eq" "$SWEEP")" -gt 0 ]]; then
    fail "shape-present" "test_v1_sweep_install_gating.sh still pipes grep -v into grep -Eq"
else
    pass "test_v1_sweep_install_gating.sh no longer pipes grep -v into grep -Eq"
fi

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi
echo
echo "ALL CODENAME SWEEP VISIBILITY TESTS PASSED"
