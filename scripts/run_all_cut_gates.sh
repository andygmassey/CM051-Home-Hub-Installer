#!/usr/bin/env bash
#
# run_all_cut_gates.sh -- every pre-cut gate, one command, fails closed.
#
#     scripts/run_all_cut_gates.sh                 # gate (exit 1 on any red)
#     scripts/run_all_cut_gates.sh --report        # run all, always exit 0
#
# WHY THIS EXISTS (2026-08-07)
# ---------------------------------------------------------------------------
# The gates were fine. Nobody ran all of them, and two of them were pointing at
# the wrong thing, so "I ran the gate" and "the cut is checked" had quietly
# stopped meaning the same thing:
#
#   * cut_hygiene_gate.sh defaulted to a v1.0.10 manifest and printed
#     "GREEN. Cut-clear." while validating a cut six versions old
#   * cuts/<ver>/MUST_CONTAIN.tsv -- the actual running BOM -- had NO reader
#     at all, so it was never updated either; on 2026-08-07 every row said
#     landed=no, including three that had landed hours earlier
#
# A gate you have to remember to run, with an argument you have to remember to
# pass, is a gate that eventually runs against the wrong input and says GREEN.
# This runner exists so the answer to "is the cut checked?" is one command with
# one exit code.
#
# WHAT IT DELIBERATELY DOES NOT DO
# ---------------------------------------------------------------------------
# It does not "fix" anything, skip anything quietly, or downgrade a red to a
# warning. If a gate cannot run, that is a RED, not a pass -- a check that did
# not happen is indistinguishable from a check that passed, and that confusion
# is what shipped stale wiki images for three months.
#
# ENVIRONMENT
#   CM044_DIR   path to the CM044 checkout   (wiki namespace + content gates)
#   BOM         path to the cut's MUST_CONTAIN.tsv
# Both are REQUIRED. There is no default -- see the header of
# scripts/verify_must_contain.sh for why a default manifest is a bug.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

MODE="${1:-gate}"

CM044_DIR="${CM044_DIR:-$HOME/Developer/CM044-PWG-Personal-Wiki}"
BOM="${BOM:-}"

RED=0; GREEN=0; SKIPPED=0
declare -a RESULTS=()

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'

# run <label> <what it proves> <command...>
run() {
    local label="$1" proves="$2"; shift 2
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        GREEN=$((GREEN+1))
        printf '%s  PASS%s  %-46s %s\n' "$c_grn" "$c_off" "$label" "$proves"
        RESULTS+=("PASS|$label|")
    else
        RED=$((RED+1))
        printf '%s  RED %s  %-46s %s\n' "$c_red" "$c_off" "$label" "$proves"
        # the last few lines are where these gates put their verdict
        printf '%s\n' "$out" | tail -4 | sed 's/^/          /'
        RESULTS+=("RED|$label|$(printf '%s' "$out" | tail -1 | tr -d '\n')")
    fi
}

# A gate that cannot run is RED. Never a silent pass.
unavailable() {
    local label="$1" why="$2"
    RED=$((RED+1))
    printf '%s  RED %s  %-46s could not run: %s\n' "$c_red" "$c_off" "$label" "$why"
    RESULTS+=("RED|$label|could not run: $why")
}

echo "=================================================================="
echo " PRE-CUT GATES"
echo "   repo     : $HERE  ($(git rev-parse --abbrev-ref HEAD 2>/dev/null))"
echo "   commit   : $(git rev-parse --short HEAD 2>/dev/null)"
echo "   CM044    : ${CM044_DIR:-<unset>}"
echo "   BOM      : ${BOM:-<unset>}"
echo "=================================================================="
echo
echo "-- Does the tree even claim to be right? -------------------------"

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    unavailable "clean working tree" "uncommitted changes; a cut must be reproducible from a commit"
else
    GREEN=$((GREEN+1))
    printf '%s  PASS%s  %-46s %s\n' "$c_grn" "$c_off" "clean working tree" "nothing uncommitted"
    RESULTS+=("PASS|clean working tree|")
fi

echo
echo "-- Bundling: does the .app actually carry what install.sh probes? -"
run "SCRIPT_DIR/X coverage" \
    "every install.sh probe has a bundler" \
    python3 scripts/check_install_sh_script_dir_coverage.py --mode ci
# These two are a PAIR and neither is sufficient alone. The first proves
# project.yml DESCRIBES every copy; the second proves the tracked pbxproj --
# the file xcodebuild actually builds -- still MATCHES project.yml. At the
# v1.0.17 cut only the first existed, and it reported "Xcode tracks every
# copy" while the pbxproj was stale and declared neither of PR #516's files.
# The label below now says which artefact it read, so it cannot overclaim again.
run "bundle-phase declarations" \
    "project.yml describes every copy" \
    bash tests/test_bundle_phase_declares_every_copy.sh
run "pbxproj in sync" \
    "the built project MATCHES project.yml" \
    bash scripts/verify_pbxproj_in_sync.sh
