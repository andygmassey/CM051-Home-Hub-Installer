#!/usr/bin/env bash
#
# tests/test_email_folder_prompt.sh
#
# Locks the email folder/label prompt and the INBOX safety warning
# in install.sh.
#
# Why this test exists:
#
#   Before this PR, install.sh hard-coded `imap_folder = "INBOX"`
#   in [channels.email]. That meant the assistant would read
#   every email the customer received -- not just messages
#   addressed to the assistant. The product rule (email_safety)
#   is: dedicated label/folder, never the main inbox. Andy's own
#   instance uses a "Marvin" Gmail label.
#
#   This test pins the safe-by-default path:
#     1. The user is prompted for a folder/label.
#     2. Default is "Ostler" if nothing supplied.
#     3. If the user supplies INBOX (any case), a warning fires
#        and the user must type INBOX a second time, exactly,
#        to confirm.
#     4. The TOML emitter writes the chosen value, not a hard-
#        coded "INBOX".
#
# Sister tests:
#   - test_consent_a7_a8.sh -- A7+A8 consent ceremony
#   - test_whatsapp_channel_block.sh -- WhatsApp channel wiring

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── Variable initialised at the top of the channel block ────────
if ! grep -qE '^CHANNEL_EMAIL_IMAP_FOLDER=""$' "$INSTALL_SCRIPT"; then
    echo "FAIL [var-init]: CHANNEL_EMAIL_IMAP_FOLDER is not initialised at the top of the channel block" >&2
    exit 1
fi
echo "PASS: CHANNEL_EMAIL_IMAP_FOLDER is initialised"

# ── Prompt is shown to the user ─────────────────────────────────
if ! grep -q 'Folder/label \[Ostler\]:' "$INSTALL_SCRIPT"; then
    echo "FAIL [prompt-missing]: 'Folder/label [Ostler]:' prompt not found" >&2
    exit 1
fi
echo "PASS: install.sh prompts 'Folder/label [Ostler]:'"

# ── Default is Ostler when input is blank ───────────────────────
# Look for the parameter-default expansion that turns blank input
# into "Ostler". A future edit that drops the default would cause
# the assistant to point at an empty string.
if ! grep -qE 'CHANNEL_EMAIL_IMAP_FOLDER="\$\{CHANNEL_EMAIL_IMAP_FOLDER:-Ostler\}"' "$INSTALL_SCRIPT"; then
    echo "FAIL [default-missing]: blank input does not default to 'Ostler'" >&2
    exit 1
fi
echo "PASS: blank input defaults to 'Ostler'"

# ── INBOX warning path exists ───────────────────────────────────
if ! grep -q 'INBOX means the assistant will read every email you receive' "$INSTALL_SCRIPT"; then
    echo "FAIL [warn-text-missing]: INBOX safety warning text not found" >&2
    exit 1
fi
echo "PASS: INBOX safety warning text present"

if ! grep -q 'Type INBOX again to confirm' "$INSTALL_SCRIPT"; then
    echo "FAIL [reconfirm-prompt]: 'Type INBOX again to confirm' prompt not found" >&2
    exit 1
fi
echo "PASS: re-confirmation prompt present"

# ── INBOX detection is case-insensitive ─────────────────────────
# The user typing "inbox" or "Inbox" must trigger the same warning
# path as "INBOX". A regex-only match on "INBOX" would silently
# let "inbox" through.
if ! grep -q 'tr .\[:upper:\]. .\[:lower:\].' "$INSTALL_SCRIPT"; then
    echo "FAIL [case-insensitive]: INBOX detection does not appear to be case-insensitive (no tr lowercase)" >&2
    exit 1
fi
echo "PASS: INBOX detection is case-insensitive"

# ── TOML emitter uses the variable, not hard-coded INBOX ────────
if grep -q 'imap_folder = \\"INBOX\\"' "$INSTALL_SCRIPT"; then
    echo "FAIL [emitter-hardcoded]: imap_folder is still hard-coded to INBOX in the TOML emitter" >&2
    exit 1
