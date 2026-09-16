#!/usr/bin/env bash
# A phase-2 (cut-manifest) failure must reach the walk record by NAME, the
# same way a phase-1 (run_box_walk.sh) failure already does.
#
# THE DEFECT. verify_cut_manifest.py re-runs every box_walk_probe row LIVE,
# independently of run_box_walk.sh's own phase 1 pass. no_unexpected_egress
# failed there on two consecutive real cuts while phase 1 stayed clean --
# egress samples network sockets on a schedule, and a real intermittent
# connection can miss one sampling window and be caught by the other.
#
# scripts/post_walk_qa.sh used to invoke that command as
#
#     python3 .../verify_cut_manifest.py --version "$CUT_VERSION" --require-runtime-proofs
#     manifest_rc=$?
#
# with NOTHING reading the output back. The walk record's `verdict` field
# still flipped to FAILED (manifest_rc fed `overall`), but no `failed_probe`
# row named which probe, and `failed_probe_names_recorded` read literally
# "0 of 0" -- and scripts/verify_walk_record.sh's promote gate reads _NONPASS_
# from exactly those `failed_probe`/`not_measured_probe` rows, found none, and
# refused UNSCOPED: correct given what it could see, wrong because the record
# could have named the probe and did not.
#
# WHAT THIS CHECKS, in three layers:
#   1. WIRING: the manifest command's output is actually captured (piped
#      through tee into a durable log), not thrown away on a bare `$?`.
#   2. THE PARSE: manifest_probe_names()/manifest_summary_count(), lifted out
#      of post_walk_qa.sh the same way tests/test_walk_record_names_the_
#      failing_probes.sh already lifts section_names(), read a synthetic
#      verify_cut_manifest.py log correctly -- including the case where a
#      FAIL row cannot be attributed to a probe name (a non-box_walk_probe
#      kind), which must still show up in the INDEPENDENT summary total
#      rather than vanishing.
#   3. THE MERGE: with a phase-2 name and a phase-2 total fed in and a clean
#      phase 1, failed_probe_names_recorded reads "N of N", never "0 of 0" --
#      the literal symptom this test exists to close out.
#
# RUN THIS AGAINST THE ORIGINAL, PRE-FIX post_walk_qa.sh FIRST:
#     git show <pre-fix-sha>:scripts/post_walk_qa.sh > /tmp/old_qa.sh
#     QA=/tmp/old_qa.sh bash tests/test_phase_2_failures_reach_the_walk_record.sh
# Every layer above must FAIL or CANNOT-RUN there.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA="${QA:-$REPO_ROOT/scripts/post_walk_qa.sh}"
FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }
cant() { echo "CANNOT-RUN [$1]: $2" >&2; exit 2; }

[[ -f "$QA" ]] || cant "qa-missing" "$QA not found -- nothing checked. NOT a pass."

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---- LAYER 1: WIRING -- is the manifest command's output even captured? ----
if grep -qF 'verify_cut_manifest.py' "$QA" && grep -qF 'tee -a "$MANIFEST_LOG"' "$QA"; then
    pass "the manifest gate's stdout is piped through tee into a durable log, not discarded"
else
    fail "no-capture" "verify_cut_manifest.py's output is not captured anywhere in $QA -- a phase-2 FAIL has nothing for this script to read back"
fi
if grep -qF 'manifest_rc="${PIPESTATUS[0]}"' "$QA"; then
    pass "the gate's own exit code is read via PIPESTATUS, not \$? on a bare command lost to the pipe"
else
    fail "no-pipestatus" "manifest_rc is not read via PIPESTATUS[0]; piping the command through tee without this would silently take tee's exit code instead of the gate's"
fi

# ---- lift manifest_probe_names() and manifest_summary_count() -------------
lift_fn() { # $1 = function name -> prints the function's source, or nothing
    local a b
    a=$(grep -n "^        $1() {" "$QA" | head -1 | cut -d: -f1)
    [[ -n "$a" ]] || return 1
    b=$(awk -v a="$a" 'NR>a && /^        }$/{print NR; exit}' "$QA")
    [[ -n "$b" ]] || return 1
    sed -n "${a},${b}p" "$QA"
}

