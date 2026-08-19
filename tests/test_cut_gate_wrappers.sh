#!/usr/bin/env bash
#
# test_cut_gate_wrappers.sh
#
# Self-test for the cut-gate WRAPPERS in gui/Makefile.
#
# The underlying gate scripts have their own suites. This one tests the thing
# between the script and the operator: the Makefile recipe that reads an exit
# code and decides what to say about it.
#
# WHY (v1018-D621d)
# -----------------
# Seven gates collapsed a could-not-run into a named defect. The exit code
# trichotomy the scripts already speak --
#
#     0  the thing is fine
#     1  the thing is WRONG
#     2  I COULD NOT LOOK      (also 3, in the two gh-backed scripts)
#
# -- was flattened by `script || { echo "ERROR: <specific defect>"; exit 1; }`.
# Two of them were live misreports before this change:
#
#   check-orphans  verify_no_orphaned_fixes.sh exits 3 "no repo checkouts
#                  resolved". The wrapper announced "work exists that is NOT
#                  in what you are about to ship" -- an accusation assembled
#                  from a run that examined zero repositories.
#   check-pr-age   verify_pr_age.sh exits 3 when no repo produces a PR listing
#                  (an expired gh token does this). The wrapper announced
#                  "PRs have outstayed the 48h limit".
#
# Neither message is a harmless imprecision. Both send the operator to fix a
# defect that was never detected, while the real fault -- the gate is blind --
# goes unmentioned. That is strictly worse than silence, because it looks like
# a finding.
#
# WHAT THIS ASSERTS, for each of the seven wrappers:
#   * exit 2 from the script  -> recipe says CANNOT RUN and propagates 2
#   * exit 3 from the script  -> same (3 is the gh-backed scripts' cannot-run)
#   * exit 1 from the script  -> recipe names the DEFECT and exits 1
#   * exit 0 from the script  -> recipe exits 0
#
# and, in both directions, that the wording does NOT cross over: a cannot-run
# must not print the defect sentence, and a defect must not print CANNOT RUN.
# Asserting only "says CANNOT RUN" would pass on a recipe that printed both.
#
# Exit 0 all controls pass / 1 a control failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUI_DIR="$REPO_ROOT/gui"

if [[ ! -f "$GUI_DIR/Makefile" ]]; then
    echo "CANNOT RUN: no Makefile at $GUI_DIR/Makefile" >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gatewrap-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

# A stub standing in for a gate script, exiting with whatever we ask.
mk_stub() { # <rc>
    local rc="$1" p="$WORK/stub-$rc.sh"
    {
      echo '#!/usr/bin/env bash'
      echo "echo 'stub gate: pretending to exit $rc'"
      echo "exit $rc"
    } > "$p"
    chmod +x "$p"
    printf '%s' "$p"
}

# The six wrappers: target, the Make variable that points at its script, and
# a distinctive fragment of the DEFECT sentence that must appear only on rc=1.
#
# Held as three parallel arrays rather than an associative array: /bin/bash on
# the cut host is 3.2, which has no `declare -A`. The gates this file tests
# run on that host, so the test must too.
TARGETS=(check-provenance check-orphans check-pr-age check-provenance-content verify-stapling verify-commit-parity check-freshness)
VARS=(PROVENANCE_SH ORPHANS_SH PR_AGE_SH PROVENANCE_CONTENT_SH STAPLING_SH COMMIT_PARITY_SH FRESHNESS_SH)
DEFECTS=(
  "a merged fix is stale/missing"
  "work exists that is NOT in what you are about to ship"
  "PRs have outstayed the 48h limit"
  "a required fix is NOT baked into a shipped artifact"
  "carries no notarisation ticket"
  "embed DIFFERENT"
  # The SEVENTH, added after the six. Its old text HEDGED -- "lags live
  # upstream HEAD (or could not be verified against GitHub)" -- which is never
  # wrong and never informative. The defect string asserted here is the
  # un-hedged half, so a return to the hedge fails this control.
  "lags live upstream HEAD."
)

# The two post-cut gates guard on a DMG existing before they run anything, so
# give them one. It is never opened -- the stub replaces the script that would.
FAKE_DMG="$WORK/fake.dmg"
: > "$FAKE_DMG"

