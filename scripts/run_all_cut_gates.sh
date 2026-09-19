#!/usr/bin/env bash
#
# run_all_cut_gates.sh -- every pre-cut gate, one command, fails closed.
#
#     scripts/run_all_cut_gates.sh                 # gate (exit 1 on any red)
#     scripts/run_all_cut_gates.sh --report        # run all, always exit 0
#     scripts/run_all_cut_gates.sh --print-checkout-guard
#                                                  # resolve every checkout the
#                                                  # gates read, print its
#                                                  # verdict and which gates it
#                                                  # blocks, run nothing
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
#   CM044_DIR             path to the CM044 checkout (wiki namespace + content)
#   OSTLER_ASSISTANT_DIR  path to the ostler-assistant checkout (cut provenance,
#                         content provenance, vendor pair drift). Defaulted to
#                         ../ostler-assistant ONLY when that directory exists,
#                         so a missing checkout still reaches the gates as
#                         "not set" and they still refuse for that reason.
#   HR015_ROOT            path to the HR015 checkout, when the pair registry
#                         names it
#   BOM                   path to the cut's MUST_CONTAIN.tsv
# CM044_DIR and BOM are REQUIRED. There is no default for BOM -- see the header
# of scripts/verify_must_contain.sh for why a default manifest is a bug.
#
# EVERY ONE OF THOSE CHECKOUTS IS GUARDED BEFORE IT IS READ. See
# scripts/lib/checkout_guard.sh: a checkout that is not at the tip of its
# default branch makes the gates that read it CANNOT-RUN, never RED and never
# PASS.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

MODE="${1:-gate}"

CM044_DIR="${CM044_DIR:-$HOME/Developer/CM044-PWG-Personal-Wiki}"
BOM="${BOM:-}"

. "$HERE/scripts/lib/checkout_guard.sh"

# ---------------------------------------------------------------------------
# THE ASSISTANT CHECKOUT IS RESOLVED HERE SO THE GUARD AND THE GATES READ THE
# SAME PATH.
#
# scripts/provenance_gate.sh and scripts/verify_cut_provenance.sh each default
# OSTLER_ASSISTANT_DIR to <CM051 root>/../ostler-assistant independently. A
# guard that checked a different path from the one the gate reads is not a
# guard, so the default is resolved once, here, and exported.
#
# 🔴 ONLY WHEN THE DIRECTORY EXISTS. Exporting a path that is not there would
# turn tests/test_vendor_pair_drift.py's honest "OSTLER_ASSISTANT_DIR is not
# set" into "no file matched <path>" -- both refuse, but the first names the
# missing input and the second reads like a glob that needs fixing. The
# existing refusal is correct behaviour and is left alone.
# ---------------------------------------------------------------------------
if [[ -z "${OSTLER_ASSISTANT_DIR:-}" && -d "$HERE/../ostler-assistant" ]]; then
    OSTLER_ASSISTANT_DIR="$(cd "$HERE/../ostler-assistant" && pwd)"
    export OSTLER_ASSISTANT_DIR
fi

RED=0; GREEN=0; SKIPPED=0
declare -a RESULTS=()

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'

