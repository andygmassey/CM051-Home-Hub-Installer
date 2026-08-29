#!/usr/bin/env bash
# CM051 #565 -- the delivery gate must fail on a DMG that lacks a required fix,
# pass on one that carries them all, and catch a PARTIAL delivery (a fix in one
# install.sh copy but not the other). It builds fixture DMGs so the green arm is
# a real must-be-present control, not just the absence of a red.
#
# macOS-only: it uses hdiutil to build and mount real (tiny) DMGs.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
CHECK="${REPO}/scripts/verify_dmg_delivers_fixes.sh"

PASS=0; FAIL=0; CANT=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; CANT=$((CANT+1)); }

[ -x "$CHECK" ] || { cant "check not executable at ${CHECK}"; echo "== 0/0/1 =="; exit 2; }
command -v hdiutil >/dev/null 2>&1 || { cant "hdiutil unavailable (not macOS) -- the check reads a real DMG, so this test cannot run here"; echo "== 0/0/1 =="; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The three invariants the check asserts. Kept in sync with the check by arm 0.
INV_1247='sudo already available without a password'
INV_1249='Install aborted at line'
INV_563='COUNTS_INCOMPLETE'

# arm 0: the check still declares exactly these three invariants (a fixture that
# drifts from the check would make every other arm meaningless).
for _inv in "$INV_1247" "$INV_1249" "$INV_563"; do
    if [ "$(grep -cF -- "$_inv" "$CHECK")" -eq 0 ]; then
        cant "arm 0: the check no longer declares invariant [${_inv}]; fixtures are stale, refusing to guess"
        echo "== ${PASS}/${FAIL}/$((CANT+1)) =="; exit 2
    fi
done
ok "arm 0: the three fixture invariants match the check's declared set"

# build_dmg <name> <inv-in-outer...pipe-separated> <inv-in-payload...>
# writes an install.sh carrying the named invariants into each of the DMG's two
# install.sh locations, then makes a real UDZO dmg.
build_dmg() {
    local name="$1" outer="$2" payload="$3"
    local stage="${TMP}/${name}-stage"
    local outer_dir="${stage}/OstlerInstaller.app/Contents/Resources"
    local pay_dir="${outer_dir}/Ostler.app/Contents/Resources/ostler-payload"
    mkdir -p "$outer_dir" "$pay_dir"
    _write_install "${outer_dir}/install.sh" "$outer"
    _write_install "${pay_dir}/install.sh" "$payload"
    hdiutil create -quiet -srcfolder "$stage" -volname "$name" -ov -format UDZO "${TMP}/${name}.dmg" >/dev/null 2>&1
    printf '%s' "${TMP}/${name}.dmg"
}
_write_install() {
    local f="$1" invs="$2" IFS='|' i
    printf '#!/usr/bin/env bash\n# synthetic install.sh fixture\n' > "$f"
    for i in $invs; do
        [ -n "$i" ] && printf 'echo "%s"\n' "$i" >> "$f"
    done
}

run() { /bin/bash "$CHECK" "$1" >/dev/null 2>&1; echo $?; }

# arm 1: GREEN -- both copies carry all three -> PASS (rc 0)
allthree="${INV_1247}|${INV_1249}|${INV_563}"
good="$(build_dmg good "$allthree" "$allthree")"
rc="$(run "$good")"
[ "$rc" = "0" ] && ok "arm 1: a DMG carrying all three fixes in both install.sh -> PASS" \
                 || bad "arm 1: a good DMG did not pass (rc=${rc}) -- the gate cannot recognise a delivered fix"

# arm 2: RED -- one fix missing entirely -> FAIL (rc 1)
missing="$(build_dmg missing "${INV_1247}|${INV_1249}" "${INV_1247}|${INV_1249}")"
rc="$(run "$missing")"
[ "$rc" = "1" ] && ok "arm 2: a DMG missing #563 -> FAIL" \
                 || bad "arm 2: a DMG missing a fix did not fail (rc=${rc})"

# arm 3: PARTIAL -- present in the outer copy, absent in the payload -> FAIL
partial="$(build_dmg partial "$allthree" "${INV_1247}|${INV_1249}")"
rc="$(run "$partial")"
[ "$rc" = "1" ] && ok "arm 3: a fix in 1 of 2 install.sh (partial delivery) -> FAIL (both copies run)" \
                 || bad "arm 3: a partial delivery passed (rc=${rc}) -- a fix in one copy is not delivered"

# arm 4: CANNOT-RUN -- a DMG with no install.sh -> rc 2, never a pass
empty_stage="${TMP}/empty-stage"; mkdir -p "${empty_stage}/x"; printf 'hi\n' > "${empty_stage}/x/readme.txt"
hdiutil create -quiet -srcfolder "$empty_stage" -volname empty -ov -format UDZO "${TMP}/empty.dmg" >/dev/null 2>&1
rc="$(run "${TMP}/empty.dmg")"
[ "$rc" = "2" ] && ok "arm 4: a DMG with no install.sh -> CANNOT-RUN (rc 2), not a false pass" \
                 || bad "arm 4: a DMG with no install.sh returned rc=${rc}, expected 2"

# arm 5: the real RED baseline, if the artefact is on this box
V50=/tmp/ostler-installer-dist-andy/OstlerInstaller-1.0.50.dmg
if [ -f "$V50" ]; then
    rc="$(run "$V50")"
    [ "$rc" = "1" ] && ok "arm 5: the real v1.0.50 artefact (carries none) -> FAIL" \
                     || bad "arm 5: v1.0.50 did not fail (rc=${rc}) -- it demonstrably carries none of the three"
else
    printf '  [SKIP] arm 5: v1.0.50 artefact not on this box (%s)\n' "$V50"
fi

echo "== ${PASS} pass / ${FAIL} fail / ${CANT} cannot-run =="
[ "${FAIL}" -gt 0 ] && exit 1
[ "${CANT}" -gt 0 ] && exit 2
exit 0
