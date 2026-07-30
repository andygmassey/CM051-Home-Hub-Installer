#!/usr/bin/env bash
# Installer version-consistency gate (CM051 #171, v1.0.13).
#
# The failure this refuses:
#   The DMG's OstlerInstaller.app stamps a STALE CFBundleShortVersionString.
#   For v1.0.11 AND v1.0.12 the installer app shipped reading "1.0.10" -- the
#   value was hardcoded and never bumped, because gui/Makefile DERIVES the DMG
#   name + the app version by READING gui/OstlerInstaller/Info.plist, not from
#   the cut tag. A half-bump (project.yml bumped but Info.plist forgotten, or
#   Info.plist bumped but `xcodegen generate` not re-run so the tracked
#   pbxproj lags) ships a version-stale installer while every signing/notarise
#   chain goes green. Same class as the "silent bail" regressions this repo
#   already gates.
#
# This test makes a half-bump impossible to merge: it asserts the installer's
# version is IDENTICAL across the three tracked sources of truth --
#   1. gui/OstlerInstaller/Info.plist        (what the built .app stamps)
#   2. gui/project.yml                        (the xcodegen source)
#   3. gui/OstlerInstaller.xcodeproj/project.pbxproj  (the generated project)
# on BOTH the marketing/short version (CFBundleShortVersionString /
# MARKETING_VERSION) and the build number (CFBundleVersion /
# CURRENT_PROJECT_VERSION). If project.yml is edited but `xcodegen generate`
# was not re-run, the pbxproj lags and this gate goes RED.
#
# Portable by design: runs in GitHub Actions on ubuntu-latest (no PlistBuddy),
# so the Info.plist is parsed with Python's stdlib plistlib, and project.yml /
# pbxproj are parsed with grep. No third-party deps.
#
# NOTE (residual manual step): the version is NOT yet derived from the cut tag.
# Bumping a release still requires a human to edit MARKETING_VERSION +
# CFBundleShortVersionString (and the build-number fields) in gui/project.yml
# and gui/OstlerInstaller/Info.plist, then run `cd gui && xcodegen generate`.
# This gate does not perform that bump -- it guarantees a PARTIAL bump cannot
# ship. See VERSIONING.md for the bump checklist and the cut-derivation
# proposal.
#
# Exit 0 = all sources agree. Exit 1 = drift (a stale/half-bumped version).

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR_TEST/.." && pwd)"

INFO_PLIST="$REPO_ROOT/gui/OstlerInstaller/Info.plist"
PROJECT_YML="$REPO_ROOT/gui/project.yml"
PBXPROJ="$REPO_ROOT/gui/OstlerInstaller.xcodeproj/project.pbxproj"

fail() { echo "FAIL: $*" >&2; exit 1; }

for f in "$INFO_PLIST" "$PROJECT_YML" "$PBXPROJ"; do
    [[ -f "$f" ]] || fail "missing required file: $f"
done

# --- Info.plist (stdlib plistlib -- portable, no PlistBuddy) -----------------
plist_key() {
    python3 - "$INFO_PLIST" "$1" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    d = plistlib.load(fh)
key = sys.argv[2]
if key not in d:
    sys.stderr.write(f"FAIL: {key} absent from Info.plist\n")
    sys.exit(1)
print(str(d[key]).strip())
PY
}

