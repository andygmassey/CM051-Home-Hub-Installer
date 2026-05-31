#!/usr/bin/env bash
#
# whatsapp-bundle-tick.sh
#
# One LaunchAgent tick of the HR015 WhatsApp CONVERSATION-MEMORY feed.
# Driven by com.creativemachines.ostler.whatsapp-bundle.plist on a
# fifteen-minute schedule.
#
# This is the four-artefact leg for WHATSAPP conversations. It reads
# the macOS WhatsApp Desktop store (ChatStorage.sqlite, FDA granted at
# install) for in-tier chats (T1 DM + T2 intimate/active group) WITH
# message bodies, renders each chat into a cleaned transcript + CM048
# metadata, and hands it to CM048's pwg-convo processor, which emits
# the four artefacts under
# ~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/.
#
# It is SEPARATE from the hydrate_whatsapp install sub-phase (which runs
# ostler_fda.whatsapp_history for people-graph FACTS, metadata only).
# Distinct label, wrapper, state file, output, so the two never collide.
# The read is local-file-only against WhatsApp Desktop's already-synced
# store; it never contacts Meta.
#
# Chain:
#   1. whatsapp_source.reader reads ChatStorage.sqlite (bodies, in-tier).
#   2. whatsapp_source.renderer builds the cleaned transcript + metadata.
#   3. whatsapp_source.pipeline invokes pwg-convo process per chat.
#
# Idempotent: a watermark in
# ~/.ostler/workspace/whatsapp_source_state.json records, per chat, the
# last-bundled message timestamp, so a tick only dispatches a chat that
# carries a message newer than the last one bundled.
#
# The installer renders the placeholders:
#   OSTLER_PYTHON            -> whatsapp-source venv python3 (env or below)
#   OSTLER_SOURCE_DIR        -> $OSTLER_DIR/services/whatsapp-source (the
#                               parent of the whatsapp_source package AND
#                               the ostler_fda package it imports)
#   PWG_CONVO_CMD            -> absolute pwg-convo invocation (CM048 venv)
#   OSTLER_USER_DISPLAY_NAME -> the operator's display name (so their
#                               own messages render as "You")
#   OSTLER_CONTACTS          -> optional contacts.yaml (whatsapp: JID ->
#                               name + contact_label/group_label + L3)
#
# Fresh-install clamp: --since-days bounds the read window to the last
# year ("your last year of WhatsApp") so we do not bundle the entire
# store in one tick. British English throughout.

set -euo pipefail

PYTHON_BIN="${OSTLER_PYTHON:-python3}"
SOURCE_DIR="${OSTLER_SOURCE_DIR:-OSTLER_SOURCE_DIR_PLACEHOLDER}"
SINCE_DAYS="${OSTLER_WHATSAPP_SINCE_DAYS:-365}"
USER_NAME="${OSTLER_USER_DISPLAY_NAME:-You}"

ARGS=(--user-name "$USER_NAME" --since-days "$SINCE_DAYS")
if [ -n "${OSTLER_CONTACTS:-}" ] && [ -f "${OSTLER_CONTACTS}" ]; then
    ARGS+=(--contacts "${OSTLER_CONTACTS}")
fi

# WhatsApp Desktop guard: if WhatsApp Desktop has never run on this Mac
# the ChatStorage.sqlite does not exist. The pipeline treats a missing
# database as "no app" (returns a no_app status and exit 0), so the tick
# exits cleanly rather than erroring. We probe here too so the log is
# honest about why a tick did nothing.
CHAT_DB="${OSTLER_WHATSAPP_DB:-$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite}"
if [ ! -f "$CHAT_DB" ]; then
    echo "whatsapp-bundle tick: no WhatsApp Desktop store at $CHAT_DB; nothing to do."
    exit 0
fi

cd "$SOURCE_DIR"
# Run as a module so the package-relative imports resolve. SOURCE_DIR is
# the parent of BOTH the whatsapp_source/ package AND the ostler_fda/
# package the reader imports.
exec "$PYTHON_BIN" -m whatsapp_source.pipeline "${ARGS[@]}"
