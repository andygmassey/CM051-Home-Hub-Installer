#!/usr/bin/env bash
#
# test_ship_prereqs_are_a_superset.sh -- CONTROL A.
#
# `ship:` must still name EVERY prerequisite it named before, BY SET.
#
# Exit 0  every recorded prerequisite is still there.
# Exit 1  at least one is GONE. Each missing name is printed.
# Exit 2  CANNOT RUN. Nothing has been found missing; this failed to LOOK.
#
# ============================================================================
# WHY A SET AND NOT A COUNT
# ============================================================================
#
# A count is satisfied by a SWAP. Drop verify-stapling, add publish-appcast,
# and a count-based assertion sees 22 before and 22 after and reports no
# change -- while the cut has silently stopped checking that anything carries
# a notarisation ticket. The defect and the instrument would be on different
# axes, which is the shape that lets a gate stay green for ever.
#
# So the assertion is SUPERSET: the new prerequisite list must contain every
# name in the recorded set. Additions are expected and are printed, not
# failed -- this file is a floor, not a freeze. Removals are the failure, and
# the message names the removed prerequisite, because "ship changed" sends a
# reader to diff a 2400-line Makefile whereas "verify-stapling is gone" sends
# them to the line.
#
# ============================================================================
# WHY THIS TEST EXISTS AT ALL
# ============================================================================
#
# The change that added publish-appcast to `ship:` was, at the time it was
# written, a GRAFT rather than a rebase. The branch that first wrote the
# publish target (feat/au1-wire-appcast-publish) forked at 1e365ef on 28 June
# and was 474 commits behind main when this landed; over that span gui/Makefile
# moved +1424 / -49 and `ship:` went from 10 prerequisites to 22. Rebasing that
# branch conflicts on the `ship:` line itself, and the way a `ship:` conflict is
# resolved wrongly is by taking one side whole -- which silently drops
# prerequisites. A cut that skips a gate and reports success is the precise
# defect this whole effort exists to remove, so the graft got an instrument
# rather than a promise.
#
# ============================================================================
# THE RECORDED SET IS MEASURED, NOT REMEMBERED
# ============================================================================
#
# Read off CM051 origin/main at ddcc0f8 (2026-08-17) with:
#
#     git show origin/main:gui/Makefile | grep '^ship:' \
#       | sed 's/^ship: *//' | tr ' ' '\n' | grep -c .
#
# which printed 22. The brief that commissioned this work said the count had
# gone "10 -> 23" while its own enumeration listed 22 names; the enumeration
# was right. The number below is the measurement, taken at the point of use,
# not the number carried in from the prose.
#
# ============================================================================
# HOW THE SET IS READ
# ============================================================================
#
# From `make -p`, make's own database, NOT from a regex over the file. Make is
# the thing that decides what `ship` depends on, so make is asked. A textual
# parser would have its own idea about variables, continuations and included
# files, and the first time the two disagreed the textual one would be wrong
# and confident.
#
# `-p -n <a target that does not exist>` prints the database and then stops,
# because make refuses the unknown goal before considering any rule. No recipe
# is reached, dry-run or otherwise -- which matters here, since gui/Makefile
# has a recipe containing $(MAKE), and $(MAKE) lines DO execute under -n.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKEFILE="$REPO_ROOT/gui/Makefile"

while [ $# -gt 0 ]; do
    case "$1" in
        # Point the test at a COPY of the Makefile. This is how the control is
        # proven RED: mutate a copy, run this against it, watch it name the
        # prerequisite that went missing. Mutating the tracked file to prove a
        # test works risks leaving the mutation behind.
        --makefile) MAKEFILE="${2:-}"; shift 2 ;;
        -h|--help)  echo "usage: $0 [--makefile <path to a gui/Makefile>]"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# THE RECORDED SET. Measured on origin/main ddcc0f8; see the header.
EXPECTED=(
    guard-local-cut
    check-orphans
    check-pr-age
    download-hub-app
    check-ostler-app
    download-safari-extension
    download-python
    stage-daemon
    stage-payload
    sparkle-embed
    notarise-hub
    release
    sign-python-bundle
    check-manifest
    notarise-app
    staple-apps
    package
    notarise-dmg
    verify-dmg-contents
    verify-stapling
    verify-commit-parity
    archive
)

