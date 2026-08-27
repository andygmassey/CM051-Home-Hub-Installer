#!/usr/bin/env bash
#
# scripts/dry_run_cut_checks.sh -- run the cut path's CHECKS, and cut nothing.
#
# WHY THIS EXISTS (task #359)
# ---------------------------------------------------------------------------
# .github/workflows/cut.yml fires on a `v1.0.*` tag push. That is correct and
# it stays correct: a cut must be written down. But it meant the only way to
# discover a broken cut-path CHECK was to SPEND A VERSION NUMBER. Five were
# spent in one day -- v1.0.27, .28, .29, .30, .31 -- at roughly one discovery
# each, and every one of those defects was in a check or a fetch. None of them
# needed a signature to be found.
#
# So the checks get a way to run that manufactures nothing. This script is that
# way. It is invoked ONLY from the dry-run job, which exists only on
# workflow_dispatch, holds contents: read, and has no signing credential, no
# notary credential and no upload step. See cut.yml's header.
#
# WHAT IT RUNS, AND THE RULE THAT DECIDES
# ---------------------------------------------------------------------------
# A `ship:` prerequisite is EXERCISED here if and only if all three hold:
#
#   1. it needs no code-signing identity,
#   2. it needs no notary credential,
#   3. it produces nothing that could be published.
#
# Fetch and stage targets pass that rule and are run, not skipped, because each
# of them ENDS in a fail-closed verification of a shipping pin -- a SHA-256, or
# a marker-string grep inside the extracted Mach-O. The fetch half writes only
# into the runner's scratch space; the verify half is exactly the class of
# cut-path break that burnt v1.0.27 (daemon / hub-app pins a version apart) and
# broke the extension fetch when SAFARI_EXT_TAG was still derived from
# DAEMON_VERSION. A dry run that skipped them would not have caught either.
#
# THE DENOMINATOR IS NOT OPTIONAL OUTPUT
# ---------------------------------------------------------------------------
# This repo has been burnt repeatedly by greens that covered less than they
# appeared to: a freshness gate GREEN over 0 verified trees, a provenance gate
# announcing 11 stale components having opened none of them, a preflight that
# shares 1 of 22 `ship:` gates and still read as cut-readiness. So every run
# ends by naming what it EXERCISED and what it did NOT, with both counts, and
# refuses to run at all if a prerequisite exists that this file has not
# classified. A dry run that silently covers 9 of 22 and reads as success is
# worse than no dry run.
#
# THE CLASSIFICATION IS DERIVED, NOT REMEMBERED
# ---------------------------------------------------------------------------
# The 22 are read out of gui/Makefile's `ship:` line at run time, and the tier-2
# set out of its `release:` and `package:` lines. If someone adds, removes or
# renames a prerequisite, this script exits 2 (CANNOT RUN) naming it, rather
# than quietly reporting a denominator that no longer describes the target. A
# ledger that can drift from the thing it counts is a decoration.
#
# EXIT CODES (the trichotomy this repo keeps re-learning)
#   0  every exercised target passed, and nothing shippable exists on this box
#   1  an exercised target FAILED, or an artefact was found
#   2  could not run (no Makefile, no `ship:` line, unclassified prerequisite)
#
# British English throughout; " -- " not em-dashes. bash 3.2 compatible: this
# runs on the macOS runner, whose /bin/bash is 3.2, and so does the cut.

#
# Usage:
#   scripts/dry_run_cut_checks.sh            run the checks, then print the ledger
#   scripts/dry_run_cut_checks.sh --plan     validate the classification against
#                                            gui/Makefile and print the ledger
#                                            WITHOUT running anything. Seconds,
#                                            no network, no tokens.

set -uo pipefail

PLAN_ONLY=0
[ "${1:-}" = "--plan" ] && PLAN_ONLY=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUI_DIR="$REPO_ROOT/gui"
MAKEFILE="$GUI_DIR/Makefile"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

rule() { printf '%s\n' "=============================================================================="; }

cannot_run() {
    printf '\n%sCANNOT RUN%s  %s\n' "$c_red" "$c_off" "$1" >&2
    printf '%s\n' "Nothing has been checked. This is not a pass." >&2
    exit 2
}

[ -f "$MAKEFILE" ] || cannot_run "no Makefile at $MAKEFILE"

