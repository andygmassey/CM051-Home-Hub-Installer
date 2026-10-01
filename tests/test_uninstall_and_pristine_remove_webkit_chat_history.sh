#!/usr/bin/env bash
#
# test_uninstall_and_pristine_remove_webkit_chat_history.sh
#
# #2520: chat history from an earlier install survived a total box_pristine
# reset AND a fresh reinstall. MEASURED 2026-10-01 on the walk box: after
# box_pristine.sh reported PRISTINE and v1.0.106 installed clean, Ostler.app's
# Chat tab showed the previous walk's conversation. It lives in the hub app's
# WebKit localStorage, keyed by bundle id -- a surface neither the test-reset
# tool nor the shipped customer uninstaller had ever named, because it is
# under neither ~/.ostler nor ~/Documents/Ostler.
#
# Five paths were found surviving:
#   ~/Library/WebKit/ai.creativemachines.ostler-hub
#   ~/Library/HTTPStorages/ai.creativemachines.ostler-hub
#   ~/Library/HTTPStorages/ai.ostler.installer
#   ~/Library/Caches/ai.creativemachines.ostler-hub
#   ~/Library/Caches/ai.ostler.installer
#
# This test is TEXT-based (greps the real files), not behavioural: driving the
# real box_pristine.sh or the real generated uninstaller needs launchctl,
# colima, security and an actual WebKit profile, none of which exist in CI.
# It is RED on unmodified code (none of the five paths appear anywhere in
# either file) and GREEN once both name all five.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0
failure() { echo "FAIL: $*" >&2; FAILED=1; }

PATHS_FRAGMENTS=(
    'Library/WebKit/ai.creativemachines.ostler-hub'
    'Library/HTTPStorages/ai.creativemachines.ostler-hub'
    'Library/HTTPStorages/ai.ostler.installer'
    'Library/Caches/ai.creativemachines.ostler-hub'
    'Library/Caches/ai.ostler.installer'
)

echo "-- 1. box_pristine.sh removes AND asserts all five (same list, per its own header) --"
PRISTINE="$REPO_ROOT/scripts/box_pristine.sh"
if [[ ! -f "$PRISTINE" ]]; then
    echo "CANNOT-RUN: $PRISTINE not found"
    exit 2
fi
for frag in "${PATHS_FRAGMENTS[@]}"; do
    n=$(grep -c "$frag" "$PRISTINE" || true)
    # Each path appears exactly once: one PATHS[] array entry that drives
    # both the removal loop and the assertion loop (box_pristine.sh's own
    # documented invariant -- "the remove list and the assert list are the
    # same list"). Zero means never added; more than one means the single-
    # source-of-truth array was bypassed.
    [[ "$n" == "1" ]] || failure "box_pristine.sh does not carry '$frag' exactly once in PATHS[] (count=$n)"
done

echo "-- 2. the generated uninstaller (install.sh's ostler-uninstall heredoc) removes all five --"
INSTALL_SH="$REPO_ROOT/install.sh"
if [[ ! -f "$INSTALL_SH" ]]; then
    echo "CANNOT-RUN: $INSTALL_SH not found"
    exit 2
fi
BODY="$(awk '/<<.UNINSTALLEOF.$/{f=1;next} /^UNINSTALLEOF$/{f=0} f' "$INSTALL_SH")"
if [[ -z "$BODY" ]]; then
    echo "CANNOT-RUN: could not extract the ostler-uninstall heredoc body from install.sh"
    exit 2
fi
# The removal loop names each path in a `for _u_webkit_path in ...` list and
# then acts on the LOOP VARIABLE (`rm -rf "$_u_webkit_path"`), not on a
# literal `rm -rf "${HOME}/<path>"` line per path -- so the proof has two
# parts: each literal path is named in the list exactly once, and the loop
# body really does remove whatever the list hands it.
for frag in "${PATHS_FRAGMENTS[@]}"; do
    n=$(grep -c "\"\${HOME}/${frag}\"" <<<"$BODY" || true)
    [[ "$n" == "1" ]] || failure "generated uninstaller does not name \${HOME}/${frag} exactly once (count=$n)"
done
n=$(grep -c 'rm -rf "\$_u_webkit_path"' <<<"$BODY" || true)
[[ "$n" == "1" ]] || failure "generated uninstaller's WebKit-path loop does not remove its own loop variable (count=$n); the five names above are listed but may not be acted on"

echo "-- 3. the hub app is quit BEFORE its WebKit data is removed (a running webview can write it back) --"
# #2520 review (Archie): the first version of this fix removed the WebKit
# data before quitting Ostler.app, so a still-running webview could recreate
# the very directory this script had just deleted. Line numbers are WITHIN
# the extracted body, so they are comparable to each other.
QUIT_LINE=$(grep -n '_u_quit_bundle_processes "/Applications/Ostler.app"' <<<"$BODY" | head -1 | cut -d: -f1)
if [[ -z "$QUIT_LINE" ]]; then
    failure "generated uninstaller never quits /Applications/Ostler.app at all"
else
    for frag in 'Library/WebKit/ai.creativemachines.ostler-hub' \
                'Library/HTTPStorages/ai.creativemachines.ostler-hub' \
                'Library/Caches/ai.creativemachines.ostler-hub'; do
        RM_LINE=$(grep -n "\"\${HOME}/${frag}\"" <<<"$BODY" | head -1 | cut -d: -f1)
        if [[ -z "$RM_LINE" ]]; then
            failure "cannot find \${HOME}/${frag} in the body to check ordering against the quit"
        elif [[ "$RM_LINE" -lt "$QUIT_LINE" ]]; then
            failure "\${HOME}/${frag} is named for removal at line $RM_LINE, BEFORE the hub app is quit at line $QUIT_LINE; a running webview can write it back"
        fi
    done
fi

# CONTROL: both extractions really found their subject, or every count above
# of 0 is "found nothing to search" rather than "searched and found nothing".
n=$(grep -c '_CONTROL_PATH="/Applications/Ostler"' "$PRISTINE" || true)
[[ "$n" -ge 1 ]] || failure "CONTROL: box_pristine.sh's own planted-surface control line is missing; the file read above is not the real script"
n=$(grep -c 'Done. Ostler has been removed' <<<"$BODY" || true)
[[ "$n" -ge 1 ]] || failure "CONTROL: the extracted uninstaller body does not contain its own closing message; the extraction is not the real heredoc"

if [[ "$FAILED" -ne 0 ]]; then exit 1; fi
echo "PASS: box_pristine.sh and the generated uninstaller both remove all five WebKit/HTTPStorages/Caches chat-history paths, in an order that cannot race the hub app"