# run <label> <what it proves> <command...>
# 🔴 A GATE THAT DIED AND EXITED 0 IS NOT A PASS.
#
# MEASURED 2026-08-26. scripts/verify_must_contain.sh used `declare -A`, a bash
# 4 builtin. Under /bin/bash 3.2 -- which is every Mac, and this host whenever
# PATH bash is not Homebrew's -- it printed:
#
#     declare: -A: invalid option
#     line 68: what: unbound variable
#
# and EXITED 0. On the real cuts/v1.0.47 BOM the true answer is rc=1: there are
# unlanded rows. run() saw rc=0 and printed
#
#     PASS  MUST_CONTAIN BOM  every promised capability landed
#
# The gate that decides whether the promised capabilities landed certified a
# cut it never read. It is not enough to fix that one file: the NEXT gate to
# acquire a bash-4 builtin, a typo'd variable under `set -u`, or a syntax error
# in a branch nobody exercises will do exactly the same thing, silently.
#
# run() captures stderr already (2>&1) and then throws it away when rc=0. So
# the evidence was always here; nothing looked at it.
#
# THE DISCRIMINATOR: bash prefixes its OWN diagnostics with "<script>: line N:".
# A gate's deliberate output does not look like that. Anchoring on that shape
# rather than on words like "error" or "not found" avoids flagging a gate that
# legitimately reports "image not found" as a finding.
#
# rc != 0 is already RED, so this only ever converts a would-be GREEN.
_interpreter_died() {
    printf '%s\n' "$1" | /usr/bin/grep -qE '^[^:]*: line [0-9]+: '
}

run() {
    local label="$1" proves="$2"; shift 2
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]] && _interpreter_died "$out"; then
        RED=$((RED+1))
        printf '%s  RED %s  %-46s %s\n' "$c_red" "$c_off" "$label" "EXITED 0 AFTER DYING -- not a pass"
        printf '          The interpreter reported an error and the gate still exited 0.\n'
        printf '          That is a gate certifying something it never measured.\n'
        printf '%s\n' "$out" | /usr/bin/grep -E '^[^:]*: line [0-9]+: ' | head -3 | sed 's/^/          /'
        RESULTS+=("RED|$label|exited 0 after an interpreter error")
        return
    fi
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

# gate_or_unavailable <why-not-or-empty> <label> <proves> <cmd...>
# One place decides whether a gate runs or refuses, so a new gate reading a
# guarded checkout cannot be wired in bare by omission -- which is exactly how
# the three ostler-assistant gates ended up unguarded.
gate_or_unavailable() {
    local why="$1" label="$2"; shift 2
    if [[ -n "$why" ]]; then
        unavailable "$label" "$why"
    else
        run "$label" "$@"
    fi
}

# ---------------------------------------------------------------------------
# EVERY CHECKOUT THE GATES READ, MEASURED ONCE, BEFORE ANY GATE RUNS (#1550).
#
# Computed here rather than beside each gate so that --print-checkout-guard
# below prints the SAME VALUES the gates consume. A mode that recomputed them
# would be a second implementation agreeing with itself, which is the shape of
# proof this repo keeps paying for.
# ---------------------------------------------------------------------------
# _state_of <path> -- the guard verdict, or why it was not asked for one.
# not-set and absent are recorded rather than collapsed into "ok": "there is no
# checkout here" and "the checkout is the reviewed tree" are different facts and
# must not print the same word in the report below.
_state_of() {
    local p="${1:-}"
    if [[ -z "$p" ]];    then printf 'not-set\n'; return 0; fi
    if [[ ! -d "$p" ]];  then printf 'absent\n';  return 0; fi
    if [[ -f "$p/.git" ]]; then printf 'worktree\n'; return 0; fi
    _checkout_tip_state "$p"
}

# _blocks <state> -- true when this state means a gate reading the checkout
# must NOT run. not-set and absent do not block HERE: the gates themselves
# already refuse for those, by name, with a better message than this file could
# write (see tests/test_vendor_pair_drift.py's "OSTLER_ASSISTANT_DIR is not
# set", quoted approvingly in #1550 as the behaviour the wiki gate should copy).
_blocks() {
    case "$1" in
        ok|not-set|absent) return 1 ;;
        *)                 return 0 ;;
    esac
}

_cm044_state="$(_state_of "$CM044_DIR")"
_assistant_state="$(_state_of "${OSTLER_ASSISTANT_DIR:-}")"
_hr015_state="$(_state_of "${HR015_ROOT:-}")"

