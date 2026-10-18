#!/usr/bin/env bash
# --wipe-stores exists, is opt-in, refuses without --reset, preserves the
# evidence before destroying it, and PROVES the volumes actually went.
#
# WHY THIS EXISTS, AND IT IS THE ANSWER TO "WHY CAN WE NOT GET A CLEAN 24".
# MEASURED on the v1.0.68 artefact walk, archie@.240, 2026-09-05:
#
#     store volumes created        2026-09-05T02:53:08Z
#     v1.0.68 installed at         2026-09-05T07:42:12Z   -- 4.8h LATER
#     oldest node in the graph     2026-09-05T03:10:26Z   -- v1.0.67 data
#
# A plain --reset is not a wipe, and says so. So the v1.0.68 walk graded a
# graph that v1.0.67 had built. Two probes failed on damage predating the
# artefact under test -- no_person_holds_two_contact_cards (54 people with two
# contact cards) and people_stores_reconcile (13 orphan vectors) -- and NO
# CHANGE TO THE ARTEFACT COULD TURN THEM GREEN.
#
# A WALK VERDICT IS A FUNCTION OF THE BUILD *AND* THE BOX STATE, and only the
# build is recorded. This flag lets an operator hold the second variable still.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/scripts/ttywalk.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no ttywalk.sh at ${SUBJECT}" >&2; exit 2; }

# ── It must parse under the shell the cut host actually has ──────────
if /bin/bash -n "$SUBJECT" 2>/dev/null; then
    ok "ttywalk.sh parses under /bin/bash 3.2, the cut host's shell"
else
    bad "ttywalk.sh does not parse under /bin/bash 3.2"
fi

# ── The guard, and WHICH error it reports ────────────────────────────
# A CANNOT-RUN with the wrong REASON sends the next person to the wrong
# problem, so this asserts the message and not merely the exit code.
out="$(/bin/bash "$SUBJECT" --host nobody@192.0.2.1 --expect-name X --wipe-stores 2>&1)"; rc=$?
case "${rc}|${out}" in
    2\|*"requires --reset"*) ok "--wipe-stores without --reset is CANNOT-RUN and SAYS SO" ;;
    2\|*"cannot reach"*)     bad "it exits 2 for the wrong reason -- it reached the ssh probe first. The guard is too late to be useful." ;;
    2\|*)                    bad "exits 2 but the message names neither cause: ${out%%$'\n'*}" ;;
    *)                       bad "expected CANNOT-RUN (2), got rc=${rc}" ;;
esac

# The guard must not fire when --reset IS given, or it would ban the mode it
# exists to gate. 192.0.2.1 is TEST-NET-1 and is unroutable by design.
out="$(/bin/bash "$SUBJECT" --host nobody@192.0.2.1 --expect-name X --reset --wipe-stores 2>&1)"
case "$out" in
    *"requires --reset"*) bad "the guard fires even WITH --reset, so the mode is unreachable" ;;
    *)                    ok "CONTROL: with --reset the guard does not fire, so the mode is reachable" ;;
esac

# A missing --host must still report the HOST error. Guard ordering is the
# property here: a new check must not shadow an older, more basic one.
out="$(/bin/bash "$SUBJECT" --wipe-stores --reset 2>&1)"
case "$out" in
    *"--host is required"*) ok "CONTROL: a missing --host still reports the HOST error, not the wipe one" ;;
    *)                      bad "a missing --host reported something else: ${out%%$'\n'*}" ;;
esac

# ── The destructive path must carry its safety properties ────────────
# Read the wipe block only, so a match elsewhere in a 900-line file cannot
# stand in for the thing being asserted.
BLOCK="$(awk '/WIPE STORES \(destructive/,/refusing to walk against a half-wiped box/' "$SUBJECT")"
if [ -z "$BLOCK" ]; then
    echo "CANNOT-RUN: could not isolate the wipe block; the anchors moved." >&2
    exit 2
fi

case "$BLOCK" in
    *"ostler-prewipe-"*) ok "the graph is DUMPED before the wipe, so a wipe cannot destroy the only copy" ;;
    *) bad "no pre-wipe dump in the block. A wipe that loses the evidence is a deletion, not a reset." ;;
esac

case "$BLOCK" in
    *"CANNOT-WIPE: the graph did not dump"*) ok "a FAILED dump aborts the wipe instead of continuing" ;;
    *) bad "a failed dump does not abort. Best-effort evidence preservation is not preservation." ;;
esac

