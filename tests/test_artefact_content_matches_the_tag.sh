#!/usr/bin/env bash
# The BUILT ARTEFACT's install.sh must be the tag's install.sh (CM051 #856/#844)
# ============================================================================
#
# WHAT THIS EXISTS FOR. Nothing in the cut ever compared the CONTENT of the
# artefact to the tag being cut. The publish-integrity check compares the DMG
# to its OWN SHA256SUMS, which proves the bytes were not corrupted in transit
# and proves NOTHING about which tree produced them. A build that packaged a
# stale install.sh would sail through every existing gate and reach a customer.
#
# Raised by TNM against v1.0.39 on 2026-08-22. On re-measurement that artefact
# turned out to be correct -- both copies of install.sh in the DMG hash to the
# v1.0.39 blob -- but THE GAP WAS REAL EITHER WAY, and a gate that only gets
# written when a defect is confirmed is a gate that arrives one incident late.
#
# WHY install.sh IS THE RIGHT FILE TO HASH. It is version-bearing (it carries
# OSTLER_ASSISTANT_VERSION, the fallback version and both integrity pins), it
# is the largest single thing a customer executes, and it is copied into the
# artefact verbatim, so its blob at the tag and its bytes in the DMG are
# directly comparable with one sha256 and no normalisation.
#
# WHAT IS ASSERTED
#   1. EVERY install.sh in the artefact matches the tag's blob -- every one,
#      not the first found. There are TWO in a v1.0.39 DMG
#      (Contents/Resources/ and the nested ostler-payload/), and a `find |
#      head -1` reads whichever the filesystem happens to return first. That
#      exact shortcut produced a wrong reading during the v1.0.39 incident.
#   2. the installer bundle's CFBundleShortVersionString IS the cut version,
#      asserted against the ARTEFACT rather than the source tree. #955 checks
#      the tracked plist; it cannot see a build that packaged something else.
#   3. CONTROL: the same predicate run against a DIFFERENT tag's blob must
#      NOT match. Without it a comparison broken to always-true certifies
#      everything. The control tag is resolved as the nearest OTHER v1.0.*
#      tag, and if none exists the check reports CANNOT-RUN rather than
#      quietly dropping to a two-limb test.
#
# CANNOT-RUN (exit 2), never a pass, when: no mounted artefact is given, the
# tag does not resolve, or no control tag exists. An assertion that could not
# find its subject has not been checked.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
cannot() { printf '  CANNOT-RUN: %s\n' "$*" >&2; printf '              This is NOT a pass.\n' >&2; exit 2; }

printf 'test_artefact_content_matches_the_tag\n'

ROOT="${1:-${OSTLER_ARTEFACT_ROOT:-}}"
CUT="${2:-${CUT_VERSION:-${GITHUB_REF_NAME:-}}}"

[ -n "$ROOT" ] || cannot "no artefact root given (arg 1 or OSTLER_ARTEFACT_ROOT). Mount the DMG and pass its mountpoint."
[ -d "$ROOT" ] || cannot "artefact root '$ROOT' is not a directory"
[ -n "$CUT" ] || cannot "no cut version given (arg 2, CUT_VERSION or GITHUB_REF_NAME)"

git -C "$REPO_ROOT" rev-parse --verify --quiet "${CUT}^{commit}" >/dev/null 2>&1 \
    || cannot "tag/ref '${CUT}' does not resolve in ${REPO_ROOT}"

# --- the tag's blob ----------------------------------------------------------
WANT="$(git -C "$REPO_ROOT" show "${CUT}:install.sh" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
[ -n "$WANT" ] && [ "$WANT" != "$(printf '' | shasum -a 256 | awk '{print $1}')" ] \
    || cannot "could not read install.sh at ${CUT}"
ok "tag ${CUT} install.sh -> ${WANT:0:16}..."

# --- 3. the control, resolved FIRST so a missing one stops the run -----------
# Nearest other v1.0.* tag. Deliberately not hardcoded: a pinned control tag
# rots the moment it is deleted, and a rotted control silently stops
# discriminating while every other limb still says PASS.
CONTROL=""
while read -r t; do
    [ "$t" = "$CUT" ] && continue
    git -C "$REPO_ROOT" rev-parse --verify --quiet "${t}^{commit}" >/dev/null 2>&1 || continue
    CONTROL="$t"; break
done <<< "$(git -C "$REPO_ROOT" tag -l 'v1.0.*' --sort=-v:refname 2>/dev/null)"
[ -n "$CONTROL" ] || cannot "no second v1.0.* tag to use as a control; a one-sided comparison proves nothing"
CONTROL_SHA="$(git -C "$REPO_ROOT" show "${CONTROL}:install.sh" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
if [ -z "$CONTROL_SHA" ]; then
    cannot "control tag ${CONTROL} has no readable install.sh"
fi
if [ "$CONTROL_SHA" = "$WANT" ]; then
    bad "control tag ${CONTROL} has an IDENTICAL install.sh to ${CUT}, so this comparison cannot discriminate between them"
    exit 1
fi
ok "control: ${CONTROL} install.sh differs (${CONTROL_SHA:0:16}...), so a match against ${CUT} is meaningful"

# --- 1. EVERY install.sh in the artefact ------------------------------------
FOUND=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    FOUND=$((FOUND+1))
    got="$(shasum -a 256 "$f" | awk '{print $1}')"
    rel="${f#"$ROOT"/}"
    if [ "$got" = "$WANT" ]; then
        ok "artefact install.sh matches ${CUT}: ${rel}"
    elif [ "$got" = "$CONTROL_SHA" ]; then
        bad "artefact install.sh is ${CONTROL}'s, NOT ${CUT}'s: ${rel} (${got:0:16}...). \
The build packaged a stale file."
    else
        bad "artefact install.sh matches NEITHER ${CUT} nor ${CONTROL}: ${rel} (${got:0:16}...)"
    fi
done <<< "$(find "$ROOT" -name 'install.sh' -type f 2>/dev/null)"

if [ "$FOUND" -eq 0 ]; then
    cannot "no install.sh found anywhere under ${ROOT}; the comparison never ran"
fi
ok "checked ALL ${FOUND} install.sh in the artefact, not the first one found"

# --- 2. the bundle version, asserted against the ARTEFACT -------------------
CUT_VER="${CUT#v}"
PLIST="$(find "$ROOT" -maxdepth 3 -name 'Info.plist' -path '*OstlerInstaller.app*' 2>/dev/null | head -1)"
if [ -z "$PLIST" ]; then
    bad "no OstlerInstaller.app Info.plist under ${ROOT}; cannot check the shipped version"
else
    SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null)"
    if [ -z "$SHORT" ]; then
        bad "could not read CFBundleShortVersionString from the shipped bundle"
    elif [ "$SHORT" = "$CUT_VER" ]; then
        ok "shipped bundle reports ${SHORT}, which IS the version being cut"
    else
        bad "shipped bundle reports ${SHORT} but the cut is ${CUT_VER}. \
This is the v1.0.39 defect, seen in the ARTEFACT rather than the source tree."
    fi
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'ARTEFACT CONTENT IS THE TAG BEING CUT\n'
