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
# A REAL DMG CARRIES MORE THAN install.sh, AND THE FIXTURE MUST TOO.
# $4 is the contact_syncer/syncer.py content selector:
#   "with"     the file is present and carries the #1543 guard
#   "without"  the file is present and does NOT carry it  (delivery failure)
#   "absent"   no such file at all                        (CANNOT-RUN)
# Defaults to "with", so the arms written before the payload limb existed keep
# describing a well-formed artefact rather than accidentally testing absence.
build_dmg() {
    local name="$1" outer="$2" payload="$3" syncer="${4:-with}"
    local stage="${TMP}/${name}-stage"
    local outer_dir="${stage}/OstlerInstaller.app/Contents/Resources"
    local pay_dir="${outer_dir}/Ostler.app/Contents/Resources/ostler-payload"
    mkdir -p "$outer_dir" "$pay_dir"
    _write_install "${outer_dir}/install.sh" "$outer"
    _write_install "${pay_dir}/install.sh" "$payload"
    if [ "$syncer" != "absent" ]; then
        mkdir -p "${outer_dir}/contact_syncer"
        printf '# synthetic contact_syncer fixture\n' > "${outer_dir}/contact_syncer/syncer.py"
        if [ "$syncer" = "with" ]; then
            printf 'def _node_holds_a_different_canonical_key(self, u, v):\n    return None\n' \
                >> "${outer_dir}/contact_syncer/syncer.py"
        fi
        # A DECOY the path-suffix match must NOT accept. `-name syncer.py` alone
        # would find this and call the payload delivered.
        mkdir -p "${outer_dir}/meeting_syncer"
        printf '# meeting_syncer, which does NOT carry the dedupe guard\n' \
            > "${outer_dir}/meeting_syncer/syncer.py"
    fi
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

# ── PREFLIGHT: REFUSE ON A DIRTY MOUNT TABLE, DO NOT FLAKE ON IT ────────────
#
# This file mounts a real DMG per arm, and the check under test detaches in a
# trap. When a detach fails -- a volume busy moments after `find` traversed it
# is ordinary -- the image stays attached and the NEXT run of any arm dies with
# "Resource busy". The script's own cleanup comment records that class costing
# the v1.0.51 cut two gates.
#
# MEASURED while adding the payload arms: from a clean mount table this file is
# 9/9. Run back to back without one, it alternates rc=1 and rc=0, and leaves a
# fixture image attached. The arms did not become wrong; the box did.
#
# So: count our OWN fixture images by name and refuse if any is already
# attached. A named refusal beats an intermittent red, and it beats
# auto-detaching -- which would quietly repair the very leak worth seeing.
_stale_fixtures() {
    hdiutil info 2>/dev/null | awk '$1=="image-path"{print $3}' \
        | /usr/bin/grep -cE '/T/tmp\.[A-Za-z0-9]+/(good|missing|partial|empty|pay_[a-z]+)\.dmg' || true
}
_stale="$(_stale_fixtures)"
if [ "${_stale:-0}" -gt 0 ]; then
    cant "${_stale} fixture image(s) from an earlier run are STILL ATTACHED, so an arm would fail with 'Resource busy' for a reason that is nothing to do with the check. Detach them and re-run:
       hdiutil info | awk '\$1==\"image-path\"{img=\$3} \$1 ~ /^\/dev\/disk[0-9]+/{d=\$1; sub(/s[0-9]+\$/,\"\",d); print d, img}' | sort -u
       hdiutil detach <device> -force"
    echo "== 0 pass / 0 fail / 1 cannot-run =="
    exit 2
fi

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
# ── arms 6-8: the payload limb, added with it ──────────────────────────────
# arm 6: the guard is in the payload -> PASS, and the meeting_syncer decoy in
# every fixture proves the suffix match is not satisfied by any syncer.py.
rc="$(run "$(build_dmg pay_ok "$allthree" "$allthree" with)")"
[ "$rc" = "0" ] && ok "arm 6: contact_syncer/syncer.py carrying the #1543 guard -> PASS, and the meeting_syncer decoy did not satisfy it" \
                 || bad "arm 6: a DMG delivering the payload fix returned rc=${rc}"

# arm 7: the file ships but WITHOUT the guard -> FAIL. This is the case the
# whole limb exists for: install.sh is perfect and the vendored package is stale.
rc="$(run "$(build_dmg pay_stale "$allthree" "$allthree" without)")"
[ "$rc" = "1" ] && ok "arm 7: a stale contact_syncer/syncer.py -> FAIL, even with all three install.sh fixes present" \
                 || bad "arm 7: a DMG shipping a stale payload returned rc=${rc}, expected 1"

# arm 8: no contact_syncer at all -> CANNOT-RUN, never a pass. An absent file
# and a present-but-stale one must not report the same.
rc="$(run "$(build_dmg pay_absent "$allthree" "$allthree" absent)")"
[ "$rc" = "2" ] && ok "arm 8: no contact_syncer/syncer.py in the DMG -> CANNOT-RUN (rc 2), not a pass" \
                 || bad "arm 8: a DMG with no payload file returned rc=${rc}, expected 2"

# arm 9: PRECEDENCE. A measured absence outranks an unmeasurable entry -- a DMG
# missing an install.sh fix AND missing the payload file must report the DEFECT,
# not "could not measure".
rc="$(run "$(build_dmg pay_both "${INV_1247}|${INV_1249}" "${INV_1247}|${INV_1249}" absent)")"
[ "$rc" = "1" ] && ok "arm 9: a missing install.sh fix outranks an unmeasurable payload entry -> FAIL, not CANNOT-RUN" \
                 || bad "arm 9: got rc=${rc}, expected 1 -- a refusal is burying a measured defect"

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
