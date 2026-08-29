#!/usr/bin/env bash
# verify_dmg_delivers_fixes.sh <dmg>
# ============================================================================
# #565 DELIVERY VERIFICATION -- READ THE ARTEFACT, NEVER main.
#
# A cut can merge every fix into main and still SHIP a DMG that carries none:
# the DMG is built from a pinned tree at cut time, and v1.0.50 (built 22:12,
# before #1247 merged at 02:38) is the proof -- it carries none of the three
# fixes that were already green on main. So the only honest question is "is the
# fix in the ARTEFACT", answered by mounting the DMG and reading its install.sh.
#
# WHAT THIS ASSERTS, AND HOW IT AVOIDS LYING:
#   - Mounts read-only at a mountpoint WE control. Never /Volumes/<Name>: a
#     stale image already there makes the new attach "<Name> 1" and you would
#     measure the OLD dmg. The hdiutil rc is READ, not swallowed.
#   - ENUMERATES every install.sh in the DMG and requires the fix in ALL of
#     them. An Ostler DMG carries two (outer installer + nested payload), both
#     run, and a `find | head -1` would sample one and miss a partial delivery.
#   - Greps a behaviour-tied INVARIANT per fix -- the string the fix introduced
#     into the code path -- never a comment, never a commit SHA. Each invariant
#     below was validated BOTH ways: absent in v1.0.50, present in origin/main
#     (@A2 2026-08-29). An absence check that is not paired with a
#     must-be-present control passes when the apparatus dies.
#   - Three outcomes: PASS (0), FAIL (1, a required fix is not delivered),
#     CANNOT-RUN (2, the mount failed or no install.sh was found -- nothing was
#     measured, which is not a pass).
#
# The next cut must carry these three; add a row when the required set changes.
# ============================================================================
set -uo pipefail

DMG="${1:-}"
if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
    echo "usage: $(basename "$0") <path-to-dmg>" >&2
    echo "  no default: a check that guesses the artefact measures the wrong one." >&2
    exit 2
fi

# (fix id, invariant). Behaviour-tied strings, validated absent-in-v1.0.50 /
# present-in-main. NOT a comment, NOT a SHA.
FIX_IDS=(  "#1247-sudo-gate-passwordless"                 "#1249-abort-speaks-on-terminal"   "#563-uninstall-count-nonfatal" )
FIX_INV=(  "sudo already available without a password"    "Install aborted at line"          "COUNTS_INCOMPLETE" )

MP="$(mktemp -d)"
DEV=""
ATTACHED=0
cleanup() {
    # A DETACH WHOSE FAILURE IS INVISIBLE IS NOT A DETACH.
    #
    # THIS LEAKED THE IMAGE AND COST THE v1.0.51 CUT TWO GATES. The old body was
    #     [ -n "$DEV" ] && hdiutil detach "$DEV" >/dev/null 2>&1 || true
    # which discards stdout, stderr AND the return code. If the detach fails --
    # a busy volume moments after traversing it with find is the ordinary case
    # on a CI runner -- the script still exits 0 with the image ATTACHED, and
    # says nothing. The next consumer of the same DMG then dies with
    # "hdiutil: attach failed - Resource busy / This image is ALREADY ATTACHED".
    #
    # THE EVIDENCE IS ORDERING, and it is decisive (@TNM, run 33268357529):
    #     18:37:46.166  this script prints "install.sh copies in the DMG: 2"
    #                   <- which REQUIRES a successful mount, so the image was FREE
    #     18:37:46.239  this script exits 0
    #     18:37:46.587  the next step attaches -> Resource busy
    # The image was free when we took it and busy 0.35s later. The only mount
    # alive in that window was ours, and the only thing that ran in between was
    # this trap.
    #
    # ⚠️ A LOCAL RUN CANNOT EXCLUDE THIS. Running the pre-fix script on a Mac
    # gives rc=0, attached=no -- I did exactly that and wrongly read it as
    # exclusion. It proves the happy path. The failure path was unobservable by
    # construction, because the rc was thrown away. A control that cannot fail
    # for the reason the subject fails is not a control.
    #
    # So: detach by the MOUNTPOINT we created (never a parsed device node, which
    # is a second thing that can silently be empty), READ the return code, and
    # if the image is still attached SAY SO with the consequence named.
    if [ "$ATTACHED" -eq 1 ]; then
        if ! hdiutil detach "$MP" -quiet 2>/dev/null; then
            [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
        fi
        if hdiutil info 2>/dev/null | grep -qF -- "$DMG"; then
            echo "WARNING: ${DMG} is STILL ATTACHED after cleanup." >&2
            echo "         The next step that mounts it will fail with 'Resource busy'." >&2
        fi
    fi
    [ -d "$MP" ] && rmdir "$MP" 2>/dev/null || true
}
trap cleanup EXIT

attach_out="$(hdiutil attach -nobrowse -readonly -mountpoint "$MP" "$DMG" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
    echo "CANNOT-RUN: hdiutil attach failed (rc=${rc}). Nothing measured." >&2
    printf '%s\n' "$attach_out" >&2
    exit 2
fi
ATTACHED=1   # set the INSTANT the attach succeeds. NOT after the parse below:
             # a cleanup gated on a parse does not run when the parse is what broke.
DEV="$(printf '%s\n' "$attach_out" | awk '/GUID_partition_scheme|Apple_HFS|Apple_APFS/{print $1; exit}')"

# Enumerate, bash 3.2-safe (no mapfile on a stock Mac shell).
INSTALLS=()
while IFS= read -r _f; do
    [ -n "$_f" ] && INSTALLS+=("$_f")
done < <(find "$MP" -name 'install.sh' -type f 2>/dev/null)
n_installs="${#INSTALLS[@]}"
echo "install.sh copies in the DMG: ${n_installs}"
if [ "$n_installs" -eq 0 ]; then
    echo "CANNOT-RUN: no install.sh found in the mounted DMG -- wrong artefact or a changed layout." >&2
    exit 2
fi

fail=0
i=0
while [ "$i" -lt "${#FIX_IDS[@]}" ]; do
    id="${FIX_IDS[$i]}"; inv="${FIX_INV[$i]}"
    present_in=0
    for f in "${INSTALLS[@]}"; do
        if [ "$(grep -cF -- "$inv" "$f")" -gt 0 ]; then
            present_in=$((present_in + 1))
        fi
    done
    if [ "$present_in" -eq "$n_installs" ]; then
        printf '  PRESENT   %-32s (in all %d install.sh)\n' "$id" "$n_installs"
    else
        printf '  ABSENT    %-32s (in %d of %d) -- NOT DELIVERED\n' "$id" "$present_in" "$n_installs"
        fail=1
    fi
    i=$((i + 1))
done

if [ "$fail" -eq 0 ]; then
    echo "PASS: every required fix invariant is present in every install.sh the DMG ships."
    exit 0
fi
echo "FAIL: the DMG does not deliver every required fix (see ABSENT above)." >&2
exit 1
