#!/usr/bin/env bash
#
# test_conversation_bundle_user_id_wired.sh
#
# Byte-walking regression test for the conversation-bundle user_id fix
# (recut 2026-06-03). Refuses the exact failure shape that left a fresh
# Studio install with zero conversations: every bundle tick crashed
# because CM048's pwg-convo fails loud at settings construction when
# user_id is unset, and the bundle LaunchAgent plists carried
# OSTLER_USER_DISPLAY_NAME but never OSTLER_USER_ID.
#
# What the failure looked like (PRE-FIX, must never recur):
#   1. a bundle plist has NO EnvironmentVariables.OSTLER_USER_ID key
#   2. install.sh does NOT assign e_user_id from the installer's USER_ID
#   3. install.sh does NOT sed-render OSTLER_USER_ID_VALUE into the plist
# Observed shape: whatsapp tick reported
#   chats_scanned: 604, chats_dispatched: 0, chats_failed: 604
# and Qdrant `conversations` stayed at 0 points.
#
# All three axes must be wired for every conversation feed. The test
# refuses any regression on any one of them, per locked memory
# feedback_silent_bail_regression_test_shape.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

# Axis 1: every conversation-bundle plist must carry an OSTLER_USER_ID
# key AND its render placeholder, alongside the existing display-name.
PLISTS=(
    "vendor/whatsapp_source/launchd/com.creativemachines.ostler.whatsapp-bundle.plist"
    "vendor/imessage_source/launchd/com.creativemachines.ostler.imessage-bundle.plist"
    "vendor/email_source/launchd/com.creativemachines.ostler.email-bundle.plist"
    "vendor/spoken_source/launchd/com.creativemachines.ostler.spoken-bundle.plist"
)
for rel in "${PLISTS[@]}"; do
    p="$REPO_ROOT/$rel"
    if [[ ! -f "$p" ]]; then
        failure "$rel missing — conversation feed cannot be wired"
        continue
    fi
    if ! grep -q '<key>OSTLER_USER_ID</key>' "$p"; then
        failure "$rel has no <key>OSTLER_USER_ID</key> — pwg-convo will fail loud on every tick"
    fi
    if ! grep -q 'OSTLER_USER_ID_VALUE' "$p"; then
        failure "$rel has no OSTLER_USER_ID_VALUE placeholder — installer cannot render the user_id"
    fi
done

# Axis 2: install.sh must derive e_user_id from the installer's USER_ID
# (the prompt-collected, :?-guaranteed operator identifier).
INSTALL_SH="$REPO_ROOT/install.sh"
if [[ ! -f "$INSTALL_SH" ]]; then
    failure "install.sh missing"
elif ! grep -Eq 'e_user_id=.*USER_ID' "$INSTALL_SH"; then
    failure "install.sh does not assign e_user_id from USER_ID — render would emit a blank user_id"
fi

# Axis 3: install.sh must sed-render OSTLER_USER_ID_VALUE into the plist,
# so the placeholder never ships unsubstituted.
if [[ -f "$INSTALL_SH" ]] \
    && ! grep -q 's/OSTLER_USER_ID_VALUE/' "$INSTALL_SH"; then
    failure "install.sh has no OSTLER_USER_ID_VALUE sed substitution — placeholder ships verbatim and pwg-convo still crashes"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_conversation_bundle_user_id_wired: FAILED" >&2
    exit 1
fi
echo "test_conversation_bundle_user_id_wired: all axes wired (4 plists + install.sh assign + render)"