# run_target -> OUT (combined output), RC (make's own status), RECIPE_RC
#
# GNU make exits 2 for ANY recipe failure, whatever the recipe itself
# returned; the recipe's real code survives only in make's "*** [target]
# Error N" line. Asserting on $? therefore tests make's error convention, not
# the wrapper -- and it silently PASSES the rc=2 cases by coincidence, because
# make's 2 and the wrapper's 2 are the same number. That false pass is exactly
# the defect class this file exists to catch, met in the test for it.
#
# So: RC proves the cut ABORTS, RECIPE_RC proves it aborts with the right code.
run_target() { # <target> <var> <stub> -> sets OUT, RC, RECIPE_RC
    local target="$1" var="$2" stub="$3"
    OUT="$(cd "$GUI_DIR" && make "$target" "$var=$stub" DMG_PATH="$FAKE_DMG" 2>&1)"
    RC=$?
    RECIPE_RC="$(printf '%s\n' "$OUT" | sed -n 's/.*\*\*\* \[.*\] Error \([0-9][0-9]*\).*/\1/p' | tail -1)"
    [ -z "$RECIPE_RC" ] && RECIPE_RC="$RC"
}

printf '== test_cut_gate_wrappers ==\n'

i=0
while [ "$i" -lt "${#TARGETS[@]}" ]; do
    target="${TARGETS[$i]}"
    var="${VARS[$i]}"
    defect="${DEFECTS[$i]}"
    i=$((i+1))

    # --- rc=2 and rc=3: CANNOT RUN, never a named defect ------------------
    for rc in 2 3; do
        run_target "$target" "$var" "$(mk_stub "$rc")"
        if [ "$RC" -ne 0 ] && [ "$RECIPE_RC" -eq "$rc" ] \
           && printf '%s' "$OUT" | grep -q "COULD NOT RUN" \
           && ! printf '%s' "$OUT" | grep -qF "$defect"; then
            ok "$target: script exit $rc -> CANNOT RUN, aborts with $rc, no defect named"
        else
            bad "$target: script exit $rc -> recipe_rc=$RECIPE_RC make_rc=$RC (expected recipe $rc + CANNOT RUN + no defect text)"
            printf '%s\n' "$OUT" | sed 's/^/        /'
        fi
    done

    # --- rc=1: the gate found the thing it looks for ----------------------
    run_target "$target" "$var" "$(mk_stub 1)"
    if [ "$RC" -ne 0 ] && [ "$RECIPE_RC" -eq 1 ] \
       && printf '%s' "$OUT" | grep -qF "$defect" \
       && ! printf '%s' "$OUT" | grep -q "COULD NOT RUN"; then
        ok "$target: script exit 1 -> names the defect, aborts with 1, no CANNOT RUN"
    else
        bad "$target: script exit 1 -> recipe_rc=$RECIPE_RC make_rc=$RC (expected recipe 1 + defect text + no CANNOT RUN)"
        printf '%s\n' "$OUT" | sed 's/^/        /'
    fi

    # --- rc=0: green stays green -----------------------------------------
    run_target "$target" "$var" "$(mk_stub 0)"
    if [ "$RC" -eq 0 ]; then
        ok "$target: script exit 0 -> exit 0"
    else
        bad "$target: script exit 0 -> rc=$RC (expected 0)"
        printf '%s\n' "$OUT" | sed 's/^/        /'
    fi
done

# ---------------------------------------------------------------------------
# The two scripts that had NO cannot-run vocabulary at all.
#
# Without this, the wrappers' rc=2 branch above is proven to work but is
# unreachable in production: verify_cut_provenance.sh and provenance_gate.sh
# reported a missing input as exit 1, i.e. as a defect. A branch that only a
# stub can reach is a claim, not a gate -- the same failure being fixed, one
# level down.
# ---------------------------------------------------------------------------
for pair in "verify_cut_provenance.sh:CUT_MARKER_MANIFEST" \
            "provenance_gate.sh:REQUIRED_FIXES_FILE"; do
    script="${pair%%:*}"; envvar="${pair##*:}"
    OUT="$(env "$envvar=$WORK/definitely-not-here.tsv" \
           bash "$REPO_ROOT/scripts/$script" 2>&1)"; RC=$?
    if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "CANNOT RUN"; then
        ok "$script: missing input -> exit 2 CANNOT RUN (not a defect claim)"
    else
        bad "$script: missing input -> rc=$RC (expected 2 + CANNOT RUN)"
        printf '%s\n' "$OUT" | sed 's/^/        /' | head -5
    fi
done

echo
echo "=== $PASS passed / $FAIL failed ==="
[ "$FAIL" -eq 0 ]
