#!/usr/bin/env bash
# Hydrate sentinel honesty: a FAILED step must not suppress its retry (#711)
# =========================================================================
#
# Behavioural test. Extracts the REAL sentinel helpers from install.sh and
# executes them, so this cannot pass against a copy of the logic.
#
# THE DEFECT, measured 2026-08-16 on the box and then in source:
#
#   _hydrate_sentinel_record <source>   writes <source>.done, ALWAYS
#   _hydrate_sentinel_fresh  <source>   skips that source for 7 DAYS
#
# The helper's own header states the contract: the sentinel drops "once it
# completes (success or no-data both count)". SUCCESS OR NO-DATA. An errored
# run is neither, and nothing enforced the difference.
#
# The customer-visible case: deny Full Disk Access once, the iMessage
# extractor exits EX_CONFIG 78, imessage.done lands carrying people=0, and
# granting FDA an hour later changes nothing -- the block is skipped because
# the sentinel is fresh. A refusal that should last one run lasts a week.
#
# THE RULE IS NOT NEW. tests/test_aiconv_hydrate_honesty.sh already asserts it
# for ONE source: "a timed-out (124/137) or crashed (any other non-zero rc)
# drain must NOT record it, so the next install/re-run retries instead of
# skipping for a week". Measured across all nine sources, 8 broke it.
#
# Control (6) is deliberately a REPORT, not just a pass: it prints which
# sources are still unguarded, so the remaining work is visible in the test
# output rather than absent from it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 🔴 OVERRIDABLE SO THIS GATE CAN BE SHOWN TO FAIL. It was not, and row 775
# recorded the consequence: "NO MUTATION, NO CONTROL -- the mutation/self-test
# grep returns 0 lines over this test". A gate that guards every hydrate source
# a customer has, and has never once been demonstrated to go red, is a gate
# nobody can trust. The override is READ-ONLY and used only by --self-test
# below, which points it at mutated COPIES in a temp dir and never writes here.
INSTALL="${OSTLER_TEST_INSTALL:-$REPO_ROOT/install.sh}"