# ── THE DUMP MUST COVER THE WHOLE STORE ──────────────────────────────
#
# Measured 2026-09-16 on the founder box at v1.0.98: the dump asked for
# /store?default, which is the default graph ONLY, and Oxigraph here runs
# without --union-default-graph (compartment.py REQUIRES it stay off). So it
# captured 155,048 of 231,105 quads and silently dropped 76,057 -- the two
# named graphs whole, including EVERY CM048 triple. The dump still exited 0,
# printed no error, and wrote 22.7 MB, so nothing downstream could tell.
#
# 🔴 THIS READS CODE LINES ONLY, NEVER PROSE, and that is not fastidiousness.
# The block DESCRIBES the old default-graph URL in its own comments, on
# purpose, so the next reader learns what went wrong. A grep over the whole
# block therefore matches the explanation and reports the defect as live
# forever -- the same trap this file records at its #1560 note, where a
# comment reproducing the wrong form satisfied the very grep meant to find
# remaining uses of it. The instrument and the defect must share a surface,
# and the surface here is the argument curl actually receives.
DUMP_CODE="$(printf '%s\n' "$BLOCK" | grep -v '^[[:space:]]*#' | grep '7878/store' || true)"
if [ -z "$DUMP_CODE" ]; then
    bad "no Oxigraph store URL on any CODE line in the wipe block"
else
    case "$DUMP_CODE" in
        *"/store?"*)
            bad "the dump still passes a query string to /store. Bare /store is the whole store; /store?default is the DEFAULT GRAPH ONLY, and without --union-default-graph that silently omits every named graph (76,057 of 231,105 quads on the founder box) while exiting 0." ;;
        *)
            ok "the dump asks for the WHOLE store, not just the default graph" ;;
    esac
    # POSITIVE CONTROL for the predicate above. If the extraction came back
    # with some other line, the clean verdict means nothing. The dump URL is
    # the one whose output is redirected into the dump file -- asserted on the
    # SAME line, because curl is split across several and a whole-block match
    # is what got us here. (The guard's own count query hits /query, not
    # /store, so it cannot be what was extracted.)
    case "$DUMP_CODE" in
        *'> "$_dump"'*) ok "CONTROL: the extracted line really is the one writing the dump file" ;;
        *) bad "CONTROL FAILED: the line extracted as the dump does not redirect into \$_dump, so the verdict above was read off the wrong line" ;;
    esac
fi

# The guard that would have caught the above. A backup trusted on its exit
# code and its byte count cannot tell two thirds from the whole.
case "$BLOCK" in
    *"CANNOT-WIPE: the dump is materially short of the store"*)
        ok "the dump REFUSES when its quad count is materially below the store total" ;;
    *)
        bad "nothing compares the dump against the store total. A backup that captures part of the store and says nothing is worse than none, because the wipe that follows trusts it." ;;
esac

# CANNOT-RUN IS NOT A PASS. If the store total cannot be read, the guard has
# not cleared the dump, it has failed to look at it.
case "$BLOCK" in
    *"could not read the store quad total"*)
        ok "an unreadable store total is CANNOT-WIPE, not a silent pass" ;;
    *)
        bad "a store total that does not come back as a number is waved through, so the guard passes precisely when it could not measure." ;;
esac

# The count query must span BOTH compartments. One bare pattern counts the
# default graph only, which would make the guard agree with the very defect
# it exists to catch.
case "$BLOCK" in
    *"UNION"*"GRAPH"*)
        ok "the store total counts the default graph AND the named graphs" ;;
    *)
        bad "the store-total query does not UNION the named graphs, so it would report the same short number as a default-only dump and the guard would always agree with itself." ;;
esac

case "$BLOCK" in
    *"WIPE INCOMPLETE"*) ok "surviving ostler_ volumes are CANNOT-RUN, not a quiet partial reset" ;;
    *) bad "nothing checks that the volumes actually went. An uninstaller that exits 0 having removed nothing is the silent no-op this exists to refuse." ;;
esac

case "$BLOCK" in
    *"AFTER, the volumes that remain"*) ok "the block MEASURES the result rather than asserting it" ;;
    *) bad "the block does not re-read the volume list after wiping" ;;
esac

# ── It must stay OPT-IN ──────────────────────────────────────────────
# The default reset must keep working on a box whose accumulated data is the
# subject of an investigation. If WIPE_STORES ever defaults to 1, a routine
# --reset silently becomes destructive.
if grep -qE '^WIPE_STORES=0$' "$SUBJECT"; then
    ok "WIPE_STORES defaults to 0, so a plain --reset is still not a wipe"
else
    bad "WIPE_STORES does not default to 0. A routine reset would become destructive."
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
