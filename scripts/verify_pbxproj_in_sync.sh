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

# The comparison below is byte-exact, so it is only meaningful against the
# generator that produced the tracked file. A different xcodegen can emit
# different bytes from identical input, and without this check that shows up as
# exit 1 -- "STALE, DO NOT SHIP" -- for a toolchain difference. That is a gate
# going red for the wrong reason, which is how gates get ignored.
#
# Deliberately exit 2 (could not run), never exit 1 (the project is wrong).
PIN_FILE="gui/.xcodegen-version"
if [[ -f "$PIN_FILE" ]]; then
    PINNED="$(grep -v '^[[:space:]]*#' "$PIN_FILE" | grep -v '^[[:space:]]*$' | head -1 | tr -d '[:space:]')"
    ACTUAL="$(xcodegen --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    if [[ -z "$PINNED" ]]; then
        unavailable "$PIN_FILE contains no version line."
    fi
    if [[ "$PINNED" != "$ACTUAL" ]]; then
        unavailable "xcodegen version mismatch.
       pinned  ($PIN_FILE): $PINNED
       running:                  ${ACTUAL:-<unparseable>}

       A byte comparison against a different generator proves nothing about
       whether project.yml and the pbxproj agree. Install $PINNED, or bump the
       pin AND commit the regenerated pbxproj together."
    fi
else
    unavailable "$PIN_FILE is missing -- the generator version is unrecorded, so
       a byte-exact comparison cannot be attributed to drift rather than to
       the toolchain."
fi

# ---------------------------------------------------------------------------
# AND THE XCODE, WHICH IS THE GENERATOR'S OTHER INPUT.
#
# Pinning xcodegen was necessary and not sufficient. xcodegen injects default
# build settings (settingPresets) that it reads from the INSTALLED XCODE, so
# the SAME xcodegen 2.44.1 emits different bytes from an identical project.yml
# depending on which Xcode is present. Measured 2026-08-13 on this repo, same
# commit, same generator version:
#
#   build host   Xcode 26.6 (17F113)   emits COMBINE_HIDPI_IMAGES,
#                                      LD_RUNPATH_SEARCH_PATHS, SDKROOT,
#                                      ASSETCATALOG_COMPILER_APPICON_NAME
#   macos-14     Xcode 15.4 (15F31d)   omits all four
#
# The tracked pbxproj carries the first set. Without this check, a hosted
# runner reports "STALE, DO NOT SHIP" for a project that is perfectly in sync
# with the toolchain it is actually built by. That is the same
# gate-red-for-the-wrong-reason failure the version pin above was written to
# prevent, one layer down, and it blocked a launch cut for two runs.
#
# Exit 2, deliberately. The project is not wrong; this environment cannot
# judge it. The real comparison is an OPERATOR check on the build machine
# before tagging -- the same shape as scripts/verify_cut_freshness.sh.
XCODE_PIN_FILE="gui/.xcode-version"
if [[ -f "$XCODE_PIN_FILE" ]]; then
    # Two fields: marketing version, then BUILD. The build is the operative
    # one -- measured 2026-08-13, two machines both reporting 26.6 with the
    # same xcodegen produced different bytes. Marketing version alone does not
    # identify the setting presets. See the comment in gui/.xcode-version.
    XPIN_LINE="$(grep -v '^[[:space:]]*#' "$XCODE_PIN_FILE" | grep -v '^[[:space:]]*$' | head -1)"
    XPINNED="$(awk '{print $1}' <<<"$XPIN_LINE")"
    XPINNED_BUILD="$(awk '{print $2}' <<<"$XPIN_LINE")"
    XACTUAL="$(xcodebuild -version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    XACTUAL_BUILD="$(xcodebuild -version 2>/dev/null | sed -n '2p' | awk '{print $3}')"
    if [[ -z "$XPINNED" ]]; then
        unavailable "$XCODE_PIN_FILE contains no version line."
    fi
    if [[ -z "$XPINNED_BUILD" ]]; then
        unavailable "$XCODE_PIN_FILE pins '$XPINNED' with no build version.
       The marketing version alone does not identify the setting presets:
       two Xcode 26.6 installs with the same xcodegen emitted different bytes
       on 2026-08-13. Record it as '<marketing> <build>', e.g. '26.6 17F113'."
    fi
    if [[ -z "$XACTUAL" || -z "$XACTUAL_BUILD" ]]; then
        unavailable "xcodebuild is absent or unparseable, so the setting presets
       baked into the tracked pbxproj cannot be attributed. Not a pass."
    fi
    if [[ "$XPINNED" != "$XACTUAL" || "$XPINNED_BUILD" != "$XACTUAL_BUILD" ]]; then
        unavailable "Xcode mismatch.
       pinned  ($XCODE_PIN_FILE): $XPINNED ($XPINNED_BUILD)
       running:                   $XACTUAL ($XACTUAL_BUILD)

       xcodegen reads its default build settings from the selected Xcode, so a
       byte comparison across different Xcodes measures the toolchain, not the
       project. The BUILD must match too: 26.6/17F113 and another 26.6 emit
       different bytes.

       Run this on a machine with Xcode $XPINNED ($XPINNED_BUILD), or bump the
       pin AND commit the regenerated pbxproj together. Do NOT relax the pin to
       make a runner green -- that reinstates exactly the blindness this check
       exists to remove."
    fi
else
    unavailable "$XCODE_PIN_FILE is missing -- the Xcode whose setting presets are
       baked into the tracked pbxproj is unrecorded, so a byte-exact comparison
       cannot be attributed to drift rather than to the toolchain."
fi

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

# DEFENCE IN DEPTH (part 3 of 3, Archie 2026-08-08). Scrub the variables the
# Makefile exports so an env-sourced ${VAR} cannot be captured even if one is
# reintroduced between linter runs.
#
# WHAT THIS DOES NOT COVER, stated so nobody trusts it further than it goes:
# process-identity vars. `env -i` still yielded the operator username, because
# XcodeGen resolves ${USER} from the process, not the environment. That class
# is closed by the ${VAR:-} source form and check_project_yml_braces.sh -- NOT
# by this scrub. Recommending the scrub as the fix for ${USER} was the review
# miss that found the bug.
_MAKE_EXPORTS="$(grep -oE '^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' gui/Makefile 2>/dev/null \
                 | awk '{print $NF}' | sort -u)"
_SCRUB=()
for _v in $_MAKE_EXPORTS; do _SCRUB+=(-u "$_v"); done
GEN_LOG="$(cd gui && env "${_SCRUB[@]}" xcodegen generate --quiet 2>&1)"
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
