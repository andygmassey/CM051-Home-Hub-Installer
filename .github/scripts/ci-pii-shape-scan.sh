#!/usr/bin/env bash
# ci-pii-shape-scan.sh -- the PII check that CAN actually run in CI.
#
# WHY THIS EXISTS
#
# `operator-pii-scan.sh` is a DENYLIST. It reads Andy's real inventory from
# ${HOME}/.ostler-operator-pii.toml and greps for those exact values. That is
# the right control on a developer machine and the wrong one in CI, because CI
# cannot have that file: the values ARE the PII, and the committed fallback at
# .github/operator-pii-inventory.toml is a blank template by design.
#
# MEASURED 2026-08-12 on CM051 #583: the committed inventory has every scalar
# set to "" and every array empty, so the scanner assembles ZERO patterns and
# exits 2 "inventory empty". After the wrapper fix stopped laundering failures
# into exit 0, that exit 2 became a hard red on EVERY CM051 pull request. The
# red said "PII" and meant "I could not run". A gate whose red carries no
# information gets routed around, which is worse than no gate.
#
# Provisioning the inventory as an Actions secret was proposed and WITHDRAWN.
# It is not coming back. So CI needs a check that needs no inventory.
#
# WHAT THIS DOES INSTEAD
#
# Scans for the SHAPE of PII rather than for known values. The patterns live
# in .githooks/pii_patterns.sh and have their own test suite asserting they
# fire on synthetic SSN and UK-phone input and stay quiet on clean input.
#
# WHAT IT COVERS, EXACTLY. `pii_load_patterns` returns FIVE patterns and all
# five are numeric:
#
#     UK mobile, international form   +44 7xxx xxxxxx
#     UK mobile, national form        07xxx xxxxxx
#     US phone                        +1 (xxx) xxx-xxxx
#     SSN                             xxx-xx-xxxx
#     long digit run                  15+ consecutive digits (DSID and kin)
#
# WHAT IT DOES NOT COVER, and this paragraph is load-bearing. This header used
# to claim "email addresses, /Users/<name>/ home paths" as well. It does not
# scan for either. Those checks are built in to .githooks/pre-commit (see
# pii_patterns.sh:10 and :35), and pre-commit does not run in CI, so on a pull
# request both classes have a denominator of ZERO.
#
# MEASURED 2026-08-15 over the 485 tracked files under vendor/: the email class
# has 90 distinct addresses in it, around 33 of them on domains that are not
# obvious fixtures. None of that is visible to this gate. A reader who trusted
# the old header would have believed it was. Adding those two classes needs a
# canary per class -- the point of the block below is that a pattern set nobody
# has demonstrated is worth nothing -- and that is tracked separately.
#
# Person NAMES are a different instrument again: tests/vendor_person_name_sweep.py.
#
# Shape-based is strictly stronger than a denylist for the classes it does
# cover. A denylist can only catch values someone already wrote down; it can
# never catch the first leak of a number nobody has enumerated. This catches a
# phone-shaped literal whoever it belongs to.
#
# THE CANARY, AND WHY IT RUNS EVERY TIME
#
# `pii_scan_files` returns 0 unconditionally and reports hits on STDOUT, and
# `pii_load_patterns` yields nothing at all when it finds no patterns. A naive
# wrapper around it reports "clean" when the detector loaded nothing -- the
# exact zero-denominator failure that put the denylist in this state.
#
# So before scanning anything real, this scans a synthetic known-bad file and
# REQUIRES a hit. If the canary does not fire, the detector is broken or empty
# and the run is CANNOT-RUN, never a pass. The gate demonstrates its own RED on
# every single invocation rather than once, in a shell, on the day it was
# written.
#
# Exit codes
#   0  scanned N files, no shape hits  (N is always printed, including 0)
#   1  at least one shape hit          (BLOCK)
#   2  CANNOT-RUN: pattern library missing, no patterns loaded, or the canary
#      failed to fire. Never silently a pass.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LIB="${PII_PATTERNS_LIB:-$REPO_ROOT/.githooks/pii_patterns.sh}"

if [ ! -r "$LIB" ]; then
    echo "ci-pii-shape-scan: CANNOT-RUN -- no pattern library at $LIB" >&2
    echo "  Provision it with bin/install-pii-guards.sh from the HR015 repo." >&2
    exit 2
fi
# shellcheck disable=SC1090
. "$LIB"

