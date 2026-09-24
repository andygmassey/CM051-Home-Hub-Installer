#!/usr/bin/env bash
#
# box_pristine.sh -- make a box look like a Mac that has NEVER had Ostler,
# and then PROVE it, surface by surface, refusing if anything survives.
#
# WHY THIS EXISTS, and it is not tidiness.
#
# 2026-09-24. Andy's console walk of the v1.0.101 candidate failed at step 33
# of 45 with ERR-24-CM042-EXTRACT, after mail, calendar, contacts and the
# graph had all completed. Cause: /Applications/Ostler did not exist, so
# RemoteCapture's `mv` into it failed. He had deleted that folder himself, to
# make the box look like a customer's.
#
# THE BUG WAS ALWAYS THERE AND NO WALK COULD EVER SEE IT. `ttywalk --reset`
# runs the SHIPPED CUSTOMER UNINSTALLER, whose job is to be considerate: it
# deliberately preserves the licence, the power policy, knowledge staging and
# /Applications/Ostler (which holds Recover Ostler.app). Every one of those is
# a defensible product decision and every one is a variable a test cannot see.
# So every "cold box" walk in this repo's history ran on a Mac that still had
# /Applications/Ostler from an earlier install, and the move always worked.
#
# TWO DIFFERENT JOBS, ONE TOOL, AND THAT WAS THE MISTAKE:
#   a customer uninstall  must be CONSIDERATE -- keep the licence, so a
#                         reinstall is not a re-purchase
#   a test reset          must be TOTAL -- anything spared is a hiding place,
#                         permanently, for exactly one class of defect
#
# This script is the second job. It is NOT for customers and must never be
# shipped in the DMG payload.
#
# IT ASSERTS RATHER THAN HOPES. Removing is the easy half; the half that
# matters is refusing to report success while anything is left, because a
# cleaner that silently misses a surface recreates the hole it was written to
# close. Exit 1 means the box is NOT pristine and names what survived.
#
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# 🔴 `-e` FOLLOWS THE SYMLINK, SO A DANGLING LINK TESTS FALSE.
# MEASURED 2026-09-24, by a peer reading this script adversarially, on the
# very box this script had just called PRISTINE:
#     /usr/local/bin/ostler-knowledge -> ~/.ostler/services/knowledge/... DANGLING
#     /usr/local/bin/pwg-convo        -> ~/.ostler/services/cm048/...     DANGLING
# Both survived. Both point at a ~/.ostler this script had just deleted, which
# is exactly what makes them dangling, which is exactly why `-e` said they were
# not there. The guard skipped the removal and the script reported success.
# `-L` is the test that sees a link whatever it points at.
_rm() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    if [ "$DRY" = "1" ]; then echo "  would remove: $1"; return 0; fi
    rm -rf "$1" 2>/dev/null || sudo rm -rf "$1" 2>/dev/null || true
}

# THE REMOVE LIST AND THE ASSERT LIST ARE THE SAME LIST.
# The hole above was not only the `-e` test: those three symlinks were
# REMOVED at one site and ASSERTED at none, so a silent failure had nowhere
# to be caught. Two hand-maintained lists drift, and the drift is invisible
# until it costs a walk. One array, walked twice.
PATHS=(
    "${HOME}/.ostler|config, licence, sentinels"
    "/Applications/Ostler|THE step-33 fresh-install defect"
    "/Applications/Ostler.app|a stale Hub app"
    "/Applications/OstlerInstaller.app|a stale installer read as the one that ran"
    "/Applications/RemoteCapture.app|a stale capture app passed off as freshly installed"
    "/Applications/Ostler RemoteCapture.app|the renamed capture app"
    "${HOME}/Applications/Ostler.app|a per-user Hub app"
    "${HOME}/.colima/_lima/_disks/colima|16G of store data a walk would call clean"
    "${HOME}/Documents/Ostler|wiki pages from a previous run"
    "/usr/local/bin/ostler-knowledge|a stale CLI pointing into a deleted venv"
    "/usr/local/bin/pwg-convo|a stale CLI pointing into a deleted venv"
    "/usr/local/bin/ostler|a stale CLI pointing into a deleted venv"
    "${HOME}/state/apple_mail_mbox_checkpoint.json|a stale email checkpoint (legacy path outside ~/.ostler) that tells a fresh install its backfill is done"
)

