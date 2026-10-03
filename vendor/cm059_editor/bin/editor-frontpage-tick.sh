#!/usr/bin/env bash
#
# editor-frontpage-tick.sh
#
# One LaunchAgent tick of The Editor's Front Page refresh. Driven by
# com.creativemachines.ostler.editor-frontpage.plist (hourly by default,
# RunAtLoad fires one emit at install so the Dashboard is never blank).
#
# What it does (one producer, then two cheap emits):
#   0. Project the Qdrant `preferences` collection into Oxigraph as
#      preference nodes. The only step that WRITES, and it must precede
#      step 1, which compiles from what it writes.
#   1. Emit the stable interest-profile artefact to
#      ~/.ostler/preferences/interest_profile.json. This is what the Hub
#      serves at /api/v1/preferences and therefore what the assistant's
#      `pwg_preferences` tool reads -- the "what do I like?" question.
#   2. Re-compile the interest profile from the live PWG graph (one
#      read-only SPARQL SELECT against Oxigraph on 127.0.0.1:7878) and
#      re-emit ~/.ostler/editor/front_page.{json,html} atomically.
#
# WHY STEP 1 EXISTS, measured on a fresh v1.0.38 box 2026-08-21:
#   This tick ran hourly, exited 0, and logged "12 cards (phase=steady)"
#   every time -- while /api/v1/preferences returned {"interests":[],
#   "count":0} over a Qdrant `preferences` collection holding 9,879 points.
#   Writer and reader disagreed on the path and BOTH reported success:
#     writer (step 2)  -> ~/.ostler/editor/front_page.json          EXISTS
#     reader (the Hub) -> ~/.ostler/preferences/interest_profile.json  ABSENT
#   ical-server.py resolves OSTLER_INTEREST_PROFILE > OSTLER_PREFERENCES_DIR/
#   interest_profile.json > the default, and its comment says that mirrors
#   "the CM059 emitter exactly" -- which was true of compiler/emit_artefact.py.
#   Nothing invoked it. The emitter was correct, vendored faithfully, and dark.
#   Running it by hand on that box turned count:0 into count:495 with no other
#   change, which is the whole proof this step is the fix.
#
#   An absent artefact and an empty profile are the SAME branch in the reader
#   (both yield count:0), so this could never surface as an error -- only as an
#   assistant that says "I do not have personal knowledge about you".
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

# They inherit nothing else either -- and that is what bricked v1.0.45.
#
# MEASURED on the shipped v1.0.45 artefact, 2026-08-26 (ORM). __OSTLER_PYTHON__
# is resolved by install.sh to $PYTHON3_BIN, which on a customer install is the
# interpreter INSIDE the notarised OstlerInstaller.app -- there is exactly one
# python3.11 in the artefact and install.sh never copies it out. CPython writes
# __pycache__/*.pyc next to the source it imports, so an unguarded run of this
# tick writes into the signed bundle and breaks the code seal:
#
#   import json, ssl, sqlite3, urllib.request, email.parser
#     guard set   ->  0 .pyc in bundle, codesign --verify --deep --strict rc=0
#     guard unset -> 69 .pyc in bundle, rc=1 "a sealed resource is missing or
#                    invalid", and spctl REFUSES the app
#
# This agent is RunAtLoad + StartInterval 3600, so unguarded it fires once at
# the END OF THE INSTALL and then every hour, forever. InstallerCoordinator
# .swift:1350 cannot help: launchd is not in the installer's process tree, and
# neither is the shell that ran install.sh.
#
# Same variable and same value the GUI uses. A parent that already set it wins.
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-${HOME}/.ostler/cache/pycache}"

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

