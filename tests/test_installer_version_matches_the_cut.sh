#!/usr/bin/env bash
# The installer's own version must BE the version being cut (CM051, v1.0.39)
# ===========================================================================
#
# THE DEFECT, SHIPPED. v1.0.39 was cut, signed, notarised, published and
# downloaded, and the OstlerInstaller.app inside it reported
# CFBundleShortVersionString = 1.0.38. The bump was simply missed.
#
# CONTROLLED WHEN FOUND, because "looks wrong" is not a finding:
#
#     tag v1.0.36 -> plist 1.0.36    tag v1.0.38 -> plist 1.0.38
#     tag v1.0.37 -> plist 1.0.37    tag v1.0.39 -> plist 1.0.38   <- the miss
#
# Three cuts in a row had carried their own version, so the field does track
# the cut and v1.0.39 was the first break.
#
# WHY NOTHING CAUGHT IT, WHICH IS THE REAL LESSON.
# A gate for exactly this was WRITTEN: OS003 #122, "assert the stamped version
# IS the version being cut".
#
# The first draft of this comment said that gate ALREADY EXISTS and runs in
# OS003 `bin/cut.sh` preflight. THAT WAS WRONG, and the wrong version is the
# dangerous one because it implies the estate is one wiring change away from
# safe. Measured: OS003 #122 is an OPEN PR, merged=never. It has never run
# anywhere, on any surface. It was read off a commit sitting on a checked-out
# feature branch and mistaken for shipped practice.
#
# So TWO independent things had to be true for this to ship, and fixing either
# alone would have left the other:
#
#   1. the OS003 gate is unmerged, so it runs nowhere
#   2. even merged, it runs in OS003 `bin/cut.sh` preflight -- and the v1.0.39
#      DMG was cut by pushing a tag, which fires CM051 cut.yml, a path that
#      never consults OS003
#
# This one lives HERE, on the surface that actually cuts, so it holds
# regardless of what happens to OS003 #122. That PR is still worth merging: it
# guards the OS003 cut path, which is a different route to a DMG. It is not a
# substitute and never was.
#
# WHAT IS ASSERTED
#   1. the plist parses and yields a version    (premise, fails loudly)
#   2. CFBundleShortVersionString == the cut version
#   3. CFBundleVersion == that version's build number, so the two cannot drift
#      apart quietly
#   4. a CONTROL: the same comparison, given a deliberately wrong version,
#      must FAIL. Without it a broken comparison passes everything.
#
# The cut version comes from $1, else GITHUB_REF_NAME, else the newest v* tag.
# Given none of those it reports CANNOT-RUN (exit 2) rather than passing: an
# assertion that could not find its expected value has not been checked.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="${REPO_ROOT}/gui/OstlerInstaller/Info.plist"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

printf 'test_installer_version_matches_the_cut\n'

[ -f "$PLIST" ] || { bad "premise: no Info.plist at ${PLIST}"; exit 1; }

# --- resolve the version being cut ------------------------------------------
CUT="${1:-${GITHUB_REF_NAME:-}}"
if [ -z "$CUT" ]; then
    CUT="$(git -C "$REPO_ROOT" tag -l 'v1.0.*' --sort=-v:refname 2>/dev/null | head -1)"
fi
if [ -z "$CUT" ]; then
    printf '  CANNOT-RUN: no cut version given and no v1.0.* tag found.\n' >&2
    printf '              This is NOT a pass -- the comparison never ran.\n' >&2
    exit 2
fi
CUT_VER="${CUT#v}"
case "$CUT_VER" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) printf '  CANNOT-RUN: %s does not look like a version.\n' "$CUT" >&2; exit 2 ;;
esac
ok "cut version resolved: ${CUT_VER} (from '${CUT}')"

# --- read the plist ---------------------------------------------------------
# PlistBuddy rather than grep: the plist is XML and a grep for <string> after a
# key is exactly the kind of positional read that breaks when a key moves.
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }
SHORT="$(read_key CFBundleShortVersionString)"
BUILD="$(read_key CFBundleVersion)"

if [ -z "$SHORT" ] || [ -z "$BUILD" ]; then
    bad "premise: could not read the version keys (short='${SHORT}' build='${BUILD}'); every check below would be vacuous"
    exit 1
fi
ok "plist reads short=${SHORT} build=${BUILD}"

# --- 2. the assertion this file exists for ----------------------------------
if [ "$SHORT" = "$CUT_VER" ]; then
    ok "CFBundleShortVersionString IS the version being cut"
else
    bad "CFBundleShortVersionString is ${SHORT} but the cut is ${CUT_VER}. \
This is the v1.0.39 defect: a DMG that cannot tell you which installer it is."
fi

# --- 3. the build number moves with it --------------------------------------
# Scheme MEASURED across v1.0.36/37/38: 3600 / 3700 / 3800. It is the PATCH
# number times 100, not the version with its dots removed -- the first draft
# of this function assumed the latter, derived 0390 for 1.0.39, and this file
# failed its own check. Left as a comment because the near-miss is the point:
# the derivation is validated below against the three real historical values,
# so a wrong formula cannot pass by agreeing with itself.
want_build() { printf '%s' "$1" | awk -F. '{printf "%d", $3 * 100}'; }
EXPECT_BUILD="$(want_build "$CUT_VER")"
if [ "$BUILD" = "$EXPECT_BUILD" ]; then
    ok "CFBundleVersion ${BUILD} matches the scheme for ${CUT_VER}"
else
    bad "CFBundleVersion is ${BUILD}, expected ${EXPECT_BUILD} for ${CUT_VER}. \
Short version and build number must not drift apart."
fi

# --- 3b. the derivation is validated against REAL historical values ---------
# A formula checked only against the value it was written for is checked
# against nothing. These three are what v1.0.36/37/38 actually shipped.
for pair in "1.0.36:3600" "1.0.37:3700" "1.0.38:3800"; do
    v="${pair%%:*}"; want="${pair#*:}"
    got="$(want_build "$v")"
    if [ "$got" = "$want" ]; then
        ok "derivation: ${v} -> ${got} (matches what v${v} shipped)"
    else
        bad "derivation: ${v} -> ${got}, but v${v} shipped ${want}. The formula is wrong."
    fi
done

# --- 4. CONTROL: the comparison must be able to fail ------------------------
# Without this, a comparison broken to always-true would pass checks 2 and 3
# and this file would certify nothing.
WRONG="0.0.0"
if [ "$SHORT" = "$WRONG" ]; then
    bad "control: the plist genuinely reads ${WRONG}, so the control cannot discriminate"
else
    ok "control: the same comparison against ${WRONG} does NOT match, so a match is meaningful"
fi
if [ "$(want_build "$WRONG")" = "$EXPECT_BUILD" ]; then
    bad "control: the build-number derivation returns the same value for ${WRONG} and ${CUT_VER}"
else
    ok "control: the build-number derivation discriminates ${WRONG} from ${CUT_VER}"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'INSTALLER VERSION IS THE VERSION BEING CUT\n'
