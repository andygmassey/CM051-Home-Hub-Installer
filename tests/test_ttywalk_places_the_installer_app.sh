#!/usr/bin/env bash
#
# THE ARTEFACT WALK PUTS THE INSTALLER APP WHERE A CUSTOMER PUTS IT.
#
# app_signature_survives_first_run reads /Applications/OstlerInstaller.app. An
# ssh walk never put it there, so the probe was CANNOT-RUN on every thin walk
# and was listed on console_only_probes.tsv as a "gui" item. MEASURED
# 2026-11-04 (v1.0.123, Mini16): placed from the verified on-box DMG over ssh,
# the probe ran and PASSED. scripts/lib_walk_place_installer_app.sh now does
# that on every artefact walk.
#
# WHAT THIS ASSERTS (behaviour, on a real DMG built here with hdiutil)
#   1. a good DMG with the right sha256: the app is placed and verifies
#   2. a STALE app already there is removed first, even when the new DMG
#      is then refused (wrong sha): the box ends with NO app, never an old one
#   3. a missing DMG: no app, non-zero exit
#   4. a DMG with no installer app in it: no app, exit 6
# AND (wiring)
#   5. ttywalk.sh runs it for artefact walks only, after staging and before
#      the --stage-only exit, and a failure is announced, not fatal
#   6. app_signature_survives_first_run is no longer on console_only_probes.tsv
#
# macOS only (hdiutil, codesign, ditto). Elsewhere: CANNOT-RUN, exit 2.
# EXIT CODES. 0 every arm held; 1 an arm failed; 2 could not run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/scripts/lib_walk_place_installer_app.sh"
TW="${ROOT}/scripts/ttywalk.sh"
CO="${ROOT}/scripts/box_walk_probes/console_only_probes.tsv"
[ -f "$LIB" ] && [ -f "$TW" ] && [ -f "$CO" ] || { echo "CANNOT-RUN: a file under test is missing"; exit 2; }
[ "$(uname -s)" = "Darwin" ] && command -v hdiutil >/dev/null && command -v codesign >/dev/null \
    || { echo "CANNOT-RUN: needs macOS hdiutil + codesign"; exit 2; }
# shellcheck source=scripts/lib_walk_place_installer_app.sh
. "$LIB"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*" >&2; }

T="$(mktemp -d)"; trap 'hdiutil detach "$T/m" >/dev/null 2>&1; rm -rf "$T"' EXIT
APPS="$T/Applications"; mkdir -p "$APPS"

mkapp() {  # mkapp <dir> <version> [with-install-sh]
    local a="$1/OstlerInstaller.app"
    mkdir -p "$a/Contents/MacOS" "$a/Contents/Resources"
    printf '#!/bin/sh\nexit 0\n' > "$a/Contents/MacOS/OstlerInstaller"; chmod +x "$a/Contents/MacOS/OstlerInstaller"
    cat > "$a/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OstlerInstaller</string>
<key>CFBundleIdentifier</key><string>test.walk.placement</string>
<key>CFBundleShortVersionString</key><string>$2</string>
</dict></plist>
PL
    [ "${3:-yes}" = "yes" ] && printf '#!/bin/bash\n' > "$a/Contents/Resources/install.sh"
    codesign -s - --force --deep "$a" >/dev/null 2>&1
}
mkdmg() {  # mkdmg <srcdir> <out.dmg>
    hdiutil create -quiet -fs HFS+ -volname WPA -srcfolder "$1" -ov "$2" >/dev/null 2>&1
}
run_place() {  # run_place <dmg> <sha>
    walk_place_installer_app_script | WPA_APPS="$APPS" WPA_DMG="$1" WPA_SHA="$2" /bin/sh -s
}
ver_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APPS/OstlerInstaller.app/Contents/Info.plist" 2>/dev/null; }

mkdir -p "$T/good" "$T/noapp" "$T/stale"
mkapp "$T/good" 9.9.9 yes
mkdir -p "$T/noapp/Readme"; printf 'x\n' > "$T/noapp/Readme/x.txt"
mkdmg "$T/good" "$T/good.dmg" && mkdmg "$T/noapp" "$T/noapp.dmg" \
    || { echo "CANNOT-RUN: hdiutil create failed"; exit 2; }
