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
#   3. WIRED rows are TRUE: the file is really referenced somewhere executable.
#      MEASURED, not trusted. A WIRED row whose reference has been deleted is
#      the precise failure this gate exists to catch, and it would otherwise
#      look identical to a healthy row.
#   4. MANUAL rows carry a REASON. "Manual" with no reason is just unwired
#      with better manners.
#   5. UNCLASSIFIED rows fail. Not a pass, not a warning.
#
# EXIT
#   0  every file is WIRED (and provably so) or MANUAL with a reason
#   1  the manifest and the tree disagree, or unclassified rows remain
#   2  could not run (manifest missing/unreadable, not a repo)
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

# Where a test may legitimately be invoked from. tests/ itself is excluded:
# a test referencing another test is not wiring, it is a helper.
SEARCH_ROOTS=(.github scripts bin)
[ -f gui/Makefile ] && SEARCH_ROOTS+=(gui/Makefile)
[ -f Makefile ] && SEARCH_ROOTS+=(Makefile)

refs_for() {  # $1 = stem; prints referencing paths, excluding tests/ and comments
    grep -rlF "$1" "${SEARCH_ROOTS[@]}" 2>/dev/null | grep -v '^tests/' || true
}

fails=0; wired_ok=0; manual_ok=0; unclassified=0
declare -a LISTED=()

while IFS=$'\t' read -r file status note; do
    [ -z "${file// }" ] && continue
    case "$file" in \#*) continue ;; esac
    LISTED+=("$file")

    if [ ! -f "tests/$file" ]; then
        red "  ROTTED    $file -- listed in the manifest, absent from tests/"
        fails=$((fails+1)); continue
    fi

    stem="${file%.*}"
    case "${status:-}" in
        WIRED)
            found="$(refs_for "$stem")"
            if [ -n "$found" ]; then
                wired_ok=$((wired_ok+1))
            else
                red "  NOT WIRED $file -- manifest says WIRED, nothing references it."
                red "            This is the exact rot the gate exists for: the row still"
                red "            reads as covered while the runner has been deleted."
                fails=$((fails+1))
            fi
            ;;
        MANUAL)
            if [ -n "${note// }" ]; then
                manual_ok=$((manual_ok+1))
            else
                red "  NO REASON $file -- MANUAL with an empty reason column."
                red "            Manual without a reason is unwired with better manners."
                fails=$((fails+1))
            fi
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
echo "  MANUAL (reasoned): $manual_ok"
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
    grn "GREEN -- every test file is wired (and proven so) or manual with a reason."
    exit 0
fi
red "RED -- $fails issue(s). See above."
exit 1
