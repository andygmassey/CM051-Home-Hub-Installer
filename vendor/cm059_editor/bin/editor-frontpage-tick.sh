#!/usr/bin/env bash
#
# editor-frontpage-tick.sh
#
# One LaunchAgent tick of The Editor's Front Page refresh. Driven by
# com.creativemachines.ostler.editor-frontpage.plist (hourly by default,
# RunAtLoad fires one emit at install so the Dashboard is never blank).
#
# What it does (single, cheap, read-only step):
#   1. Re-compile the interest profile from the live PWG graph (one
#      read-only SPARQL SELECT against Oxigraph on 127.0.0.1:7878) and
#      re-emit ~/.ostler/editor/front_page.{json,html} atomically.
#
# The Hub/app Dashboard's <FrontPageCards> reads front_page.json via the
# get_front_page Tauri command; this tick is the producer that keeps that
# file fresh. CM059's emitter NEVER blanks: if the graph is unavailable or
# still hydrating it writes a graceful "still settling in" card instead of
# an empty page, so a fresh install shows something honest from tick one and
# fills with interest cards as preferences land in the graph.
#
# Why this tick is light (NOT the conversation-feed pattern): the Front Page
# emit is stdlib-only, makes no Ollama call, spawns no Docker, and finishes
# sub-second. It therefore does NOT take the shared background-Ollama slot
# lock (that lock is for LLM producers) and is not deferred by the load
# governor -- the Front Page is a first-impression surface, like the wiki
# recompile, so it stays responsive. It DOES honour an explicit operator
# Pause and serialises overlapping ticks with its own mutex.
#
# Idempotent: a re-run just re-emits from current graph state. Failure
# surface: a non-zero exit is recorded by launchd in
# OSTLER_LOGS/editor-frontpage.err.
#
# Placeholders rendered by INSTALL_SNIPPET.sh at install time:
#   __OSTLER_PYTHON__      absolute python3 the installer resolved (>=3.10)
#   __OSTLER_SOURCE_DIR__  staged CM059 tree (holds the compiler/ package)
#
# British English throughout.

set -euo pipefail

# LaunchAgents inherit only the bare system PATH.
export PATH="/usr/local/bin:/opt/homebrew/bin:${PATH:-/usr/bin:/bin}"

PYTHON_BIN="__OSTLER_PYTHON__"
SOURCE_DIR="__OSTLER_SOURCE_DIR__"

OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# --- Operator Pause (Doctor Settings) ---------------------------------
# The load governor's auto-deferral is for the heavy LLM producers; the
# Front Page emit is far too cheap to defer. But an explicit operator Pause
# means "leave my Mac alone", so we honour it here too. Fail-safe: if the
# tier lib is absent we simply proceed (pre-governor behaviour). Disable the
# whole check with OSTLER_RESOURCE_GOVERNOR=0.
if [ "${OSTLER_RESOURCE_GOVERNOR:-1}" = "1" ]; then
    _tier_lib="${OSTLER_RESOURCE_TIER_LIB:-$OSTLER_DIR/lib/ostler-resource-tier.sh}"
    if [ -f "$_tier_lib" ]; then
        # shellcheck source=/dev/null
        . "$_tier_lib"
        if command -v ostler_resource_tier_is_paused >/dev/null 2>&1 \
            && ostler_resource_tier_is_paused; then
            log "background work paused by the operator; skipping this Front Page refresh (auto-resumes when the pause ends)."
            exit 0
        fi
    fi
fi

# --- Source-present guard ---------------------------------------------
# Never hard-fail a RunAtLoad tick because the staged tree is missing --
# just exit cleanly so launchd does not flag the agent.
if [ ! -f "$SOURCE_DIR/compiler/emit_frontpage.py" ]; then
    log "Editor front-page source not found at $SOURCE_DIR/compiler/emit_frontpage.py; skipping (has the installer run?)."
    exit 0
fi
if [ ! -x "$PYTHON_BIN" ]; then
    log "python interpreter not executable at $PYTHON_BIN; skipping."
    exit 0
fi

# --- Single-flight mutex (own lock, NOT the Ollama slot) --------------
# Hourly ticks can overlap the RunAtLoad tick / a catch-up burst. The
# atomic emit already keeps front_page.json consistent, but we serialise
# anyway so two compiles do not race the same SPARQL endpoint. macOS has no
# flock(1); use an atomic mkdir mutex with a PID file for stale reclaim.
LOCK_DIR="${OSTLER_DIR}/.editor-frontpage.lock"
mkdir -p "$OSTLER_DIR" 2>/dev/null || true
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    _holder_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    if [ -n "${_holder_pid:-}" ] && kill -0 "$_holder_pid" 2>/dev/null; then
        log "another Front Page tick (pid ${_holder_pid}) is already running; skipping this tick"
        exit 0
    fi
    log "reclaiming stale Front Page lock (previous holder pid ${_holder_pid:-unknown} is gone)"
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "could not acquire Front Page lock after reclaim; another tick won the race -- skipping"
        exit 0
    fi
fi
printf '%s\n' "$$" > "${LOCK_DIR}/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# --- Emit ------------------------------------------------------------
# Oxigraph is published to the host at 127.0.0.1:7878 by the compose stack;
# CM059 defaults to http://localhost:7878. Pin to the loopback IP to skip
# any localhost DNS quirk and dodge a host http_proxy that would otherwise
# swallow the query.
export OSTLER_OXIGRAPH_URL="${OXIGRAPH_URL:-http://127.0.0.1:7878}"
export no_proxy="${no_proxy:-127.0.0.1,localhost}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"

log "Editor front-page tick start (recompiling interest profile -> front_page.json)"
cd "$SOURCE_DIR"
PYTHONPATH="$SOURCE_DIR" "$PYTHON_BIN" -m compiler.emit_frontpage --oxigraph "$OSTLER_OXIGRAPH_URL"
log "Editor front-page tick complete"
