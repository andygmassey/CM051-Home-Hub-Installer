#!/usr/bin/env bash
# scripts/lib_walk_place_installer_app.sh
#
# PUT THE INSTALLER APP WHERE A CUSTOMER PUTS IT, FROM THE DMG ON THE BOX.
#
# app_signature_survives_first_run asks whether /Applications/OstlerInstaller.app
# still verifies after its own bundled interpreter has run (the v1.0.45
# "damaged and can't be opened" brick). An ssh artefact walk runs install.sh
# from the DMG's Contents/Resources and never drags the app anywhere, so the
# probe was CANNOT-RUN on every thin walk and sat on console_only_probes.tsv
# as a "gui" item. MEASURED 2026-11-04 (v1.0.123, Mini16): with the app placed
# from the verified on-box DMG over ssh, the probe ran and PASSED (2233 .pyc
# unchecked-hash, 0 files changed). It never needed the console. Archie, same
# day: the harness places it, and the row comes off the console list.
#
# A STALE APP IS WORSE THAN NO APP. /Applications held a 1.0.63 app during the
# v1.0.66 walk (ttywalk.sh, ARTEFACT_VERSION comment). So the existing app is
# removed FIRST and verified gone, and nothing is placed unless the DMG on the
# box hashes to the DMG this walk mounted. Any failure leaves NO app, so the
# probe reads CANNOT-RUN about the right thing rather than PASS about the
# wrong build.
#
# walk_place_installer_app_script
#   Prints the POSIX sh program that runs ON THE BOX. Inputs come from its
#   environment: WPA_DMG (path on the box), WPA_SHA (sha256 it must have),
#   WPA_APPS (default /Applications; a test points it elsewhere).
#   Exit 0 placed and verified; 3 DMG hash mismatch or missing; 4 could not
#   remove the old app; 5 mount failed; 6 no installer app in the DMG;
#   7 copy failed; 8 the placed copy does not verify (and is removed).

walk_place_installer_app_script() {
    cat <<'BOX'
set -u
APPS="${WPA_APPS:-/Applications}"
DST="${APPS}/OstlerInstaller.app"
if [ -e "$DST" ]; then
    if old="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DST/Contents/Info.plist" 2>/dev/null)"; then :; else old="unreadable"; fi
    rm -rf "$DST"
    [ ! -e "$DST" ] || { echo "place: could not remove the existing app (version ${old}); not placing"; exit 4; }
    echo "place: removed the existing app first (it said version ${old})"
fi
[ -f "$WPA_DMG" ] || { echo "place: no DMG at ${WPA_DMG}"; exit 3; }
got="$(shasum -a 256 "$WPA_DMG" | awk '{print $1}')"
[ "$got" = "$WPA_SHA" ] || { echo "place: DMG on the box hashes ${got}, this walk mounted ${WPA_SHA}; not placing"; exit 3; }
echo "place: DMG on the box verified sha256 ${got}"
mnt="$(mktemp -d "${TMPDIR:-/tmp}/wpa-mnt.XXXXXX")"
err="$(hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$WPA_DMG" 2>&1 >/dev/null)" \
    || { rmdir "$mnt" 2>/dev/null; echo "place: hdiutil attach failed: ${err}"; exit 5; }
src=""
for a in "$mnt"/*.app; do
    [ -f "$a/Contents/Resources/install.sh" ] && { src="$a"; break; }
done
if [ -z "$src" ]; then
    hdiutil detach "$mnt" >/dev/null 2>&1; rmdir "$mnt" 2>/dev/null
    echo "place: no .app with Contents/Resources/install.sh in the DMG"; exit 6
fi
if ! ditto "$src" "$DST"; then
    rm -rf "$DST"; hdiutil detach "$mnt" >/dev/null 2>&1; rmdir "$mnt" 2>/dev/null
    echo "place: ditto failed"; exit 7
fi
hdiutil detach "$mnt" >/dev/null 2>&1; rmdir "$mnt" 2>/dev/null
if ! cs="$(codesign --verify --deep --strict "$DST" 2>&1)"; then
    rm -rf "$DST"
    echo "place: the placed copy does not verify, removed it: ${cs}"; exit 8
fi
if ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DST/Contents/Info.plist" 2>/dev/null)"; then :; else ver="unreadable"; fi
echo "place: ${DST} placed from the DMG, version ${ver}, codesign --verify --deep --strict rc 0"
exit 0
BOX
}