# The reason the three vendor/provenance gates must not run, or empty when they
# may. FIRST offender wins: naming one wrong checkout is actionable, naming two
# in one line is a paragraph nobody reads.
_vendor_block=""
if _blocks "$_assistant_state"; then
    _vendor_block="$(_checkout_explain OSTLER_ASSISTANT_DIR "${OSTLER_ASSISTANT_DIR:-}" "$_assistant_state")"
elif _blocks "$_hr015_state"; then
    _vendor_block="$(_checkout_explain HR015_ROOT "${HR015_ROOT:-}" "$_hr015_state")"
fi

if [[ "$MODE" == "--print-checkout-guard" ]]; then
    # Machine-readable, and it prints the variables the gates below read rather
    # than re-deriving them. Consumed by
    # tests/test_every_checkout_a_cut_gate_reads_is_guarded.sh.
    printf 'CHECKOUT\t%s\t%s\t%s\n' CM044_DIR "${CM044_DIR:-}" "$_cm044_state"
    printf 'CHECKOUT\t%s\t%s\t%s\n' OSTLER_ASSISTANT_DIR "${OSTLER_ASSISTANT_DIR:-}" "$_assistant_state"
    printf 'CHECKOUT\t%s\t%s\t%s\n' HR015_ROOT "${HR015_ROOT:-}" "$_hr015_state"
    for _lbl in "cut provenance" "content provenance" "vendor pair drift"; do
        printf 'GATEBLOCK\t%s\t%s\n' "$_lbl" "${_vendor_block:--}"
    done
    if _blocks "$_cm044_state"; then
        printf 'GATEBLOCK\t%s\t%s\n' "wiki image CONTENT" \
            "$(_checkout_explain CM044_DIR "$CM044_DIR" "$_cm044_state")"
    else
        printf 'GATEBLOCK\t%s\t%s\n' "wiki image CONTENT" '-'
    fi
    exit 0
fi

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
#
# 🔴 AND A CANONICAL CLONE CAN BE ON THE WRONG BRANCH TOO (2026-09-06).
#
# The check above was written for the 2026-08-07 incident described in the note,
# and it fixed exactly ONE of the two ways that incident can happen. A canonical
# clone -- .git a real directory, passes the test above -- sits on whatever branch
# someone left it on just as a worktree does.
#
# Measured today: $HOME/Developer/CM044-PWG-Personal-Wiki was left on
# fix/embed-one-chrome-band-nav-crop, 7 commits behind origin/main. The content
# gate compared the pinned image (built from main) against that tree and returned
# a confident RED, quoting settling-panel lines that live in the 7 missing
# commits. Checking main out and re-running the same gate: rc=0, with its own
# positive control firing. The image was correct the whole time.
#
# So the identical false RED, from the identical cause, past the guard written to
# stop it. Comparing HEAD to origin/main is the check the worktree test was
# really reaching for.
#
# CANNOT-RUN rather than RED, deliberately: the cut is still blocked (see the
# `run` note below -- unavailable counts as red in the tally), but the operator is
# told the checkout is wrong rather than being told the artefact is.
# 🔴 AND IT WAS ONLY EVER APPLIED TO CM044 (#1550, measured 2026-09-16).
#
# The guard below used to be a local _cm044_branch_ok(). Two things were wrong
# with that and only one of them was about CM044:
#
#   1. It compared against refs/remotes/origin/main WITHOUT FETCHING. A cached
#      remote ref from days ago is the same staleness one level up, and it
#      reads as a clean comparison.
#   2. OSTLER_ASSISTANT_DIR appeared ZERO times in this file (control:
#      CM044_DIR, 20 times in the same file, so the zero was real). Three gates
#      read that checkout and all three were invoked bare. That side fails
#      towards a false GREEN, which is worse than the false RED this paragraph
#      was written about.
#
# Both are now in scripts/lib/checkout_guard.sh, applied to every checkout, and
# the state is computed once near the top of this file.
if [[ -n "$CM044_DIR" && -f "$CM044_DIR/.git" ]]; then
    unavailable "wiki image namespace" \
        "CM044_DIR is a git WORKTREE, not the canonical checkout: $CM044_DIR"
    unavailable "wiki image CONTENT" \
        "CM044_DIR is a git WORKTREE -- it sits on whoever's branch was left
                    checked out, so a mismatch here would say nothing about the cut.
                    Use the canonical clone (\$HOME/Developer/CM044-PWG-Personal-Wiki)."
