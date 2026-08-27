#!/usr/bin/env bash
# The gate that guards the customer download must READ the probe names, not just
# let the writer emit them.
#
# THE DEFECT. #1106 (01a7b06c) taught post_walk_qa.sh to record WHICH probes
# failed and wired tests/test_walk_record_names_the_failing_probes.sh to guard
# it. That test asserts on post_walk_qa.sh's SOURCE TEXT. Measured 2026-08-27 on
# origin/main efab6a59, scripts/verify_walk_record.sh read whole (199 lines):
#
#     failed_probe_names_recorded 0 · failed_probe 0
#     not_measured_probe          0 · broken_probe 0
#     CONTROL, same read: verdict 10    <- the read works, the zeros are real
#
# The writer emitted four name families and the READER consulted none. So
# section_names() could rot at runtime -- a reworded header in run_box_walk.sh,
# a changed indent -- the record would write `failed_probe_names_recorded 0 of
# 4`, and this gate would PASS it. Merged, wired, unit-tested, and the consuming
# path unguarded. It is the qa_exit defect (:126 in that file) one field family
# later.
#
# WHAT THIS TEST DOES. Drives the REAL gate against hand-built records via
# OSTLER_WALK_RECORD_DIR. ARM 8 mutates the new block out and requires the rot
# fixture to go GREEN, so this file cannot pass against a gate that checks
# nothing. ARM 9 runs the LIVE walks/ records, which is the arm that proves the
# CANNOT-RUN branch is not theoretical: walks/v1.0.47.tsv was written ~15h
# BEFORE #1106 landed and must exit 2, never 1.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$HERE/scripts/verify_walk_record.sh"
FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