fi
echo "PASS: TOML emitter does not hard-code imap_folder = INBOX"

if ! grep -q 'imap_folder = .*CHANNEL_EMAIL_IMAP_FOLDER' "$INSTALL_SCRIPT"; then
    echo "FAIL [emitter-variable]: TOML emitter does not reference CHANNEL_EMAIL_IMAP_FOLDER" >&2
    exit 1
fi
echo "PASS: TOML emitter references CHANNEL_EMAIL_IMAP_FOLDER"

# ── End-to-end: emitter outputs the chosen folder ───────────────
EMITTER="$(mktemp)"
trap 'rm -f "$EMITTER"' EXIT

awk '
    /^TOMLPREAMBLE$/                         { capture = 1; next }
    capture && /^\} > "\$ASSISTANT_CONFIG"$/ { capture = 0 }
    capture                                  { print }
' "$INSTALL_SCRIPT" > "$EMITTER"

if [[ ! -s "$EMITTER" ]]; then
    echo "FAIL [emitter-empty]: could not extract TOML emitter body" >&2
    exit 1
fi

# Custom folder
OUTPUT="$(
    CHANNEL_IMESSAGE_ENABLED=false \
    CHANNEL_EMAIL_ENABLED=true \
    CHANNEL_WHATSAPP_ENABLED=false \
    CHANNEL_EMAIL_IMAP_HOST="imap.gmail.com" \
    CHANNEL_EMAIL_IMAP_PORT=993 \
    CHANNEL_EMAIL_SMTP_HOST="smtp.gmail.com" \
    CHANNEL_EMAIL_SMTP_PORT=587 \
    CHANNEL_EMAIL_USERNAME="testuser" \
    CHANNEL_EMAIL_PASSWORD="x" \
    CHANNEL_EMAIL_FROM="testuser" \
    CHANNEL_EMAIL_IMAP_FOLDER="Ostler" \
    bash -c "$(cat "$EMITTER")" 2>&1
)"

if ! echo "$OUTPUT" | grep -q '^imap_folder = "Ostler"$'; then
    echo "FAIL [end-to-end-custom]: emitter did not write 'imap_folder = \"Ostler\"'" >&2
    echo "Output was:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi
echo "PASS: emitter writes the chosen folder ('Ostler')"

# INBOX is honoured if the user explicitly chose it (after the
# prompt-side reconfirmation). The emitter does not second-guess
# what the prompt set.
OUTPUT_INBOX="$(
    CHANNEL_IMESSAGE_ENABLED=false \
    CHANNEL_EMAIL_ENABLED=true \
    CHANNEL_WHATSAPP_ENABLED=false \
    CHANNEL_EMAIL_IMAP_HOST="imap.gmail.com" \
    CHANNEL_EMAIL_IMAP_PORT=993 \
    CHANNEL_EMAIL_SMTP_HOST="smtp.gmail.com" \
    CHANNEL_EMAIL_SMTP_PORT=587 \
    CHANNEL_EMAIL_USERNAME="testuser" \
    CHANNEL_EMAIL_PASSWORD="x" \
    CHANNEL_EMAIL_FROM="testuser" \
    CHANNEL_EMAIL_IMAP_FOLDER="INBOX" \
    bash -c "$(cat "$EMITTER")" 2>&1
)"

if ! echo "$OUTPUT_INBOX" | grep -q '^imap_folder = "INBOX"$'; then
    echo "FAIL [end-to-end-inbox]: emitter did not honour explicit INBOX choice" >&2
    echo "Output was:" >&2
    echo "$OUTPUT_INBOX" >&2
    exit 1
fi
echo "PASS: emitter honours explicit INBOX choice (post-prompt reconfirmation)"

echo ""
echo "ALL EMAIL FOLDER PROMPT TESTS PASSED"