elif [[ -d "$CM044_DIR" ]] && _blocks "$_cm044_state"; then
    _cm044_why="$(_checkout_explain CM044_DIR "$CM044_DIR" "$_cm044_state")"
    unavailable "wiki image namespace" "$_cm044_why"
    unavailable "wiki image CONTENT" \
        "${_cm044_why}
                    Comparing the pinned image against a tree that is not the reviewed
                    one produces a RED that says nothing about the image -- exactly the
                    2026-08-07 failure, and again on 2026-09-05 via a canonical clone
                    instead of a worktree."
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
echo "-- Privacy: no real person's name in the shipping payload --------"
# THE CUT, not just the PR. A workflow gate protects what goes through review;
# it does not protect what is ASSEMBLED. Of the gate scripts in this repo, most
# are invoked by nothing, so wiring a check into CI alone is not evidence that
# it runs before a DMG exists.
#
# CM051 is PUBLIC and vendors the identity modules, so this is the last point
# at which a real name can be stopped before it is inside a customer artefact.
#
# `run` treats any non-zero as RED, so exit 2 (CANNOT-RUN) blocks the cut. A
# check that did not happen is indistinguishable from a check that passed.
run "person-name permit-list" "no name outside the synthetic cast ships" \
    python3 bin/pii_name_guard.py --root .

echo
echo "-- Vendor + artefact freshness -----------------------------------"
# Tests IMPORT, production EXECUTES. A top-level def below a `__main__` guard
# binds fine on import, so the whole test suite passes, and raises NameError
# the moment the file is run as a script -- which is how every LaunchAgent in
# the DMG runs it. That shipped once already, in the Front Page producer, and
# for the life of the release it presented as "the page never updates" because
# the degraded-feed path kept serving the last good feed.
#
# It belongs in the CUT gates and not only in CI: the gate reads the three
# shipped roots (vendor/, scripts/, lib/) in the tree being cut, so it is
# asking about the artefact rather than about a branch.
run "no defs after __main__ guard" \
    "shipped .py files run as scripts, not just import" \
    python3 scripts/verify_no_defs_after_main_guard.py
run "cut freshness"   "vendored inputs match live upstream"  bash scripts/verify_cut_freshness.sh

# THE THREE GATES THAT READ THE ostler-assistant CHECKOUT (#1550). Each one
# compares something in the cut against that working tree, so each one is only
# as true as the branch someone left it on. All three ran bare until this
# guard; $_vendor_block is computed once near the top of this file from
# scripts/lib/checkout_guard.sh.
#
# The vendor-pair gate is the reason this matters more than the CM044 case:
# it compares the run-source enum in ostler-assistant against the array in the
# CM051 wrapper, so a feature-branch enum against a main wrapper can agree by
# accident and report GREEN on a comparison that was never valid.
gate_or_unavailable "$_vendor_block" \
    "cut provenance"  "components are the intended builds"   bash scripts/verify_cut_provenance.sh
gate_or_unavailable "$_vendor_block" \
    "content provenance" "artefacts contain the required fixes" bash scripts/provenance_gate.sh
# --require-full is LOAD-BEARING. Without it the gate runs in CI mode and
# reports an unresolvable enforced pair as a gap while exiting 0. At cut time
# the app bundle exists, so an enforced pair it cannot resolve means the
# resolution has rotted, and a gate that cannot see what it enforces must fail.
gate_or_unavailable "$_vendor_block" \
    "vendor pair drift" "the copy that RUNS matches the copy that was reviewed" \
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
