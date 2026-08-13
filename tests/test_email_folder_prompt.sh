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

# ── The folder is HARDCODED, and never the inbox ────────────────
#
# v1018-D675. This file used to assert an install-time prompt:
#   'Folder/label [Ostler]:', a blank-input default, an INBOX safety
#   warning, and a 'Type INBOX again to confirm' re-prompt.
#
# ANDY REMOVED THAT PROMPT ON PURPOSE. install.sh:4079-4083 records the
# decision verbatim -- "v1.0 (2026-05-20 Studio retest #2 follow-up): Andy's
# call -- 99.5% of operators want the dedicated 'Ostler' label by default, so
# we hardcode it and surface customisation as a post-install Doctor knob
# rather than an install-time question. Removing this prompt drops the
# customer-visible question count by one."
#
# So the four assertions below it were not stale wording, they demanded a
# question that was deliberately deleted. Retargeting rather than deleting the
# file, because the PRODUCT RULE the test existed for is still live and still
# worth guarding: email_safety says a dedicated folder, NEVER the inbox. A
# hardcoded default is only safe while it stays hardcoded to something that is
# not INBOX.
if ! grep -qE '^\s*CHANNEL_EMAIL_IMAP_FOLDER="Ostler"\s*$' "$INSTALL_SCRIPT"; then
    echo "FAIL [hardcoded-folder]: CHANNEL_EMAIL_IMAP_FOLDER is not hardcoded to \"Ostler\"." >&2
    echo "      Andy's 2026-05-20 call was to hardcode it and move customisation" >&2
    echo "      to Doctor. If that decision has been reversed, retarget this test;" >&2
    echo "      do not just delete the assertion." >&2
    exit 1
fi
echo "PASS: CHANNEL_EMAIL_IMAP_FOLDER is hardcoded to \"Ostler\""

# The safety rule: the assistant must never be pointed at the whole inbox.
if grep -qE '^\s*CHANNEL_EMAIL_IMAP_FOLDER="(INBOX|Inbox|inbox)"' "$INSTALL_SCRIPT"; then
    echo "FAIL [inbox]: CHANNEL_EMAIL_IMAP_FOLDER is set to the INBOX." >&2
    echo "      email_safety: a dedicated folder/label, never the inbox --" >&2
    echo "      the assistant would read every email the customer receives." >&2
    exit 1
fi
echo "PASS: the folder is never the INBOX"