# ── --self-test: DRIVE THIS GATE AGAINST MUTATED COPIES ─────────────────────
# Each arm mutates a COPY of install.sh in a temp dir, runs THIS SCRIPT against
# it, and demands an exit code. Nothing under the repo is written. A mutant is
# refused unless its literal occurs the expected number of times, because a
# mutation that did not apply looks exactly like one that was not caught.
if [[ "${1:-}" == "--self-test" ]]; then
    _st_work="$(mktemp -d)"
    trap 'rm -rf "$_st_work"' EXIT
    _st_fail=0
    _st_arms=0

    _st_arm() {   # _st_arm <name> <mutated install path> <wanted rc> <wanted substring>
        local name="$1" inst="$2" want_rc="$3" want_txt="$4" out rc
        _st_arms=$((_st_arms + 1))
        out="$(OSTLER_TEST_INSTALL="$inst" bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
        if [[ "$rc" != "$want_rc" ]]; then
            echo "  [FAIL] ${name}: exit ${rc}, wanted ${want_rc}"
            _st_fail=$((_st_fail + 1)); return
        fi
        if [[ -n "$want_txt" ]] && ! printf '%s' "$out" | grep -qF -- "$want_txt"; then
            echo "  [FAIL] ${name}: exit ${rc} as wanted, but the output does not name [${want_txt}]"
            _st_fail=$((_st_fail + 1)); return
        fi
        echo "  [PASS] ${name}: exit ${rc}${want_txt:+, naming [${want_txt}]}"
    }

    # ARM 1. The real install.sh must PASS. Without this the other arms could
    # all pass on a gate that returns non-zero unconditionally.
    _st_arm "an unmutated install.sh passes" "$REPO_ROOT/install.sh" 0 "every hydrate source is guarded"

    # ARM 2. A guarded source loses its error-variant recorder and writes the
    # SUCCESS sentinel on the error path instead: the original #711 defect.
    _st_mut2="$_st_work/mutant2.sh"
    _st_lit='_hydrate_sentinel_record_error "whatsapp"'
    _st_n="$(grep -cF -- "$_st_lit" "$REPO_ROOT/install.sh")"
    if [[ "$_st_n" != "1" ]]; then
        echo "  [CANNOT-RUN] arm 2: its literal occurs ${_st_n} time(s) in install.sh, expected 1."
        echo "               Re-anchor the mutant rather than deleting it: a mutation that"
        echo "               cannot be applied proves nothing about this gate."
        _st_fail=$((_st_fail + 1))
    else
        sed 's/_hydrate_sentinel_record_error "whatsapp"/_hydrate_sentinel_record "whatsapp"/' \
            "$REPO_ROOT/install.sh" > "$_st_mut2"
        # prove the edit landed, and that it landed ONCE
        if [[ "$(grep -cF -- '_hydrate_sentinel_record "whatsapp"' "$_st_mut2")" -lt 1 ]]; then
            echo "  [CANNOT-RUN] arm 2: the mutation did not land in the copy"
            _st_fail=$((_st_fail + 1))
        else
            _st_arm "a source writing the SUCCESS sentinel on its error path is caught" \
                    "$_st_mut2" 1 "UNGUARDED  whatsapp"
        fi
    fi

    # ARM 3. The DERIVATION breaks: the call sites stop matching the pattern the
    # population is derived from. The gate must refuse rather than report a
    # population it did not establish.
    _st_mut3="$_st_work/mutant3.sh"
    sed 's/_hydrate_sentinel_record_error "/_hydrate_sentinel_recordERR "/g; s/_hydrate_sentinel_record "/_hydrate_sentinel_recordOK "/g' \
        "$REPO_ROOT/install.sh" > "$_st_mut3"
    _st_left="$(grep -oE '_hydrate_sentinel_[a-z_]+ "[a-z_]+"' "$_st_mut3" | grep -oE '"[a-z_]+"' | sort -u | wc -l | tr -d ' ')"
    if [[ "$_st_left" -ge 13 ]]; then
        echo "  [CANNOT-RUN] arm 3: the mutation left ${_st_left} derivable source(s), so it does not break the derivation"
        _st_fail=$((_st_fail + 1))
    else
        _st_arm "a broken population derivation refuses instead of reporting a typed number" \
                "$_st_mut3" 1 "the derivation is broken"
    fi

    echo
    if [[ "$_st_fail" -gt 0 ]]; then
        echo "SELF-TEST FAIL: ${_st_fail} of ${_st_arms} arm(s) did not behave"
        exit 1
    fi
    echo "SELF-TEST PASS: ${_st_arms} of ${_st_arms} arms behaved -- this gate passes a clean tree and goes RED on both defect shapes."
    exit 0
fi

FAILURES=0
CHECKS=0
fail() { echo "  FAIL  $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  PASS  $*"; }
check() {
    CHECKS=$((CHECKS + 1))
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

[[ -f "$INSTALL" ]] || { echo "CANNOT-RUN: install.sh not found at $INSTALL" >&2; exit 2; }

# --- extract the REAL helpers, not a copy -----------------------------------
HARNESS="$(mktemp -d -t hydratesentinel-XXXXXX)"
trap 'rm -rf "$HARNESS"' EXIT

extract_fn() {
    # Print the function named $1 exactly as install.sh defines it.
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}$/ { exit }
    ' "$INSTALL"
}

# _hydrate_payload_is_all_zero and gui_step_record_rc are CALLEES of the three
# recorders, and they were missing from this harness. Every run printed
# `command not found` to stderr and carried on, which meant control (1) was
# passing over a recorder whose zero-payload branch could not execute -- the
# apparatus was half dark while the assertions read green. #848.
{
    printf '_HYDRATE_SENTINEL_DIR="%s/state"\n' "$HARNESS"
    printf 'mkdir -p "$_HYDRATE_SENTINEL_DIR"\n'
    printf 'gui_step_record_rc() { :; }\n'
    extract_fn _hydrate_sentinel_fresh
    extract_fn _hydrate_payload_is_all_zero
    extract_fn _hydrate_sentinel_record
    extract_fn _hydrate_sentinel_record_error
} > "$HARNESS/helpers.sh"