# ---------------------------------------------------------------------------
# The prerequisite lists, READ OUT OF THE MAKEFILE.
# ---------------------------------------------------------------------------
prereqs_of() {
    grep -E "^$1:[[:space:]]" "$MAKEFILE" | head -1 | sed "s/^$1:[[:space:]]*//"
}

SHIP_PREREQS="$(prereqs_of ship)"
[ -n "$SHIP_PREREQS" ] || cannot_run "gui/Makefile has no 'ship:' line with prerequisites"

RELEASE_PREREQS="$(prereqs_of release)"
PACKAGE_PREREQS="$(prereqs_of package)"
[ -n "$RELEASE_PREREQS" ] || cannot_run "gui/Makefile has no 'release:' line with prerequisites"
[ -n "$PACKAGE_PREREQS" ] || cannot_run "gui/Makefile has no 'package:' line with prerequisites"

# Tier 2 is the verification-only prerequisites of the two COMPOSITE targets
# tier 1 has to skip (`release` builds and signs; `package` writes and signs the
# DMG). Skipping those two as units would discard eight real cut-path checks
# that need neither a signature nor a built .app, so they are run individually
# and counted in their own denominator. Anything already counted in tier 1 is
# not counted twice.
TIER2_TARGETS=""
for _t in $RELEASE_PREREQS $PACKAGE_PREREQS; do
    case " $SHIP_PREREQS " in *" $_t "*) continue ;; esac
    case " $TIER2_TARGETS " in *" $_t "*) continue ;; esac
    TIER2_TARGETS="$TIER2_TARGETS $_t"
done
TIER2_TARGETS="$(printf '%s' "$TIER2_TARGETS" | sed 's/^ *//')"

# ---------------------------------------------------------------------------
# THE PLAN. One row per target: name|verdict|reason.
#
# The reason column is not decoration. A skip with no reason is how a hole
# becomes permanent, and every one of these was argued from what the target
# actually does in gui/Makefile.
#
# HELD IN FUNCTIONS, NOT IN VARIABLES, AND THAT IS NOT STYLE. `VAR="$(cat <<'X'
# ... X)"` does not parse under /bin/bash 3.2 once the text contains an
# apostrophe: 3.2 tracks quoting THROUGH $( ) and through the here-document.
# The macOS runner and the cut machine both run 3.2, so a form that only parses
# under 5.x would make this file unrunnable exactly where it ships.
# ---------------------------------------------------------------------------
tier1_plan() {
cat <<'PLAN'
guard-local-cut|EXERCISE|the CI guard itself. Asserts a cut is permitted in this environment; manufactures nothing.
check-orphans|EXERCISE|pure verification: does a written fix exist that this cut does not carry?
check-pr-age|EXERCISE|pure verification: has an open PR outstayed the 48h rule?
download-hub-app|EXERCISE|fetch + fail-closed SHA-256 on the Hub pin. check-ostler-app has nothing to check without it.
check-ostler-app|EXERCISE|pure verification, and the gate that burnt v1.0.30. Needs download-hub-app above.
download-safari-extension|EXERCISE|fetch + fail-closed SHA-256. Its tag/SHA pin pair is the coupling that broke the v1.0.26 line; the fetch IS the check of that pin.
download-python|EXERCISE|fetch + fail-closed SHA-256 on a pinned URL. Nothing signed, nothing published.
stage-daemon|EXERCISE|fetch + SHA-256 + fingerprint grep inside the extracted Mach-O. A wrong daemon pin fails here, which is the v1.0.27 shape.
stage-payload|EXERCISE|assembles the (B-lite) payload and asserts completeness plus the 500 MB cap. Writes only inside the fetched Hub bundle.
sparkle-embed|SKIP|embed-sparkle.sh CODESIGNS. Without the identity it takes its "leave the bundle unsigned" branch, so running it here would exercise a path the cut never takes and prove the wrong thing.
notarise-hub|SKIP|signs and notarises the Hub. Excluded by construction: a dry run reaches no Apple service and produces no signature.
release|SKIP|builds and Developer-ID signs OstlerInstaller.app. Excluded by construction. Its verification-only prerequisites are exercised in tier 2.
sign-python-bundle|SKIP|codesigns every nested Mach-O. Excluded by construction.
check-manifest|SKIP|a CHECK, but it reads the BUILT .app that `release` produces. Unreachable without building and signing one. THIS IS THE LARGEST HOLE IN THIS DRY RUN.
notarise-app|SKIP|notarises. Excluded by construction.
staple-apps|SKIP|staples, re-seals and re-notarises. Excluded by construction.
package|SKIP|writes and signs the DMG. Needs the built .app, and a signed DMG is precisely the artefact a dispatch must not be able to make. Its verification-only prerequisites are exercised in tier 2.
notarise-dmg|SKIP|notarises. Excluded by construction.
verify-dmg-contents|SKIP|a CHECK, but it mounts the DMG. No DMG, nothing to mount.
verify-stapling|SKIP|a CHECK, but it mounts the DMG.
verify-commit-parity|SKIP|a CHECK, but it mounts the DMG.
archive|SKIP|copies the shipped DMG into the operator archive dir. That is publishing. Excluded by construction.
PLAN
}