# --- Step 0: PROJECT QDRANT PREFERENCES INTO THE GRAPH -----------------
#
# 🔴 compiler/project_preferences.py SHIPPED AND WAS CALLED BY NOTHING.
# Measured on the v1.0.100 box, with a control of the same shape:
#     grep -rl project_preferences ~/.ostler  -> 1 (the file itself)
#     grep -rl emit_frontpage      ~/.ostler  -> 15
# Its own docstring says it "runs before each compile". Nothing ran it.
#
# The consequence was the front page a customer actually sees. Before:
#     Oxigraph pwg:LikePreference nodes   0
#     interest_profile.json stats         raw_rows 0
#     front_page.json                     1 card, "Ostler has spotted 0
#                                         interests from what it has read so far"
# After running it by hand on the same box:
#     projected 4792 preference nodes (43128 triples) from 5721 Qdrant points
#     graph total                         76167 -> 120493 triples
#     interest_profile.json stats         raw_rows 4792
#
# THE ORDERING IS THE WIRING, not a preference. This block WRITES the
# preference nodes that step 1 below READS: the two name the same ontology
# host, the same node types and the same four required predicates, and
# neither side uses a GRAPH clause, so they meet in the default graph. A
# compile that runs first sees the graph as the PREVIOUS tick left it.
#
# THAT IS EXACTLY WHAT THIS FILE DID UNTIL 2026-09-23, and this very comment
# asserted the opposite while it did so, which is how it survived review. The
# block was numbered "Step 1.5" and sat BELOW Step 1. It is a ONE-TICK LAG
# and not a permanent zero, so a box up for two hourly ticks looked correct
# and nobody saw it; it bites only between ingest completing and the
# following tick, which is the window a thin walk runs in. Measured there:
# interest_profile.json count 0 and stats.raw_rows 0 over a graph holding
# 4718 preference nodes, so /api/v1/preferences served an empty set with
# HTTP 200, so the assistant's pwg_preferences tool answered "No preferences
# were found in the personal graph", so the BLOCKING walk probe
# assistant_answers_grounded scored tool_found_nothing.
#
# tests/test_the_preference_projection_runs_before_the_compile_that_reads_it.sh
# renders this wrapper the way INSTALL_SNIPPET.sh does, runs it, and fails if
# the two are ever swapped back.
#
# Guarded on the file existing for the same reason step 1 below is: a tick
# against an older staged tree degrades instead of erroring every hour.
#
# ⚠️ THIS IS NECESSARY AND NOT SUFFICIENT, AND SAYING SO HERE IS THE POINT.
# With all 4792 rows present the profile STILL reports 0 interests:
#     suppressed_low_confidence   4701 of 4792
# because compile_profile's min_confidence default is 0.28 while the dominant
# source, bookmarks, has a measured ceiling of 0.18 with unlimited
# corroboration. That is a separate defect (the interest floor) and this wiring
# does not close it. Anyone reading a still-empty front page after this change
# should look there, not here.
if [ -f "$SOURCE_DIR/compiler/project_preferences.py" ]; then
    _project_rc=0
    PYTHONPATH="$SOURCE_DIR" "$PYTHON_BIN" -m compiler.project_preferences || _project_rc=$?
    if [ "$_project_rc" -ne 0 ]; then
        log "preference projection failed (rc=${_project_rc}); the interest profile will read whatever the graph already held, which on a first run is nothing."
    fi
else
    log "compiler/project_preferences.py not in the staged tree; skipping the preference projection (staged tree predates it)."
fi

# --- Step 1: the interest-profile artefact the Hub actually serves -----
# DELIBERATELY NON-FATAL, and the ordering matters. This step is new; the
# front-page emit below has worked on every box since it shipped. Under
# `set -e` a hard failure here would take the working surface down with the
# new one, so a failure is logged and stepped over. The reverse ordering
# (front page first) was rejected: the artefact is the one the ASSISTANT
# reads, so it goes first of the two emits, and the front page is
# unaffected either way because the two writes touch different files.
#
# IT MUST STAY BELOW STEP 0. That is not a budget question but a data
# dependency: this step compiles from the graph the projection writes, so
# running it first compiles last tick's graph. See Step 0 for the measurement.
#
# Guarded on the file existing so a tick running against an older staged
# tree degrades to previous behaviour instead of erroring every hour.
if [ -f "$SOURCE_DIR/compiler/emit_artefact.py" ]; then
    # rc captured explicitly: `$?` read inside an if/else branch reports the
    # branch's own last command, not the condition's, and that misreports the
    # failure in the log line -- the exact class of wrong-surface reporting
    # this fix exists to remove.
    _artefact_rc=0
    PYTHONPATH="$SOURCE_DIR" "$PYTHON_BIN" -m compiler.emit_artefact \
        --oxigraph "$OSTLER_OXIGRAPH_URL" || _artefact_rc=$?
    if [ "$_artefact_rc" -ne 0 ]; then
        log "interest-profile artefact emit failed (rc=${_artefact_rc}); /api/v1/preferences will keep serving the previous artefact, or count:0 if this is a first run. Front page emit continues."
    fi
else
    log "compiler/emit_artefact.py not in the staged tree; skipping the interest-profile artefact (staged tree predates it)."
fi

# --- Step 2: the Dashboard front page (unchanged) ----------------------
PYTHONPATH="$SOURCE_DIR" "$PYTHON_BIN" -m compiler.emit_frontpage --oxigraph "$OSTLER_OXIGRAPH_URL"
log "Editor front-page tick complete"