for fn in _hydrate_sentinel_fresh _hydrate_payload_is_all_zero \
          _hydrate_sentinel_record _hydrate_sentinel_record_error; do
    if ! grep -q "^${fn}() {" "$HARNESS/helpers.sh"; then
        echo "CANNOT-RUN: could not extract $fn from install.sh." >&2
        echo "  This test drives the REAL helpers; it refuses to run against a copy." >&2
        exit 2
    fi
done

bash -n "$HARNESS/helpers.sh" || { echo "CANNOT-RUN: extracted helpers do not parse" >&2; exit 2; }

echo "test_hydrate_sentinel_not_on_error.sh"

run_in_harness() { bash -c "source '$HARNESS/helpers.sh'; $1"; echo "$?"; }

# (1) A successful record is fresh. Without this the fix would break the
#     7-day dedupe the sentinel exists for.
rc=$(run_in_harness '_hydrate_sentinel_record imessage "people=12"; _hydrate_sentinel_fresh imessage')
check "(1) a completed run IS fresh, so re-runs still dedupe" "$rc" "0"

# (2) THE DEFECT. An errored record must NOT be fresh.
rc=$(run_in_harness '_hydrate_sentinel_record_error imessage 78 "people=0"; _hydrate_sentinel_fresh imessage')
check "(2) an ERRORED run is NOT fresh, so the next run retries" "$rc" "1"

# (3) The record still exists on disk and names the rc. Refusing to write the
#     file at all would lose the evidence Doctor and a human need.
out="$(bash -c "source '$HARNESS/helpers.sh'; _hydrate_sentinel_record_error places 2 'status=run'; cat \"\$_HYDRATE_SENTINEL_DIR/places.done\"")"
if printf '%s' "$out" | grep -q '^status=error' && printf '%s' "$out" | grep -q '^rc=2'; then
    pass "(3) the failure is still RECORDED (status=error, rc=2), not discarded"
else
    fail "(3) the error record lost its status or rc: $out"
fi
CHECKS=$((CHECKS + 1))

# (4) An error sentinel is not fresh at ANY age, including brand new. Guards
#     against a fix that only works once the mtime has aged.
rc=$(run_in_harness '_hydrate_sentinel_record_error whatsapp 1; _hydrate_sentinel_fresh whatsapp')
check "(4) an error sentinel is stale immediately, not after 7 days" "$rc" "1"

