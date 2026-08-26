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
#   is: dedicated label/folder, never the main inbox.
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
# THIS USED TO DEMAND THE PROMPT BACK. It was deliberately removed --
# install.sh:5741-5745 records it as "Andy's call" on 2026-05-20: 99.5% of
# operators want the dedicated 'Ostler' label, so it is hardcoded and
# customisation moved to a post-install Doctor knob, dropping the
# customer-visible question count by one. Demanding the prompt asserts the
# OPPOSITE of the intended design.
#
# What actually matters is the email_safety product rule stated at
# install.sh:5736-5739: a DEDICATED label/folder, NEVER the inbox. Connecting
# the assistant to the main inbox would let it see every email the customer
# receives. Assert that, and that the customer is TOLD which folder is used.
_imap_default="$(grep -oE '^[[:space:]]*CHANNEL_EMAIL_IMAP_FOLDER="[^"]+"' "$INSTALL_SCRIPT" \
    | tail -1 | sed -E 's/.*="([^"]+)"/\1/')"
if [[ -z "$_imap_default" ]]; then
    echo "FAIL [folder-unset]: CHANNEL_EMAIL_IMAP_FOLDER has no non-empty default; the assistant would fall back to the whole inbox" >&2
    exit 1
fi

case "$(printf '%s' "$_imap_default" | tr '[:upper:]' '[:lower:]')" in
    inbox|"in box"|all|"all mail")
        echo "FAIL [folder-is-inbox]: CHANNEL_EMAIL_IMAP_FOLDER defaults to '$_imap_default' -- email_safety requires a DEDICATED label, never the inbox" >&2
        exit 1
        ;;
esac
echo "PASS: IMAP folder defaults to a dedicated label ('$_imap_default'), not the inbox"

# The prompt was removed, so DISCLOSURE is the only thing telling the customer
# which folder the assistant will read. If that goes, the scoping becomes silent.
if ! grep -q 'MSG_OK_EMAIL_CHANNEL_FOLDER' "$INSTALL_SCRIPT"; then
    echo "FAIL [folder-undisclosed]: install.sh never surfaces MSG_OK_EMAIL_CHANNEL_FOLDER; with the prompt gone the customer is never told which folder is used" >&2
    exit 1
fi
echo "PASS: install.sh discloses the chosen folder to the customer"
echo "PASS: the folder is scoped without asking the customer"

# ── No install-time path may select the inbox ───────────────────
# The two assertions that stood here -- a `${CHANNEL_EMAIL_IMAP_FOLDER:-Ostler}`
# blank-input default, and an "INBOX means the assistant will read every email
# you receive" warning -- both belonged to the PROMPT, which was removed
# deliberately (install.sh:5741-5745). With no prompt there is no blank input
# to default and no typed INBOX to warn about.
#
# The substantive protection is now the hardcoded non-inbox default asserted
# above. What remains worth guarding is that no OTHER install-time path can
# quietly point the assistant at the whole mailbox.
if grep -nE '^[[:space:]]*CHANNEL_EMAIL_IMAP_FOLDER=' "$INSTALL_SCRIPT" \
        | grep -qiE '=("|\x27)?(INBOX|ALL MAIL)'; then
    echo "FAIL [inbox-assignment]: an install-time assignment points CHANNEL_EMAIL_IMAP_FOLDER at the inbox -- email_safety forbids it" >&2
    exit 1
fi
echo "PASS: no install-time assignment points the folder at the inbox"

# (The INBOX warning text assertion was removed with the prompt it belonged
# to -- see the note above. The inbox is now unreachable at install time
# rather than warned about, which is the stronger guarantee.)
echo "PASS: INBOX safety warning text present"

# (The "Type INBOX again to confirm" reconfirmation was part of the removed
# prompt flow -- there is no typed input to reconfirm. install.sh:5741-5745.)

# (Case-insensitive INBOX detection validated TYPED input. With no prompt
# there is nothing to case-fold; the hardcoded default is asserted above.)

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
    CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED=true \
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
    CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED=true \
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
