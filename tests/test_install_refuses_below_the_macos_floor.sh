#!/usr/bin/env bash
#
# tests/test_install_refuses_below_the_macos_floor.sh
#
# THE INSTALLER MUST REFUSE BELOW THE macOS FLOOR THE DMG IS BUILT FOR.
#
# Measured 2026-09-07 on origin/main: the prerequisite check WARNED below
# macOS 13 and said "We recommend macOS 13", while gui/project.yml sets
# MACOSX_DEPLOYMENT_TARGET 14.0, so the installer .app carries
# LSMinimumSystemVersion 14.0 and cannot open on 13. A customer on 13 who got
# past the README would spend an hour installing an app that cannot open.
#
# The fix pins ONE floor in install.sh (OSTLER_MACOS_FLOOR_MAJOR) and refuses
# below it with fail_with_code, in the README's wording. The shipped script
# cannot read gui/project.yml, so this test is what keeps the pin honest.
#
# THIS TEST DRIVES THE REAL BLOCK, extracted from install.sh, with a stubbed
# sw_vers and a stubbed fail_with_code, and locks:
#
#   1  DRIFT      OSTLER_MACOS_FLOOR_MAJOR in install.sh equals the major of
#                 MACOSX_DEPLOYMENT_TARGET in gui/project.yml. One number, or
#                 CANNOT-RUN.
#   2  REFUSES    macOS floor-1 (and floor-2) -> fail_with_code with
#                 ERR-02-PREREQ-MACOS-OLD, the message naming both the
#                 customer's version and the floor.
#   3  ADMITS     macOS floor.0 and floor+1 -> no refusal.
#   4  CONTROL    the PRE-FIX block, carried here as a fixture because a
#                 squash merge orphans the commit it lived in, run through the
#                 SAME harness on floor-1 -> does NOT refuse. This is what
#                 proves the harness can tell the fix from the bug.
#   5  MUTANT     the extracted block with its comparison floored at 0 ->
#                 arm 2 must fail. Proved landed by diff.
#   6  PARSES     the extracted block parses under /bin/bash 3.2.
#
# Exit: 0 all cases passed, 1 a case failed, 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_FILE="${REPO_ROOT}/install.sh.strings.en-GB.sh"
PROJECT_YML="${REPO_ROOT}/gui/project.yml"
RC_FAIL=1
RC_CANNOT_RUN=2

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
lines() {
    printf '%s\n' "$1" | grep -c .
}

[[ -f "$INSTALL_SH" ]]   || cannot_run "install.sh not found at $INSTALL_SH"
[[ -f "$STRINGS_FILE" ]] || cannot_run "string catalogue not found at $STRINGS_FILE"
[[ -f "$PROJECT_YML" ]]  || cannot_run "gui/project.yml not found at $PROJECT_YML"
command -v diff >/dev/null 2>&1 || cannot_run "diff not on PATH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/macosfloor.XXXXXX")" || cannot_run "could not create a scratch directory"
trap 'rm -rf "$WORK"' EXIT

# ── case-1: the pin and the deployment target agree ─────────────────────
DEPLOY="$(grep -E '^[[:space:]]*MACOSX_DEPLOYMENT_TARGET:[[:space:]]*"[0-9]+\.[0-9]+"' "$PROJECT_YML" | grep -oE '[0-9]+\.[0-9]+')"
[[ "$(lines "$DEPLOY")" -eq 1 ]] || cannot_run "expected exactly one MACOSX_DEPLOYMENT_TARGET in gui/project.yml, found $(lines "$DEPLOY")"
DEPLOY_MAJOR="${DEPLOY%%.*}"
PIN="$(grep -oE '^OSTLER_MACOS_FLOOR_MAJOR=[0-9]+$' "$INSTALL_SH" | grep -oE '[0-9]+$')"
[[ "$(lines "$PIN")" -eq 1 ]] || cannot_run "expected exactly one 'OSTLER_MACOS_FLOOR_MAJOR=<n>' line in install.sh, found $(lines "$PIN"). The floor must be pinned in one place, as a literal."
if [[ "$PIN" != "$DEPLOY_MAJOR" ]]; then
    fail case-1 "install.sh pins the macOS floor at ${PIN} but the installer app is built for ${DEPLOY} (gui/project.yml). The check would admit a Mac the app cannot open on, or refuse one it can."