# (4b) THE UPGRADE-PATH GAP. Every sentinel written before #768 has NO
#      status line. Testing only for `status=error` left those reading as
#      fresh, so the fix could not reach any box that already had the defect.
#      Measured on the launch box after #768 merged: 8 sentinels, all legacy,
#      including the imessage.done written by the EX_CONFIG 78 tick itself.
rc=$(run_in_harness 'printf "recorded_at=2026-08-16T12:51:08Z\nsource=imessage\npayload=people=0\n" \
                       > "$_HYDRATE_SENTINEL_DIR/imessage.done"
                     _hydrate_sentinel_fresh imessage')
check "(4b) a LEGACY sentinel with no status line is NOT fresh" "$rc" "1"

# (4c) ...and it CONVERGES. After the retry records a success the source is
#      suppressed again, so an upgraded box re-hydrates ONCE, not every run.
rc=$(run_in_harness 'printf "recorded_at=2026-08-16T12:51:08Z\nsource=imessage\npayload=people=0\n" \
                       > "$_HYDRATE_SENTINEL_DIR/imessage.done"
                     _hydrate_sentinel_fresh imessage || _hydrate_sentinel_record imessage "people=41"
                     _hydrate_sentinel_fresh imessage')
check "(4c) after the retry succeeds it IS fresh again -- one re-hydrate, not a loop" "$rc" "0"

# (5) A success sentinel older than 7 days is still not fresh (unchanged).
rc=$(run_in_harness '_hydrate_sentinel_record browsing "sent=3"
                     touch -t 202001010000 "$_HYDRATE_SENTINEL_DIR/browsing.done"
                     _hydrate_sentinel_fresh browsing')
check "(5) the 7-day expiry still applies to a successful run" "$rc" "1"

# (6) An absent sentinel is not fresh.
rc=$(run_in_harness '_hydrate_sentinel_fresh never_ran')
check "(6) an absent sentinel is not fresh" "$rc" "1"

# (7) POPULATION REPORT + RATCHET. Which sources keep their non-zero-rc arm
#     from writing a success sentinel? Prints every source by name so the
#     remaining work is visible in the output rather than silently missing.
#
#     TWO SHAPES ARE VALID, and they are not interchangeable:
#
#       (a) the arm records the ERROR variant  -- _hydrate_sentinel_record_error
#       (b) the arm records NOTHING AT ALL     -- the ai_conversations shape
#
#     (b) is equally correct: an absent sentinel is not fresh, so the next run
#     retries. Control (6) proves that.
#
#     🔴 THIS CONTROL USED TO CARRY `|| [[ "$src" == "ai_conversations" ]]`,
#     which is an unconditional pass -- for that one source it could not fail,
#     whatever install.sh did. Shape (b) is now ASSERTED by reading the arm and
#     requiring it to be free of a success record, so adding one there turns
#     this red instead of being waved through. #712.
echo
echo "  -- sentinel guard coverage --"
GUARDED=0
# #848 widened this population from 9 to 13. contacts, calendar, email and
# dedupe are hydrate steps that ran with NO sentinel at all, so they could not
# break this rule -- there was no record to be wrong. They are inside the
# machinery now, which means they are inside this ratchet too.
# THE POPULATION IS DERIVED FROM install.sh, NOT TYPED HERE (#775).
#
# This used to be a hand-written list of 13 names, checked against a
# hand-written floor of 13. Both halves were typed by the same person at the
# same time, so the gate was comparing a number against itself: a FOURTEENTH
# hydrate source with an unguarded error arm would not appear in the list, and
# the control would report a confident "13 of 13 guarded" about a population it
# had never established. Sound for the artefact as written, unsound for the
# artefact as it might be written.
#
# A source with no sentinel call at all is outside the sentinel system by
# definition, so deriving from the sentinel calls has no blind spot for what
# this control is about.
#
# THE HAND LIST IS KEPT AND UNIONED IN, never replaced: if the derivation ever
# returns less than it should, the union means a source cannot silently LEAVE
# the population. The arms below then require the derived set to be at least
# the floor, so the derivation going quiet is itself a red.
SENTINEL_SOURCES_KNOWN="imessage places whatsapp browsing email_preferences apple_notes people privacy_backfill ai_conversations contacts calendar email dedupe"
SENTINEL_SOURCES_DERIVED="$(grep -oE '_hydrate_sentinel_[a-z_]+ "[a-z_]+"' "$INSTALL" \
    | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u | tr '\n' ' ')"
ALL_SOURCES="$(printf '%s %s\n' "$SENTINEL_SOURCES_KNOWN" "$SENTINEL_SOURCES_DERIVED" \
    | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
SENTINEL_DERIVED_COUNT="$(printf '%s' "$SENTINEL_SOURCES_DERIVED" | wc -w | tr -d ' ')"
SENTINEL_POPULATION="$(printf '%s' "$ALL_SOURCES" | wc -w | tr -d ' ')"
echo "     population: ${SENTINEL_POPULATION} source(s) (${SENTINEL_DERIVED_COUNT} derived from install.sh)"
for src in $ALL_SOURCES; do
    if grep -q "_hydrate_sentinel_record_error \"$src\"" "$INSTALL"; then
        echo "     guarded    $src   (records the error variant)"
        GUARDED=$((GUARDED + 1))
        continue
    fi
    # Shape (b): the rc arm must exist AND must not write a success sentinel.
    # THE TERMINATOR TRACKS NESTING DEPTH. It used to be
    #
    #     grab && /^ *(elif|else|fi)/ && ++seen > 1   { exit }
    #
    # which counts terminator-shaped lines and stops at the second one. That
    # cannot tell a NESTED block's `fi` from the end of the arm, so a success
    # record placed after any `if ... fi` inside the error arm was never
    # scanned and the control reported "guarded" on an arm that writes .done.
    # Measured (#775): the same record without a nested block is caught
    # (8 passed / 1 failed); behind a nested if/fi it was a FALSE PASS
    # (9 passed / 0 failed) -- the control could not fail on the one shape it
    # most needed to catch.
    #
    # Now: the arm ends at the first elif/else/fi at DEPTH 0. A nested `if`
    # opens a level and its `fi` closes it, so neither can end the arm early.
    # An inline `if ...; then ...; fi` opens and closes on one line and must
    # not increment, hence the trailing-fi exclusion.
    ARM="$(awk -v s="$src" '
        /elif \[\[ "\$_aiconv_rc" -ne 0 \]\]; then/ {
            if (s == "ai_conversations") { grab = 1; depth = 0; next }
        }
        grab {
            if (depth == 0 && $0 ~ /^[[:space:]]*(elif|else|fi)([[:space:]]|$)/) exit
            print
            if ($0 ~ /^[[:space:]]*if[[:space:]]/ && $0 !~ /[[:space:];][[:space:]]*fi[[:space:]]*$/) depth++
            else if ($0 ~ /^[[:space:]]*fi([[:space:]]|$)/) depth--
        }
    ' "$INSTALL")"
    if [[ -n "$ARM" ]] && ! printf '%s\n' "$ARM" | grep -q '_hydrate_sentinel_record '; then
        echo "     guarded    $src   (error arm records NO sentinel, so the retry stands)"
        GUARDED=$((GUARDED + 1))
    else
        # Two different faults share this arm and the message must not claim
        # the wrong one: a source with NO recorder at all (#848) is not
        # "writing .done on the error path", it is writing nothing anywhere.
        if grep -q "_hydrate_sentinel_record[a-z_]* \"$src\"" "$INSTALL"; then
            echo "     UNGUARDED  $src   <- still writes .done on the error path (#711/#712)"
        else
            echo "     UNGUARDED  $src   <- no sentinel recorder of any kind (#848)"
        fi
    fi
done
echo
# FLOOR, not equality. 9 of 9 as of #712, 13 of 13 as of #848; it can only
# go up.
SENTINEL_GUARD_FLOOR=13
CHECKS=$((CHECKS + 1))
# THE DERIVATION MUST HAVE WORKED. A grep that silently returns nothing would
# give a population of 13 from the known list alone and this control would go
# on reporting a typed number. A derived set smaller than the floor means the
# derivation broke, NOT that the artefact shrank.
if [[ "$SENTINEL_DERIVED_COUNT" -lt "$SENTINEL_GUARD_FLOOR" ]]; then
    fail "(7) the population derivation returned ${SENTINEL_DERIVED_COUNT} source(s) from install.sh, fewer than the floor ${SENTINEL_GUARD_FLOOR}: the derivation is broken, so any verdict here would be about a population this control did not establish"
# EVERY source in the DERIVED population must be guarded, not merely as many
# as the floor. This is what makes a fourteenth unguarded source red without
# anyone editing this file.
elif [[ "$GUARDED" -lt "$SENTINEL_POPULATION" ]]; then
    fail "(7) $((SENTINEL_POPULATION - GUARDED)) of ${SENTINEL_POPULATION} hydrate source(s) are UNGUARDED (guarded=$GUARDED). The population was derived from install.sh, so this includes any source added since this test was last edited."
elif [[ "$SENTINEL_POPULATION" -lt "$SENTINEL_GUARD_FLOOR" ]]; then
    fail "(7) coverage went BACKWARDS: population=$SENTINEL_POPULATION, floor is $SENTINEL_GUARD_FLOOR"
else
    pass "(7) every hydrate source is guarded (guarded=$GUARDED of $SENTINEL_POPULATION derived, floor=$SENTINEL_GUARD_FLOOR)"
fi

echo
echo "=== $((CHECKS - FAILURES)) passed / $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]]