# --- project.yml (single-occurrence keys; grep the quoted scalar) ------------
# Keys are unique in project.yml: MARKETING_VERSION + CURRENT_PROJECT_VERSION
# live once under settings.base; CFBundleShortVersionString + CFBundleVersion
# live once under the target's info.properties. Guard against a future
# duplicate by asserting exactly one match.
yml_val() {
    local key="$1" matches
    matches="$(grep -E "^[[:space:]]*${key}:[[:space:]]" "$PROJECT_YML" || true)"
    [[ -n "$matches" ]] || fail "$key not found in project.yml"
    if [[ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" != "1" ]]; then
        fail "$key appears more than once in project.yml -- ambiguous:
$matches"
    fi
    printf '%s\n' "$matches" | sed -E 's/.*:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
}

# --- pbxproj (multiple occurrences: Debug + Release must all agree) ----------
pbx_uniq() {
    local key="$1" vals
    vals="$(grep -E "^[[:space:]]*${key} = " "$PBXPROJ" \
              | sed -E "s/.*${key} = ([^;]*);.*/\1/" | sort -u || true)"
    [[ -n "$vals" ]] || fail "$key not found in pbxproj"
    if [[ "$(printf '%s\n' "$vals" | wc -l | tr -d ' ')" != "1" ]]; then
        fail "$key has inconsistent values across build configs in pbxproj:
$vals"
    fi
    printf '%s\n' "$vals"
}

# ---------------------------------------------------------------------------
# Marketing / short version (e.g. "1.0.13")
# ---------------------------------------------------------------------------
PLIST_SHORT="$(plist_key CFBundleShortVersionString)"
YML_SHORT="$(yml_val CFBundleShortVersionString)"
YML_MARKETING="$(yml_val MARKETING_VERSION)"
PBX_MARKETING="$(pbx_uniq MARKETING_VERSION)"

echo "[version] CFBundleShortVersionString (Info.plist):     $PLIST_SHORT"
echo "[version] CFBundleShortVersionString (project.yml):    $YML_SHORT"
echo "[version] MARKETING_VERSION          (project.yml):    $YML_MARKETING"
echo "[version] MARKETING_VERSION          (pbxproj):        $PBX_MARKETING"

if [[ "$PLIST_SHORT" != "$YML_SHORT" || "$PLIST_SHORT" != "$YML_MARKETING" || "$PLIST_SHORT" != "$PBX_MARKETING" ]]; then
    fail "installer marketing version drift -- the three sources disagree.
  Info.plist CFBundleShortVersionString = $PLIST_SHORT
  project.yml CFBundleShortVersionString = $YML_SHORT
  project.yml MARKETING_VERSION          = $YML_MARKETING
  pbxproj     MARKETING_VERSION          = $PBX_MARKETING
  This is the #171 stale-version shape. If you bumped project.yml, run
  'cd gui && xcodegen generate' to refresh the pbxproj and edit Info.plist
  to match. All four must be the same string."
fi

# ---------------------------------------------------------------------------
# Build number (e.g. "13")
# ---------------------------------------------------------------------------
PLIST_BUILD="$(plist_key CFBundleVersion)"
YML_BUILD="$(yml_val CFBundleVersion)"
YML_CURRENT="$(yml_val CURRENT_PROJECT_VERSION)"
PBX_CURRENT="$(pbx_uniq CURRENT_PROJECT_VERSION)"

echo "[build]   CFBundleVersion        (Info.plist):    $PLIST_BUILD"
echo "[build]   CFBundleVersion        (project.yml):   $YML_BUILD"
echo "[build]   CURRENT_PROJECT_VERSION (project.yml):  $YML_CURRENT"
echo "[build]   CURRENT_PROJECT_VERSION (pbxproj):      $PBX_CURRENT"

if [[ "$PLIST_BUILD" != "$YML_BUILD" || "$PLIST_BUILD" != "$YML_CURRENT" || "$PLIST_BUILD" != "$PBX_CURRENT" ]]; then
    fail "installer build number drift -- the four sources disagree.
  Info.plist CFBundleVersion         = $PLIST_BUILD
  project.yml CFBundleVersion         = $YML_BUILD
  project.yml CURRENT_PROJECT_VERSION = $YML_CURRENT
  pbxproj     CURRENT_PROJECT_VERSION = $PBX_CURRENT
  Re-run 'cd gui && xcodegen generate' after editing project.yml, and keep
  Info.plist in lockstep."
fi

echo "PASS: installer version consistent across Info.plist, project.yml, pbxproj (v$PLIST_SHORT build $PLIST_BUILD)"
exit 0