fi
echo "PASS [case-1]: install.sh floor ${PIN} == deployment target ${DEPLOY}"

# ── the harness: the real block, stubs around it ────────────────────────
extract_block() {   # $1 install.sh path -> the prereq macOS block, from sw_vers to the pct=20 emit
    awk '
        /^MACOS_VERSION=\$\(sw_vers -productVersion\)/ { on = 1 }
        on { print }
        on && /^gui_emit PCT "step=prereq_check" "pct=20"/ { exit }
    ' "$1"
}
BLOCK="${WORK}/block.sh"
extract_block "$INSTALL_SH" > "$BLOCK"
[[ -s "$BLOCK" ]] || cannot_run "could not extract the prereq macOS block from install.sh (from MACOS_VERSION= to the pct=20 emit)"
[[ "$(grep -c 'OSTLER_MACOS_FLOOR_MAJOR' "$BLOCK")" -ge 2 ]] || fail case-2 "the extracted block does not read OSTLER_MACOS_FLOOR_MAJOR; the refusal is not keyed to the pin"

# run_block <block file> <macOS version> -> prints the block's output, rc: 0 admitted, 42 refused
run_block() {
    local blk="$1" ver="$2"
    STUB_MACOS="$ver" bash -c '
        set -uo pipefail
        sw_vers() { printf "%s\n" "$STUB_MACOS"; }
        ok() { :; }
        warn() { printf "WARN %s\n" "$*"; }
        gui_emit() { :; }
        fail_with_code() { printf "FAIL_WITH_CODE %s :: %s\n" "$1" "$2"; exit 42; }
        # shellcheck disable=SC1090
        . "$1"
        # The pre-fix block reads two catalogue keys the fix removed. Give
        # them a value so the CONTROL exercises the pre-fix BEHAVIOUR rather
        # than tripping on nounset. The fixed block never reads them.
        : "${MSG_WARN_MACOS_OUTDATED_WE_RECOMMEND_MACOS_13:=pre-fix warn %s}"
        : "${MSG_WARN_SOME_FEATURES_MAY_NOT_WORK_CORRECTLY:=pre-fix warn 2}"
        # shellcheck disable=SC1090
        . "$2"
        exit 0
    ' _ "$STRINGS_FILE" "$blk" 2>&1
}

# ── case-2: refuses below the floor ─────────────────────────────────────
for v in "$((PIN - 1)).6" "$((PIN - 2)).7"; do
    out="$(run_block "$BLOCK" "$v")"; rc=$?
    [[ "$rc" -eq 42 ]] || fail case-2 "macOS ${v} was ADMITTED (rc=${rc}); the app cannot open there. Output: ${out}"
    [[ "$(count 'FAIL_WITH_CODE ERR-02-PREREQ-MACOS-OLD' "$out")" -eq 1 ]] || fail case-2 "macOS ${v} was refused without ERR-02-PREREQ-MACOS-OLD, so the walk driver cannot classify it as a box precondition: ${out}"
    [[ "$(count "macOS ${v} " "$out")" -ge 1 ]] || fail case-2 "the refusal does not name the customer's version ${v}: ${out}"
    [[ "$(count "macOS ${PIN} or later" "$out")" -ge 1 ]] || fail case-2 "the refusal does not name the floor in the README's words (macOS ${PIN} or later): ${out}"
done
echo "PASS [case-2]: macOS $((PIN - 1)).6 and $((PIN - 2)).7 are refused with ERR-02-PREREQ-MACOS-OLD, naming the version and the floor"

