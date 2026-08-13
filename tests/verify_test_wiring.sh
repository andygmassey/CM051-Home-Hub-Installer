#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify_test_wiring.sh -- every test file is WIRED or declared MANUAL.
#
# v1018-D675. Measured 2026-08-13: 171 test files, 40 referenced anywhere
# executable, 131 referenced NOWHERE. Among the unwired were the daemon
# signature gate, both red-team pin tests, the walk-away input-leak test, and a
# guard shipped four days earlier that had never run once.
#
# A test that nobody runs is not a safety net. It is a note claiming there is
# one. This gate makes the claim checkable.
#
# WHAT IT CHECKS
#   1. every tests/test_* file has a row in TEST_WIRING.tsv  (no new file
#      slips in unlisted -- that is how the 131 accumulated)
#   2. every row names a file that still exists              (no rotted rows)
#   3. WIRED rows are TRUE: the file is really referenced somewhere executable,
#      on a line that is not a comment. MEASURED, not trusted. A WIRED row
#      whose reference has been deleted is the precise failure this gate exists
#      to catch, and it would otherwise look identical to a healthy row.
#   4. MANUAL rows carry a REASON, a DECLARER and a REVIEW-BY date, and the
#      date has not passed. A permanent opt-out is unwired with better manners.
#   5. MANUAL rows that are in fact referenced fail: the declaration is stale.
#   6. UNCLASSIFIED rows fail. Not a pass, not a warning.
#
# TWO CORRECTIONS ARE BAKED IN HERE. Both were found after the first version
# was written, and both are the house defect.
#
#   MATCH THE FULL FILENAME, NEVER THE STEM.
#   The first version matched the extensionless stem, so test_install_gui_
#   contract.py was satisfied by any reference to test_install_gui_contract_
#   negatives.py. Both are referenced today, so nothing was mis-reported -- but
#   delete the first from its workflow and this gate would still have called it
#   WIRED. A latent false pass in the one direction the gate exists to police.
#   Measured across the tree at the time: 172 stems, exactly 1 such collision.
#
#   A MENTION IN A COMMENT IS NOT WIRING.
#   grep -l answers "does this file contain the string", which is not the
#   question. Earlier the same day a comment in cut.yml was counted as CI
#   wiring for a different gate. Reference lines are filtered for leading # and
#   // before they count.
#
# THE EXPIRY on MANUAL is Archie's, and it is paid for: CM051 cut-deferrals.yaml
# still carried a deferral for #606 after #606 had merged, and is_deferred() ran
# before branch_landed(), so the gate printed DEFERRED over shipping work. A
# reason field with no review date is that bug wearing a badge.
#
# EXIT
#   0  every file is WIRED (and provably so) or MANUAL, reasoned and in date
#   1  the manifest and the tree disagree, or unclassified rows remain
#   2  could not run (manifest missing/unreadable, not a repo, no usable date)
#      A gate that cannot run is NOT a pass.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || { echo "cannot cd to repo root" >&2; exit 2; }

MANIFEST="tests/TEST_WIRING.tsv"
red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

[ -f "$MANIFEST" ] || { red "UNAVAILABLE: $MANIFEST not found."; red "Without it there is nothing to check against, and 'no findings' would mean 'no expectations'."; exit 2; }

# TODAY drives the MANUAL expiry check. Overridable so the self-test can pin it
# -- a control that depends on the wall clock passes or fails by calendar.
TODAY="${TEST_WIRING_TODAY:-$(date +%F)}"
case "$TODAY" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) red "UNAVAILABLE: cannot establish today's date (got '$TODAY')."
       red "The MANUAL expiry check is unenforceable without it, and skipping it silently"
       red "would turn every expired opt-out green. Refusing to run."
       exit 2 ;;
esac

# Where a test may legitimately be invoked from. tests/ itself is excluded:
# a test referencing another test is not wiring, it is a helper.
SEARCH_ROOTS=(.github scripts bin)
[ -f gui/Makefile ] && SEARCH_ROOTS+=(gui/Makefile)
[ -f Makefile ] && SEARCH_ROOTS+=(Makefile)

