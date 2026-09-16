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

# The PAYLOAD invariants -- everything the check looks for OUTSIDE install.sh.
# A fixture that carries fewer than the check declares is not a "good DMG",
# and arm 0b refuses rather than letting the green arms fail misleadingly.
INV_1543='_node_holds_a_different_canonical_key'
INV_755='_source_is_the_users_own'
INV_142='is_kinship_given_name'
# CM041 #145. Deliberately asserted on the CALL SITES, not on the
# definition: resolver.py and batch_resolver.py are divergent twins that
# keep their own `given = next(...)`, so re-vendoring canonical_name.py
# alone would add a function nobody calls and a definition-row would go
# green over it.
INV_145='prefer_real_given_name'
# The two dedupe_merge rows (2026-09-07): the stats key the RULE 2 veto returns,
# and the f-string of the mergedInto tombstone update. Both live only on the
# vendored copy, which is exactly why the DMG must be read for them.
INV_1573_VETO='refused_rule2'
INV_1573_TOMB='mergedInto> <{canonical}>'

# arm 0: the check still declares exactly these three invariants (a fixture that
# drifts from the check would make every other arm meaningless).
for _inv in "$INV_1247" "$INV_1249" "$INV_563"; do
    if [ "$(grep -cF -- "$_inv" "$CHECK")" -eq 0 ]; then
        cant "arm 0: the check no longer declares invariant [${_inv}]; fixtures are stale, refusing to guess"
        echo "== ${PASS}/${FAIL}/$((CANT+1)) =="; exit 2
    fi
done
ok "arm 0: the three fixture invariants match the check's declared set"

# arm 0b: THE PAYLOAD SET, ASSERTED IN BOTH DIRECTIONS.
#
# WHY, MEASURED 2026-09-06: two PAYLOAD rows were added to the check and this
# fixture was not updated with them, so the "good DMG" fixture was no longer a
# well-formed artefact. Arms 1 and 6 then failed with "a good DMG did not
# pass" -- which reads as the CHECK being broken when the FIXTURE was stale.
#
# One direction is not enough. Asserting only "every fixture invariant is in
# the check" catches a row being DELETED and is blind to one being ADDED,
# which is the direction that actually happened. So both, and a mismatch is
# CANNOT-RUN rather than a fail: the arms below cannot mean anything until the
# fixture describes a complete artefact again.
PAYLOAD_INV_FIXTURE=( "$INV_1543" "$INV_755" "$INV_142" "$INV_145" "$INV_1573_VETO" "$INV_1573_TOMB" )
# The payload FILES this fixture writes into every "good DMG". Kept beside
# the invariants so the two cannot drift apart unnoticed.
PAYLOAD_PATH_FIXTURE=( "contact_syncer/syncer.py"
                       "identity_resolver/canonical_name.py"
                       "identity_resolver/resolver.py"
                       "identity_resolver/batch_resolver.py"
                       "ostler_fda/dedupe_merge.py" )