CUSTOM="$REPO_ROOT/.pii-patterns"
[ -f "$CUSTOM" ] || CUSTOM=""

PATTERN_COUNT="$(pii_load_patterns "$CUSTOM" | grep -c . || true)"
if [ "${PATTERN_COUNT:-0}" -eq 0 ]; then
    echo "ci-pii-shape-scan: CANNOT-RUN -- the pattern library loaded 0 patterns." >&2
    echo "  Zero patterns would report every file clean. That is not a pass." >&2
    exit 2
fi

# ── Positive control ──────────────────────────────────────────────────────
# Composed from parts on purpose: a phone-shaped literal written directly into
# this file would be blocked by the very hook this script supports. A gate must
# not carry the thing it hunts.
#
# THE CANARY MUST BE A NON-RESERVED NUMBER. It used to be an OFCOM drama-range
# one (+44 7700 900xxx), which was correct while this repo's copy of
# pii_patterns.sh reported on a bare `grep -l`. Re-provisioning that library
# from HR015 brought pii_reserved_placeholder_re with it, whose entire job is
# to EXCUSE the drama range -- so the canary stopped firing and this scanner
# went permanently CANNOT-RUN.
#
# It failed in the right direction, which is the point of the canary: it
# refused to report a pass rather than reporting a clean tree it had not
# examined. But a permanently-refusing gate is still a dead gate, so the
# fixture has to sit outside every reserved range. If this scanner ever goes
# CANNOT-RUN across the board, check whether a reserved range swallowed the
# canary before looking at the patterns.
CANARY_DIR="$(mktemp -d -t pii-canary-XXXXXX)"
trap 'rm -rf "$CANARY_DIR"' EXIT
_cc="+44"; _sub="7911123456"
printf 'contact = "%s%s"\n' "$_cc" "$_sub" > "$CANARY_DIR/canary.txt"

CANARY_HIT="$(pii_scan_files "$CANARY_DIR/canary.txt" "$CUSTOM")"
if [ -z "$CANARY_HIT" ]; then
    echo "ci-pii-shape-scan: CANNOT-RUN -- the canary did not fire." >&2
    echo "  $PATTERN_COUNT pattern(s) loaded, yet a known phone-shaped literal" >&2
    echo "  was not detected. The detector is broken; a clean result from it" >&2
    echo "  would be meaningless. Refusing to report a pass." >&2
    exit 2
fi

# ── Resolve what to scan ──────────────────────────────────────────────────
# BASE_REF set   -> the diff against it (pull request)
# args given     -> those paths
# neither        -> tracked files
#
# IN PR MODE THIS SCANS ADDED LINES, NOT WHOLE FILES. Read this before
# "tightening" it back, because the whole-file version is the obvious one and it
# is the one that broke.
#
# v1 collected `git diff --name-only` and then scanned each named file in full.
# MEASURED 2026-08-12 on CM051 #587: that PR changed exactly two lines of
# install.sh, both of them a Docker image digest, and the scan failed it on
# install.sh lines 3695 and 3746 -- two `echo "  Example: ..."` strings in
# installer prompt copy that have been on main for months and that this PR never
# touched. Every PR touching install.sh was therefore red, permanently, with a
# red that said nothing about the PR.
#
# That is precisely the failure this file's own header warns about: "A gate
# whose red carries no information gets routed around, which is worse than no
# gate." It was describing the denylist and had become true of itself.
#
# The question a PR gate answers is "did THIS CHANGE introduce PII-shaped
# content". Pre-existing content is an audit question, and the no-BASE_REF
# branch below still scans the whole tree for exactly that.
#
# THE HOLE THAT NARROWING WOULD OTHERWISE OPEN, and how it is closed: a rename
# can carry a file full of PII to a new path while git reports no added lines.
# So A (added) and R/C (renamed/copied) are scanned IN FULL -- all of their
# content is new at that path -- and only M (modified) is narrowed to its added
# lines. Deleting PII is not a violation, so removed lines are never scanned.
FILES=""
ADDED_ONLY_DIR=""
if [ "$#" -gt 0 ]; then
    FILES="$(printf '%s\n' "$@")"
    SOURCE="$# path argument(s)"