# Prints the paths that reference $1 on a line that is not a comment.
# $1 is the FULL basename including extension.
#
# MATCHING IS ON THE STEM WITH AN IDENTIFIER BOUNDARY, not on the raw filename,
# because a python test is legitimately invoked WITHOUT its extension:
#
#     python3 -m unittest tests.test_tailnet_owner_resolution
#
# A filename-only match called that test unwired, which is a false negative in
# the direction that creates busywork rather than false comfort -- but it is
# still wrong, and it demoted a genuinely-wired row on first run.
#
# The boundary is what keeps this from collapsing back into the stem bug:
# [^A-Za-z0-9_] on both sides means test_alpha matches "test_alpha.sh" and
# "tests.test_alpha" but NOT "test_alpha_extra", because _ is an identifier
# character. Verified against the tree: no two tests share a stem across
# extensions, so a .sh row cannot be satisfied by a .py file of the same name.
refs_for() {
    local name="$1" stem cand pat
    stem="${name%.*}"
    pat="(^|[^A-Za-z0-9_])${stem}([^A-Za-z0-9_]|$)"
    for cand in $(grep -rlE -- "$pat" "${SEARCH_ROOTS[@]}" 2>/dev/null | grep -v '^tests/'); do
        # A hit only counts if some line carrying it is executable text.
        # Leading-# (yaml, make, sh, py) and leading-// are comments.
        if grep -E -- "$pat" "$cand" 2>/dev/null \
             | sed 's/^[[:space:]]*//' \
             | grep -qvE '^(#|//)'; then
            printf '%s\n' "$cand"
        fi
    done
}

fails=0; wired_ok=0; manual_ok=0; unclassified=0
declare -a LISTED=()

while IFS=$'\t' read -r file status note declarer review; do
    [ -z "${file// }" ] && continue
    case "$file" in \#*) continue ;; esac
    LISTED+=("$file")

    if [ ! -f "tests/$file" ]; then
        red "  ROTTED    $file -- listed in the manifest, absent from tests/"
        fails=$((fails+1)); continue
    fi

    case "${status:-}" in
        WIRED)
            found="$(refs_for "$file")"
            if [ -n "$found" ]; then
                wired_ok=$((wired_ok+1))
            else
                red "  NOT WIRED $file -- manifest says WIRED, nothing executable references it."
                red "            This is the exact rot the gate exists for: the row still"
                red "            reads as covered while the runner has been deleted."
                fails=$((fails+1))
            fi
            ;;
        MANUAL)
            row_bad=0
            if [ -z "${note// }" ]; then
                red "  NO REASON $file -- MANUAL with an empty reason column."
                red "            Manual without a reason is unwired with better manners."
                row_bad=1
            fi
            if [ -z "${declarer:-}" ] || [ -z "${declarer// }" ]; then
                red "  NO OWNER  $file -- MANUAL with nobody declaring it."
                row_bad=1
            fi
            case "${review:-}" in
                [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
                    if [ "$review" \< "$TODAY" ]; then
                        red "  EXPIRED   $file -- MANUAL review date $review has passed (today $TODAY)."
                        red "            Re-confirm it is still unautomatable, or wire it. An opt-out"
                        red "            that never comes up for review is a permanent hiding place."
                        row_bad=1
                    fi
                    ;;
                *)
                    red "  NO EXPIRY $file -- MANUAL needs a YYYY-MM-DD review-by date (got '${review:-<empty>}')."
                    row_bad=1
                    ;;
            esac
            # A MANUAL row that IS referenced is a stale declaration, not a
            # harmless one: it under-states coverage and hides a runner nobody
            # knows exists.
            if [ -n "$(refs_for "$file")" ]; then
                red "  STALE     $file -- declared MANUAL but something executable DOES run it."
                red "            Change the row to WIRED, or remove the runner."
                row_bad=1
            fi
            if [ "$row_bad" -eq 0 ]; then manual_ok=$((manual_ok+1)); else fails=$((fails+1)); fi
            ;;
        UNCLASSIFIED)
            unclassified=$((unclassified+1))
            ;;
        *)
            red "  BAD STATUS $file -- '${status:-<empty>}' is not WIRED/MANUAL/UNCLASSIFIED"
            fails=$((fails+1))
            ;;
    esac
done < "$MANIFEST"

# Any test on disk with no row at all. This is how 131 accumulated unnoticed.
missing=0
for f in tests/test_*.sh tests/test_*.py; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    hit=0
    for l in ${LISTED[@]+"${LISTED[@]}"}; do [ "$l" = "$b" ] && { hit=1; break; }; done
    if [ "$hit" -eq 0 ]; then
        red "  UNLISTED  $b -- exists in tests/, has no manifest row"
        missing=$((missing+1)); fails=$((fails+1))
    fi
done

echo ""
echo "  WIRED (verified):  $wired_ok"
echo "  MANUAL (in date):  $manual_ok"
echo "  UNCLASSIFIED:      $unclassified"
echo "  unlisted on disk:  $missing"
echo ""

if [ "$unclassified" -gt 0 ]; then
    ylw "  $unclassified file(s) are still UNCLASSIFIED."
    ylw "  Each needs a WIRED or MANUAL ruling. Do NOT bulk-convert them to"
    ylw "  MANUAL to go green -- that turns this manifest into the defect it records."
    fails=$((fails+unclassified))
fi

if [ "$fails" -eq 0 ]; then
    grn "GREEN -- every test file is wired (and proven so) or manual, reasoned and in date."
    exit 0
fi
red "RED -- $fails issue(s). See above."
exit 1