MPN="$(lift_fn manifest_probe_names)" || {
    fail "no-manifest_probe_names" "$QA has no manifest_probe_names() function; a phase-2 row's probe name cannot be recovered at all"
}
MSC="$(lift_fn manifest_summary_count)" || {
    fail "no-manifest_summary_count" "$QA has no manifest_summary_count() function; a phase-2 FAIL/CANNOT-RUN total cannot be read independently of the per-row parse"
}

if [[ -n "${MPN:-}" && -n "${MSC:-}" ]]; then
    { printf '%s\n%s\n' "$MPN" "$MSC"; } > "$WORK/lifted.sh"
    bash -n "$WORK/lifted.sh" || cant "extract-syntax" "the lifted functions do not parse"
    pass "lifted manifest_probe_names() and manifest_summary_count() from $QA and they parse"

    # ---- LAYER 2: THE PARSE, against a synthetic verify_cut_manifest.py log --
    cat > "$WORK/manifest.log" <<'EOF'
=== Cut manifest gate ===
  app_path       = /tmp/x

--- permanent (2 entries) ---
  PASS  some-passing-row                            a row that measured cleanly
  FAIL  box-walk-no-unexpected-egress                no Ostler-owned process may hold a connection outside the declared local boundary
        probe=no_unexpected_egress exit=1 stdout='VERDICT: FAIL -- 1 connection(s) attributable to Ostler reached an undeclared destination'
  FAIL  some-static-grep-row                         a row this parse cannot attribute to a probe
        pattern 'BEGIN_FDA_TOKEN' matched in install.sh:412, a static leak check unrelated to any probe

=== Summary: 1 PASS  2 FAIL  0 SKIP  0 CANNOT-RUN  (3 total) ===
EOF

    got="$(bash -c 'source "$0"; manifest_probe_names FAIL "$1"' "$WORK/lifted.sh" "$WORK/manifest.log")"
    if [[ "$got" == "no_unexpected_egress" ]]; then
        pass "the box_walk_probe FAIL row's probe name is recovered, and the static-grep FAIL row is NOT falsely attributed to a probe"
    else
        fail "probe-names" "expected exactly 'no_unexpected_egress', got '$got'"
    fi

    got="$(bash -c 'source "$0"; manifest_probe_names CANNOT-RUN "$1"' "$WORK/lifted.sh" "$WORK/manifest.log")"
    if [[ -z "$got" ]]; then
        pass "no CANNOT-RUN rows in this fixture, and none are invented"
    else
        fail "phantom-cannotrun" "expected nothing, got '$got'"
    fi

    got="$(bash -c 'source "$0"; manifest_summary_count FAIL "$1"' "$WORK/lifted.sh" "$WORK/manifest.log")"
    if [[ "$got" == "2" ]]; then
        pass "the independent FAIL total is 2 -- INCLUDING the row this parse could not name, so the gap is visible rather than hidden"
    else
        fail "fail-total" "expected 2 (one named + one unnameable), got '$got'"
    fi

    got="$(bash -c 'source "$0"; manifest_summary_count CANNOT-RUN "$1"' "$WORK/lifted.sh" "$WORK/manifest.log")"
    if [[ "$got" == "0" ]]; then
        pass "the independent CANNOT-RUN total is 0"
    else
        fail "cannotrun-total" "expected 0, got '$got'"
    fi
else
    fail "layer2-skipped" "manifest_probe_names()/manifest_summary_count() could not be lifted, so the parse layer could not be checked at all"
fi

# ---- LAYER 3: THE MERGE -- 0 of 0 must become N of N -----------------------
#
# Lift section_names() the same way tests/test_walk_record_names_the_failing_
# probes.sh does, then the merge block by its literal first/last line, and
# drive both together: a CLEAN phase 1 (no FAILED: section) plus a NAMED
# phase-2 failure must produce a NON-ZERO, SELF-CONSISTENT
# failed_probe_names_recorded -- never "0 of 0" while a probe is actually red.
A=$(grep -n 'section_names() {' "$QA" | head -1 | cut -d: -f1)
if [[ -z "$A" ]]; then
    fail "no-section-names" "$QA has no section_names(); phase 1 naming is gone too"
