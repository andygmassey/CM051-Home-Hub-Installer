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

# --- Interactive-chat priority yield (v1.0.3 chat-saturation fix) ----
# Live chat (the Hub app's /ws/chat AND iMessage / WhatsApp / email
# replies, all routed through the daemon's agent turn) must win the one
# shared Ollama slot over background enrichment. The daemon touches a
# marker file when an interactive turn starts and refreshes it while the
# turn runs; we yield this whole tick if that marker is FRESH, so a new
# background summary never starts decoding while the user is waiting on a
# reply. The marker lives next to the single-flight lock so it resolves
# to the same workspace on every install. Fail-safe: if the marker is
# absent or stale the tick proceeds exactly as before, and the freshness
# window means a crashed daemon can never wedge background work forever.
#   OSTLER_INTERACTIVE_MARKER    -> override the marker path.
#   OSTLER_INTERACTIVE_TTL_SECS  -> freshness window in seconds (default
#                                   120; 0 disables this yield entirely).
_ostler_imarker="${OSTLER_INTERACTIVE_MARKER:-${OSTLER_STATE_DIR:-$HOME/.ostler/workspace}/interactive-chat.active}"
_ostler_ittl="${OSTLER_INTERACTIVE_TTL_SECS:-120}"
if [ "$_ostler_ittl" -gt 0 ] && [ -f "$_ostler_imarker" ]; then
    # Age the marker by its mtime. `stat` flags differ across BSD/macOS
    # and GNU; try the BSD form first (macOS is the install target), then
    # the GNU form. If neither works we cannot age it, so we do NOT yield
    # (fail-safe: never wedge background work on a stat quirk).
    _ostler_mtime="$(stat -f %m "$_ostler_imarker" 2>/dev/null || stat -c %Y "$_ostler_imarker" 2>/dev/null || true)"
    if [ -n "${_ostler_mtime:-}" ]; then
        _ostler_age=$(( $(date +%s) - _ostler_mtime ))
        if [ "$_ostler_age" -ge 0 ] && [ "$_ostler_age" -lt "$_ostler_ittl" ]; then
            echo "bundle tick: interactive chat active (${_ostler_age}s ago, < ${_ostler_ittl}s); yielding this tick to keep live replies fast."
            exit 0
        fi
    fi
fi
# --------------------------------------------------------------------

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
# tick catches up). The lock is reclaimed only when its recorded holder
# PID is dead -- never on age, because the wiki summary backfill holds this
# same lock for hours; a dead holder PID means a previous tick was
# killed mid-run. OSTLER_INGEST_LOCK=/dev/null-style override disables.
_ostler_lock="${OSTLER_INGEST_LOCK:-${OSTLER_STATE_DIR:-$HOME/.ostler/workspace}/ingest-ollama.lock.d}"
mkdir -p "$(dirname "$_ostler_lock")" 2>/dev/null || true

# --- Anti-starvation fairness (CM044 conversations-ingest fix) -------
# On a fresh install with several feeds active, WhatsApp + email each
# grab the shared slot for long runs and the iMessage feed instant-yields
# on EVERY tick -- the live-box symptom was an iMessage feed that had
# never run a single pass (no watermark, empty Conversations dir) while
# the slot churned through other feeds. A feed that has NEVER produced a
# watermark is starving, so it waits (bounded) for the slot instead of
# yielding immediately, guaranteeing it a first drain. Once it has a
# watermark it reverts to the instant-yield behaviour, so a healthy feed
# never blocks live chat for hours.
#   OSTLER_INGEST_STARVE_WAIT  -> max seconds a never-run feed waits for
#                                 the slot (default 75; 0 disables, i.e.
#                                 restores pure instant-yield).
_ostler_watermark="${OSTLER_STATE_DIR:-$HOME/.ostler/workspace}/imessage_source_state.json"
_ostler_starve_wait="${OSTLER_INGEST_STARVE_WAIT:-75}"
_ostler_never_ran=0
if [ ! -s "$_ostler_watermark" ]; then
    _ostler_never_ran=1
fi

if ! mkdir "$_ostler_lock" 2>/dev/null; then
    # Lock held. Reclaim ONLY if the recorded holder PID is dead. A
    # time-based steal would wrongly evict the wiki summary backfill, which
    # holds this SAME lock for hours (v1.0.0 chat-saturation fix); if the
    # holder is alive, yield this tick (the watermark catches up next tick)
    # -- UNLESS this feed has never run, in which case wait (bounded) for
    # the slot so a starving feed gets its first turn.
    _ostler_h="$(cat "$_ostler_lock/pid" 2>/dev/null || true)"
    if [ -n "${_ostler_h:-}" ] && kill -0 "$_ostler_h" 2>/dev/null; then
        if [ "$_ostler_never_ran" = "1" ] && [ "$_ostler_starve_wait" -gt 0 ]; then
            echo "imessage-bundle tick: slot held by pid ${_ostler_h}; this feed has never run, waiting up to ${_ostler_starve_wait}s for a turn."
            _ostler_waited=0
            _ostler_got_lock=0
            while [ "$_ostler_waited" -lt "$_ostler_starve_wait" ]; do
                sleep 5
                _ostler_waited=$((_ostler_waited + 5))
                if mkdir "$_ostler_lock" 2>/dev/null; then
                    _ostler_got_lock=1
                    break
                fi
                # Holder died mid-wait -> reclaim the stale lock.
                _ostler_h2="$(cat "$_ostler_lock/pid" 2>/dev/null || true)"
                if [ -z "${_ostler_h2:-}" ] || ! kill -0 "$_ostler_h2" 2>/dev/null; then
                    rm -rf "$_ostler_lock" 2>/dev/null || true
                    if mkdir "$_ostler_lock" 2>/dev/null; then
                        _ostler_got_lock=1
                        break
                    fi
                fi
            done
            if [ "$_ostler_got_lock" != "1" ]; then
                # Still could not take it within the window -- next tick retries.
                echo "imessage-bundle tick: slot still busy after waiting ${_ostler_waited}s; yielding this tick (next tick retries)."
                exit 0
            fi
        else
            echo "imessage-bundle tick: another LLM job (pid ${_ostler_h}) holds the model slot; yielding this tick."
            exit 0
        fi
    else
        rm -rf "$_ostler_lock" 2>/dev/null || true
        if ! mkdir "$_ostler_lock" 2>/dev/null; then
            echo "imessage-bundle tick: lost the race for the model slot; yielding this tick."
            exit 0
        fi
    fi
fi
printf '%s\n' "$$" > "$_ostler_lock/pid"
trap 'rm -rf "$_ostler_lock" 2>/dev/null || true' EXIT
# --------------------------------------------------------------------

cd "$SOURCE_DIR"
# Run as a module so the package-relative imports resolve. SOURCE_DIR
# is the parent of the `services/` tree on the Hub install layout.
# (No exec -- we keep the shell alive so the EXIT trap releases the lock.)
"$PYTHON_BIN" -m services.imessage_source.pipeline "${ARGS[@]}"