# publish-appcast IS DELIBERATELY ABSENT FROM THIS TIER-1 PLAN.
#
# It is no longer a prerequisite of `ship:`. CM051 #828 lifted it out and moved
# it into .github/workflows/cut.yml as a step that runs AFTER upload-artifact,
# because on v1.0.34 it was the LAST prerequisite of ship: and its failure
# destroyed a finished build: DMG notarised, stapled and spctl-verified at
# 03:10:04, publish-appcast hard-failed on an unset OSTLER_SPARKLE_SIGNING_KEY
# at 03:10:09, `make ship` returned non-zero, so the verify step and the upload
# were SKIPPED and the ephemeral runner was torn down with the only copy on it
# (run 32093975602, artifacts total_count = 0).
#
# This plan's denominator is `ship:`. A row here for a target ship: no longer
# names would report coverage of something this tier does not contain, which is
# the exact failure the CANNOT-RUN below exists to catch -- and it caught mine.
#
# It is NOT unenforced. tests/test_appcast_publish_cannot_destroy_the_dmg.sh
# asserts it is absent from ship:, has a body, is invoked by cut.yml AFTER the
# upload, and carries no continue-on-error.


tier2_plan() {
cat <<'PLAN'
check-tools|EXERCISE|xcodebuild and xcrun present.
check-identity|SKIP|needs the Developer ID in a keychain. This job deliberately never imports one, which is the reason it cannot sign.
check-version|EXERCISE|the three tracked version sources must agree (#171).
check-pbxproj-sync|EXERCISE|tracked pbxproj must equal xcodegen(project.yml) (#662).
check-create-dmg|EXERCISE|create-dmg on PATH -- the gap that killed run 31681624343 after every other gate had gone green.
check-clean-tree|EXERCISE|the cut checkout must be clean and on the expected branch. Network-free, so this job can run it in full.
check-branch-truth|SKIP|reads the HR015 SHIPPING_LEDGER and resolves daemon tags on GitHub. This job checks out neither, so it would report CANNOT-VERIFY; counting that as exercised would inflate the denominator.
check-freshness|EXERCISE|every shippable input against live upstream HEAD.
check-provenance|EXERCISE|named fixes present in this tree and in the pinned daemon tag.
check-provenance-content|EXERCISE|required fixes actually baked into the pinned artefacts.
PLAN
}

# $1 is the NAME of a plan function, called to emit its rows.
plan_names()  { "$1" | awk -F'|' 'NF>=3 {print $1}'; }
plan_field()  { "$1" | awk -F'|' -v t="$2" -v f="$3" '$1==t {print $f; exit}'; }

# The anti-drift assertion. A prerequisite this file has not classified is not
# a skip, it is an unknown -- and an unknown counted as either would corrupt the
# denominator the whole script exists to print.
validate_plan() {
    _label="$1"; _plan="$2"; _actual="$3"
    _unclassified=""; _phantom=""
    for _t in $_actual; do
        if [ -z "$(plan_field "$_plan" "$_t" 2)" ]; then
            _unclassified="$_unclassified $_t"
        fi
    done
    for _t in $(plan_names "$_plan"); do
        case " $_actual " in *" $_t "*) ;; *) _phantom="$_phantom $_t" ;; esac
    done
    if [ -n "$_unclassified" ] || [ -n "$_phantom" ]; then
        printf '\n%sCANNOT RUN%s  the %s plan no longer matches gui/Makefile.\n' \
               "$c_red" "$c_off" "$_label" >&2
        [ -n "$_unclassified" ] && printf '  prerequisite(s) with no row here:%s\n' "$_unclassified" >&2
        [ -n "$_phantom" ] && printf '  row(s) here naming no prerequisite:%s\n' "$_phantom" >&2
        printf '%s\n' "  Classify them in scripts/dry_run_cut_checks.sh and re-run. Reporting a" >&2
        printf '%s\n' "  denominator that no longer describes the target is how a ledger becomes" >&2
        printf '%s\n' "  a decoration." >&2
        exit 2
    fi
}