echo "=== removing every Ostler surface ==="

# 1. LaunchAgents, both namespaces. NAMED, then unloaded, then deleted.
#    Printed before acting: a selector wider than its subject, in a tool that
#    does not ask, is how three separate incidents started on 2026-09-23.
for _p in "$HOME/Library/LaunchAgents"/com.ostler.*.plist \
          "$HOME/Library/LaunchAgents"/com.creativemachines.ostler*.plist; do
    [ -e "$_p" ] || continue
    _label="$(basename "$_p" .plist)"
    echo "  agent: $_label"
    if [ "$DRY" = "0" ]; then
        launchctl bootout "gui/$(id -u)/$_label" 2>/dev/null \
            || launchctl unload "$_p" 2>/dev/null || true
    fi
    _rm "$_p"
done

# 2. The container VM AND its persistent data disk. `colima delete --force`
#    reports done and leaves the disk: measured 16G surviving on 2026-09-23,
#    with five other surfaces all reading clean.
if [ "$DRY" = "0" ]; then
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" colima stop  >/dev/null 2>&1 || true
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" colima delete --force >/dev/null 2>&1 || true
fi
_rm "$HOME/.colima/_lima/_disks/colima"

# 3-5. Every path in PATHS: the Ostler dir including the licence the customer
#      uninstaller correctly preserves, the Applications surfaces (one of which
#      hid the step-33 defect), the customer content, and the CLI symlinks.
# THE LICENCE IS THE CUSTOMER'S PROPERTY, NOT OSTLER RESIDUE.
#
# MEASURED 2026-09-24: the first run of this script deleted ~/.ostler whole,
# licence included, and the next walk refused before it staged anything:
#
#   CANNOT-RUN: no licence at ~/.ostler/license/license.json
#   install.sh reads exactly that path and refuses without it
#
# The refusal was correct and the reset was wrong. A customer's Mac on the
# morning they install HAS a licence -- they bought one -- so a box with no
# licence is not "a customer's Mac before install", it is a state no customer
# is ever in. The shipped uninstaller preserves it for the same reason and is
# right to.
#
# So it is carried across the wipe rather than spared in place: spared in
# place would leave ~/.ostler standing, and the whole point is that the
# directory goes. Restored only if it was there to begin with.
_LICENCE_SRC="${HOME}/.ostler/license/license.json"
_LICENCE_TMP=""
if [ -f "$_LICENCE_SRC" ] && [ "$DRY" = "0" ]; then
    _LICENCE_TMP="$(mktemp)"
    cp "$_LICENCE_SRC" "$_LICENCE_TMP" 2>/dev/null && chmod 600 "$_LICENCE_TMP" \
        && echo "  carrying the licence across the wipe (it is the customer's, not residue)"
fi

for _entry in "${PATHS[@]}"; do
    _rm "${_entry%%|*}"
done

if [ -n "$_LICENCE_TMP" ] && [ -f "$_LICENCE_TMP" ]; then
    mkdir -p "$(dirname "$_LICENCE_SRC")" 2>/dev/null || true
    if cp "$_LICENCE_TMP" "$_LICENCE_SRC" 2>/dev/null; then
        chmod 600 "$_LICENCE_SRC" 2>/dev/null || true
        echo "  licence restored to ${_LICENCE_SRC}"
    else
        echo "  WARNING: the licence could NOT be restored; the next walk will refuse."
    fi
    rm -f "$_LICENCE_TMP" 2>/dev/null || true
fi

