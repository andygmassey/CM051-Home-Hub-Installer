#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Proves the TRACKED project.pbxproj is exactly what xcodegen generates from
# gui/project.yml.
#
# WHY THIS EXISTS
# ---------------
# gui/project.yml is the spec a human edits. xcodebuild builds the tracked
# gui/OstlerInstaller.xcodeproj/project.pbxproj. The ship chain never runs
# `xcodegen`, so those two can silently disagree -- and the build follows the
# pbxproj, not the YAML.
#
# At the v1.0.17 cut (2026-08-08) the pbxproj WAS stale: PR #516 added
# inputFiles/outputFiles for lib/settling_progress.sh to project.yml and the
# pbxproj was never regenerated. Meanwhile
# tests/test_bundle_phase_declares_every_copy.sh -- which parses project.yml
# and ONLY project.yml -- reported "Xcode tracks every copy (no stale files)".
# That statement was true of the YAML and false of the thing being built. It
# was the fourth wrong-artefact gate found in a single week, and it did not
# bite only because `release` does `rm -rf` on the staging dir first: luck,
# not design.
#
# check-version (#171) already compares project.yml <-> pbxproj <-> Info.plist,
# but only on the version fields. This gate generalises that comparison to the
# WHOLE project: any project.yml edit that was never regenerated is caught,
# not just a version half-bump.
#
# EXIT CODES -- deliberately distinct, because "the thing is wrong" and "the
# gate could not run" must never look the same:
#   0  tracked pbxproj == what xcodegen generates       (in sync)
#   1  they differ -- the cut would build something project.yml does not
#      describe. DO NOT SHIP.
#   2  the gate could NOT run (xcodegen missing, pbxproj already dirty, not a
#      git repo). A gate that cannot run is NOT a pass.
#
# SAFETY: regeneration happens IN PLACE (xcodegen resolves paths relative to
# the project location, so generating elsewhere produces spurious path diffs).
# The original is restored from git on every exit path via a trap, and the
# gate REFUSES to run if the pbxproj is already dirty -- it will not destroy
# uncommitted work to satisfy itself.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJ_DIR="gui/OstlerInstaller.xcodeproj"
PBXPROJ="$PROJ_DIR/project.pbxproj"
SPEC="gui/project.yml"

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

unavailable() {
    red "UNAVAILABLE: $*"
    red ""
    red "  This gate did not run. That is NOT a pass -- resolve the cause and"
    red "  re-run before cutting."
    exit 2
}

cd "$REPO_ROOT" || unavailable "cannot cd to repo root: $REPO_ROOT"

git rev-parse --git-dir >/dev/null 2>&1 \
    || unavailable "not a git repository: $REPO_ROOT (the gate restores the pbxproj from git)"

command -v xcodegen >/dev/null 2>&1 \
    || unavailable "xcodegen is not installed (brew install xcodegen)"

[[ -f "$SPEC" ]]    || unavailable "spec not found: $SPEC"
[[ -f "$PBXPROJ" ]] || unavailable "tracked project not found: $PBXPROJ"

git ls-files --error-unmatch "$PBXPROJ" >/dev/null 2>&1 \
    || unavailable "$PBXPROJ is not tracked by git -- cannot restore it after regenerating"

# Refuse to run against a dirty project: regenerating would destroy whatever
# uncommitted edit is sitting there.
if ! git diff --quiet -- "$PROJ_DIR" 2>/dev/null; then
    unavailable "$PROJ_DIR has uncommitted changes.
       Commit or stash them first -- this gate regenerates in place and would
       otherwise overwrite your work. Refusing."
fi

BEFORE_SHA="$(shasum -a 256 "$PBXPROJ" | cut -d' ' -f1)"

restore() {
    git checkout -- "$PROJ_DIR" 2>/dev/null || true
}
trap restore EXIT INT TERM

GEN_LOG="$(cd gui && xcodegen generate --quiet 2>&1)"
GEN_RC=$?
if (( GEN_RC != 0 )); then
    unavailable "xcodegen failed (rc=$GEN_RC):
$GEN_LOG"
fi

AFTER_SHA="$(shasum -a 256 "$PBXPROJ" | cut -d' ' -f1)"

if [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; then
    green "PASS  tracked pbxproj == xcodegen(project.yml)"
    exit 0
fi

red "FAIL: the tracked Xcode project is STALE against gui/project.yml."
red ""
red "  tracked   sha256: $BEFORE_SHA"
red "  generated sha256: $AFTER_SHA"
red ""
red "  xcodebuild builds the PBXPROJ, not the YAML. Anything project.yml adds"
red "  -- a bundled file, an inputFiles/outputFiles declaration -- is absent"
red "  from the build until \`xcodegen generate\` is re-run and the result is"
red "  COMMITTED."
red ""
red "  Diff (tracked -> generated), first 40 lines:"
git --no-pager diff --no-color -- "$PBXPROJ" 2>/dev/null | head -40 >&2
red ""
red "  Fix:  cd gui && xcodegen generate  &&  git add $PBXPROJ  &&  commit"
red "  DO NOT SHIP."
exit 1