validate_plan "tier 1 (ship:)" tier1_plan "$SHIP_PREREQS"
validate_plan "tier 2 (release: + package:)" tier2_plan "$TIER2_TARGETS"

# ---------------------------------------------------------------------------
# RUN. Every exercised target runs even when an earlier one fails, because the
# point of a dry run is to surface every break in ONE round trip. Serial
# discovery of parallel facts at one CI round trip each is the cost this file
# exists to remove.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dryrun-XXXXXX")" || cannot_run "could not create a scratch dir"
trap 'rm -rf "$WORK"' EXIT
RESULTS="$WORK/results"
: > "$RESULTS"

FAILED=0

run_target() {
    _tier="$1"; _t="$2"
    printf '\n'
    rule
    printf ' [dry-run %s] make -C gui %s\n' "$_tier" "$_t"
    rule
    if make -C "$GUI_DIR" --no-print-directory "$_t"; then
        _rc=0
        printf '%s  PASS%s  %s\n' "$c_grn" "$c_off" "$_t"
    else
        _rc=$?
        FAILED=$((FAILED + 1))
        printf '%s  RED %s  %s (exit %s)\n' "$c_red" "$c_off" "$_t" "$_rc"
    fi
    printf '%s|%s|%s\n' "$_tier" "$_t" "$_rc" >> "$RESULTS"
}

if [ "$PLAN_ONLY" = "1" ]; then
    printf '\n%s--plan: the classification was validated against gui/Makefile and\n' "$c_dim"
    printf 'nothing was run. Every target below reports NOT RUN, which is the truth.%s\n' "$c_off"
else
    # Tier 1 in `ship:` order, so a dependency is never asked for before the
    # target that produces it (check-ostler-app after download-hub-app,
    # stage-payload after stage-daemon).
    for t in $SHIP_PREREQS; do
        [ "$(plan_field tier1_plan "$t" 2)" = "EXERCISE" ] || continue
        run_target 1 "$t"
    done

    # Tier 2 after tier 1: check-freshness and the two provenance gates want the
    # reference checkout the workflow exported, and cost the most.
    for t in $TIER2_TARGETS; do
        [ "$(plan_field tier2_plan "$t" 2)" = "EXERCISE" ] || continue
        run_target 2 "$t"
    done
fi

# ---------------------------------------------------------------------------
# NOTHING SHIPPABLE WAS MANUFACTURED. Measured, not asserted in prose.
#
# The paths are asked of make rather than restated here. v1.0.26 threw away a
# fully notarised DMG because two steps read `dist/` while DIST_DIR pointed at
# /tmp; a second copy of a path is a second thing to drift.
#
# Each absence check is paired with a POSITIVE CONTROL where one exists, because
# an "X is absent" assertion also passes when the apparatus is dead.
# ---------------------------------------------------------------------------
ARTEFACT_FAILS=0
artefact_ok()  { printf '   %s[OK]%s   %s\n' "$c_grn" "$c_off" "$1"; }
artefact_bad() { printf '   %s[FAIL]%s %s\n' "$c_red" "$c_off" "$1"; ARTEFACT_FAILS=$((ARTEFACT_FAILS + 1)); }

if [ "$PLAN_ONLY" = "0" ]; then

ask_make() { make -C "$GUI_DIR" --no-print-directory "$1" 2>/dev/null | tail -1; }

DMG_PATH="$(ask_make print-dmg-path)"
DIST_DIR="$(ask_make print-dist-dir)"
BUILD_DIR="$(ask_make print-build-dir)"
ARCHIVE_DIR="$(ask_make print-archive-dir)"