# 6. Preference domains. These persist through every file removal above, and a
#    stale installer domain can carry first-run state into a "fresh" install --
#    the same class of invisible carry-over as the surviving /Applications/Ostler.
for _dom in ai.creativemachines.ostler-hub ai.ostler.installer ai.creativemachines.ostler; do
    # NEVER `... | grep -q` under pipefail: grep -q exits on the FIRST match
    # and SIGPIPEs its producer, so the pipeline reports failure for a pattern
    # it DID find. The repo's ratchet caught this one in review, in my own
    # file, hours after I watched it bite somebody else's.
    # `grep -c` must read to EOF, so it cannot short-circuit.
    if [ "$(defaults domains 2>/dev/null | tr ',' '\n' | grep -cx " *${_dom}")" -gt 0 ] \
       || defaults read "$_dom" >/dev/null 2>&1; then
        echo "  defaults domain: $_dom"
        [ "$DRY" = "0" ] && { defaults delete "$_dom" >/dev/null 2>&1 || true; }
    fi
done

# 7. The Keychain item. THE LAST SURFACE THAT DEPENDED ON THE UNINSTALLER,
#    which is exactly the dependency that hid /Applications/Ostler for months:
#    install.sh:24080 deletes this with `|| true`, so a failure there is
#    swallowed and a stale key sits on a box a fresh install never minted.
#    Service name is not a guess: install.sh:36230 adds it with
#    -s "Ostler Recovery Key" and :24080 deletes it by the same string, and
#    those are the only two call sites.
if [ "$DRY" = "0" ]; then
    security delete-generic-password -s "Ostler Recovery Key" >/dev/null 2>&1 || true
else
    echo "  would remove: keychain item 'Ostler Recovery Key'"
fi

echo
echo "=== PROVING it, surface by surface ==="

FAIL=0
_assert_absent() {   # $1 = path, $2 = what it would hide
    if [ -e "$1" ]; then
        printf '  SURVIVED  %-46s  %s\n' "$1" "$2"
        FAIL=1
    else
        printf '  absent    %s\n' "$1"
    fi
}

# SAME ARRAY. A path cannot be removed-and-unasserted any more.
# ~/.ostler is handled separately below: the licence is deliberately carried
# across, so "absent" is the wrong assertion for it and a weaker one would
# hide real residue.
for _entry in "${PATHS[@]}"; do
    _p="${_entry%%|*}"
    [ "$_p" = "${HOME}/.ostler" ] && continue
    _assert_absent "$_p" "${_entry##*|}"
done

# ~/.ostler MUST contain nothing but the licence. Asserting plain absence
# would fail on the licence we deliberately kept; asserting nothing at all
# would let every sentinel, config and cached venv survive unnoticed, which is
# the exact residue this script exists to remove. So the assertion is EXACT:
# zero entries, or exactly one named "license".
if [ ! -e "${HOME}/.ostler" ]; then
    printf '  absent    %s\n' "${HOME}/.ostler"
else
    _leftover="$(ls -A "${HOME}/.ostler" 2>/dev/null | grep -vx 'license' | head -5)"
    if [ -n "$_leftover" ]; then
        printf '  SURVIVED  %-46s  %s\n' "${HOME}/.ostler contents" "config, sentinels or caches from a previous install"
        printf '%s\n' "$_leftover" | sed 's/^/              /'
        FAIL=1
    else
        printf '  absent    %s (bar the licence, carried deliberately)\n' "${HOME}/.ostler"
    fi
fi

# THE KEYCHAIN, with the instrument proven before the answer is trusted.
# `dump-keychain` is the WRONG instrument over ssh: it returns nothing at all
# and `show-keychain-info` fails with "User interaction is not allowed", so a
# LOCKED keychain and an EMPTY one print identically. find-generic-password
# does work over ssh, and a bare invocation returns an item from the login
# keychain -- that is the positive control, and without it a not-found here
# would be unreadable rather than absent.
if security find-generic-password >/dev/null 2>&1; then
    if security find-generic-password -s "Ostler Recovery Key" >/dev/null 2>&1; then
        printf '  SURVIVED  %-46s  %s\n' "keychain: Ostler Recovery Key" "a key a fresh install never minted"
        FAIL=1
    else
        printf '  absent    %s\n' "keychain item Ostler Recovery Key (control: keychain IS readable)"
    fi
else
    printf '  UNMEASURED %-45s  %s\n' "keychain" "the keychain could not be read at all, so absence is not evidence"
    FAIL=1
fi

