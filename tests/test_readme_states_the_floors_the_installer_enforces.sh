#!/usr/bin/env bash
#
# tests/test_readme_states_the_floors_the_installer_enforces.sh
#
# WHAT A CUSTOMER READS BEFORE THEY DOWNLOAD MUST BE WHAT THE PRODUCT DOES.
#
# Measured 2026-09-07 on origin/main: README.md said "macOS 13 (Ventura) or
# later" while gui/project.yml sets MACOSX_DEPLOYMENT_TARGET 14.0 -- the
# installer .app carries LSMinimumSystemVersion 14.0 and will not open on 13.
# It said "35 GB free disk" while install.sh warns below 35 GB and REFUSES
# below 15 GB, so a customer with 20 GB free was told they could not install
# a product that would have installed. Both figures had a second copy in the
# README that nothing compared to the file enforcing it.
#
# THIS TEST TAKES EVERY FIGURE FROM THE FILE THAT ENFORCES IT and requires the
# README to state it:
#
#   macOS floor   gui/project.yml   MACOSX_DEPLOYMENT_TARGET: "N.M"   -> N
#   disk floor    install.sh        $FREE_GB -lt <n>   (two: warn, refuse)
#   RAM floor     install.sh        $RAM_GB  -lt <n>   (two: refuse, warn)
#
# Each extraction must find EXACTLY the number of figures it expects, or the
# run is CANNOT-RUN: "found nothing" and "could not look" print identically,
# and a README compared to nothing passes for free.
#
# And two mutants on a COPY of the README, each proved landed by diff:
#   M1  the macOS floor drops by one   -> case-1 must fail
#   M2  the disk floor figure vanishes -> case-2 must fail
#
# Exit: 0 all cases passed, 1 a case failed, 2 could not run.
# BASH 3.2 clean.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="${OSTLER_README_UNDER_TEST:-${REPO_ROOT}/README.md}"
INSTALL_SH="${REPO_ROOT}/install.sh"
PROJECT_YML="${REPO_ROOT}/gui/project.yml"
RC_FAIL=1
RC_CANNOT_RUN=2
RUN_MUTANTS=1
[[ "${1:-}" == "--no-mutants" ]] && RUN_MUTANTS=0

cannot_run() {
    echo "" >&2
    echo "CANNOT-RUN: $1" >&2
    echo "  NOTHING was checked. This is not a pass." >&2
    exit "$RC_CANNOT_RUN"
}
fail() {
    echo "FAIL [$1]: $2" >&2
    exit "$RC_FAIL"
}
count() {   # $1 fixed string, $2 text -> lines containing it
    printf '%s\n' "$2" | grep -cF -- "$1"
}
lines() {   # how many non-empty lines in $1
    printf '%s\n' "$1" | grep -c .
}

[[ -f "$README" ]]      || cannot_run "README not found at $README"
[[ -f "$INSTALL_SH" ]]  || cannot_run "install.sh not found at $INSTALL_SH"
[[ -f "$PROJECT_YML" ]] || cannot_run "gui/project.yml not found at $PROJECT_YML"
command -v diff >/dev/null 2>&1 || cannot_run "diff not on PATH"

# ── the enforcing files ─────────────────────────────────────────────────
DEPLOY="$(grep -E '^[[:space:]]*MACOSX_DEPLOYMENT_TARGET:[[:space:]]*"[0-9]+\.[0-9]+"' "$PROJECT_YML" | grep -oE '[0-9]+\.[0-9]+')"
[[ "$(lines "$DEPLOY")" -eq 1 ]] || cannot_run "expected exactly one MACOSX_DEPLOYMENT_TARGET in gui/project.yml, found $(lines "$DEPLOY")"
MAC_FLOOR="${DEPLOY%%.*}"

# shellcheck disable=SC2016  # the literal $FREE_GB / $RAM_GB text is the subject
DISK_NUMS="$(grep -oE '\$FREE_GB -lt [0-9]+' "$INSTALL_SH" | grep -oE '[0-9]+$' | sort -n)"
[[ "$(lines "$DISK_NUMS")" -eq 2 ]] || cannot_run "expected exactly two '\$FREE_GB -lt <n>' checks in install.sh (warn + refuse), found $(lines "$DISK_NUMS")"
DISK_FLOOR="$(printf '%s\n' "$DISK_NUMS" | head -n 1)"
DISK_REC="$(printf '%s\n' "$DISK_NUMS" | tail -n 1)"
[[ "$DISK_FLOOR" -lt "$DISK_REC" ]] || cannot_run "install.sh's two disk thresholds are not floor < recommended: ${DISK_FLOOR} ${DISK_REC}"

# shellcheck disable=SC2016
RAM_NUMS="$(grep -oE '\$RAM_GB -lt [0-9]+' "$INSTALL_SH" | grep -oE '[0-9]+$' | sort -n)"
[[ "$(lines "$RAM_NUMS")" -eq 2 ]] || cannot_run "expected exactly two '\$RAM_GB -lt <n>' checks in install.sh (refuse + warn), found $(lines "$RAM_NUMS")"
RAM_MIN="$(printf '%s\n' "$RAM_NUMS" | head -n 1)"
RAM_REC="$(printf '%s\n' "$RAM_NUMS" | tail -n 1)"

echo "enforced: macOS >= ${MAC_FLOOR} (gui/project.yml ${DEPLOY}); disk warn < ${DISK_REC} GB, refuse < ${DISK_FLOOR} GB; RAM refuse < ${RAM_MIN} GB, warn < ${RAM_REC} GB"

