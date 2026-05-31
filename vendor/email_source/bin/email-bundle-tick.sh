#!/usr/bin/env bash
#
# email-bundle-tick.sh
#
# One LaunchAgent tick of the HR015 email CONVERSATION-MEMORY feed.
# Driven by com.creativemachines.ostler.email-bundle.plist on a
# fifteen-minute schedule.
#
# This is the four-artefact leg, NOT the facts leg. The sibling
# email-ingest-tick.sh drains Apple Mail into an mbox and pushes
# email FACTS into the graph via pwg-email-ingest. This tick reads
# the same Apple Mail store, threads it into conversation threads,
# and hands each new/updated thread to CM048's pwg-convo processor,
# which emits the four artefacts under
# ~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/.
#
# Chain:
#   1. email_source.reader reads Apple Mail's .emlx tree (reusing
#      ostler_fda.apple_mail_mbox primitives).
#   2. email_source.threader groups messages into threads.
#   3. email_source.pipeline renders the transcript + metadata and
#      invokes pwg-convo process per thread.
#
# Idempotent: a watermark in
# ~/.ostler/workspace/email_source_state.json records the message-ids
# already bundled per thread, so a tick only dispatches a thread that
# carries a genuinely new message. A fresh reply re-bundles the whole
# thread so the four-artefact output stays complete.
#
# The installer renders the placeholders:
#   OSTLER_PYTHON            -> email-source venv python3 (env or below)
#   OSTLER_SOURCE_DIR        -> $OSTLER_DIR/services/email-source (the
#                               parent of the email_source package +
#                               the ostler_fda package it imports)
#   PWG_CONVO_CMD            -> absolute pwg-convo invocation (CM048 venv)
#   OSTLER_USER_DISPLAY_NAME -> the operator's display name
#   OSTLER_USER_EMAIL        -> the operator's own address (so their
#                               outgoing messages render as "You")
#   OSTLER_CONTACTS          -> optional contacts.yaml (addr -> name, L3)
#
# Fresh-install clamp: --since-days bounds the first read window so we
# do not bundle the entire mailbox in one tick. British English.

set -euo pipefail

PYTHON_BIN="${OSTLER_PYTHON:-python3}"
SOURCE_DIR="${OSTLER_SOURCE_DIR:-OSTLER_SOURCE_DIR_PLACEHOLDER}"
SINCE_DAYS="${OSTLER_EMAIL_SINCE_DAYS:-30}"
USER_NAME="${OSTLER_USER_DISPLAY_NAME:-You}"
USER_EMAIL="${OSTLER_USER_EMAIL:-}"

ARGS=(--user-name "$USER_NAME" --since-days "$SINCE_DAYS")
if [ -n "$USER_EMAIL" ]; then
    ARGS+=(--user-address "$USER_EMAIL")
fi
if [ -n "${OSTLER_CONTACTS:-}" ] && [ -f "${OSTLER_CONTACTS}" ]; then
    ARGS+=(--contacts "${OSTLER_CONTACTS}")
fi

# Account / FDA guard: if Apple Mail has never been opened on this Mac
# the ~/Library/Mail tree does not exist. The reader treats a missing
# tree as "no messages" (discover_emlx_files yields nothing), so the
# tick exits 0 cleanly rather than erroring. We probe here too so the
# log is honest about why a tick did nothing.
MAIL_DIR="${OSTLER_MAIL_DIR:-$HOME/Library/Mail}"
if [ ! -d "$MAIL_DIR" ]; then
    echo "email-bundle tick: no Apple Mail store at $MAIL_DIR; nothing to do."
    exit 0
fi

cd "$SOURCE_DIR"
# Run as a module so the package-relative imports resolve. SOURCE_DIR
# is the parent of both the email_source/ package and the ostler_fda/
# package it imports for the Apple Mail primitives.
exec "$PYTHON_BIN" -m email_source.pipeline "${ARGS[@]}"
