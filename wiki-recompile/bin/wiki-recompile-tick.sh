#!/usr/bin/env bash
#
# wiki-recompile-tick.sh
#
# One LaunchAgent tick of the wiki-recompile schedule. Driven by
# com.creativemachines.ostler.wiki-recompile.plist (daily by
# default, configurable per the open question in piece 3's PR).
#
# Chain (two-phase, publish-fast / backfill-summaries):
#   1. cd $OSTLER_DIR (where docker-compose.yml lives)
#   2. Phase 1 -- fast baseline. Run the compiler with
#      OSTLER_WIKI_SKIP_LLM=1 so it renders every person/org/etc.
#      page from current Oxigraph + Qdrant state but SKIPS the
#      per-person LLM summary pass (~40s/person, hours for
#      thousands). This finishes in seconds-to-minutes and is what
#      makes people appear fast after a recompile.
#   3. docker compose up -d wiki-site publishes that baseline so the
#      user sees the fresh names immediately (it's
#      restart: unless-stopped, but a manual stop or a crashed
#      daemon could have it down).
#   4. Phase 2 -- detached full compile. AFTER publishing, launch a
#      FULL compile (no SKIP_LLM) detached with nohup + disown so
#      the LLM summaries backfill into the already-published wiki
#      without blocking this tick. The tick returns the moment the
#      baseline is published and the background full is launched --
#      it never waits on the multi-hour summary pass.
#
# Why: a single full compile blocked the tick (and therefore the
# published wiki) for hours -- the wiki showed 0 people until the
# whole summary pass finished. Mirrors the install-time pattern.
#
# Idempotent: a re-run just rebuilds; CM044's compiler is
# deterministic over the same input.
#
# Failure surface: any non-zero exit propagates so launchd records
# the failure in OSTLER_LOGS/wiki-recompile.err. Mirrors the no-
# silent-fallback discipline from H4 / H5 and the email-ingest
# LaunchAgent shipped earlier tonight.
#
# Configuration (env, set by the installer or LaunchAgent):
#   OSTLER_DIR  (default ~/.ostler) -- artefact root, holds
#                                     docker-compose.yml
#
# British English throughout.

set -euo pipefail

# LaunchAgents inherit only the bare system PATH. Belt-and-braces:
# the plist sets EnvironmentVariables.PATH too, but a stale or
# manually-installed plist without the block would still resolve
# docker through this prepend.
export PATH="/usr/local/bin:/opt/homebrew/bin:${PATH:-/usr/bin:/bin}"

# --- User controls: pause + config env (resource throttle) -----------
# The wiki recompile is ESSENTIAL on first run, so it is NOT deferred by
# the load gate the conversation feeds use -- but the user-facing Pause
# control DOES stop it (it is the single biggest Ollama producer on the
# box), and the Config env file feeds its governor settings. Both are
# no-ops when their files are absent. Pause beats everything below.
_ostler_runtime_lib="${OSTLER_RUNTIME_LIB:-$HOME/.ostler/lib/ostler-runtime.sh}"
if [ -f "$_ostler_runtime_lib" ]; then
    # shellcheck source=/dev/null
    . "$_ostler_runtime_lib"
    command -v ostler_runtime_load_env >/dev/null 2>&1 && ostler_runtime_load_env
    if command -v ostler_pause_active >/dev/null 2>&1 && ostler_pause_active; then
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
            "wiki-recompile tick: background processing is paused by the user; yielding this tick."
        exit 0
    fi
fi
# --------------------------------------------------------------------

OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# --- Adaptive resource governor (v1.0.3 first-run-storm fix) ----------
# The wiki recompile is ESSENTIAL on first run (People + Wiki are the
# first-impression surfaces), so it is NOT deferred by the load gate the
# conversation feeds use. But its Phase-2 summary backfill is the single
# biggest Ollama producer on the box, so it MUST scale its parallel LLM
# worker count to the hardware tier: FLOOR=1, LOW=2, HIGH=3. Left fixed at
# the shipped 3, a 16GB floor machine runs three parallel summary workers
# against the one shared model slot and re-creates the saturation. We read
# the tier here and pass WIKI_LLM_WORKERS to the Phase-2 compile container
# only (Phase 1 is OSTLER_WIKI_SKIP_LLM=1, no LLM, so it is untouched).
#
# Fail-safe: if the tier lib is absent we leave WIKI_LLM_WORKERS unset and
# the compiler uses its own default (the pre-governor behaviour).
# Override / disable with OSTLER_RESOURCE_GOVERNOR=0.
WIKI_TIER_WORKERS=""
if [ "${OSTLER_RESOURCE_GOVERNOR:-1}" = "1" ]; then
    _ostler_tier_lib="${OSTLER_RESOURCE_TIER_LIB:-$HOME/.ostler/lib/ostler-resource-tier.sh}"
    if [ -f "$_ostler_tier_lib" ]; then
        # shellcheck source=/dev/null
        . "$_ostler_tier_lib"
        if command -v ostler_resource_tier_detect >/dev/null 2>&1; then
            ostler_resource_tier_detect
            case "${OSTLER_TIER:-}" in
                floor) WIKI_TIER_WORKERS=1 ;;
                low)   WIKI_TIER_WORKERS=2 ;;
                high)  WIKI_TIER_WORKERS=3 ;;
            esac
            [ -n "$WIKI_TIER_WORKERS" ] && \
                log "resource tier ${OSTLER_TIER}: capping wiki summary workers to ${WIKI_TIER_WORKERS}"
        fi
    fi
fi
# --------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Sanity: compose file present?
# ---------------------------------------------------------------------------

COMPOSE_FILE="${OSTLER_DIR}/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
    log "ERROR: docker-compose.yml not found at $COMPOSE_FILE."
    log "       Has the Ostler installer been run? Re-run install.sh, then retry."
    exit 1
fi

# ---------------------------------------------------------------------------
# Sanity: docker available?
# ---------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
    log "ERROR: docker is not on PATH."
    log "       The wiki-recompile LaunchAgent needs Docker Desktop or Colima."
    log "       Start the Docker daemon and retry; or disable this LaunchAgent if"
    log "       you intentionally uninstalled Docker."
    exit 127
fi

cd "$OSTLER_DIR"

# ---------------------------------------------------------------------------
# Single-tick mutex (concurrency guard)
# ---------------------------------------------------------------------------
#
# The first-day catch-up runner fires many ticks in quick succession, and
# the daily schedule can overlap a still-running compile. With no lock the
# ticks spawn competing `wiki-compiler` run containers that contend for
# Ollama and race on the wiki_docs volume -- on a fresh install this storm
# meant no baseline compile ever survived to publish (concurrent runners
# interrupted one another, exit 130) and the wiki never came up. Serialise:
# a tick that finds another already running exits 0 (success -- nothing to
# do; the in-flight tick will publish) instead of piling on.
#
# macOS has no flock(1), so we use an atomic mkdir mutex with a PID file for
# stale-lock recovery (a tick killed mid-run leaves the dir behind; if its
# holder PID is gone we reclaim it).
LOCK_DIR="${OSTLER_DIR}/.wiki-recompile.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    _holder_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    if [ -n "${_holder_pid:-}" ] && kill -0 "$_holder_pid" 2>/dev/null; then
        log "another wiki-recompile tick (pid ${_holder_pid}) is already running; skipping this tick"
        exit 0
    fi
    log "reclaiming stale wiki-recompile lock (previous holder pid ${_holder_pid:-unknown} is gone)"
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "could not acquire wiki-recompile lock after reclaim; another tick won the race -- skipping"
        exit 0
    fi
fi
printf '%s\n' "$$" > "${LOCK_DIR}/pid"
# Release the mutex on any exit path (success, failure, or watchdog kill).
# The detached Phase-2 backfill does NOT hold this lock -- the lock only
# serialises the baseline compile + publish that decides whether the wiki
# is up. Phase 2 has its own no-stack guard below.
trap 'rm -rf "$LOCK_DIR"' EXIT

# ---------------------------------------------------------------------------
# 1. Phase 1 -- fast baseline compile (OSTLER_WIKI_SKIP_LLM=1)
# ---------------------------------------------------------------------------
#
# Renders every page from current PWG state but skips the per-person
# LLM summary pass. This is the step that gets people visible fast;
# the summaries backfill in Phase 2 below.

log "wiki-recompile tick start (phase 1: fast baseline, OSTLER_WIKI_SKIP_LLM=1)"

