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

# --- Adaptive resource governor (v1.0.3 first-run-storm fix) ----------
# This conversation-bundle feed is NON-ESSENTIAL on first run: the user's
# first impression is People + Wiki + Chat, not the deep body reads + AI
# summaries this feed produces. On the 16GB floor a fresh install fires
# four of these feeds + the wiki recompile at once (all RunAtLoad), which
# (with the Docker VM and macOS first-login indexing) drove the Studio to
# load ~37 and made the Hub app unusable. The hardware-tier governor caps
# that storm: on the FLOOR/LOW tiers (defer flag set) a non-essential tick
# yields whenever the machine is busier than the tier's per-core loadavg
# ceiling, so the spawn spike never lands while first-run load is high.
# The watermark means nothing is lost (next StartInterval catches up).
#
# Fail-safe: if the tier lib is absent or the load is unreadable the tick
# proceeds exactly as before -- the governor never wedges background work.
# Disable entirely with OSTLER_RESOURCE_GOVERNOR=0.
#   OSTLER_RESOURCE_TIER_LIB -> override the lib path (default
#                               ~/.ostler/lib/ostler-resource-tier.sh).
if [ "${OSTLER_RESOURCE_GOVERNOR:-1}" = "1" ]; then
    _ostler_tier_lib="${OSTLER_RESOURCE_TIER_LIB:-$HOME/.ostler/lib/ostler-resource-tier.sh}"
    if [ -f "$_ostler_tier_lib" ]; then
        # shellcheck source=/dev/null
        . "$_ostler_tier_lib"
        if command -v ostler_resource_tier_detect >/dev/null 2>&1; then
            ostler_resource_tier_detect
            if ostler_resource_tier_should_defer_nonessential; then
                echo "bundle tick: ${OSTLER_TIER:-?} tier, load over the per-core ceiling (${OSTLER_LOADAVG_CEILING:-?}); deferring this non-essential enrichment tick to keep first-run surfaces responsive."
                exit 0
            fi
        fi
    fi
fi
# --------------------------------------------------------------------

# --- Off-peak ingest throttle (v1.0.0) -------------------------------
# One shared Ollama slot serves both live chat and these conversation
# feeds. On a fresh install the historic backlog is large and each
# session costs a ~1-minute summary, so left unthrottled the feeds
# saturate the slot for hours and chat feels dead. Outside the
# 01:00-06:00 local window we shrink the read window so daytime ticks
# only touch the last day or two (keeps the assistant current on recent
# conversations and stays light); overnight the full configured window
# drains at full throttle. Nothing is lost: the per-chat watermark means
# an older chat deferred during the day is picked up on the next
# overnight tick.
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
        echo "whatsapp-bundle tick: another LLM job (pid ${_ostler_h}) holds the model slot; yielding this tick."
        exit 0
    fi
    rm -rf "$_ostler_lock" 2>/dev/null || true
    if ! mkdir "$_ostler_lock" 2>/dev/null; then
        echo "whatsapp-bundle tick: lost the race for the model slot; yielding this tick."
        exit 0
    fi
fi
printf '%s\n' "$$" > "$_ostler_lock/pid"
trap 'rm -rf "$_ostler_lock" 2>/dev/null || true' EXIT
# --------------------------------------------------------------------

cd "$SOURCE_DIR"
# Run as a module so the package-relative imports resolve. SOURCE_DIR is
# the parent of BOTH the whatsapp_source/ package AND the ostler_fda/
# package the reader imports.
# (No exec -- we keep the shell alive so the EXIT trap releases the lock.)
"$PYTHON_BIN" -m whatsapp_source.pipeline "${ARGS[@]}"
