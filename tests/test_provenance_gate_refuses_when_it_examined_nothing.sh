#!/usr/bin/env bash
# THE PROVENANCE GATE MUST NEVER PRINT GREEN HAVING EXAMINED NOTHING.
#
# WHAT THIS CAUGHT, demonstrated live against origin/main before this fix:
# running scripts/verify_cut_provenance.sh with OSTLER_PROVENANCE_ONLY_KINDS
# set to a kind that matches no manifest row printed
#
#     0 pass / 0 fail / 0 could-not-run / 47 not-run-here
#     PROVENANCE GREEN -- every merged fix is present. Safe to cut.
#
# and exited 0. The verdict block checked FAIL > 0, then CANNOT > 0, and fell
# through to GREEN on anything else -- with no assertion that the three counts
# summed to more than zero. cut.yml deliberately splits this gate across two
# jobs with OSTLER_PROVENANCE_ONLY_KINDS / OSTLER_PROVENANCE_SKIP_KINDS (the
# wiki-image checks need docker, so they run in a separate job from everything
# else). A typo'd kind name in either job, or a future manifest edit that
# empties one side of that split, silently certified a cut it never inspected.
#
# WHAT IS ASSERTED HERE, three arms:
#   1. TEETH: a manifest with one real, passing row still exits 0 GREEN --
#      the fix must not turn a genuine pass into a refusal.
#   2. THE DEFECT: filtering with a --only-kind that matches nothing gives
#      0/0/0 and must refuse (CANNOT-RUN), never GREEN.
#   3. THE SAME SHAPE via --skip-kind covering the manifest's only kind.
#
# Exit: 0 all assertions pass, 1 a failure, 2 the harness itself could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_cut_provenance.sh"
[ -f "$GATE" ] || { echo "CANNOT-RUN: $GATE not found" >&2; exit 2; }

WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# A minimal, real manifest: one vendor_file row that exists in this checkout.
# vendor_file is the simplest kind (existence only, no docker, no git remote),
# so this fixture asserts real GREEN behaviour rather than stubbing the gate.
printf 'vendor_file|README.md|-|fixture: a file that genuinely exists\n' > "${WORK}/manifest.tsv"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

run_gate() {  # extra env assignments as "$@"
    env "$@" CUT_MARKER_MANIFEST="${WORK}/manifest.tsv" \
        bash "$GATE" 2>&1
}

echo "== 1. TEETH: a real, passing row still exits 0 GREEN =="
OUT="$(run_gate)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'PROVENANCE GREEN'; then
    ok "a manifest with one genuine pass exits 0 GREEN (the fix narrows nothing)"
else
    bad "a genuinely passing manifest gave rc=${RC}, expected 0 GREEN"
    printf '%s\n' "$OUT" | sed 's/^/          /'
fi
if printf '%s' "$OUT" | grep -q '1 pass / 0 fail / 0 could-not-run'; then
    ok "the summary line shows the one row was actually examined"
else
    bad "the summary line does not show 1 pass -- the fixture itself is not measuring what it claims"
    printf '%s\n' "$OUT" | sed 's/^/          /'
fi

echo
echo "== 2. THE DEFECT: --only-kind matching nothing must CANNOT-RUN, never GREEN =="
OUT="$(run_gate OSTLER_PROVENANCE_ONLY_KINDS=this_kind_does_not_exist_anywhere)"; RC=$?
if printf '%s' "$OUT" | grep -q '0 pass / 0 fail / 0 could-not-run'; then
    ok "the fixture reproduces the exact 0/0/0 shape from the live incident"
else
    bad "the only-kind filter did not zero out pass/fail/cannot -- the repro did not fire"
    printf '%s\n' "$OUT" | sed 's/^/          /'
fi
case "$RC" in
    2) ok "0 pass / 0 fail / 0 cannot-run refuses with CANNOT-RUN (rc=2)" ;;
    0) bad "0 pass / 0 fail / 0 cannot-run exited 0 GREEN -- the anti-vacuity floor is absent or broken" ;;
    *) bad "0 pass / 0 fail / 0 cannot-run gave rc=${RC}, expected 2" ;;
esac
if printf '%s' "$OUT" | grep -qi 'examined NOTHING'; then
    ok "the refusal says plainly that nothing was examined"
else
    bad "the refusal does not say the run examined nothing"
    printf '%s\n' "$OUT" | sed 's/^/          /'
fi
if printf '%s' "$OUT" | grep -q 'PROVENANCE GREEN'; then
    bad "the output STILL contains 'PROVENANCE GREEN' text alongside the refusal"
fi

echo
echo "== 3. THE SAME SHAPE via --skip-kind covering the manifest's only kind =="
OUT="$(run_gate OSTLER_PROVENANCE_SKIP_KINDS=vendor_file)"; RC=$?
case "$RC" in
    2) ok "skip-kind covering every row also refuses with CANNOT-RUN (rc=2)" ;;
    0) bad "skip-kind covering every row exited 0 GREEN" ;;
    *) bad "skip-kind covering every row gave rc=${RC}, expected 2" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