GOOD_SHA="$(shasum -a 256 "$T/good.dmg" | awk '{print $1}')"
NOAPP_SHA="$(shasum -a 256 "$T/noapp.dmg" | awk '{print $1}')"

# 1
out="$(run_place "$T/good.dmg" "$GOOD_SHA" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(ver_of)" = "9.9.9" ] && codesign --verify --deep --strict "$APPS/OstlerInstaller.app" 2>/dev/null \
    && ok "good DMG, right sha: placed at version 9.9.9 and verifies" || bad "good DMG not placed (rc ${rc}): ${out}"

# 2: stale app present, wrong sha -> stale removed, nothing placed
# A wrong sha256, built at runtime (a literal run of digits trips the PII shape scan).
WRONG_SHA="$(printf '%064d' 0)"
rm -rf "$APPS/OstlerInstaller.app"; mkapp "$APPS" 1.0.63 yes
out="$(run_place "$T/good.dmg" "$WRONG_SHA" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && [ ! -e "$APPS/OstlerInstaller.app" ] \
    && ok "wrong sha: refused (rc 3) AND the stale 1.0.63 app is gone" || bad "wrong sha: rc ${rc}, app present=$([ -e "$APPS/OstlerInstaller.app" ] && echo yes || echo no)"
printf '%s\n' "$out" | /usr/bin/grep -q 'removed the existing app first (it said version 1.0.63)' \
    && ok "the stale removal is announced with its version" || bad "stale removal not announced"

# 3
out="$(run_place "$T/absent.dmg" "$GOOD_SHA" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$APPS/OstlerInstaller.app" ] && ok "missing DMG: rc ${rc}, no app" || bad "missing DMG: rc ${rc}"

# 4
out="$(run_place "$T/noapp.dmg" "$NOAPP_SHA" 2>&1)"; rc=$?
[ "$rc" -eq 6 ] && [ ! -e "$APPS/OstlerInstaller.app" ] && ok "DMG without an installer app: rc 6, no app" || bad "no-app DMG: rc ${rc}"

# 5: wiring
l_ctrl="$(/usr/bin/grep -n 'say "control: ostler_fda resolves beside install.sh' "$TW" | head -1 | cut -d: -f1)"
l_place="$(/usr/bin/grep -n 'walk_place_installer_app_script | "\${SSH\[@\]}"' "$TW" | head -1 | cut -d: -f1)"
l_stage="$(/usr/bin/grep -n '^if \[\[ "\$STAGE_ONLY" -eq 1 \]\]; then' "$TW" | head -1 | cut -d: -f1)"
if [ -z "$l_ctrl" ] || [ -z "$l_place" ] || [ -z "$l_stage" ]; then
    echo "CANNOT-RUN: ttywalk.sh anchors moved (ctrl=${l_ctrl:-?} place=${l_place:-?} stage_only=${l_stage:-?})"; exit 2
fi
[ "$l_ctrl" -lt "$l_place" ] && [ "$l_place" -lt "$l_stage" ] \
    && ok "ttywalk places the app after staging (${l_ctrl}) and before the --stage-only exit (${l_stage})" \
    || bad "placement out of order: ctrl=${l_ctrl} place=${l_place} stage_only=${l_stage}"
awk -v p="$l_place" 'NR>=p-12 && NR<=p' "$TW" | /usr/bin/grep -q 'if \[\[ "\$STAGE_KIND" == "artefact" \]\]; then' \
    && ok "placement is for artefact walks only" || bad "placement is not gated on an artefact walk"
awk -v p="$l_place" 'NR>p && NR<=p+8' "$TW" | /usr/bin/grep -q 'NOT PLACED' \
    && ! awk -v p="$l_place" 'NR>p && NR<=p+8' "$TW" | /usr/bin/grep -q 'die ' \
    && ok "a placement failure is announced, not fatal" || bad "placement failure handling wrong"

# 6
if /usr/bin/grep -q '^app_signature_survives_first_run[[:space:]]' "$CO"; then
    bad "app_signature_survives_first_run is still on console_only_probes.tsv"
else
    ok "app_signature_survives_first_run is off the console-only list"
fi

echo "test_ttywalk_places_the_installer_app: ${PASS} ok, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