# Capture docker's exit code through the tail filter. Two
# subtleties together:
#   (a) Without disabling `set -o pipefail`, a non-zero docker
#       exit makes the pipeline non-zero and `set -e` terminates
#       the script before we can read the exit code.
#   (b) PIPESTATUS[0] is the docker exit code, NOT the tail exit
#       code -- without explicit PIPESTATUS we'd see tail's 0
#       and miss the failure entirely.
# -T disables docker's pseudo-TTY allocation and </dev/null detaches
# stdin: together they cure the `compose run --rm` exit-hang where the CLI
# wrapper sits at 0% CPU after the container exits until something kills it
# (confirmed on the live Studio box -- without -T the daily tick wedges and
# never refreshes the wiki). A watchdog hard-kills a genuinely stuck
# baseline compile after WIKI_COMPILE_TIMEOUT so the LaunchAgent can never
# wedge indefinitely (the baseline should be quick, but we guard anyway).
# Output is captured to a temp file and tailed afterwards so a long compile
# still surfaces its last lines without holding a TTY.
WIKI_COMPILE_TIMEOUT="${WIKI_COMPILE_TIMEOUT:-1800}"
_compile_log="$(mktemp -t wiki-recompile.XXXXXX)"
docker compose --profile compile run --rm -T -e OSTLER_WIKI_SKIP_LLM=1 wiki-compiler </dev/null >"$_compile_log" 2>&1 &
_compile_pid=$!
# Watchdog: stdio detached to /dev/null so it never holds a parent pipe
# open. Killed the instant the compile returns, so it only ever fires on a
# genuine hang.
{
    sleep "$WIKI_COMPILE_TIMEOUT"
    if kill -0 "$_compile_pid" 2>/dev/null; then
        kill -TERM "$_compile_pid" 2>/dev/null
        sleep 5
        kill -KILL "$_compile_pid" 2>/dev/null
    fi
} >/dev/null 2>&1 &
_watchdog_pid=$!
COMPILE_RC=0
wait "$_compile_pid" || COMPILE_RC=$?
kill "$_watchdog_pid" 2>/dev/null || true
wait "$_watchdog_pid" 2>/dev/null || true
tail -20 "$_compile_log" 2>/dev/null || true
rm -f "$_compile_log"
if [ "$COMPILE_RC" -eq 137 ] || [ "$COMPILE_RC" -eq 143 ]; then
    log "ERROR: wiki-compiler (baseline) exceeded ${WIKI_COMPILE_TIMEOUT}s and was killed by the watchdog (exit $COMPILE_RC)."
fi
if [ "$COMPILE_RC" -ne 0 ]; then
    log "ERROR: wiki-compiler baseline failed (exit $COMPILE_RC); skipping wiki-site refresh."
    log "       Common causes: Oxigraph unhealthy, disk pressure on wiki_docs"
    log "       volume, ostler-wiki-compiler image missing or stale."
    log "       Manual retry:"
    log "         cd $OSTLER_DIR"
    log "         docker compose --profile compile run --rm -T -e OSTLER_WIKI_SKIP_LLM=1 wiki-compiler </dev/null"
    exit "$COMPILE_RC"
fi

# ---------------------------------------------------------------------------
# 2. Publish the baseline -- make sure wiki-site is up so the user
#    sees the freshly-compiled pages within seconds
# ---------------------------------------------------------------------------

set +o pipefail
# Ensure wiki-site is up (restart: unless-stopped, but a manual stop or a
# crashed daemon could have it down). NO --force-recreate: the wiki-site
# container now runs a static server (CM044 docker/wiki-site-serve.py) that
# builds the HTML off the serving path and picks up the compile we just ran by
# polling the compiler's .compile-complete marker, then atomically swaps the
# new build in -- so a plain `up -d` (a no-op when already running) is correct
# and the server refreshes itself within its poll interval. The old
# force-recreate existed only because `mkdocs serve` could not see
# cross-container volume writes via inotify and had to be restarted (#598);
# that restart WAS the recompile-window 000 this design removes. install.sh
# uses the identical publish primitive.
docker compose up -d wiki-site 2>&1 | tail -5
UP_RC=${PIPESTATUS[0]}
set -o pipefail
if [ "$UP_RC" -ne 0 ]; then
    log "ERROR: wiki-site failed to start (exit $UP_RC)."
    log "       The baseline compile succeeded; the page server did not."
    log "       Manual retry:"
    log "         cd $OSTLER_DIR"
    log "         docker compose up -d wiki-site"
    exit "$UP_RC"
fi

log "wiki baseline published and wiki-site verified up"