else
    B=$(awk -v a="$A" 'NR>a && /^    }$/{print NR; exit}' "$QA")
    # -F (fixed string), NOT a bare pattern: a mid-pattern `$` is an anchor
    # under some grep implementations and literal under others -- fixed-string
    # search sidesteps the question entirely rather than trusting either.
    MSTART=$(grep -nF 'FAILED_NAMES_P1="$(section_names' "$QA" | head -1 | cut -d: -f1)
    MEND=$(grep -nF 'n_fail_total=$(( ${n_fail:-0} + ${PHASE2_FAIL_TOTAL:-0} ))' "$QA" | head -1 | cut -d: -f1)
    if [[ -z "$B" || -z "$MSTART" || -z "$MEND" ]]; then
        fail "no-merge-block" "could not find the phase1+phase2 merge block in $QA by its known start/end lines -- the merge that turns a phase-2 name into a failed_probe row may not exist at all"
    else
        {
            echo 'PROBE_LOG="$1"'
            sed -n "${A},${B}p" "$QA"
            sed -n "${MSTART},${MEND}p" "$QA"
        } > "$WORK/merge.sh"
        bash -n "$WORK/merge.sh" || cant "merge-extract-syntax" "the lifted merge block does not parse"
        pass "lifted section_names() + the phase1/phase2 merge block and it parses"

        # A phase 1 log with NO FAILED: section (phase 1 ran clean) --
        # matching what a real box would print when only phase 2 is red.
        cat > "$WORK/clean_phase1.log" <<'EOF'
============================================================
RESULT
  PASS        21
  FAIL        0
  CANNOT-RUN  0
  BROKEN      0
============================================================
EOF
        # The variables the merge block READS must be set BEFORE it runs, so
        # they are set before `source`, not after -- the block executes AT
        # source time, not lazily when referenced later in this script.
        out="$(bash -c '
            n_fail=0
            PHASE2_FAILED_NAMES="no_unexpected_egress"
            PHASE2_CANNOTRUN_NAMES=""
            PHASE2_FAIL_TOTAL=1
            source "$0" "$1"
            printf "FAILED_NAMES=%s\n" "$FAILED_NAMES"
            printf "n_failed_named=%s\n" "$n_failed_named"
            printf "n_fail_total=%s\n" "$n_fail_total"
        ' "$WORK/merge.sh" "$WORK/clean_phase1.log")"

        if grep -q '^FAILED_NAMES=no_unexpected_egress$' <<<"$out"; then
            pass "the phase-2-only failure is merged into FAILED_NAMES"
        else
            fail "not-merged" "FAILED_NAMES did not carry the phase-2 name: $out"
        fi

        named="$(awk -F= '/^n_failed_named=/{print $2}' <<<"$out")"
        total="$(awk -F= '/^n_fail_total=/{print $2}' <<<"$out")"
        if [[ "$named" == "1" && "$total" == "1" ]]; then
            pass "failed_probe_names_recorded would read '1 of 1', not '0 of 0', with a clean phase 1 and one named phase-2 failure"
        else
            fail "zero-of-zero" "expected named=1 total=1 (the fix for '0 of 0'), got named='$named' total='$total'"
        fi

        # CONTROL: with NO phase-2 failure at all, the merge must still read
        # 0 of 0 -- this is a legitimate clean walk, and the fix must not
        # manufacture a failure that was never measured.
        out2="$(bash -c '
            n_fail=0
            PHASE2_FAILED_NAMES=""
            PHASE2_CANNOTRUN_NAMES=""
            PHASE2_FAIL_TOTAL=0
            source "$0" "$1"
            printf "n_failed_named=%s\n" "$n_failed_named"
            printf "n_fail_total=%s\n" "$n_fail_total"
        ' "$WORK/merge.sh" "$WORK/clean_phase1.log")"
        named2="$(awk -F= '/^n_failed_named=/{print $2}' <<<"$out2")"
        total2="$(awk -F= '/^n_fail_total=/{print $2}' <<<"$out2")"
        if [[ "$named2" == "0" && "$total2" == "0" ]]; then
            pass "CONTROL: a genuinely clean run (no failure in either phase) still reads '0 of 0' -- the fix does not invent a defect"
        else
            fail "control-invented" "expected named=0 total=0 on a clean run, got named='$named2' total='$total2'"
        fi
    fi
fi

[[ "$FAILED" -ne 0 ]] && exit 1
echo
echo "ALL PHASE-2 WALK-RECORD TESTS PASSED"