# ── case-3: admits at and above the floor ───────────────────────────────
for v in "${PIN}.0" "$((PIN + 1)).1"; do
    out="$(run_block "$BLOCK" "$v")"; rc=$?
    [[ "$rc" -eq 0 ]] || fail case-3 "macOS ${v} was REFUSED (rc=${rc}) though it is at or above the floor: ${out}"
    [[ "$(count 'FAIL_WITH_CODE' "$out")" -eq 0 ]] || fail case-3 "macOS ${v} produced a fail_with_code: ${out}"
done
echo "PASS [case-3]: macOS ${PIN}.0 and $((PIN + 1)).1 are admitted"

# ── case-4: THE CONTROL -- the pre-fix block must NOT refuse ────────────
# Carried as a fixture: this repo squash-merges, so the commit the pre-fix
# block lived in is orphaned the moment the fix lands, and `git show` of a
# pre-fix tree is not available on main. Verbatim from origin/main at
# a340ce91, 2026-09-07.
PREFIX="${WORK}/prefix.sh"
cat > "$PREFIX" <<'FIXTURE'
MACOS_VERSION=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)
ok "$(printf "$MSG_OK_MACOS_DETECTED" "${MACOS_VERSION}")"

# Minimum macOS 13 (Ventura) -- needed for modern Docker, Ollama, and security features
if [[ $MACOS_MAJOR -lt 13 ]]; then
    warn "$(printf "$MSG_WARN_MACOS_OUTDATED_WE_RECOMMEND_MACOS_13" "${MACOS_VERSION}")"
    warn "$MSG_WARN_SOME_FEATURES_MAY_NOT_WORK_CORRECTLY"
fi
gui_emit PCT "step=prereq_check" "pct=20"
FIXTURE
out="$(run_block "$PREFIX" "$((PIN - 1)).6")"; rc=$?
if [[ "$rc" -eq 42 ]]; then
    fail case-4 "the PRE-FIX block refused macOS $((PIN - 1)).6, so the harness cannot tell the fix from the bug and cases 2-3 measured nothing: ${out}"
fi
[[ "$rc" -eq 0 ]] || cannot_run "the pre-fix control exited ${rc}, neither admitted nor refused: ${out}"
echo "PASS [case-4]: the pre-fix block admits macOS $((PIN - 1)).6 (rc=0), so the refusal above is the fix and not the harness"

# ── case-5: mutant -- the comparison floored at 0 ───────────────────────
MUT="${WORK}/mutant.sh"
# shellcheck disable=SC2016  # the literal $OSTLER_MACOS_FLOOR_MAJOR text is the subject
sed -e 's/-lt \$OSTLER_MACOS_FLOOR_MAJOR \]\]/-lt 0 ]]/' "$BLOCK" > "$MUT"
changed="$(diff "$BLOCK" "$MUT" | grep -c '^>')"
[[ "$changed" -eq 1 ]] || cannot_run "mutant did not land: ${changed} changed line(s), wanted 1"
out="$(run_block "$MUT" "$((PIN - 1)).6")"; rc=$?
if [[ "$rc" -eq 42 ]]; then
    fail case-5 "mutant SURVIVED: with the comparison floored at 0, macOS $((PIN - 1)).6 was still refused, so case-2 does not measure the comparison: ${out}"
fi
echo "PASS [case-5]: the mutant is killed (a floor of 0 admits $((PIN - 1)).6, and case-2 would have caught it)"

# ── case-6: bash 3.2 parses the block ───────────────────────────────────
if [[ -x /bin/bash ]]; then
    /bin/bash -n "$BLOCK" || fail case-6 "the prereq block does not parse under /bin/bash ($(/bin/bash --version | head -1))"
    echo "PASS [case-6]: the block parses under /bin/bash ($(/bin/bash --version | head -1 | sed 's/GNU bash, version //'))"
else
    echo "NOTE [case-6]: no /bin/bash here; the 3.2 parse arm was NOT measured"
fi

echo ""
echo "ALL macOS-FLOOR TESTS PASSED"
exit 0