printf '\n'
rule
printf ' NOTHING SHIPPABLE WAS MANUFACTURED\n'
rule

count_glob() {
    # $1 = directory, $2 = glob suffix. 0 when the directory does not exist,
    # which is the normal case here and must not be an error.
    ls -d "$1"/$2 2>/dev/null | wc -l | tr -d ' '
}

if [ -z "$DMG_PATH" ] || [ -z "$DIST_DIR" ] || [ -z "$BUILD_DIR" ] || [ -z "$ARCHIVE_DIR" ]; then
    artefact_bad "make could not name one of its output paths, so these checks did not look:"
    printf '     dmg=[%s] dist=[%s] build=[%s] archive=[%s]\n' \
           "$DMG_PATH" "$DIST_DIR" "$BUILD_DIR" "$ARCHIVE_DIR"
else
    if [ -f "$DMG_PATH" ]; then
        artefact_bad "a DMG EXISTS at $DMG_PATH"
    else
        artefact_ok "no DMG at $DMG_PATH"
    fi

    _apps="$(count_glob "$DIST_DIR" '*.app')"
    if [ "$_apps" = "0" ]; then
        artefact_ok "no exported .app in $DIST_DIR"
    else
        artefact_bad "$_apps exported .app(s) in $DIST_DIR"
    fi

    _dmgs="$(count_glob "$DIST_DIR" '*.dmg')"
    if [ "$_dmgs" = "0" ]; then
        artefact_ok "no .dmg in $DIST_DIR"
    else
        artefact_bad "$_dmgs .dmg file(s) in $DIST_DIR"
    fi

    _arch="$(count_glob "$BUILD_DIR" '*.xcarchive')"
    if [ "$_arch" = "0" ]; then
        artefact_ok "no .xcarchive in $BUILD_DIR"
    else
        artefact_bad "$_arch .xcarchive(s) in $BUILD_DIR"
    fi

    _keep="$(count_glob "$ARCHIVE_DIR" '*.dmg')"
    if [ "$_keep" = "0" ]; then
        artefact_ok "no archived DMG in $ARCHIVE_DIR"
    else
        artefact_bad "$_keep archived DMG(s) in $ARCHIVE_DIR -- the archive target ran"
    fi
fi

# dist/ is what cut.yml's upload-artifact reads. It must not exist here.
if [ -e "$REPO_ROOT/dist" ]; then
    artefact_bad "$REPO_ROOT/dist exists -- that is what upload-artifact globs"
else
    artefact_ok "no dist/ in the workspace (upload-artifact's glob target)"
fi

# THE SIGNING IDENTITY, WITH A POSITIVE CONTROL.
#
# "codesign identity absent" would also print on a runner where `security` is
# broken, so assert the command PRODUCED A LISTING first. An absence check whose
# apparatus died reads exactly like a clean result.
if command -v security >/dev/null 2>&1; then
    _ids="$(security find-identity -p codesigning -v 2>&1)"
    _idlines="$(printf '%s\n' "$_ids" | wc -l | tr -d ' ')"
    if [ -z "$_ids" ]; then
        artefact_bad "security produced no listing at all, so this check did not look"
    elif printf '%s' "$_ids" | grep -q 'Developer ID Application: Creative Machines Limited'; then
        artefact_bad "the SHIPPING IDENTITY is in a keychain on this runner"
    else
        artefact_ok "the shipping identity is in no keychain here (listing had $_idlines line(s))"
    fi
else
    artefact_bad "no 'security' binary, so the identity check did not look"
fi

else
    printf '\n'
    rule
    printf ' NOTHING SHIPPABLE WAS MANUFACTURED -- not asserted under --plan\n'
    rule
    printf '   %s[skipped]%s --plan validates the classification only. Nothing ran, so there\n' "$c_dim" "$c_off"
    printf '   %s           is nothing to assert about this runner.%s\n' "$c_dim" "$c_off"
fi

# ---------------------------------------------------------------------------
# THE LEDGER.
# ---------------------------------------------------------------------------
result_rc() { awk -F'|' -v t="$2" -v tier="$1" '$1==tier && $2==t {print $3; exit}' "$RESULTS"; }

