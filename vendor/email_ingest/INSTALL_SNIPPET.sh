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

# Ingest-reroute (v1.0.10): ProgramArguments[0] is the SHIPPED,
# code-signed daemon binary INSIDE the .app bundle -- the FDA holder --
# so `run-source email-ingest` forks the tick as its child and the
# protected Apple Mail read inherits Full Disk Access. A distinct token
# (OSTLER_ASSISTANT_BINARY) because OSTLER_BIN here == $OSTLER_DIR/bin,
# the wrong (legacy, non-FDA) path.
esc_assistant="$(printf '%s' "$OSTLER_DIR/OstlerAssistant.app/Contents/MacOS/ostler-assistant" | sed 's/[&/\]/\\&/g')"

# OSTLER_VENV_PYTHON: absolute path to a python3 binary that has
# `ostler_fda` installed (created by CM051 install.sh's email-ingest
# venv setup). Falling back to the bare literal "python3" is a LAST
# resort and is logged: launchd does not use a login PATH, so a bare
# name may not resolve at all under it.
# Reference: CX-17 (retest 2026-05-23) — system python lookup was
# the launch-blocker root cause.
OSTLER_PYTHON_PATH_VALUE="${OSTLER_VENV_PYTHON:-python3}"
if [[ "$OSTLER_PYTHON_PATH_VALUE" != /* ]]; then
    echo "email-ingest install: WARNING - interpreter '$OSTLER_PYTHON_PATH_VALUE'" >&2
    echo "  is not an absolute path. launchd runs with a minimal PATH, so the" >&2
    echo "  hourly tick's emit leg will likely fail with ModuleNotFoundError." >&2
    echo "  Expected: the email-ingest venv python from CM051 install.sh." >&2
fi
esc_python="$(printf '%s' "$OSTLER_PYTHON_PATH_VALUE"        | sed 's/[&/\]/\\&/g')"

# OSTLER_EMAIL_INGEST_BIN: absolute path to CM021's pwg-email-ingest
# console script inside the email-ingest venv (created by CM051
# install.sh's CM021 pip-install). Rendered into the plist's
# PWG_EMAIL_INGEST env var so the tick's ingest leg resolves the binary
# under launchd's minimal PATH. If unset/empty we fall back to the
# literal "pwg-email-ingest" so a dev run with the venv on PATH still
# works; the tick's LOUD guard then fails the tick if the binary is
# genuinely absent rather than dropping harvested mail silently.
# This is the sibling fix to OSTLER_VENV_PYTHON: that wired the emit
# leg's interpreter, this wires the ingest leg's binary. Without it the
# emit leg succeeded and EVERY harvested message was dropped at the
# ingest leg with "not on PATH" / exit 127.
OSTLER_EMAIL_INGEST_BIN_VALUE="${OSTLER_EMAIL_INGEST_BIN:-pwg-email-ingest}"
esc_ingest="$(printf '%s' "$OSTLER_EMAIL_INGEST_BIN_VALUE"   | sed 's/[&/\]/\\&/g')"

# PWG_EMAIL_INGEST_PATH is rendered before OSTLER_PYTHON_PATH purely for
# readability; the two placeholders share no common substring so the
# order is byte-safe either way.
sed \
    -e "s/OSTLER_ASSISTANT_BINARY/$esc_assistant/g" \
    -e "s/OSTLER_BIN/$esc_bin/g" \
    -e "s/OSTLER_HOME/$esc_home/g" \
    -e "s/OSTLER_LOGS/$esc_logs/g" \
    -e "s/PWG_EMAIL_INGEST_PATH/$esc_ingest/g" \
    -e "s/OSTLER_PYTHON_PATH/$esc_python/g" \
    "$EMAIL_INGEST_PLIST_SRC" > "$RENDERED_PLIST"

chmod 0644 "$RENDERED_PLIST"

# ---------------------------------------------------------------------------
# 4. Load via launchctl bootstrap (idempotent: bootout if already loaded)
# ---------------------------------------------------------------------------

LABEL="com.creativemachines.ostler.email-ingest"
DOMAIN="gui/$(id -u)"

# ---------------------------------------------------------------------------
# PRE-BOOTSTRAP GUARD: never load an agent that cannot possibly run.
# ---------------------------------------------------------------------------
# ProgramArguments[0] is the code-signed assistant binary inside the .app
# (the FDA holder). launchd resolves it at BOOTSTRAP time and this plist has
# RunAtLoad=true, so bootstrapping while that binary is absent makes launchd
# fire the tick immediately, fail to exec, and return EX_CONFIG (78).
#
# EX_CONFIG is not a retry. launchd treats it as "this job is misconfigured",
# records runs=1, and never starts the job again -- StartInterval included.
# Both log files stay 0 bytes because nothing ever executed to write to them,
# so it presents as total silence rather than as an error.
#
# That is exactly what the v1.0.15 box-walk found: email-ingest sitting at
# runs=1 / last exit 78, no mail ingested since install, nothing in any log.
#
# A LaunchAgent that is absent and says so is strictly better than one that is
# present and permanently dead, so if the binary is missing we render the
# plist (ready to load later) and refuse to bootstrap.
ASSISTANT_BINARY="$OSTLER_DIR/OstlerAssistant.app/Contents/MacOS/ostler-assistant"
if [[ ! -x "$ASSISTANT_BINARY" ]]; then
    echo "email-ingest install: REFUSING to bootstrap the LaunchAgent." >&2
    echo "  ProgramArguments[0] does not exist or is not executable:" >&2
    echo "    $ASSISTANT_BINARY" >&2
    echo "" >&2
    echo "  Bootstrapping now would fire RunAtLoad against a missing binary," >&2
    echo "  and launchd would answer EX_CONFIG (78) and disable the job" >&2
    echo "  PERMANENTLY -- no retry, no logs, no mail ever ingested." >&2
    echo "" >&2
    echo "  The plist is rendered and ready at:" >&2
    echo "    $RENDERED_PLIST" >&2
    echo "  Load it once the Ostler app is in place with:" >&2
    echo "    launchctl bootstrap $DOMAIN $RENDERED_PLIST" >&2
    exit 1
fi

# Bootout silently if already loaded; bootstrap is not idempotent on
# its own so we have to flush a stale agent first. Don't fail the
# install if the bootout returns non-zero (unloaded state).
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

# A previous install may have left the job in the EX_CONFIG penalty box.
# bootout above clears that state, so the bootstrap below starts clean.

if launchctl bootstrap "$DOMAIN" "$RENDERED_PLIST"; then
    echo "email-ingest install: LaunchAgent bootstrapped ($LABEL)"
else
    rc=$?
    echo "email-ingest install: bootstrap returned $rc; check ${RENDERED_PLIST} and ${LOGS_DIR}/email-ingest.err" >&2
    exit "$rc"
fi
