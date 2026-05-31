#!/usr/bin/env bash
#
# spoken-bundle-tick.sh
#
# One LaunchAgent tick of the HR015 spoken CONVERSATION-MEMORY feed.
# Driven by com.creativemachines.ostler.spoken-bundle.plist on a
# fifteen-minute schedule.
#
# This is the four-artefact leg for SPOKEN conversations (meetings,
# calls, AND voice notes). It does NOT record or transcribe anything;
# CM042 (RemoteCapture) owns capture + Whisper transcription and writes
# finished markdown transcripts under
# ~/Documents/Ostler/Transcripts/YYYY/MM/. This tick reads those
# finished transcripts, normalises each session, and hands it to
# CM048's pwg-convo processor, which emits the four artefacts under
# ~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/.
#
# Chain:
#   1. spoken_source.reader reads CM042's finished transcript tree.
#   2. spoken_source.renderer builds the cleaned transcript + metadata.
#   3. spoken_source.pipeline invokes pwg-convo process per session.
#
# Idempotent: a watermark in
# ~/.ostler/workspace/spoken_source_state.json records the CM042 call
# ids already bundled, so a tick only dispatches a session it has not
# seen before.
#
# The installer renders the placeholders:
#   OSTLER_PYTHON            -> spoken-source venv python3 (env or below)
#   OSTLER_SOURCE_DIR        -> $OSTLER_DIR/services/spoken-source (the
#                               parent of the spoken_source package)
#   PWG_CONVO_CMD            -> absolute pwg-convo invocation (CM048 venv)
#   OSTLER_USER_DISPLAY_NAME -> the operator's display name (so their
#                               own utterances render as "You")
#   OSTLER_CONTACTS          -> optional contacts.yaml (spoken: L3 map)
#
# Fresh-install clamp: --since-days bounds the first read window so we
# do not bundle every historic recording in one tick. British English.

set -euo pipefail

PYTHON_BIN="${OSTLER_PYTHON:-python3}"
SOURCE_DIR="${OSTLER_SOURCE_DIR:-OSTLER_SOURCE_DIR_PLACEHOLDER}"
SINCE_DAYS="${OSTLER_SPOKEN_SINCE_DAYS:-30}"
USER_NAME="${OSTLER_USER_DISPLAY_NAME:-You}"

ARGS=(--user-name "$USER_NAME" --since-days "$SINCE_DAYS")
if [ -n "${OSTLER_CONTACTS:-}" ] && [ -f "${OSTLER_CONTACTS}" ]; then
    ARGS+=(--contacts "${OSTLER_CONTACTS}")
fi

# Transcripts-dir guard: if RemoteCapture has never produced a
# transcript on this Mac the tree does not exist. The reader treats a
# missing tree as "no transcripts" (read_transcripts returns []), so
# the tick exits 0 cleanly rather than erroring. We probe here too so
# the log is honest about why a tick did nothing.
TRANSCRIPTS_DIR="${OSTLER_TRANSCRIPTS_DIR:-$HOME/Documents/Ostler/Transcripts}"
if [ ! -d "$TRANSCRIPTS_DIR" ]; then
    echo "spoken-bundle tick: no RemoteCapture transcripts at $TRANSCRIPTS_DIR; nothing to do."
    exit 0
fi

cd "$SOURCE_DIR"
# Run as a module so the package-relative imports resolve. SOURCE_DIR
# is the parent of the spoken_source/ package.
exec "$PYTHON_BIN" -m spoken_source.pipeline "${ARGS[@]}"
