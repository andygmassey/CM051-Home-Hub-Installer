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
# Drop pipefail just for the pipeline, capture PIPESTATUS, restore.
set +o pipefail
docker compose --profile compile run --rm wiki-compiler 2>&1 | tail -20
COMPILE_RC=${PIPESTATUS[0]}
set -o pipefail
if [ "$COMPILE_RC" -ne 0 ]; then
    log "ERROR: wiki-compiler failed (exit $COMPILE_RC); skipping wiki-site refresh."
    log "       Common causes: Oxigraph unhealthy, disk pressure on wiki_docs"
    log "       volume, ostler-wiki-compiler image missing or stale."
    log "       Manual retry:"
    log "         cd $OSTLER_DIR"
    log "         docker compose --profile compile run --rm wiki-compiler"
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