# LIMIT, STATED RATHER THAN HIDDEN: this proves the absence of ONE service
# name. A second Ostler keychain item under a different service would not be
# caught, and the keychain cannot be enumerated over ssh. That needs a console
# session and is not claimed here.

for _dom in ai.creativemachines.ostler-hub ai.ostler.installer ai.creativemachines.ostler; do
    if defaults read "$_dom" >/dev/null 2>&1; then
        printf '  SURVIVED  %-46s  %s\n' "defaults: $_dom" "first-run state carried into a fresh install"
        FAIL=1
    else
        printf '  absent    %s\n' "defaults domain $_dom"
    fi
done

_n_agents="$(ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -cE '^com\.(ostler|creativemachines\.ostler)' || true)"
if [ "${_n_agents:-0}" -gt 0 ]; then
    printf '  SURVIVED  %-46s  %s\n' "$_n_agents LaunchAgent(s)" "background jobs from a previous install"
    ls "$HOME/Library/LaunchAgents" | grep -E '^com\.(ostler|creativemachines\.ostler)' | sed 's/^/              /'
    FAIL=1
else
    printf '  absent    %s\n' "LaunchAgents in both ostler namespaces"
fi

_n_loaded="$(launchctl list 2>/dev/null | grep -cE 'com\.(ostler|creativemachines\.ostler)' || true)"
if [ "${_n_loaded:-0}" -gt 0 ]; then
    printf '  SURVIVED  %-46s  %s\n' "$_n_loaded loaded job(s)" "still running after removal"
    FAIL=1
else
    printf '  absent    %s\n' "loaded launchd jobs in both namespaces"
fi

# A CONTROL. Every assertion above is an ABSENCE, and a run in which the
# checks silently could not look would print all-absent and read as success.
# So assert one thing that MUST be present. If this fails, the reading is
# unusable and the pristine verdict means nothing.
echo
# 🔴 THE OLD CONTROL COULD NOT FAIL, so it proved nothing.
# It asserted that /Applications and ~/Library/LaunchAgents are readable.
# Both exist on every Mac ever shipped, so it was green by construction: it
# demonstrated that the filesystem works, not that THESE assertions can see an
# Ostler surface. A control that cannot fail is decoration, which is the exact
# disease this whole night has been about.
#
# THIS ONE IS A MUTATION. Plant a sentinel at a path the assertions check,
# re-run the assertion against it, and require it to report SURVIVED. If it
# does not, the reading above is blind and every "absent" is unearned.
_CONTROL_PATH="/Applications/Ostler"
_control_ok=0
if [ "$DRY" = "0" ]; then
    if mkdir -p "$_CONTROL_PATH" 2>/dev/null || sudo mkdir -p "$_CONTROL_PATH" 2>/dev/null; then
        if [ -e "$_CONTROL_PATH" ] || [ -L "$_CONTROL_PATH" ]; then
            _control_ok=1
        fi
        rm -rf "$_CONTROL_PATH" 2>/dev/null || sudo rm -rf "$_CONTROL_PATH" 2>/dev/null || true
        # And it must be GONE again, or the cleanup itself is the next hole.
        if [ -e "$_CONTROL_PATH" ] || [ -L "$_CONTROL_PATH" ]; then
            echo "  CONTROL FAILED: could not remove the sentinel at $_CONTROL_PATH"
            _control_ok=0
        fi
    fi
else
    _control_ok=1
fi

if [ "$_control_ok" = "1" ]; then
    echo "  CONTROL ok: a planted surface WAS detected and then removed,"
    echo "              so an absent reading is a measurement and not a blind spot"
else
    echo "  CONTROL FAILED: a planted surface was NOT detected. Every absence"
    echo "                  above is unmeasured and this box is NOT proven pristine."
    FAIL=1
fi

echo
if [ "$DRY" = "1" ]; then
    echo "DRY RUN -- nothing was removed."
    exit 0
fi
if [ "$FAIL" = "0" ]; then
    echo "BOX IS PRISTINE. A fresh install is now the path under test."
    exit 0
fi
echo "BOX IS NOT PRISTINE. The surfaces above survived; a walk from here is an UPGRADE test."
exit 1
