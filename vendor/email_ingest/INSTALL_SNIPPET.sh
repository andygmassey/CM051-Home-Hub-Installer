#!/usr/bin/env bash
#
# INSTALL_SNIPPET.sh
#
# Sourced by the CM051 Ostler installer to install the CM046 email-
# ingest LaunchAgent on the user's Mac. Do NOT run standalone unless
# you know what you are doing -- it writes to ~/Library/LaunchAgents/
# and calls launchctl.
#
# Mirrors hub-power/INSTALL_SNIPPET.sh's shape so the installer
# integration in CM051 looks symmetric across LaunchAgents.
#
# Inputs (set by the installer before sourcing):
#   OSTLER_INSTALL_ROOT  absolute path to the installed email-ingest/
#                        dir (defaults to the dir this file lives in)
#   OSTLER_DIR           artefact root (default ~/.ostler)
#   LOGS_DIR             log directory (default $OSTLER_DIR/logs)
#
# Side effects:
#   - Copies email-ingest-tick.sh into $OSTLER_DIR/bin/ (chmod 0755)
#   - Renders com.creativemachines.ostler.email-ingest.plist into
#     ~/Library/LaunchAgents/ with placeholders replaced
#   - Loads the LaunchAgent via launchctl bootstrap gui/$(id -u)
#
# British English throughout.

set -euo pipefail

EMAIL_INGEST_HOME_RESOLVED="${HOME}"
EMAIL_INGEST_INSTALL_ROOT="${OSTLER_INSTALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"

# Artefact roots. The installer sets these; we default for a manual
# run during dev.
OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"
LOGS_DIR="${LOGS_DIR:-$OSTLER_DIR/logs}"

EMAIL_INGEST_BIN_SRC="$EMAIL_INGEST_INSTALL_ROOT/bin/email-ingest-tick.sh"
EMAIL_INGEST_PLIST_SRC="$EMAIL_INGEST_INSTALL_ROOT/launchd/com.creativemachines.ostler.email-ingest.plist"

if [ ! -f "$EMAIL_INGEST_BIN_SRC" ]; then
    echo "email-ingest install: wrapper not found at $EMAIL_INGEST_BIN_SRC" >&2
    exit 1
fi
if [ ! -f "$EMAIL_INGEST_PLIST_SRC" ]; then
    echo "email-ingest install: plist not found at $EMAIL_INGEST_PLIST_SRC" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Stage wrapper script
# ---------------------------------------------------------------------------

OSTLER_BIN_DIR="$OSTLER_DIR/bin"
mkdir -p "$OSTLER_BIN_DIR"
cp "$EMAIL_INGEST_BIN_SRC" "$OSTLER_BIN_DIR/email-ingest-tick.sh"
chmod 0755 "$OSTLER_BIN_DIR/email-ingest-tick.sh"

# #259 rescan helper. Customer-runnable; fix_command for the
# Doctor empty-Mail banner. Idempotent launchctl kickstart.
EMAIL_INGEST_RESCAN_SRC="$EMAIL_INGEST_INSTALL_ROOT/bin/ostler-rescan-mail"
if [ -f "$EMAIL_INGEST_RESCAN_SRC" ]; then
    cp "$EMAIL_INGEST_RESCAN_SRC" "$OSTLER_BIN_DIR/ostler-rescan-mail"
    chmod 0755 "$OSTLER_BIN_DIR/ostler-rescan-mail"
fi

# #260 mark_first_ingest helper. Called by the tick on the first
# successful non-empty ingest; stamps pipeline_signals.json so the
# Doctor backfill-progress diagnostic can distinguish "no ingest yet"
# from "ingest running, backfill climbing". Optional -- the tick
# logs a warning and continues if the helper is missing.
MARK_FIRST_INGEST_SRC="$EMAIL_INGEST_INSTALL_ROOT/bin/mark_first_ingest.py"
if [ -f "$MARK_FIRST_INGEST_SRC" ]; then
    cp "$MARK_FIRST_INGEST_SRC" "$OSTLER_BIN_DIR/mark_first_ingest.py"
    chmod 0755 "$OSTLER_BIN_DIR/mark_first_ingest.py"
fi

# ---------------------------------------------------------------------------
# 2. Stage log dir + imports dir so the first tick has somewhere to write
# ---------------------------------------------------------------------------

mkdir -p "$LOGS_DIR"
mkdir -p "$OSTLER_DIR/imports/email"
mkdir -p "$OSTLER_DIR/state"

# ---------------------------------------------------------------------------
# 3. Render the plist
# ---------------------------------------------------------------------------

USER_LAUNCH_AGENTS="$EMAIL_INGEST_HOME_RESOLVED/Library/LaunchAgents"
mkdir -p "$USER_LAUNCH_AGENTS"
RENDERED_PLIST="$USER_LAUNCH_AGENTS/com.creativemachines.ostler.email-ingest.plist"

esc_bin="$(printf '%s' "$OSTLER_BIN_DIR"                    | sed 's/[&/\]/\\&/g')"
esc_home="$(printf '%s' "$EMAIL_INGEST_HOME_RESOLVED"        | sed 's/[&/\]/\\&/g')"
esc_logs="$(printf '%s' "$LOGS_DIR"                          | sed 's/[&/\]/\\&/g')"

# OSTLER_VENV_PYTHON: absolute path to a python3 binary that has
# `ostler_fda` installed (created by CM051 install.sh's email-ingest
# venv setup). If unset/empty we fall back to the literal "python3"
# so the tick script's PATH-based default kicks in; the operator
# will see a ModuleNotFoundError at runtime, but the LaunchAgent
# itself still loads, which is the degraded-but-survivable shape.
# Reference: CX-17 (retest 2026-05-23) — system python lookup was
# the launch-blocker root cause.
OSTLER_PYTHON_PATH_VALUE="${OSTLER_VENV_PYTHON:-python3}"
esc_python="$(printf '%s' "$OSTLER_PYTHON_PATH_VALUE"        | sed 's/[&/\]/\\&/g')"

sed \
    -e "s/OSTLER_BIN/$esc_bin/g" \
    -e "s/OSTLER_HOME/$esc_home/g" \
    -e "s/OSTLER_LOGS/$esc_logs/g" \
    -e "s/OSTLER_PYTHON_PATH/$esc_python/g" \
    "$EMAIL_INGEST_PLIST_SRC" > "$RENDERED_PLIST"

chmod 0644 "$RENDERED_PLIST"

# ---------------------------------------------------------------------------
# 4. Load via launchctl bootstrap (idempotent: bootout if already loaded)
# ---------------------------------------------------------------------------

LABEL="com.creativemachines.ostler.email-ingest"
DOMAIN="gui/$(id -u)"

# Bootout silently if already loaded; bootstrap is not idempotent on
# its own so we have to flush a stale agent first. Don't fail the
# install if the bootout returns non-zero (unloaded state).
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if launchctl bootstrap "$DOMAIN" "$RENDERED_PLIST"; then
    echo "email-ingest install: LaunchAgent bootstrapped ($LABEL)"
else
    rc=$?
    echo "email-ingest install: bootstrap returned $rc; check ${RENDERED_PLIST} and ${LOGS_DIR}/email-ingest.err" >&2
    exit "$rc"
fi