if [ ! -f "$MAKEFILE" ]; then
    echo "ship-prereqs: CANNOT RUN -- no Makefile at $MAKEFILE" >&2
    exit 2
fi
if ! command -v make >/dev/null 2>&1; then
    echo "ship-prereqs: CANNOT RUN -- make is not on PATH." >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shipprereq-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Ask make, in a scratch directory, so nothing in the real tree is touched and
# no build directory is created by a stray variable expansion.
cp "$MAKEFILE" "$WORK/Makefile"
DUMP="$WORK/dump.txt"
( cd "$WORK" && make -p -n __ship_prereqs_probe_no_such_target__ ) >"$DUMP" 2>"$WORK/err.txt"

# THE PROBE MUST BE VALIDATED BEFORE ITS ANSWER IS BELIEVED. If the database
# dump does not contain a `ship:` rule at all, the honest report is CANNOT RUN.
# Reported as "0 of 22 present" it would look like a catastrophic finding; as
# an empty diff it would look like a pass. It is neither.
SHIP_LINE="$(grep -m1 '^ship:' "$DUMP" || true)"
if [ -z "$SHIP_LINE" ]; then
    echo "ship-prereqs: CANNOT RUN -- make's database has no 'ship:' rule." >&2
    echo "  The Makefile probably failed to parse. This has NOT found a missing" >&2
    echo "  prerequisite; it failed to read the graph at all. make said:" >&2
    sed 's/^/    /' "$WORK/err.txt" >&2
    exit 2
fi

ACTUAL="$WORK/actual.txt"
printf '%s\n' "${SHIP_LINE#ship:}" | tr ' ' '\n' | grep . | sort -u >"$ACTUAL"

MISSING="$WORK/missing.txt"
: >"$MISSING"
for want in "${EXPECTED[@]}"; do
    grep -qxF "$want" "$ACTUAL" || printf '%s\n' "$want" >>"$MISSING"
done

n_expected="${#EXPECTED[@]}"
n_actual="$(wc -l <"$ACTUAL" | tr -d ' ')"
n_missing="$(wc -l <"$MISSING" | tr -d ' ')"
n_present=$(( n_expected - n_missing ))

# STATE THE DENOMINATOR ON EVERY RUN, PASS OR FAIL. "OK" hides how much was
# checked; "22 of 22" is a fact a reader can act on, and it is the line that
# would visibly shrink if somebody quietly trimmed the recorded set.
echo "ship-prereqs: ${n_present} of ${n_expected} recorded prerequisites are still named by 'ship:'"
echo "  (ship: currently names ${n_actual} prerequisites in total)"

ADDED="$WORK/added.txt"
: >"$ADDED"
while IFS= read -r have; do
    found=0
    for want in "${EXPECTED[@]}"; do
        [ "$have" = "$want" ] && { found=1; break; }
    done
    [ "$found" -eq 0 ] && printf '%s\n' "$have" >>"$ADDED"
done <"$ACTUAL"

if [ -s "$ADDED" ]; then
    echo
    echo "  ADDED since the set was recorded (expected -- this gate is a floor, not a freeze):"
    while IFS= read -r a; do echo "    + $a"; done <"$ADDED"
fi

if [ -s "$MISSING" ]; then
    echo >&2
    echo "  MISSING -- 'ship:' no longer names these, so the cut no longer runs them:" >&2
    while IFS= read -r m; do echo "    - $m" >&2; done <"$MISSING"
    echo >&2
    echo "  A prerequisite that leaves 'ship:' does not announce itself: the cut goes" >&2
    echo "  green faster and ships whatever that step was there to refuse. If a step" >&2
    echo "  was removed ON PURPOSE, say so by deleting it from EXPECTED in this file," >&2
    echo "  in the same commit, with the reason -- that edit is reviewable and a" >&2
    echo "  silent disappearance from a merge conflict is not." >&2
    exit 1
fi

echo "  no recorded prerequisite has been dropped."
exit 0
