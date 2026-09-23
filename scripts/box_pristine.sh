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

_rm() {
    [ -e "$1" ] || return 0
    if [ "$DRY" = "1" ]; then echo "  would remove: $1"; return 0; fi
    rm -rf "$1" 2>/dev/null || sudo rm -rf "$1" 2>/dev/null || true
}

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

# 3. Everything under the Ostler dir, INCLUDING the licence and power policy
#    the customer uninstaller correctly preserves.
_rm "$HOME/.ostler"

# 4. The Applications surfaces. THIS IS THE ONE THAT HID THE STEP-33 DEFECT.
_rm "/Applications/Ostler"
_rm "/Applications/Ostler.app"
_rm "/Applications/OstlerInstaller.app"
_rm "/Applications/RemoteCapture.app"
_rm "/Applications/Ostler RemoteCapture.app"
_rm "$HOME/Applications/Ostler.app"

# 5. Customer-visible content and the CLI symlinks.
_rm "$HOME/Documents/Ostler"
for _l in /usr/local/bin/ostler-knowledge /usr/local/bin/pwg-convo /usr/local/bin/ostler; do
    _rm "$_l"
done

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

_assert_absent "$HOME/.ostler"                    "config, licence, sentinels"
_assert_absent "/Applications/Ostler"             "THE step-33 fresh-install defect"
_assert_absent "/Applications/Ostler.app"         "a stale Hub app"
_assert_absent "/Applications/OstlerInstaller.app" "a stale installer read as the one that ran"
_assert_absent "/Applications/RemoteCapture.app"  "a stale capture app passed off as freshly installed"
_assert_absent "$HOME/.colima/_lima/_disks/colima" "16G of store data a walk would call clean"
_assert_absent "$HOME/Documents/Ostler"           "wiki pages from a previous run"

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
if [ -d "$HOME/Library/LaunchAgents" ] && [ -d "/Applications" ]; then
    echo "  CONTROL ok: the directories being checked are readable"
else
    echo "  CONTROL FAILED: cannot read the directories, so every absence above is unmeasured"
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