# `sort -u`, not `sort`. TWO PAYLOAD ROWS MAY SHARE ONE INVARIANT: #145 names
# `prefer_real_given_name` in BOTH resolver.py and batch_resolver.py, because
# the fix must fire on two divergent twins. The invariant is a string to grep
# for, so a duplicate carries no extra information and comparing multisets
# would fail on a correctly-specified check.
_declared="$(sed -n '/^PAYLOAD_INV=(/,/)/p' "$CHECK" | grep -oE '"[^"]+"' | tr -d '"' | sort -u)"
_fixture="$(printf '%s\n' "${PAYLOAD_INV_FIXTURE[@]}" | sort -u)"
if [ "$_declared" != "$_fixture" ]; then
    cant "arm 0b: the check's PAYLOAD_INV set and this fixture's set differ, so a 'good DMG' arm would fail for a stale fixture rather than a broken check.
    check declares : $(printf '%s' "$_declared" | tr '\n' ' ')
    fixture builds : $(printf '%s' "$_fixture" | tr '\n' ' ')"
    echo "== ${PASS}/${FAIL}/$((CANT+1)) =="; exit 2
fi
ok "arm 0b: the check's PAYLOAD_INV set and the fixture's set are identical, both ways"

# arm 0c: THE PATH SET, FOR THE SAME REASON ONE LEVEL ALONG.
#
# Matching invariants is not enough. A new PAYLOAD row can name a FILE the
# fixture never creates, and then the "good DMG" is missing a payload file and
# the check correctly returns CANNOT-RUN -- which reads as the check being
# broken. That is exactly what #145 would have done: its two rows share an
# invariant already in the set, so arm 0b alone would have gone green while
# resolver.py and batch_resolver.py were absent from every fixture.
_declared_paths="$(sed -n '/^PAYLOAD_PATH=(/,/)/p' "$CHECK" | grep -oE '"[^"]+"' | tr -d '"' | sort -u)"
_fixture_paths="$(printf '%s\n' "${PAYLOAD_PATH_FIXTURE[@]}" | sort -u)"
if [ "$_declared_paths" != "$_fixture_paths" ]; then
    cant "arm 0c: the check's PAYLOAD_PATH set and the files this fixture builds differ.
    check declares : $(printf '%s' "$_declared_paths" | tr '\n' ' ')
    fixture builds : $(printf '%s' "$_fixture_paths" | tr '\n' ' ')"
    echo "== ${PASS}/${FAIL}/$((CANT+1)) =="; exit 2
fi
ok "arm 0c: every PAYLOAD_PATH the check declares is a file this fixture creates"

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
    local name="$1" outer="$2" payload="$3" syncer="${4:-with}" dedupe="${5:-with}"
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
            printf 'def %s(self, u, v):\n    return None\n' "$INV_1543" \
                >> "${outer_dir}/contact_syncer/syncer.py"
            printf 'def %s(self, source_uuid):\n    return True\n' "$INV_755" \
                >> "${outer_dir}/contact_syncer/syncer.py"
        fi
        # identity_resolver/canonical_name.py is a SEPARATE payload row, so it
        # is present and complete in BOTH the "with" and "without" cases. Only
        # the syncer goes stale under "without", which is what makes arm 7 a
        # FAIL (one payload row unmet) rather than a CANNOT-RUN (a payload file
        # missing entirely). Those two must never print the same.
        mkdir -p "${outer_dir}/identity_resolver"
        printf '# synthetic canonical_name fixture\ndef %s(v):\n    return False\n' "$INV_142" \
            > "${outer_dir}/identity_resolver/canonical_name.py"
        # #145's two rows name the CALLERS. Both files must carry the call or
        # the fix cannot fire, which is the exact way the artefact was wrong
        # while the #142 row stayed green.
        printf '# synthetic resolver fixture\ngiven = %s(x)\n' "$INV_145" \
            > "${outer_dir}/identity_resolver/resolver.py"
        printf '# synthetic batch_resolver fixture\ngiven = %s(x)\n' "$INV_145" \
            > "${outer_dir}/identity_resolver/batch_resolver.py"
        # A DECOY the path-suffix match must NOT accept. `-name syncer.py` alone
        # would find this and call the payload delivered.
        # ostler_fda/dedupe_merge.py: fresh carries the veto's stats key and the
        # tombstone f-string; stale is the pre-graft module, which has neither.
        mkdir -p "${outer_dir}/ostler_fda"
        printf '# synthetic dedupe_merge fixture\n' > "${outer_dir}/ostler_fda/dedupe_merge.py"
        if [ "$dedupe" = "with" ]; then
            printf 'stats = {"%s": 0}\n' "$INV_1573_VETO" >> "${outer_dir}/ostler_fda/dedupe_merge.py"
            printf 'q = f"INSERT DATA {{ <{dupe}> <{PWG}%s }}"\n' "$INV_1573_TOMB" >> "${outer_dir}/ostler_fda/dedupe_merge.py"
        fi
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
rc="$(run "$(build_dmg pay_dedupestale "$allthree" "$allthree" with without)")"
if [ "$rc" = "1" ]; then
    ok "arm 7b: a stale ostler_fda/dedupe_merge.py beside a fresh contact_syncer -> FAIL; the dedupe rows are load-bearing on their own"
else
    bad "arm 7b: a DMG shipping the pre-graft dedupe_merge.py returned rc=${rc}, expected 1 -- the veto and tombstone could ship dark"
fi
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
