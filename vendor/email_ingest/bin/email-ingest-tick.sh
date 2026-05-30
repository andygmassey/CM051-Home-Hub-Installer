#!/usr/bin/env bash
#
# email-ingest-tick.sh
#
# One LaunchAgent tick of the CM046 email pipeline. Driven by
# com.creativemachines.ostler.email-ingest.plist on an hourly
# schedule.
#
# Chain:
#   1. ostler_fda/apple_mail_mbox.py drains any new messages from
#      Apple Mail's .emlx tree into an hourly mbox file.
#   2. pwg-email-ingest mbox <path> hands the mbox to CM046's
#      email adapter, which threads + cleans + writes CM048
#      conversation files.
#
# Idempotent: if no new messages, the emitter writes no file (or an
# empty one) and we skip the ingest step. The emitter's checkpoint
# guards against double-ingest if the LaunchAgent fires faster than
# expected (e.g. user manually `launchctl kickstart`s it).
#
# Failure surface: any non-zero exit propagates so launchd records
# the failure in OSTLER_LOGS/email-ingest.err. The wrapper does NOT
# silently retry; if the emit failed (e.g. FDA permission denied),
# the operator sees a real error rather than a quiet no-op. Mirrors
# the no-silent-fallback discipline from H4 / H5.
#
# Configuration (env, set by the installer or LaunchAgent):
#   OSTLER_DIR         (default ~/.ostler) -- artefact root
#   OSTLER_HOME        (default $HOME)     -- ostler-fda needs this
#   OSTLER_PYTHON      (default python3)   -- python interpreter
#   OSTLER_BACKFILL_DAYS (default 1825)    -- first-tick clamp
#   OSTLER_BACKFILL_CHUNK_DAYS (default 30) -- backward-sweep chunk
#
# British English throughout.

set -euo pipefail

# Resolve config with sensible defaults so a manual run (e.g. "what
# would the LaunchAgent do?") works without env-var ceremony.
# CX-94 (DMG #48g, 2026-05-29): default backfill bumped from 365
# (1 year) to 1825 (5 years) so a fresh customer install lands on
# a wiki populated with their full multi-year correspondence.
# The 30-day chunk size is unchanged -- the apple_mail_mbox reader
# stream-processes per chunk + the LaunchAgent's checkpoint state
# survives across ticks so a slow first-run progressively catches
# up over a handful of hourly ticks rather than blocking the
# install on the full multi-year scan.
OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"
OSTLER_HOME="${OSTLER_HOME:-$HOME}"
OSTLER_PYTHON="${OSTLER_PYTHON:-python3}"
OSTLER_BACKFILL_DAYS="${OSTLER_BACKFILL_DAYS:-1825}"
OSTLER_BACKFILL_CHUNK_DAYS="${OSTLER_BACKFILL_CHUNK_DAYS:-30}"

# Where to drop the hourly mbox. One file per hour means a re-run
# in the same hour appends rather than overwriting; the emitter's
# checkpoint still prevents duplicate records.
TS="$(date +%Y-%m-%d-%H)"
IMPORTS_DIR="$OSTLER_DIR/imports/email"
MBOX="$IMPORTS_DIR/${TS}.mbox.txt"
mkdir -p "$IMPORTS_DIR"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# ---------------------------------------------------------------------------
# 1. Emit fresh messages from Apple Mail
# ---------------------------------------------------------------------------

log "email-ingest tick start: mbox=$MBOX backfill_days=$OSTLER_BACKFILL_DAYS"

OSTLER_HOME="$OSTLER_HOME" "$OSTLER_PYTHON" -m ostler_fda.apple_mail_mbox \
    --emit-mbox "$MBOX" \
    --backfill-days "$OSTLER_BACKFILL_DAYS" \
    --backfill-chunk-days "$OSTLER_BACKFILL_CHUNK_DAYS" \
    || {
        rc=$?
        log "ERROR: apple_mail_mbox emit failed (exit $rc); leaving checkpoint untouched."
        exit "$rc"
    }

