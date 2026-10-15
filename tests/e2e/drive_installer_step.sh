#!/usr/bin/env bash
# Runs the REAL assistant-mailbox installer step (the helper block and
# _assistant_mailbox_flow, extracted verbatim from install.sh) non-interactively:
# only gui_read is replaced, by answers from a file, because there is no human.
# The probes (IMAP/SMTP, Keychain) are the real vendor/doctor/agent module.
#
# Env in: E2E_REPO, E2E_ANSWERS (id=value lines), E2E_BASE_CONFIG, E2E_OUT_CONFIG,
#         E2E_OWNER, plus the OSTLER_E2E_* seam variables.
# Writes the config the installer would write ([email_assistant] block appended
# to the base config) and prints ENABLED=/ADDRESS=/HELLO_ID= lines.
set -uo pipefail
REPO="${E2E_REPO:?}"
INSTALL_SH="$REPO/install.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
{
    sed -n '/^# BEGIN assistant-mailbox-helpers/,/^# END assistant-mailbox-helpers/p' "$INSTALL_SH"
    sed -n '/^_assistant_mailbox_flow() {/,/^}/p' "$INSTALL_SH"
} > "$tmp/step.sh"
[ "$(wc -l < "$tmp/step.sh")" -gt 80 ] || { echo "CANNOT-RUN: step not found in install.sh"; exit 2; }

ok() { echo "[ok] $*"; }; warn() { echo "[warn] $*"; }; info() { echo "[info] $*"; }
. "$REPO/install.sh.strings.en-GB.sh"
ASSISTANT_NAME="Tess"; USER_EMAIL="$E2E_OWNER"; CHANNEL_EMAIL_ALLOWED_SENDERS="$E2E_OWNER"; CHANNEL_EMAIL_USERNAME=""
ASSISTANT_MAILBOX_ENABLED=false; ASSISTANT_MAILBOX_ADDRESS=""; ASSISTANT_MAILBOX_PROVIDER=""
ASSISTANT_MAILBOX_SELFTEST=""; ASSISTANT_MAILBOX_HELLO_ID=""
SCRIPT_DIR="$REPO"
gui_read() { # title kind default help choices id [error]
    local a
    a="$(sed -n "s/^$6=//p" "$E2E_ANSWERS" | head -n 1)"
    [[ -z "$a" && "$2" == yesno ]] && a="${3:-N}"
    [[ -z "$a" && "$2" == acknowledge ]] && a="OK"
    printf '%s' "$a"
}
. "$tmp/step.sh"
_assistant_mailbox_flow
echo "ENABLED=$ASSISTANT_MAILBOX_ENABLED"
echo "ADDRESS=$ASSISTANT_MAILBOX_ADDRESS"
echo "SELFTEST=$ASSISTANT_MAILBOX_SELFTEST"
echo "HELLO_ID=$ASSISTANT_MAILBOX_HELLO_ID"
if [[ "$ASSISTANT_MAILBOX_ENABLED" == true ]]; then
    { cat "$E2E_BASE_CONFIG"; _am_emit_config "$ASSISTANT_MAILBOX_ADDRESS" "$ASSISTANT_MAILBOX_PROVIDER" "$ASSISTANT_MAILBOX_HELLO_ID"; } > "$E2E_OUT_CONFIG"
    chmod 600 "$E2E_OUT_CONFIG"
fi
