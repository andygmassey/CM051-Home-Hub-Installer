#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Select the Xcode named in gui/.xcode-version, and PROVE the selection took.
#
# WHY THIS IS A SCRIPT AND NOT TWO COPIES OF A WORKFLOW STEP
#
# It was inline in .github/workflows/pbxproj-sync.yml, and the `cut` job in
# cut.yml did not have it. That job ran on macos-14 (Xcode 15.4) against a 26.6
# pin, so `make ship` hit the same UNAVAILABLE the PR workflow had already
# diagnosed and fixed on run 31618148018 -- and the fix simply never travelled
# the ten lines to the other file.
#
# Two copies of a toolchain contract is how the copies come to disagree, which
# is the same class of defect as everything else this cut has surfaced. One
# body, two callers.
#
# WHY THE BUILD VERSION, NOT THE MARKETING VERSION
#
# xcodegen reads its default build settings from the SELECTED Xcode, so the
# selection is an INPUT to a byte-exact comparison. Measured 2026-08-13: a
# runner and the build host both reported 26.6 with xcodegen 2.44.1 and emitted
# different bytes. Marketing version does not identify the setting presets.
#
# NEVER FALLS BACK. If the pinned build is absent this exits 1 and enumerates
# every Xcode that IS present, so the next failure is diagnosable in one read.
# Relaxing the pin to make a runner green reinstates exactly the blindness the
# comparison exists to remove.
#
# Usage:   scripts/select_pinned_xcode.sh
# Writes:  DEVELOPER_DIR into $GITHUB_ENV when running under Actions.
#          Otherwise prints an export line for the caller to eval.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN_FILE="$REPO_ROOT/gui/.xcode-version"

[ -f "$PIN_FILE" ] || { echo "::error::$PIN_FILE not found" >&2; exit 1; }

LINE="$(grep -v '^[[:space:]]*#' "$PIN_FILE" | grep -v '^[[:space:]]*$' | head -1)"
PIN="$(awk '{print $1}' <<<"$LINE")"
PIN_BUILD="$(awk '{print $2}' <<<"$LINE")"

[ -n "$PIN" ] || { echo "::error::gui/.xcode-version is empty" >&2; exit 1; }
[ -n "$PIN_BUILD" ] || {
    echo "::error::gui/.xcode-version has no build version; marketing version alone is not a sufficient pin" >&2
    exit 1
}
echo "pinned Xcode: $PIN ($PIN_BUILD)"

FOUND=""
echo "installed Xcodes here (marketing / build):"
for APP in /Applications/Xcode*.app; do
    [ -d "$APP" ] || continue
    V="$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
    B="$(/usr/bin/defaults read "$APP/Contents/version.plist" ProductBuildVersion 2>/dev/null || echo '?')"
    echo "  $V  $B  $APP"
    if [ "$V" = "$PIN" ] && [ "$B" = "$PIN_BUILD" ] && [ -z "$FOUND" ]; then
        FOUND="$APP"
    fi
done

if [ -z "$FOUND" ]; then
    echo "::error::no Xcode $PIN build $PIN_BUILD here. Every Xcode that IS present is listed above, with its build." >&2
    echo "::error::Do NOT relax the pin to make this green. If no hosted runner can supply the build the DMG is cut with, then a byte-exact comparison does not belong in CI: keep it as a pre-cut check on the cut machine and give CI a toolchain-independent check instead." >&2
    exit 1
fi

export DEVELOPER_DIR="$FOUND/Contents/Developer"
echo "selected: $FOUND"

# ASSERT THE SELECTION TOOK EFFECT. Setting DEVELOPER_DIR and assuming it
# applied is the same class of error one layer down, so read it back from the
# tool that will actually be used.
GOT="$(xcodebuild -version | head -1 | awk '{print $2}')"
GOT_BUILD="$(xcodebuild -version | sed -n '2p' | awk '{print $3}')"
echo "xcodebuild reports: $GOT ($GOT_BUILD)   pin: $PIN ($PIN_BUILD)"
if [ "$GOT" != "$PIN" ] || [ "$GOT_BUILD" != "$PIN_BUILD" ]; then
    echo "::error::DEVELOPER_DIR did not take: xcodebuild is $GOT ($GOT_BUILD), pin is $PIN ($PIN_BUILD)" >&2
    exit 1
fi

if [ -n "${GITHUB_ENV:-}" ]; then
    echo "DEVELOPER_DIR=$DEVELOPER_DIR" >> "$GITHUB_ENV"
else
    echo "export DEVELOPER_DIR=$DEVELOPER_DIR"
fi
