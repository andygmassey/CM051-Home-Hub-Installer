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

# --- Off-peak ingest throttle (v1.0.0) -------------------------------
# One shared Ollama slot serves both live chat and these conversation
# feeds. On a fresh install the historic backlog is large and each
# session costs a ~1-minute summary, so left unthrottled the feeds
# saturate the slot for hours and chat feels dead. Outside the
# 01:00-06:00 local window we shrink the read window so daytime ticks
# only touch the last day or two (keeps the assistant current on recent
# conversations and stays light); overnight the full configured window
# drains at full throttle. Nothing is lost: the per-session watermark
# means an older session deferred during the day is picked up on the
# next overnight tick.
#   OSTLER_INGEST_OFFPEAK_ONLY=0      -> disable the gate (full window
#                                       every tick).
#   OSTLER_INGEST_DAYTIME_SINCE_DAYS  -> daytime read window (default 2).
if [ "${OSTLER_INGEST_OFFPEAK_ONLY:-1}" = "1" ]; then
    # 10# forces base-10 so a leading-zero hour ("08","09") is not read
    # as an invalid octal literal.
    _ostler_hour=$((10#$(date +%H)))
    if [ "$_ostler_hour" -lt 1 ] || [ "$_ostler_hour" -ge 6 ]; then
        _ostler_daytime_days="${OSTLER_INGEST_DAYTIME_SINCE_DAYS:-2}"
        if [ "$SINCE_DAYS" -gt "$_ostler_daytime_days" ]; then
            SINCE_DAYS="$_ostler_daytime_days"
        fi
    fi
fi
# --------------------------------------------------------------------

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

# --- Single-flight across all conversation feeds (v1.0.0) ------------
# The iMessage / email / WhatsApp / spoken feeds each tick on their own
# 15-minute schedule and all summarise through the one shared Ollama
# slot. Without a shared lock a fresh install fires several at once and
# starves live chat. Take an atomic, non-blocking lock (a mkdir, which
# is atomic on every POSIX filesystem -- macOS ships no flock); if
# another feed holds it, skip this tick (the watermark means the next
# tick catches up). The lock is reclaimed only when its recorded holder
# PID is dead -- never on age, because the wiki summary backfill holds this
# same lock for hours; a dead holder PID means a previous tick was
# killed mid-run.
_ostler_lock="${OSTLER_INGEST_LOCK:-${OSTLER_STATE_DIR:-$HOME/.ostler/workspace}/ingest-ollama.lock.d}"
mkdir -p "$(dirname "$_ostler_lock")" 2>/dev/null || true
if ! mkdir "$_ostler_lock" 2>/dev/null; then
    # Lock held. Reclaim ONLY if the recorded holder PID is dead. A
    # time-based steal would wrongly evict the wiki summary backfill, which
    # holds this SAME lock for hours (v1.0.0 chat-saturation fix); if the
    # holder is alive, yield this tick (the watermark catches up next tick).
    _ostler_h="$(cat "$_ostler_lock/pid" 2>/dev/null || true)"
    if [ -n "${_ostler_h:-}" ] && kill -0 "$_ostler_h" 2>/dev/null; then
        echo "spoken-bundle tick: another LLM job (pid ${_ostler_h}) holds the model slot; yielding this tick."
        exit 0
    fi
    rm -rf "$_ostler_lock" 2>/dev/null || true
    if ! mkdir "$_ostler_lock" 2>/dev/null; then
        echo "spoken-bundle tick: lost the race for the model slot; yielding this tick."
        exit 0
    fi
fi
printf '%s\n' "$$" > "$_ostler_lock/pid"
trap 'rm -rf "$_ostler_lock" 2>/dev/null || true' EXIT
# --------------------------------------------------------------------

cd "$SOURCE_DIR"
# Run as a module so the package-relative imports resolve. SOURCE_DIR
# is the parent of the spoken_source/ package.
# (No exec -- we keep the shell alive so the EXIT trap releases the lock.)
"$PYTHON_BIN" -m spoken_source.pipeline "${ARGS[@]}"