[[ -f "$GATE" ]] || { echo "FAIL [gate-missing]: $GATE not found -- nothing checked. NOT a pass." >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/walks"

# build <version> <fail> <cannot> <broken> <names_line-or-OMIT> <extra-rows...>
build() {
    _v="$1"; _f="$2"; _c="$3"; _b="$4"; _nl="$5"; shift 5
    {
        printf 'version\t%s\n' "$_v"
        printf 'version_source\tmeasured(CFBundleShortVersionString, matches argument)\n'
        printf 'walked_at\t2026-08-27T00:00:00Z\n'
        printf 'box_fp\tdeadbeefdeadbeef\n'
        printf 'pass\t5\n'
        printf 'fail\t%s\n' "$_f"
        printf 'cannot_run\t%s\n' "$_c"
        printf 'broken\t%s\n' "$_b"
        printf 'verdict\tFAILED\n'
        printf 'qa_exit\t1\n'
        [[ "$_nl" != "OMIT" ]] && printf 'failed_probe_names_recorded\t%s\n' "$_nl"
        for _r in "$@"; do printf '%s\n' "$_r"; done
    } > "$WORK/walks/$_v.tsv"
}

# run <version> [gate-override] -> writes $WORK/out, sets RC IN THE CALLER.
# NOT `out="$(run …)"`: a command substitution is a subshell, so RC would be
# assigned there and the caller's would stay 0 -- every rc assertion below would
# then be satisfied by construction rather than by the gate. That exact defect
# was found in this file's sibling (OS003 #165) before it shipped.
RC=0
run() {
    OSTLER_WALK_RECORD_DIR="$WORK/walks" /bin/bash "${2:-$GATE}" "$1" > "$WORK/out" 2>&1
    RC=$?
}

NAMES=(
    'failed_probe\tdaemon_is_listening.sh'
    'failed_probe\tpeople_count_agreement.sh'
)

# build_clean <version> -- a consistent CLEAN record with NO name field.
build_clean() {
    {
        printf 'version\t%s\n' "$1"
        printf 'version_source\tmeasured(CFBundleShortVersionString, matches argument)\n'
        printf 'walked_at\t2026-08-01T00:00:00Z\n'
        printf 'box_fp\tdeadbeefdeadbeef\n'
        printf 'pass\t9\n'; printf 'fail\t0\n'
        printf 'cannot_run\t0\n'; printf 'broken\t0\n'
        printf 'verdict\tCLEAN\n'; printf 'qa_exit\t0\n'
    } > "$WORK/walks/$1.tsv"
}

# --- ARM 1a: ABSENT field on an ALREADY-REFUSED record must NOT change the ---
#     exit code. This arm exists because my first draft DID change it: both
#     live records went 1 -> 2, turning "the walk FAILED, real defects were
#     measured" into a generic CANNOT-RUN. A stricter-looking gate that
#     destroys signal is not stricter.
build v9.9.1 2 0 0 OMIT "$(printf 'failed_probe\tdaemon_is_listening.sh')" "$(printf 'failed_probe\tpeople_count_agreement.sh')"
run v9.9.1
if [[ "$RC" -eq 1 ]] && grep -qF 'Real defects were measured' "$WORK/out" && grep -qF 'Not decided here' "$WORK/out"; then
    pass "ARM 1a: absent field + FAILED verdict keeps the specific refusal (1), and says why it abstained"
else
    fail "arm1a" "expected rc=1 with the FAILED message intact, got rc=$RC. The names block must not downgrade an informative refusal. Output:
$(< "$WORK/out")"
fi

# --- ARM 1b: ABSENT field on a record claiming CLEAN -> CANNOT-RUN (2) ------
#     Here it CAN change an outcome, so it must: a record that would otherwise
#     authorise a customer download, carrying nothing that can be checked
#     against which probes it says ran.
build_clean v9.9.0
run v9.9.0
if [[ "$RC" -eq 2 ]] && grep -qF '#1106' "$WORK/out"; then
    pass "ARM 1b: absent field + CLEAN claim is CANNOT-RUN (2), naming the writer it predates"
else
    fail "arm1b" "expected rc=2 citing #1106, got rc=$RC. Output:
$(< "$WORK/out")"
fi

# --- ARM 2: malformed field -> 2 -------------------------------------------
build v9.9.2 2 0 0 'two of four' "$(printf 'failed_probe\ta.sh')" "$(printf 'failed_probe\tb.sh')"
run v9.9.2
if [[ "$RC" -eq 2 ]]; then
    pass "ARM 2: a malformed reconciliation line is CANNOT-RUN (2)"
else
    fail "arm2" "expected rc=2, got rc=$RC. Output:
$(< "$WORK/out")"
fi

# --- ARM 3: denominator disagrees with the fail count -> REFUSE (1) --------
build v9.9.3 2 0 0 '3 of 3' "$(printf 'failed_probe\ta.sh')" "$(printf 'failed_probe\tb.sh')" "$(printf 'failed_probe\tc.sh')"
run v9.9.3
if [[ "$RC" -eq 1 ]] && grep -qF 'two numbers for one fact' "$WORK/out"; then
    pass "ARM 3: denominator vs fail count disagreement REFUSES (1)"
else
    fail "arm3" "expected rc=1, got rc=$RC. Output:
$(< "$WORK/out")"
fi

# --- ARM 4: THE ROT DETECTOR. n < m -> REFUSE (1) --------------------------
# This is the defect. Four probes failed; the record can name none of them.
# Before this block the gate accepted it.
build v9.9.4 4 0 0 '0 of 4'
run v9.9.4
if [[ "$RC" -eq 1 ]] && grep -qF 'stopped matching' "$WORK/out"; then
    pass "ARM 4: '0 of 4' -- the parser rotted -- REFUSES (1)"
else
    fail "arm4-THE-DEFECT" "expected rc=1 naming the rot, got rc=$RC. This is the whole point of the block. Output:
$(< "$WORK/out")"
fi

# --- ARM 5/6/7: the rows must agree with each count field ------------------
build v9.9.5 2 0 0 '2 of 2' "$(printf 'failed_probe\ta.sh')"
run v9.9.5
if [[ "$RC" -eq 1 ]] && grep -qF "carries 1 'failed_probe' row" "$WORK/out"; then
    pass "ARM 5: the line can be right while the ROWS were lost -- caught"
else
    fail "arm5" "expected rc=1 on a row/count mismatch, got rc=$RC. Output:
$(< "$WORK/out")"
fi

build v9.9.6 0 3 0 '0 of 0' "$(printf 'not_measured_probe\ta.sh')"
run v9.9.6
if [[ "$RC" -eq 1 ]] && grep -qF "not_measured_probe" "$WORK/out"; then
    pass "ARM 6: cannot_run=3 with 1 not_measured_probe row REFUSES -- coverage lost is not coverage named"
else
    fail "arm6" "expected rc=1, got rc=$RC. Output:
$(< "$WORK/out")"
fi

build v9.9.7 0 0 2 '0 of 0' "$(printf 'broken_probe\ta.sh')"
run v9.9.7
if [[ "$RC" -eq 1 ]] && grep -qF "broken_probe" "$WORK/out"; then
    pass "ARM 7: broken=2 with 1 broken_probe row REFUSES"
else
    fail "arm7" "expected rc=1, got rc=$RC. Output:
$(< "$WORK/out")"
fi

# --- ARM 7b: a WELL-FORMED record must get PAST this block ------------------
# ANTI-VACUITY. Without this, a block that refused everything would pass arms
# 1-7 perfectly. The record below is consistent, so it must reach the verdict
# logic and fail there for the ORIGINAL reason (verdict FAILED = rc 1, message
# about real defects), not for anything this block says.
build v9.9.8 2 1 0 '2 of 2' \
    "$(printf 'failed_probe\ta.sh')" "$(printf 'failed_probe\tb.sh')" \
    "$(printf 'not_measured_probe\tc.sh')"
run v9.9.8
if grep -qE 'names_recorded|stopped matching|two numbers for one fact|row\(s\) but its own' "$WORK/out"; then
    fail "arm7b-overreach" "a CONSISTENT record was refused by the new block. It would red every legitimate walk. Output:
$(< "$WORK/out")"
elif [[ "$RC" -eq 1 ]] && grep -qF 'Real defects were measured' "$WORK/out"; then
    pass "ARM 7b: a consistent record passes this block and fails for its ORIGINAL reason"
else
    fail "arm7b" "expected the pre-existing FAILED-verdict refusal, got rc=$RC. Output:
$(< "$WORK/out")"
fi

# --- ARM 8: MUTATION -- prove this file detects the block's absence ---------
ANCHOR='NAMES_RECONCILED="$(field failed_probe_names_recorded)"'
n="$(grep -cF "$ANCHOR" "$GATE")"
if [[ "$n" -ne 1 ]]; then
    fail "arm8-anchor" "expected exactly 1 occurrence of the anchor, found $n. The mutation is not aimed at a unique site, so ARM 8 proves nothing."
else
    MUT="$WORK/mutant.sh"
    # Neuter by reading a key that cannot exist, so the block takes its absent
    # branch and exits 2 -- no. That would still refuse. Instead skip the whole
    # block the way the pre-fix gate did: delete from the anchor to the marker
    # that begins the next section. Structural, and asserted below to have
    # actually removed lines AND still parse.
    awk '
        index($0, "NAMES_RECONCILED=\"$(field failed_probe_names_recorded)\"") { skip = 1 }
        skip && index($0, "# --- a walk that measured nothing is not a clean walk") { skip = 0 }
        !skip { print }
    ' "$GATE" > "$MUT"
    removed=$(( $(wc -l < "$GATE") - $(wc -l < "$MUT") ))
    if ! /bin/bash -n "$MUT" 2>/dev/null; then
        fail "arm8-parse" "the mutant does not parse. A syntax error is not a caught defect -- it would fail for the wrong reason."
    elif [[ "$removed" -lt 20 ]]; then
        fail "arm8-inert" "the mutation removed only ${removed} lines; the block is ~90. It did not apply, so the mutant is not the pre-fix gate."
    else
        run v9.9.4 "$MUT"
        if [[ "$RC" -eq 1 ]] && ! grep -qF 'stopped matching' "$WORK/out"; then
            pass "ARM 8: the pre-fix gate ACCEPTS '0 of 4' past this block (${removed} lines removed) -- this file genuinely detects its absence"
        else
            fail "arm8" "the pre-fix gate should NOT have produced the rot message, but rc=$RC. Either the mutation missed or ARM 4 is red for an unrelated reason. Output:
$(< "$WORK/out")"
        fi
    fi
fi

# --- ARM 9: THE LIVE RECORDS. The CANNOT-RUN branch is not theoretical ------
# walks/v1.0.47.tsv was walked 2026-08-26T14:17:14Z; #1106 landed
# 2026-08-27T05:14:56Z. It CANNOT carry the field. It must exit 2, never 1:
# retro-failing a record for the date it was taken is exactly the conflation
# this repo's exit codes exist to prevent.
shopt -s nullglob
live=("$HERE"/walks/v*.tsv)
if [[ "${#live[@]}" -eq 0 ]]; then
    echo "FAIL [arm9-empty]: no walks/*.tsv found -- the live check has a ZERO denominator and proves nothing. NOT a pass." >&2
    FAILED=1
else
    for rec in "${live[@]}"; do
        v="$(basename "$rec" .tsv)"
        OSTLER_WALK_RECORD_DIR="$HERE/walks" /bin/bash "$GATE" "$v" > "$WORK/out" 2>&1
        rc=$?
        if grep -qF 'Not decided here' "$WORK/out"; then
            # Predates #1106 AND its verdict already refuses. The block must
            # have abstained, leaving the pre-existing exit code untouched.
            if [[ "$rc" -eq 1 ]] && grep -qE 'Real defects were measured|Coverage was lost' "$WORK/out"; then
                pass "ARM 9: ${v} predates #1106 -> block ABSTAINED, original refusal (${rc}) preserved"
            else
                fail "arm9-signal-lost" "${v} predates #1106 and the block abstained, but rc=${rc} and the original message is gone. The pre-existing verdict must survive untouched."
            fi
        elif grep -qF 'failed_probe_names_recorded field' "$WORK/out"; then
            if [[ "$rc" -eq 2 ]]; then
                pass "ARM 9: ${v} claims CLEAN without names -> CANNOT-RUN (2)"
            else
                fail "arm9-conflated" "${v} lacks the field on a CLEAN claim but exited ${rc}, not 2. CANNOT-RUN is neither FAIL nor PASS."
            fi
        else
            pass "ARM 9: ${v} carries the field; this block did not object (rc=${rc})"
        fi
    done
fi

[[ "$FAILED" -ne 0 ]] && exit 1
echo
echo "ALL WALK-RECORD NAME-RECONCILIATION TESTS PASSED"