run "project.yml brace hygiene" \
    "no \${VAR} xcodegen can freeze in" \
    bash scripts/check_project_yml_braces.sh

echo
echo "-- Wiki images: provenance AND content ---------------------------"
# CM044_DIR must be the CANONICAL checkout, not a worktree. A worktree sits on
# whatever branch someone left it on -- during the 2026-08-07 cut it was on a
# docs branch, and comparing the shipped image against it produced a confident
# RED on images that were provably correct. A false red costs as much trust as
# a false green: it teaches you to disbelieve the gate.
# In a worktree, .git is a FILE (a gitdir pointer), not a directory.
if [[ -n "$CM044_DIR" && -f "$CM044_DIR/.git" ]]; then
    unavailable "wiki image namespace" \
        "CM044_DIR is a git WORKTREE, not the canonical checkout: $CM044_DIR"
    unavailable "wiki image CONTENT" \
        "CM044_DIR is a git WORKTREE -- it sits on whoever's branch was left
                    checked out, so a mismatch here would say nothing about the cut.
                    Use the canonical clone (\$HOME/Developer/CM044-PWG-Personal-Wiki)."
elif [[ -d "$CM044_DIR" ]]; then
    run "wiki image namespace" \
        "CI publishes where install.sh reads" \
        env CM044_DIR="$CM044_DIR" bash tests/test_wiki_image_namespace_matches_ci.sh
    run "wiki image CONTENT" \
        "the pinned image IS the current build" \
        env CM044_DIR="$CM044_DIR" bash tests/test_pinned_wiki_image_has_design_system.sh
else
    unavailable "wiki image namespace" "CM044_DIR not a directory: $CM044_DIR"
    unavailable "wiki image CONTENT"   "CM044_DIR not a directory: $CM044_DIR"
fi

# PLATFORM, and note it is OUTSIDE the CM044_DIR branch above on purpose: this
# one reads the registry, not a checkout, so there is no environment in which
# it should silently not run. The two gates above can go unavailable; this one
# cannot hide behind a missing checkout.
#
# It asserts the pinned digests are arm64-ONLY. Dropping linux/amd64 from
# CM044 release-images.yml is a promise that can be edited back, and a stale
# pin outlives the workflow being correct either way. This checks the artefact
# that ships instead of the config that produced it.
run "wiki image PLATFORM" \
    "the pinned digests are arm64-only" \
    bash tests/test_pinned_wiki_images_are_arm64_only.sh

echo
echo "-- Vendor + artefact freshness -----------------------------------"
run "cut freshness"   "vendored inputs match live upstream"  bash scripts/verify_cut_freshness.sh
run "cut provenance"  "components are the intended builds"   bash scripts/verify_cut_provenance.sh
run "content provenance" "artefacts contain the required fixes" bash scripts/provenance_gate.sh
# --require-full is LOAD-BEARING. Without it the gate runs in CI mode and
# reports an unresolvable enforced pair as a gap while exiting 0. At cut time
# the app bundle exists, so an enforced pair it cannot resolve means the
# resolution has rotted, and a gate that cannot see what it enforces must fail.
run "vendor pair drift" "the copy that RUNS matches the copy that was reviewed" \
    python3 tests/test_vendor_pair_drift.py --require-full

echo
echo "-- The BOM: is everything we said would ship, shipping? ----------"
if [[ -z "$BOM" ]]; then
    unavailable "MUST_CONTAIN BOM" "BOM unset. Pass BOM=/path/to/cuts/<ver>/MUST_CONTAIN.tsv"
elif [[ ! -f "$BOM" ]]; then
    unavailable "MUST_CONTAIN BOM" "not a file: $BOM"
else
    run "MUST_CONTAIN BOM" "every promised capability landed" \
        bash scripts/verify_must_contain.sh "$BOM"
fi

echo
echo "=================================================================="
printf '  %s green  |  %s red\n' "$GREEN" "$RED"
echo
if [[ "$RED" -gt 0 ]]; then
    echo "  Red:"
    for r in "${RESULTS[@]}"; do
        [[ "${r%%|*}" == "RED" ]] || continue
        rest="${r#RED|}"
        printf '    - %s\n' "${rest%%|*}"
    done
    echo
    echo "  DO NOT ASSEMBLE THE DMG."
    echo
    echo "  Fix the cause. Never edit a gate to make a cut pass, and never"
    echo "  re-point a gate at an input that happens to be greener -- that is"
    echo "  precisely how cut_hygiene_gate.sh spent six versions validating"
    echo "  v1.0.10 and reporting 'Cut-clear'."
    echo "=================================================================="
    [[ "$MODE" == "--report" ]] && exit 0
    exit 1
fi

echo "  ALL GATES GREEN. Cut-clear on the mechanical checks."
echo
echo "  Still not automated, still required:"
echo "    - the box walk on a real Mac"
echo "    - notarytool exits 0 on 'Invalid' -- parse the status, not the code"
echo "    - staple the nested Hub .app BEFORE the outer installer seals it"
echo "=================================================================="
exit 0