# Skip the ingest leg if the emitter produced no work this tick.
# `-s` is "exists and non-empty"; the emitter declines to create the
# file when there is nothing to write.
if [ ! -s "$MBOX" ]; then
    log "no new messages this tick, skipping ingest"
    # Tidy up an empty file if one was created (defence in depth).
    [ -f "$MBOX" ] && rm -f "$MBOX"
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. Hand the mbox to CM046's email adapter -> CM048
# ---------------------------------------------------------------------------

# pwg-email-ingest is CM046's CLI entry point. It threads + cleans
# the mbox and writes per-conversation state directories that CM048
# then promotes into Qdrant + Oxigraph + the conversation MDs.
#
# CX-115g (2026-05-30): under the LaunchAgent, PATH is the default
# system PATH (/usr/bin:/bin:...), which does not include the
# email-ingest venv bin where pwg-email-ingest actually lives. The
# install never symlinks the CLI into /usr/local/bin either, so
# `pwg-email-ingest` is unresolvable and the tick exits 127 every
# hour. Derive the venv-local path from OSTLER_PYTHON (which IS
# correctly set to the venv python via plist EnvironmentVariables)
# so the CLI is reachable without depending on PATH.
if [ -z "${PWG_EMAIL_INGEST:-}" ]; then
    if [ -n "${OSTLER_PYTHON:-}" ] && [ -x "$(dirname "$OSTLER_PYTHON")/pwg-email-ingest" ]; then
        PWG_EMAIL_INGEST="$(dirname "$OSTLER_PYTHON")/pwg-email-ingest"
    else
        PWG_EMAIL_INGEST="pwg-email-ingest"
    fi
fi

if [ ! -x "$PWG_EMAIL_INGEST" ] && ! command -v "$PWG_EMAIL_INGEST" >/dev/null 2>&1; then
    log "ERROR: $PWG_EMAIL_INGEST is not executable or on PATH. CM046 not installed?"
    log "       The mbox at $MBOX is preserved; re-run after install."
    exit 127
fi

"$PWG_EMAIL_INGEST" mbox "$MBOX" || {
    rc=$?
    log "ERROR: pwg-email-ingest failed (exit $rc); mbox preserved at $MBOX."
    exit "$rc"
}

log "ingested $MBOX successfully"

# ---------------------------------------------------------------------------
# 3. Mark first_ingest_complete_ts (#260)
# ---------------------------------------------------------------------------
#
# On the first tick that successfully ingests a non-empty mbox we
# stamp ~/.ostler/state/pipeline_signals.json with
# first_ingest_complete_ts. The Doctor backfill-progress diagnostic
# uses this sentinel to distinguish "no ingest has ever happened" (the
# #259 banner case) from "ingest is up and running and backfill is
# still climbing." The mark_first_ingest helper is idempotent --
# subsequent ticks see the key already set and exit 0 without
# touching disk.
#
# Failure here is NON-FATAL. The mbox already ingested cleanly; the
# customer's data is safe. We log loudly so the LaunchAgent err log
# captures the diagnostic, but we don't exit non-zero (which would
# cause launchd to flag the agent as failing and would obscure the
# fact that the ingest itself succeeded).
SIDECAR="$OSTLER_DIR/state/pipeline_signals.json"
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MARK_FIRST_INGEST="${OSTLER_MARK_FIRST_INGEST:-$SCRIPT_DIR_REAL/mark_first_ingest.py}"

if [ -f "$MARK_FIRST_INGEST" ]; then
    "$OSTLER_PYTHON" "$MARK_FIRST_INGEST" --sidecar "$SIDECAR" || {
        rc=$?
        log "WARNING: mark_first_ingest exited $rc; pipeline_signals.json not updated."
        log "         The ingest itself succeeded; Doctor backfill-progress may stay quiet for one more tick."
    }
else
    log "WARNING: mark_first_ingest helper not found at $MARK_FIRST_INGEST; skipping first-ingest stamp."
fi
