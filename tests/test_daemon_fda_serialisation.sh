#!/usr/bin/env bash
#
# tests/test_daemon_fda_serialisation.sh
#
# Locks the mid-install permission-glut fix (Job 1): the assistant
# daemon's own "read your Messages" TCC prompt must fire ALONE, after a
# one-line pre-warn, and NOT concurrently with the System Settings +
# Finder + osascript Full Disk Access cluster.
#
# Mechanism under test:
#   1. The assistant LaunchAgent is rendered-but-not-bootstrapped by
#      INSTALL_SNIPPET.sh (deferred via OSTLER_ASSISTANT_DEFER_BOOTSTRAP).
#   2. install.sh passes that flag when it invokes the snippet.
#   3. The plist keeps RunAtLoad=true (login persistence unchanged).
#   4. install.sh defines + calls a serialised bootstrap helper before
#      the FDA modal, behind a pre-warn dialog.
#   5. The stray concurrent Finder reveal (open -R before the modal) is
#      gone; the only reveal left is the post-modal still-not-granted
#      drag-add fallback.
#
# These are timing/TCC-sensitive and MUST still be certified on a
# clean-wipe box-walk -- this test only locks the structural invariants.
#
# British English throughout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
SNIPPET="${REPO_ROOT}/assistant-agent/INSTALL_SNIPPET.sh"
PLIST="${REPO_ROOT}/assistant-agent/launchd/com.creativemachines.ostler.assistant.plist"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

# ── 1. Snippet honours the defer flag ──────────────────────────────
if grep -q 'OSTLER_ASSISTANT_DEFER_BOOTSTRAP' "$SNIPPET"; then
    pass "snippet reads OSTLER_ASSISTANT_DEFER_BOOTSTRAP"
else
    fail "snippet does not honour OSTLER_ASSISTANT_DEFER_BOOTSTRAP"
fi

# ── 2. install.sh passes the defer flag to the snippet ─────────────
if grep -q 'OSTLER_ASSISTANT_DEFER_BOOTSTRAP="1"' "$INSTALL_SH"; then
    pass "install.sh defers the snippet bootstrap"
else
    fail "install.sh does not pass OSTLER_ASSISTANT_DEFER_BOOTSTRAP=1"
fi

# ── 3. plist keeps RunAtLoad=true (login persistence) ──────────────
# RunAtLoad must stay true: the serialisation is achieved by deferring
# the install-time bootstrap, NOT by disabling auto-start at login.
if awk '/<key>RunAtLoad<\/key>/{getline; if ($0 ~ /<true\/>/) ok=1} END{exit !ok}' "$PLIST"; then
    pass "plist keeps RunAtLoad=true"
else
    fail "plist RunAtLoad is not true -- login persistence would break"
fi

# ── 4. Serialised bootstrap helper defined + invoked ───────────────
if grep -q '_ostler_bootstrap_assistant_daemon()' "$INSTALL_SH" \
   && grep -q '_ostler_bootstrap_assistant_daemon$' "$INSTALL_SH"; then
    pass "serialised bootstrap helper is defined and called"
else
    fail "serialised bootstrap helper missing or never called"
fi

# ── 5. Pre-warn fires before the FDA assist modal ──────────────────
PREWARN_LINE=$(awk '/MSG_INFO_ASSISTANT_DAEMON_PREWARN/{print NR; exit}' "$INSTALL_SH")
ASSIST_OPEN_LINE=$(awk '/MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING/{print NR; exit}' "$INSTALL_SH")
if [[ -n "$PREWARN_LINE" && -n "$ASSIST_OPEN_LINE" && "$PREWARN_LINE" -lt "$ASSIST_OPEN_LINE" ]]; then
    pass "pre-warn (line $PREWARN_LINE) precedes FDA assist (line $ASSIST_OPEN_LINE)"
else
    fail "pre-warn must precede the FDA assist modal (prewarn=$PREWARN_LINE assist=$ASSIST_OPEN_LINE)"
fi

# Pre-warn strings present in the catalogue.
for key in MSG_INFO_ASSISTANT_DAEMON_PREWARN \
           MSG_PROMPT_ASSISTANT_DAEMON_PREWARN_TITLE \
           MSG_PROMPT_ASSISTANT_DAEMON_PREWARN_LINE1 \
           MSG_PROMPT_ASSISTANT_DAEMON_PREWARN_LINE2 \
           MSG_PROMPT_ASSISTANT_DAEMON_PREWARN_BUTTON; do
    grep -q "^${key}=" "$STRINGS" || fail "catalogue missing $key"
done
[[ "$FAILED" -eq 0 ]] && pass "pre-warn catalogue strings present"

# ── 6. The bootstrap is serialised BEFORE the FDA assist modal ─────
# The helper call must come before the System Settings deep link so the
# daemon's prompt cannot land on top of the modal.
BOOTSTRAP_CALL_LINE=$(awk '/^    _ostler_bootstrap_assistant_daemon$/{print NR; exit}' "$INSTALL_SH")
# install.sh has an earlier installer-FDA pane too; pin to the DAEMON
# pane, i.e. the first Privacy_AllFiles deep link AFTER the bootstrap.
FDA_PANE_LINE=$(awk -v b="$BOOTSTRAP_CALL_LINE" 'NR>b && /x-apple.systempreferences.*Privacy_AllFiles/{print NR; exit}' "$INSTALL_SH")
if [[ -n "$BOOTSTRAP_CALL_LINE" && -n "$FDA_PANE_LINE" && "$BOOTSTRAP_CALL_LINE" -lt "$FDA_PANE_LINE" ]]; then
    pass "daemon bootstrap (line $BOOTSTRAP_CALL_LINE) precedes the daemon FDA pane (line $FDA_PANE_LINE)"
else
    fail "daemon bootstrap must precede the daemon FDA System Settings pane (boot=$BOOTSTRAP_CALL_LINE pane=$FDA_PANE_LINE)"
fi

# ── 7. No concurrent Finder reveal before the modal ────────────────
# The remaining open -R must sit AFTER the display-dialog modal (the
# post-modal drag-add fallback), never before it.
REVEAL_LINE=$(awk '/open -R "\$ASSISTANT_APP_BUNDLE"/{print NR; exit}' "$INSTALL_SH")
MODAL_LINE=$(awk '/display dialog \\"\$\{_imessage_fda_dialog_msg_esc\}/{print NR; exit}' "$INSTALL_SH")
if [[ -z "$REVEAL_LINE" ]]; then
    pass "no open -R \$ASSISTANT_APP_BUNDLE reveal remains (fully removed is acceptable)"
elif [[ -n "$MODAL_LINE" && "$REVEAL_LINE" -gt "$MODAL_LINE" ]]; then
    pass "the only Finder reveal (line $REVEAL_LINE) fires AFTER the modal (line $MODAL_LINE)"
else
    fail "a Finder reveal still fires before/with the modal (reveal=$REVEAL_LINE modal=$MODAL_LINE)"
fi

# ── 8. install.sh + snippet remain bash-syntax-clean ───────────────
bash -n "$INSTALL_SH" || fail "bash -n install.sh failed"
bash -n "$SNIPPET" || fail "bash -n INSTALL_SNIPPET.sh failed"
[[ "$FAILED" -eq 0 ]] && pass "bash -n clean (install.sh + snippet)"

if [[ "$FAILED" -ne 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
