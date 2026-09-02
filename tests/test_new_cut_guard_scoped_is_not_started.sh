#!/usr/bin/env bash
#
# scripts/new_cut.sh refused to start ANY cut that had been scoped first.
#
# Its guard tested `-e cuts/<version>` -- the DIRECTORY. Writing
# cuts/<version>/SCOPE.md before starting a cut is the standard workflow, so
# the directory exists for every real cut and the one-command path was dead for
# all of them. v1.0.60 sat scoped for hours; `[ -e cuts/v1.0.60 ]` was TRUE
# with SCOPE.md as the only file in it.
#
# The fix moves the guard onto cut.env, which is what the SAME FILE already
# treats as the marker of a real cut: PREV detection accepts a version dir only
# if `cuts/$d/cut.env` exists. The guard was the one place with a different
# definition.
#
# WHY THIS EXTRACTS AND RUNS RATHER THAN GREPS. A grep for `cut.env` in the
# guard passes the moment the string appears, including in a comment. And the
# whole script cannot simply be invoked: past the guard it copies cut.env,
# vendors the BOM and runs every cut gate, i.e. it MUTATES THE REPO. So the
# guard block is extracted by its own anchors and executed under both states
# with `die` stubbed.
#
# THE SECOND ARM IS THE ONE THAT MATTERS. A fix that simply deleted the guard
# would pass "a scoped cut is allowed" and silently permit overwriting a cut
# already in flight. Both arms are asserted.
#
# Exit: 0 pass, 1 RED (defect present), 2 CANNOT-RUN (not a pass).

set -uo pipefail

# NO `... | grep -q` IN THIS FILE. grep -q exits at its first match and
# SIGPIPEs the producer, which under pipefail can invert the verdict of the
# assertion being made. Herestrings have no pipe, so there is nothing to
# SIGPIPE. (Bashism, and the shebang is bash, which we control.)

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEW_CUT="${REPO}/scripts/new_cut.sh"

fail=0
red()  { printf 'RED   %s\n' "$1"; fail=1; }
okay() { printf 'ok    %s\n' "$1"; }

if [[ ! -f "$NEW_CUT" ]]; then
    printf 'CANNOT-RUN: missing prerequisite %s\n' "$NEW_CUT"
    printf 'This is not a pass.\n'
    exit 2
fi

# ── Extract the guard by its own anchors ──────────────────────────────────
# From the NEW= assignment to the guard line itself. If either anchor moves
# this is CANNOT-RUN, never a silent pass on an empty subject.
# The end anchor is DELIBERATELY LOOSE -- any guard line ending in `&& die`.
# A tight anchor naming cut.env would stop matching under the very mutations
# this test must detect, turning a RED into a CANNOT-RUN and letting a broken
# guard read as untestable rather than wrong.
BLOCK="$(awk '
    /^NEW="cuts\/\$VERSION"$/ { grab=1 }
    grab { print }
    grab && /&& die / { exit }
' "$NEW_CUT")"

if [[ -z "$BLOCK" ]]; then
    printf 'CANNOT-RUN: could not extract the guard from new_cut.sh.\n'
    printf 'The anchor moved. Refusing to report a pass on an empty subject.\n'
    exit 2
fi

# Positive control on the extraction: the block must actually contain a die.
# Without this, a block that grabbed the wrong region would "pass" both arms.
if ! grep -q 'die ' <<< "$BLOCK"; then
    printf 'CANNOT-RUN: extracted block contains no die -- wrong region.\n'
    exit 2
fi

# ── Harness ───────────────────────────────────────────────────────────────
# $1 = which files to create in the version dir. Prints DIED:<msg> or SURVIVED.
run_case() {
    local mode="$1"
    local tmp; tmp="$(mktemp -d)"
    (
        cd "$tmp" || exit 9
        VERSION="v9.9.99"
        mkdir -p "cuts/${VERSION}"
        case "$mode" in
            scoped)  : > "cuts/${VERSION}/SCOPE.md" ;;
            started) : > "cuts/${VERSION}/SCOPE.md"; : > "cuts/${VERSION}/cut.env" ;;
            absent)  rm -rf "cuts/${VERSION}" ;;
        esac
        die() { echo "DIED:$*"; exit 0; }
        eval "$BLOCK"
        echo "SURVIVED"
    )
    rm -rf "$tmp"
}

scoped_out="$(run_case scoped)"
started_out="$(run_case started)"
absent_out="$(run_case absent)"

# ── Assertions ────────────────────────────────────────────────────────────

# 1. THE DEFECT. A cut that has only been SCOPED must be allowed to start.
if grep -q '^SURVIVED' <<< "$scoped_out"; then
    okay "a SCOPE.md-only directory does not block the cut from starting"
else
    red "a scoped-but-not-started cut is still refused: ${scoped_out}"
fi

# 2. THE CONTROL THAT MUST FAIL IF THE GUARD WAS SIMPLY DELETED. A cut whose
#    cut.env exists is genuinely started, and re-running IS an overwrite.
if grep -q '^DIED:' <<< "$started_out"; then
    okay "a directory WITH cut.env still refuses (guard not merely removed)"
else
    red "a started cut is no longer refused -- the guard was deleted, not narrowed"
fi

# 3. The refusal must name cut.env, so the operator learns which file decided.
if grep -q 'cut\.env' <<< "$started_out"; then
    okay "the refusal names cut.env as the deciding file"
else
    red "the refusal does not say which file made it refuse: ${started_out}"
fi

# 4. A wholly absent version dir must also be allowed -- the original
#    behaviour for a brand-new cut, which must not regress.
if grep -q '^SURVIVED' <<< "$absent_out"; then
    okay "an absent version directory still starts cleanly"
else
    red "a brand-new cut is now refused: ${absent_out}"
fi

if [[ "$fail" -eq 0 ]]; then
    printf '\nPASS: 4 assertions, 3 executed states (scoped / started / absent)\n'
    exit 0
fi
printf '\nFAIL: see RED lines above\n'
exit 1