# --- Step 3: close the wiki/front-page staleness gap --------------------
# CM051 walk #5: the compiled wiki's "Needs you now" and the live app's
# front_page.json showed ZERO cards in common. Reproduced read-only on
# macmini16-walk: the wiki-compiler service has the correct editor mount
# and OSTLER_FRONT_PAGE_JSON, and genuinely reads and uses the feed -- the
# compile that ran at 2026-10-03T20:54:18Z correctly rendered front_page.json
# as of its OWN most recent read at that time (confirmed via docker inspect
# on the live container plus an in-container call to the real
# _editor_need_cards(), whose returned card content byte-matched the raw
# feed). The compose service definition is not the bug.
#
# The actual gap: this tick runs hourly (StartInterval 3600) and is the only
# writer of front_page.json, while wiki-recompile ships StartInterval 86400
# (daily) by deliberate v1 design -- CM051 #20's own "open question" chose
# daily over hourly for disk/battery cost, which is a decision about the
# WHOLE wiki (thousands of pages) and is left untouched here. Nothing ever
# told the wiki that THIS one hourly artefact had changed, so "Needs you
# now" could run stale by up to a full day in steady state -- exactly the
# daily-tick-is-a-day-of-latency shape already measured for the container
# supervisor (3.2a-sup above).
#
# Fix: trigger a wiki recompile ONLY when front_page.json's content actually
# changed since the wiki last picked it up -- not on every hourly tick, so
# the daily-cadence decision for the rest of the wiki is unaffected when the
# feed is quiet.
#
# 🔴 DO NOT FORK wiki-recompile-tick.sh AS A CHILD OF THIS PROCESS. This
# plist (vendor/cm059_editor/launchd/com.creativemachines.ostler.editor-
# frontpage.plist) has NO AbandonProcessGroup key, so launchd kills this
# job's WHOLE PROCESS GROUP the moment this script exits -- including any
# plain `( cmd & )` backgrounded child, which stays a member of this group
# by default. That is the exact v1.0.107 defect (see wiki-recompile-tick.sh's
# own Phase-2 launch, which exists only because of this same failure mode,
# and solves it with `set -m` + the sibling plist's AbandonProcessGroup).
# An earlier version of this fix forked directly and would have silently
# killed the recompile the instant this tick's own process exited.
#
# Fix: ask launchd itself to start the SEPARATE wiki-recompile LaunchAgent
# job (com.creativemachines.ostler.wiki-recompile, whose own plist DOES set
# AbandonProcessGroup) via `launchctl kickstart`. That job runs under its
# own launchd-managed lifetime, entirely independent of this script's --
# nothing here needs to outlive this process for the recompile to survive.
# Without `-k`, kickstart is idempotent: if the job is already running (the
# regular/catch-up schedule, or a previous trigger) it is a no-op, so this
# never double-compiles or interrupts an in-flight run; wiki-recompile-
# tick.sh's own single-flight mutex is a second, independent guard against
# the same thing.
#
# Cost: wiki-recompile-tick.sh's Phase 2 (the LLM summary backfill, by far
# the most expensive part) has no time-based throttle of its own, only an
# anti-STACKING check (skip if one is still running). Triggering Phase 1
# hourly is cheap (seconds-to-minutes, no LLM), but doing so would make
# Phase 2 restart as soon as each run finishes -- turning the deliberate
# daily LLM cost (CM051 #20) into a near-continuous one. wiki-recompile-
# tick.sh therefore also gained a Phase-2 debounce (next section) so this
# trigger can fire hourly without reopening that cost decision.
FRONT_PAGE_JSON="${OSTLER_DIR}/editor/front_page.json"
FRONT_PAGE_SEEN="${OSTLER_DIR}/state/wiki-recompile-last-frontpage.sha256"
WIKI_RECOMPILE_LABEL="com.creativemachines.ostler.wiki-recompile"
if [ -f "$FRONT_PAGE_JSON" ]; then
    mkdir -p "${OSTLER_DIR}/state" 2>/dev/null || true
    # `|| true` on the assignment: under `set -e`, a failed command
    # substitution used as a plain assignment DOES abort the script (unlike
    # inside an `if`/`&&`), and this whole step must stay as non-fatal as the
    # rest of this tick -- a hash hiccup must never take the front-page emit
    # above down with it.
    _new_hash="$(shasum -a 256 "$FRONT_PAGE_JSON" 2>/dev/null | awk '{print $1}')" || true
    _old_hash="$(cat "$FRONT_PAGE_SEEN" 2>/dev/null || true)"
    if [ -n "$_new_hash" ] && [ "$_new_hash" != "$_old_hash" ]; then
        printf '%s' "$_new_hash" > "$FRONT_PAGE_SEEN"
        log "front_page.json changed (was ${_old_hash:-<none>}, now ${_new_hash}); kickstarting ${WIKI_RECOMPILE_LABEL} so Needs-you-now catches up within one tick"
        _kick_rc=0
        launchctl kickstart "gui/$(id -u)/${WIKI_RECOMPILE_LABEL}" || _kick_rc=$?
        if [ "$_kick_rc" -ne 0 ]; then
            log "launchctl kickstart ${WIKI_RECOMPILE_LABEL} returned rc=${_kick_rc} (job not loaded? agent not installed?); the daily/catch-up schedule will pick this up instead"
        fi
    else
        log "front_page.json unchanged since the wiki last saw it; leaving the daily wiki-recompile schedule alone"
    fi
fi
