#!/bin/bash
# Ostler iMessage bundle tick (CM040 product path).
#
# Runs one pass of the iMessage source: read chat.db, thread recent
# conversations into sessions, hand each new session to CM048's
# pwg-convo processor (four-artefact bundle).
#
# Mirrors email-ingest-tick.sh. The installer renders the placeholders:
#   OSTLER_PYTHON      -> imessage-source venv python3 (env or below)
#   OSTLER_SOURCE_DIR  -> $OSTLER_DIR/services/imessage-source
#   PWG_CONVO_CMD      -> absolute pwg-convo invocation (CM048 venv)
#   OSTLER_USER_DISPLAY_NAME -> the operator's display name
#   OSTLER_CONTACTS    -> optional contacts.yaml (handle -> name, L3)
#
# Fresh-install clamp: --since-days bounds the first read window so we
# don't bundle the entire history in one tick. British English.
set -euo pipefail

PYTHON_BIN="${OSTLER_PYTHON:-python3}"
SOURCE_DIR="${OSTLER_SOURCE_DIR:-OSTLER_SOURCE_DIR_PLACEHOLDER}"
SINCE_DAYS="${OSTLER_IMESSAGE_SINCE_DAYS:-30}"
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

# --- Single-flight across all conversation feeds (v1.0.0) ------------
# The iMessage / email / WhatsApp / spoken feeds each tick on their own
# 15-minute schedule and all summarise through the one shared Ollama
# slot. Without a shared lock a fresh install fires several at once and
# starves live chat. Take an atomic, non-blocking lock (a mkdir, which
# is atomic on every POSIX filesystem -- macOS ships no flock); if
# another feed holds it, skip this tick (the watermark means the next
# tick catches up). A lock older than 30 minutes is stolen: a tick never
# legitimately runs that long, so an aged lock means a previous tick was
# killed mid-run. OSTLER_INGEST_LOCK=/dev/null-style override disables.
_ostler_lock="${OSTLER_INGEST_LOCK:-${OSTLER_STATE_DIR:-$HOME/.ostler/workspace}/ingest-ollama.lock.d}"
mkdir -p "$(dirname "$_ostler_lock")" 2>/dev/null || true
if [ -d "$_ostler_lock" ] && [ -n "$(find "$_ostler_lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rmdir "$_ostler_lock" 2>/dev/null || true
fi
if ! mkdir "$_ostler_lock" 2>/dev/null; then
    echo "imessage-bundle tick: another conversation feed holds the model slot; yielding this tick."
    exit 0
fi
trap 'rmdir "$_ostler_lock" 2>/dev/null || true' EXIT
# --------------------------------------------------------------------

cd "$SOURCE_DIR"
# Run as a module so the package-relative imports resolve. SOURCE_DIR
# is the parent of the `services/` tree on the Hub install layout.
# (No exec -- we keep the shell alive so the EXIT trap releases the lock.)
"$PYTHON_BIN" -m services.imessage_source.pipeline "${ARGS[@]}"