print_tier() {
    _tier="$1"; _plan="$2"; _actual="$3"; _title="$4"
    _n=0; _ex=0; _sk=0
    for _t in $_actual; do _n=$((_n + 1)); done

    printf '\n %s\n\n' "$_title"

    printf '   EXERCISED\n'
    for _t in $_actual; do
        [ "$(plan_field "$_plan" "$_t" 2)" = "EXERCISE" ] || continue
        _ex=$((_ex + 1))
        _rc="$(result_rc "$_tier" "$_t")"
        if [ "${_rc:-}" = "0" ]; then
            printf '     %sPASS%s  %-28s %s\n' "$c_grn" "$c_off" "$_t" ""
        elif [ -z "${_rc:-}" ]; then
            if [ "$PLAN_ONLY" = "1" ]; then
                printf '     %sNOT RUN%s %-27s --plan: classification only, nothing was run\n' "$c_yel" "$c_off" "$_t"
            else
                printf '     %sNOT RUN%s %-27s the run stopped before reaching it\n' "$c_yel" "$c_off" "$_t"
            fi
        else
            printf '     %sRED %s  %-28s exit %s\n' "$c_red" "$c_off" "$_t" "$_rc"
        fi
    done

    printf '\n   NOT EXERCISED\n'
    for _t in $_actual; do
        [ "$(plan_field "$_plan" "$_t" 2)" = "SKIP" ] || continue
        _sk=$((_sk + 1))
        printf '     %sSKIP%s  %-28s %s\n' "$c_yel" "$c_off" "$_t" "$(plan_field "$_plan" "$_t" 3)"
    done

    printf '\n   %s: %s of %s exercised, %s of %s NOT exercised.\n' \
           "$_title" "$_ex" "$_n" "$_sk" "$_n"
    TOTAL_N=$((TOTAL_N + _n)); TOTAL_EX=$((TOTAL_EX + _ex)); TOTAL_SK=$((TOTAL_SK + _sk))
}

TOTAL_N=0; TOTAL_EX=0; TOTAL_SK=0

printf '\n'
rule
printf ' DRY RUN LEDGER -- what this run actually exercised\n'
rule
print_tier 1 tier1_plan "$SHIP_PREREQS" \
    "TIER 1: the direct prerequisites of gui/Makefile 'ship:'"
print_tier 2 tier2_plan "$TIER2_TARGETS" \
    "TIER 2: verification-only prerequisites of the SKIPPED composites 'release:' and 'package:'"

printf '\n'
rule
printf ' TOTAL: %s of %s targets exercised, %s NOT exercised.\n' "$TOTAL_EX" "$TOTAL_N" "$TOTAL_SK"
rule
printf '%s' "$c_dim"
cat <<'CAVEAT'
 WHAT A GREEN HERE DOES NOT SAY.

 It does not say the cut will pass. The whole build-and-sign half of the chain
 is unexercised by design, and check-manifest -- which reads the BUILT .app --
 is unreachable without it. Nothing here has been signed, notarised, stapled,
 packaged, released, archived or uploaded, and the section above measured that
 rather than claiming it.

 What a green DOES say: every check in the lists above ran, in the cut's own
 environment, on the cut's own runner image, against this tree -- and none of
 them is the reason the next tag fails.

 To cut:  git tag v1.0.X && git push origin v1.0.X
CAVEAT
printf '%s\n' "$c_off"

if [ "$FAILED" -gt 0 ] || [ "$ARTEFACT_FAILS" -gt 0 ]; then
    printf '\n%sDRY RUN RED%s  %s check(s) failed, %s artefact assertion(s) failed.\n' \
           "$c_red" "$c_off" "$FAILED" "$ARTEFACT_FAILS" >&2
    exit 1
fi

if [ "$PLAN_ONLY" = "1" ]; then
    printf '\n%sPLAN OK%s  %s of %s targets are classified EXERCISE, %s SKIP. Nothing was run.\n' \
           "$c_grn" "$c_off" "$TOTAL_EX" "$TOTAL_N" "$TOTAL_SK"
    exit 0
fi

printf '\n%sDRY RUN GREEN%s  %s of %s targets exercised; nothing shippable was produced.\n' \
       "$c_grn" "$c_off" "$TOTAL_EX" "$TOTAL_N"
exit 0
