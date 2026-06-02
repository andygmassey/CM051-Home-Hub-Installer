#!/usr/bin/env bash
#
# wiki-recompile-tick.sh
#
# One LaunchAgent tick of the wiki-recompile schedule. Driven by
# com.creativemachines.ostler.wiki-recompile.plist (daily by
# default, configurable per the open question in piece 3's PR).
#
# Chain:
#   1. cd $OSTLER_DIR (where docker-compose.yml lives)
#   2. docker compose --profile compile run --rm wiki-compiler
#      reads current Oxigraph + Qdrant state, rebuilds the wiki
#      under the wiki_docs volume.
#   3. docker compose up -d wiki-site ensures the server is up
#      (it's restart: unless-stopped, but a manual stop or a
#      crashed daemon could have it down).
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

OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

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
# 1. Recompile the wiki against current PWG state
# ---------------------------------------------------------------------------

log "wiki-recompile tick start"

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
# compile after WIKI_COMPILE_TIMEOUT so the LaunchAgent can never wedge
# indefinitely. Output is captured to a temp file and tailed afterwards so
# a long compile still surfaces its last lines without holding a TTY.
WIKI_COMPILE_TIMEOUT="${WIKI_COMPILE_TIMEOUT:-1800}"
_compile_log="$(mktemp -t wiki-recompile.XXXXXX)"
docker compose --profile compile run --rm -T wiki-compiler </dev/null >"$_compile_log" 2>&1 &
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
    log "ERROR: wiki-compiler exceeded ${WIKI_COMPILE_TIMEOUT}s and was killed by the watchdog (exit $COMPILE_RC)."
fi
if [ "$COMPILE_RC" -ne 0 ]; then
    log "ERROR: wiki-compiler failed (exit $COMPILE_RC); skipping wiki-site refresh."
    log "       Common causes: Oxigraph unhealthy, disk pressure on wiki_docs"
    log "       volume, ostler-wiki-compiler image missing or stale."
    log "       Manual retry:"
    log "         cd $OSTLER_DIR"
    log "         docker compose --profile compile run --rm -T wiki-compiler </dev/null"
    exit "$COMPILE_RC"
fi

# ---------------------------------------------------------------------------
# 2. Make sure wiki-site is up so the user sees the new compile
# ---------------------------------------------------------------------------

set +o pipefail
docker compose up -d wiki-site 2>&1 | tail -5
UP_RC=${PIPESTATUS[0]}
set -o pipefail
if [ "$UP_RC" -ne 0 ]; then
    log "ERROR: wiki-site failed to start (exit $UP_RC)."
    log "       The compile succeeded; the page server did not."
    log "       Manual retry:"
    log "         cd $OSTLER_DIR"
    log "         docker compose up -d wiki-site"
    exit "$UP_RC"
fi

log "wiki recompiled and wiki-site verified up"
