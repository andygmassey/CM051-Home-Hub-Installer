#!/bin/bash
# The payload app-icon gate (scripts/verify_payload_app_icons.py) FIRES, on
# synthetic bundles, one arm per behaviour, and the two targets that shipped
# with the blank icon in v1.0.117 (118 U4) carry the brand asset catalog.
#
# Hermetic: no network, no real app is launched, assetutil is stubbed on the
# one arm that needs it. Exit 0 all arms as expected, 1 otherwise.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/scripts/verify_payload_app_icons.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0; arms=0

mkapp() { # dir name version [IconFile] [IconName]
    local app="$1/$2.app"
    mkdir -p "$app/Contents/Resources"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
        echo "<key>CFBundleShortVersionString</key><string>$3</string>"
        [ -n "${4:-}" ] && echo "<key>CFBundleIconFile</key><string>$4</string>"
        [ -n "${5:-}" ] && echo "<key>CFBundleIconName</key><string>$5</string>"
        echo '</dict></plist>'
    } > "$app/Contents/Info.plist"
}
icns() { printf 'icns\000\000\000\040padpadpadpadpadpadpadpad' > "$1"; }

expect() { # want_rc label cmd...
    local want="$1" label="$2"; shift 2
    arms=$((arms + 1))
    local out rc=0
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" -eq "$want" ]; then
        echo "ok   [$label] rc=$rc"
    else
        echo "FAIL [$label] want rc=$want got rc=$rc"; echo "$out" | sed 's/^/     /'
        fails=$((fails + 1))
    fi
}

# 1. Positive: an icns that resolves.
mkdir -p "$T/a1"; mkapp "$T/a1" Good 1.0 AppIcon; icns "$T/a1/Good.app/Contents/Resources/AppIcon.icns"
expect 0 "icns resolves -> PASS" python3 "$GATE" "$T/a1"

# 2. The v1.0.117 shape: no icon keys at all.
mkdir -p "$T/a2"; mkapp "$T/a2" Blank 1.0
expect 1 "no icon keys -> FAIL" python3 "$GATE" "$T/a2"

# 3. Key names a file that is not there.
mkdir -p "$T/a3"; mkapp "$T/a3" Dangling 1.0 AppIcon
expect 1 "CFBundleIconFile points at nothing -> FAIL" python3 "$GATE" "$T/a3"

# 4. Key names a file that is empty / not icns.
mkdir -p "$T/a4"; mkapp "$T/a4" Junk 1.0 AppIcon.icns; printf 'PNGPNGPNGPNGPNG' > "$T/a4/Junk.app/Contents/Resources/AppIcon.icns"
expect 1 "non-icns bytes -> FAIL" python3 "$GATE" "$T/a4"

# 5/6. CFBundleIconName through Assets.car, assetutil stubbed.
cat > "$T/assetutil" <<'EOF'
#!/bin/bash
echo "$@" >> "${ASSETUTIL_LOG:-/dev/null}"
cat "$(dirname "$0")/assetutil.json"
EOF
chmod +x "$T/assetutil"
mkdir -p "$T/a5"; mkapp "$T/a5" Car 1.0 "" AppIcon; : > "$T/a5/Car.app/Contents/Resources/Assets.car"
echo '[{"AssetStorageVersion":"x"},{"AssetType":"Icon Image","Name":"AppIcon"}]' > "$T/assetutil.json"
expect 0 "IconName in Assets.car -> PASS" env OSTLER_ASSETUTIL="$T/assetutil" python3 "$GATE" "$T/a5"
echo '[{"AssetStorageVersion":"x"},{"AssetType":"Image","Name":"AppIcon"}]' > "$T/assetutil.json"
expect 1 "IconName not an Icon Image -> FAIL" env OSTLER_ASSETUTIL="$T/assetutil" python3 "$GATE" "$T/a5"

# 7. An app nested in another app's Resources is examined (the 117 shape).
mkdir -p "$T/a7"; mkapp "$T/a7" Outer 1.0 AppIcon; icns "$T/a7/Outer.app/Contents/Resources/AppIcon.icns"
mkapp "$T/a7/Outer.app/Contents/Resources" InnerBlank 1.0
expect 1 "nested blank app -> FAIL" python3 "$GATE" "$T/a7"

# 8. A helper inside a .framework is set aside, not failed.
mkdir -p "$T/a8"; mkapp "$T/a8" Host 1.0 AppIcon; icns "$T/a8/Host.app/Contents/Resources/AppIcon.icns"
mkapp "$T/a8/Host.app/Contents/Frameworks/Vendor.framework" Updater 1.0
expect 0 "framework helper set aside -> PASS" python3 "$GATE" "$T/a8"

# 9. Nothing examined is CANNOT-RUN, never PASS.
mkdir -p "$T/a9"
expect 2 "no apps -> CANNOT-RUN" python3 "$GATE" "$T/a9"

# 10/11/12. Known-red is an equality, not an allow-list.
printf 'Blank\t1.0\tsynthetic declared row\n' > "$T/kr"
expect 0 "declared failure -> PASS" python3 "$GATE" "$T/a2" --known-red "$T/kr"
expect 1 "declared row that now passes -> FAIL (delete it)" python3 "$GATE" "$T/a1" --known-red <(printf 'Good\t1.0\tstale\n')
printf 'Blank\t0.9\tolder pin\n' > "$T/kr2"
expect 1 "row for another version does not cover a re-pin -> FAIL" python3 "$GATE" "$T/a2" --known-red "$T/kr2"

# 13. A tarball subject (the RemoteCapture release shape).
tar -czf "$T/rc.tgz" -C "$T/a2" Blank.app
expect 1 "tarball with blank app -> FAIL" python3 "$GATE" "$T/rc.tgz"

# 14. The fix itself: both targets that shipped blank carry the brand catalog,
# read from the TRACKED pbxproj that xcodebuild builds (project.yml is its
# source; the pbxproj-sync gate keeps the two equal).
arms=$((arms + 1))
PBX="$ROOT/gui/OstlerInstaller.xcodeproj/project.pbxproj"
n="$(python3 - "$PBX" <<'EOF'
import re, sys
s = open(sys.argv[1]).read()
# target name -> its buildPhases ids -> any Resources phase holding Assets.xcassets
hits = 0
for name in ("Ostler Uninstaller", "Recover Ostler"):
    m = re.search(r'/\* %s \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};' % re.escape(name), s, re.S)
    if not m:
        continue
    for pid in re.findall(r'([0-9A-F]{24}) /\* Resources \*/', m.group(1)):
        ph = re.search(pid + r' /\* Resources \*/ = \{(.*?)\};', s, re.S)
        if ph and "Assets.xcassets in Resources" in ph.group(1):
            hits += 1
            break
print(hits)
EOF
)"
if [ "$n" = "2" ]; then echo "ok   [Uninstaller + Recover build the brand Assets.xcassets] 2/2"
else echo "FAIL [Uninstaller + Recover build the brand Assets.xcassets] $n/2"; fails=$((fails + 1)); fi

echo "arms $arms, failed $fails"
[ "$arms" -ge 14 ] || { echo "CANNOT-RUN: expected at least 14 arms, ran $arms"; exit 2; }
[ "$fails" -eq 0 ]
