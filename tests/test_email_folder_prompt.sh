#!/usr/bin/env bash
#
# tests/test_email_folder_prompt.sh
#
# Locks the email folder/label scoping in install.sh.
#
# Why this test exists:
#
#   Originally install.sh hard-coded `imap_folder = "INBOX"` in
#   [channels.email]. That meant the assistant would read every
#   email the customer received, not just messages addressed to
#   the assistant. The product rule (email_safety) is: dedicated
#   label/folder, never the main inbox.
#
# Decision history (test updated 2026-07-07):
#
#   v0.x: an interactive "Folder/label [Ostler]:" prompt with an
#   INBOX double-confirm ceremony. SUPERSEDED by Andy's v1.0 call
#   (2026-05-20 Studio retest #2 follow-up, documented inline in
#   install.sh): 99.5% of operators want the dedicated 'Ostler'
#   label, so install.sh HARDCODES it and surfaces customisation
#   as a post-install Doctor knob instead of an install-time
#   question (drops the customer-visible question count by one).
#
#   This test pins the CURRENT safe-by-default path:
#     1. CHANNEL_EMAIL_IMAP_FOLDER is initialised, then set to the
#        hardcoded 'Ostler' default inside the email channel block.
#     2. NO interactive folder prompt remains (the question was
#        deliberately removed; its return would regress the
#        question-count decision).
#     3. The TOML emitter writes the variable, never a hard-coded
#        "INBOX" (the original email_safety axis).
#     4. End-to-end: the extracted emitter body writes whatever
#        folder the variable carries.
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

# ── Hardcoded 'Ostler' default (v1.0 decision, 2026-05-20) ──────
if ! grep -qE '^\s+CHANNEL_EMAIL_IMAP_FOLDER="Ostler"$' "$INSTALL_SCRIPT"; then
    echo "FAIL [default-missing]: CHANNEL_EMAIL_IMAP_FOLDER is not hardcoded to 'Ostler' inside the email channel block (v1.0 decision: no install-time folder question)" >&2
    exit 1
fi
echo "PASS: folder is hardcoded to the dedicated 'Ostler' label"

# ── No interactive folder prompt remains ────────────────────────
# The install-time question was deliberately removed; customisation
# is a post-install Doctor knob. A returning prompt would silently
# regress the question-count decision.
if grep -q 'Folder/label \[Ostler\]:' "$INSTALL_SCRIPT"; then
    echo "FAIL [prompt-returned]: the removed 'Folder/label [Ostler]:' install-time prompt is back (v1.0 decision was to hardcode + Doctor knob)" >&2
    exit 1
fi
echo "PASS: no install-time folder prompt (post-install Doctor knob instead)"

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

# ── End-to-end: emitter outputs the configured folder ───────────
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
    echo "FAIL [end-to-end-default]: emitter did not write 'imap_folder = \"Ostler\"'" >&2
    echo "Output was:" >&2
    echo "$OUTPUT" >&2
    exit 1
fi
echo "PASS: emitter writes the dedicated folder ('Ostler')"

# A post-install Doctor edit may set a custom folder; the emitter
# must honour whatever the variable carries rather than second-
# guessing it.
OUTPUT_CUSTOM="$(
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
    CHANNEL_EMAIL_IMAP_FOLDER="Assistant-Inbox" \
    bash -c "$(cat "$EMITTER")" 2>&1
)"

if ! echo "$OUTPUT_CUSTOM" | grep -q '^imap_folder = "Assistant-Inbox"$'; then
    echo "FAIL [end-to-end-custom]: emitter did not honour a custom folder value" >&2
    echo "Output was:" >&2
    echo "$OUTPUT_CUSTOM" >&2
    exit 1
fi
echo "PASS: emitter honours a custom folder value (Doctor-knob path)"

echo ""
echo "ALL EMAIL FOLDER SCOPING TESTS PASSED"