# ---------------------------------------------------------------------------
# 3. Phase 2 -- detached full compile (LLM summaries backfill)
# ---------------------------------------------------------------------------
#
# Now that the baseline is published, kick off the FULL compile (no
# OSTLER_WIKI_SKIP_LLM) so the per-person summaries backfill into the
# already-visible wiki. This runs detached (nohup + disown) so the
# multi-hour summary pass NEVER blocks the tick: we launch it and
# return. It is intentionally non-fatal -- a failed/slow summary pass
# must not fail the tick, because the baseline is already live.
_bg_log="${OSTLER_LOGS:-$OSTLER_DIR/logs}/wiki-recompile-summaries.log"
mkdir -p "$(dirname "$_bg_log")" 2>/dev/null || true
# No-stack guard: the first-day catch-up would otherwise launch one detached
# full compile per tick -- N multi-hour summary passes hammering the box for
# days. Only launch if no backfill from a previous tick is still running.
_bg_pidfile="${OSTLER_DIR}/.wiki-recompile-summaries.pid"
_bg_running=false
if [ -f "$_bg_pidfile" ]; then
    _bg_prev_pid="$(cat "$_bg_pidfile" 2>/dev/null || true)"
    if [ -n "${_bg_prev_pid:-}" ] && kill -0 "$_bg_prev_pid" 2>/dev/null; then
        _bg_running=true
    fi
fi
if [ "$_bg_running" = true ]; then
    log "wiki summary backfill already running (pid ${_bg_prev_pid}); not launching another"
else
    # --- Shared background-LLM slot lock (v1.0.0 chat-saturation fix) ------
    # The full-summary backfill is the single biggest Ollama producer on the
    # box. It MUST share the one background-LLM slot lock with the
    # conversation feeds (imessage/email/whatsapp/spoken *-bundle-tick.sh).
    # Otherwise the backfill + one conversation feed run at once, fill both
    # OLLAMA_NUM_PARALLEL=2 slots, and live chat starves (measured on the
    # .149 box: 277s + truncated under load vs 1.5s idle). Holding the lock
    # for the whole compile keeps total background Ollama concurrency at 1,
    # so the 2nd parallel slot is always free for chat.
    #
    # Blocking acquire with PID-LIVENESS reclaim -- NOT a time-based steal.
    # A real summary compile legitimately runs for hours, so any time
    # threshold would let a conversation tick wrongly declare the lock stale
    # and steal it mid-compile, re-creating the 2-producer collision. We
    # reclaim only when the recorded holder PID is actually dead. The
    # conversation ticks take the SAME lock non-blocking and yield while we
    # hold it. ${OSTLER_INGEST_LOCK} (default workspace/ingest-ollama.lock.d)
    # is the identical path the tick wrappers use.
    _slot="${OSTLER_INGEST_LOCK:-${OSTLER_STATE_DIR:-$HOME/.ostler/workspace}/ingest-ollama.lock.d}"
    nohup bash -c '
        set -u
        _slot="$1"; _wd="$2"; _workers="$3"
        cd "$_wd" || exit 1
        mkdir -p "$(dirname "$_slot")" 2>/dev/null || true
        while ! mkdir "$_slot" 2>/dev/null; do
            _h="$(cat "$_slot/pid" 2>/dev/null || true)"
            if [ -n "${_h:-}" ] && kill -0 "$_h" 2>/dev/null; then
                sleep 10
            else
                rm -rf "$_slot" 2>/dev/null || true
            fi
        done
        printf "%s\n" "$$" > "$_slot/pid"
        trap "rm -rf \"$_slot\" 2>/dev/null || true" EXIT
        # Pass the tier-capped parallel summary worker count to the compile
        # container only when the governor resolved one; otherwise let the
        # compiler use its own default (pre-governor behaviour).
        if [ -n "$_workers" ]; then
            docker compose --profile compile run --rm -T -e "WIKI_LLM_WORKERS=$_workers" wiki-compiler </dev/null
        else
            docker compose --profile compile run --rm -T wiki-compiler </dev/null
        fi
    ' _ "$_slot" "$OSTLER_DIR" "$WIKI_TIER_WORKERS" >"$_bg_log" 2>&1 &
    _bg_new_pid=$!
    printf '%s\n' "$_bg_new_pid" > "$_bg_pidfile"
    disown || true
    log "wiki summary backfill launched in background (holds shared Ollama slot lock; full compile, see $_bg_log)"
fi

log "wiki recompile tick complete (baseline published; summaries backfilling)"