# ── the README rows ─────────────────────────────────────────────────────
MAC_ROW="$(grep -E '^\| macOS ' "$README")"
[[ "$(lines "$MAC_ROW")" -eq 1 ]] || cannot_run "expected exactly one '| macOS ...' row in the README prerequisites table, found $(lines "$MAC_ROW")"
DISK_ROW="$(grep -iE '^\|[^|]*free disk' "$README")"
[[ "$(lines "$DISK_ROW")" -eq 1 ]] || cannot_run "expected exactly one '... free disk' row in the README prerequisites table, found $(lines "$DISK_ROW")"
RAM_ROW="$(grep -iE '^\|[^|]*GB RAM' "$README")"
[[ "$(lines "$RAM_ROW")" -eq 1 ]] || cannot_run "expected exactly one '... GB RAM' row in the README prerequisites table, found $(lines "$RAM_ROW")"

# ── case-1: the macOS floor ─────────────────────────────────────────────
# The CLAIM is the Requirement cell (the first column); the Why cell may
# repeat the figure with a minor version, and that is not the claim.
MAC_CELL="$(printf '%s' "$MAC_ROW" | cut -d'|' -f2)"
MAC_SAID="$(printf '%s' "$MAC_CELL" | grep -oE 'macOS [0-9]+' | grep -oE '[0-9]+')"
[[ "$(lines "$MAC_SAID")" -eq 1 ]] || cannot_run "the README macOS requirement cell names $(lines "$MAC_SAID") version numbers, wanted exactly one: ${MAC_CELL}"
if [[ "$MAC_SAID" != "$MAC_FLOOR" ]]; then
    fail case-1 "the README tells the customer macOS ${MAC_SAID}, but the installer app is built for ${DEPLOY} (gui/project.yml MACOSX_DEPLOYMENT_TARGET) and will not open below ${MAC_FLOOR}.
  README row: ${MAC_ROW}"
fi
echo "PASS [case-1]: README macOS floor ${MAC_SAID} matches the deployment target ${DEPLOY}"

# ── case-2: the disk floor and the recommendation ───────────────────────
[[ "$(count "${DISK_REC} GB" "$DISK_ROW")" -ge 1 ]] \
    || fail case-2 "the README disk row does not state the ${DISK_REC} GB recommendation the installer warns below: ${DISK_ROW}"
[[ "$(count "${DISK_FLOOR} GB" "$DISK_ROW")" -ge 1 ]] \
    || fail case-2 "the README disk row does not state the ${DISK_FLOOR} GB floor the installer refuses below, so a customer between ${DISK_FLOOR} and ${DISK_REC} GB is told they cannot install: ${DISK_ROW}"
[[ "$(printf '%s' "$DISK_ROW" | grep -ci 'floor')" -ge 1 ]] \
    || fail case-2 "the README disk row names two figures but not which one is the floor: ${DISK_ROW}"
echo "PASS [case-2]: README disk row states ${DISK_REC} GB recommended and the ${DISK_FLOOR} GB floor"

# ── case-3: the RAM figures ─────────────────────────────────────────────
[[ "$(count "${RAM_MIN} GB" "$RAM_ROW")" -ge 1 ]] \
    || fail case-3 "the README RAM row does not state the ${RAM_MIN} GB minimum the installer refuses below: ${RAM_ROW}"
[[ "$(count "${RAM_REC} GB" "$RAM_ROW")" -ge 1 ]] \
    || fail case-3 "the README RAM row does not state the ${RAM_REC} GB the installer warns below: ${RAM_ROW}"
echo "PASS [case-3]: README RAM row states ${RAM_MIN} GB minimum and ${RAM_REC} GB recommended"

# ── case-4: mutants on a COPY of the README ─────────────────────────────
if [[ "$RUN_MUTANTS" -eq 1 ]]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/readmefloors.XXXXXX")" || cannot_run "could not create a scratch directory"
    trap 'rm -rf "$WORK"' EXIT
    mutate() {   # $1 sed expr, $2 out -> rc 2 if it did not land
        local changed
        sed -e "$1" "$README" > "$2"
        changed="$(diff "$README" "$2" | grep -c '^>')"
        [[ "$changed" -eq 1 ]] || { echo "  mutant did not land: ${changed} changed line(s), wanted 1" >&2; return 2; }
    }
    # M1: the macOS floor drops by one.
    mutate "s/^| macOS ${MAC_FLOOR} /| macOS $((MAC_FLOOR - 1)) /" "${WORK}/m1.md" \
        || cannot_run "mutant M1 did not land on the README copy"
    OSTLER_README_UNDER_TEST="${WORK}/m1.md" bash "$0" --no-mutants >/dev/null 2>&1; rc=$?
    [[ "$rc" -eq "$RC_FAIL" ]] || fail case-4 "mutant M1 SURVIVED (rc=${rc}): a README that names macOS $((MAC_FLOOR - 1)) was not caught, so case-1 is decoration"
    # M2: the disk floor figure vanishes from the disk row -- EVERY occurrence
    # (the row states it twice), or the mutant is decoration itself. The
    # first draft lacked the g flag and survived exactly that way.
    mutate "/free disk/ s/${DISK_FLOOR} GB/some GB/g" "${WORK}/m2.md" \
        || cannot_run "mutant M2 did not land on the README copy"
    OSTLER_README_UNDER_TEST="${WORK}/m2.md" bash "$0" --no-mutants >/dev/null 2>&1; rc=$?
    [[ "$rc" -eq "$RC_FAIL" ]] || fail case-4 "mutant M2 SURVIVED (rc=${rc}): a README disk row without the ${DISK_FLOOR} GB floor was not caught, so case-2 is decoration"
    echo "PASS [case-4]: both mutants killed (M1 by case-1, M2 by case-2)"
fi

echo ""
echo "ALL README-FLOOR TESTS PASSED"
exit 0