elif [ -n "${BASE_REF:-}" ]; then
    if ! git rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
        echo "ci-pii-shape-scan: CANNOT-RUN -- BASE_REF '$BASE_REF' does not resolve." >&2
        echo "  A shallow checkout cannot see the base. Fetch it before scanning;" >&2
        echo "  scanning nothing must not read as scanning clean." >&2
        exit 2
    fi
    # Whole-file set: added, renamed, copied.
    FILES="$(git diff --name-only --diff-filter=ARC "$BASE_REF"...HEAD)"
    # Modified files: materialise ONLY their added lines, one temp file each,
    # named after the real path so a hit still names something a human can find.
    ADDED_ONLY_DIR="$(mktemp -d -t pii-added-XXXXXX)"
    while IFS= read -r mf; do
        [ -n "$mf" ] || continue
        added="$(git diff -U0 "$BASE_REF"...HEAD -- "$mf" \
                 | sed -n 's/^+\([^+].*\)$/\1/p; s/^+$//p')"
        [ -n "$added" ] || continue
        dest="$ADDED_ONLY_DIR/$mf"
        mkdir -p "$(dirname "$dest")"
        printf '%s\n' "$added" > "$dest"
        FILES="$FILES
$dest"
    done <<< "$(git diff --name-only --diff-filter=M "$BASE_REF"...HEAD)"
    SOURCE="diff vs $BASE_REF (added lines of modified files; whole file if added or renamed)"
else
    FILES="$(git ls-files)"
    SOURCE="all tracked files"
fi
[ -z "$ADDED_ONLY_DIR" ] || trap 'rm -rf "$CANARY_DIR" "$ADDED_ONLY_DIR"' EXIT

# Drop paths that no longer exist. REFUSE directories -- see below.
#
# MEASURED 2026-08-15 on CM051. This loop used to filter with `[ -f ]` alone,
# which discards a directory as quietly as it discards a stale path. So
#
#     ci-pii-shape-scan.sh vendor/
#
# printed "examining 0 file(s) ... Nothing was scanned, and nothing was found."
# and exited 0. The same tree handed over as an explicit 485-file list exits 1
# on twelve files. The text was honest and the EXIT CODE was not, and exit 0 is
# what a caller reads.
#
# That is the failure this file's own header names: "a green tick" over a zero.
# It was describing the printed line and had become true of the status. CI never
# hit it (the workflow passes no arguments and sets BASE_REF), but the audit
# path -- a human scanning a subtree by hand -- is exactly where a directory
# gets typed, and it is the path with no second check behind it.
#
# A stale path is still dropped silently: git can name a file the working tree
# no longer has, and that is not a caller error. A directory IS a caller error.
EXISTING=""
DIRS=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -d "$f" ]; then
        DIRS="$DIRS    $f
"
        continue
    fi
    [ -f "$f" ] || continue
    EXISTING="$EXISTING$f
"
done <<< "$FILES"

if [ -n "$DIRS" ]; then
    echo "ci-pii-shape-scan: CANNOT-RUN -- directory argument(s) given:" >&2
    printf '%s' "$DIRS" >&2
    echo "  This scanner reads FILES. It cannot walk a directory, and reporting" >&2
    echo "  the resulting zero as a pass would be a clean bill from a scan that" >&2
    echo "  examined nothing. Expand it first:" >&2
    echo "    .github/scripts/ci-pii-shape-scan.sh \$(git ls-files -- 'vendor/*')" >&2
    exit 2
fi

COUNT="$(printf '%s' "$EXISTING" | grep -c . || true)"

echo "ci-pii-shape-scan: $PATTERN_COUNT pattern(s) loaded, canary fired, examining $COUNT file(s) from $SOURCE"

if [ "${COUNT:-0}" -eq 0 ]; then
    # Honest zero. Printed, not hidden behind a green tick.
    echo "ci-pii-shape-scan: 0 files to examine. Nothing was scanned, and nothing was found."
    exit 0
fi

HITS="$(pii_scan_files "$EXISTING" "$CUSTOM")"

if [ -n "$HITS" ]; then
    echo "ci-pii-shape-scan: PII-shaped content in $COUNT examined file(s):" >&2
    printf '%s\n' "$HITS" >&2
    echo "" >&2
    echo "These patterns match on SHAPE, not on a list of known values, so a" >&2
    echo "synthetic-looking number still trips them. Do not weaken the pattern" >&2
    echo "and do not bypass the hook. Compose the literal from parts at runtime," >&2
    echo "or move the fixture under a path the guard excludes." >&2
    exit 1
fi

echo "ci-pii-shape-scan: clean, $COUNT file(s) examined"
exit 0
