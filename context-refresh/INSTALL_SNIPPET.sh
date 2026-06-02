#!/usr/bin/env bash
#
# INSTALL_SNIPPET.sh
#
# Sourced by the CM051 Ostler installer to install the personal-
# context-digest refresh LaunchAgent on the user's Mac (#608). Do
# NOT run standalone unless you know what you are doing -- it writes
# to ~/Library/LaunchAgents/ and calls launchctl.
#
# Mirrors the wiki-recompile INSTALL_SNIPPET.sh shape so the
# installer integration looks symmetric across LaunchAgents.
#
# What this wires up:
#   generate_pwg_context.py (vendored from ostler-assistant) queries
#   the local ical-server and writes CONTEXT.md into the assistant's
#   workspace dir. The assistant daemon injects CONTEXT.md into every
#   system prompt, giving the chat assistant baseline awareness of the
#   customer's personal graph. The LaunchAgent refreshes the digest on
#   login (RunAtLoad) and on a daily schedule.
#
# Inputs (set by the installer before sourcing):
#   OSTLER_INSTALL_ROOT  absolute path to the installed context-
#                        refresh/ dir (defaults to the dir this file
#                        lives in)
#   OSTLER_DIR           artefact root (default ~/.ostler)
#   LOGS_DIR             log directory (default $OSTLER_DIR/logs)
#
# Side effects:
#   - Copies context-refresh-tick.sh + generate_pwg_context.py into
#     $OSTLER_DIR/bin/ (tick chmod 0755)
#   - Renders com.creativemachines.ostler.context-refresh.plist into
#     ~/Library/LaunchAgents/ with placeholders replaced
#   - Loads the LaunchAgent via launchctl bootstrap gui/$(id -u),
#     whose RunAtLoad produces the first CONTEXT.md immediately
#
# British English throughout.

set -euo pipefail

CONTEXT_REFRESH_HOME_RESOLVED="${HOME}"
CONTEXT_REFRESH_INSTALL_ROOT="${OSTLER_INSTALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"

OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"
LOGS_DIR="${LOGS_DIR:-$OSTLER_DIR/logs}"

CONTEXT_REFRESH_TICK_SRC="$CONTEXT_REFRESH_INSTALL_ROOT/bin/context-refresh-tick.sh"
CONTEXT_REFRESH_GENERATOR_SRC="$CONTEXT_REFRESH_INSTALL_ROOT/bin/generate_pwg_context.py"
CONTEXT_REFRESH_PLIST_SRC="$CONTEXT_REFRESH_INSTALL_ROOT/launchd/com.creativemachines.ostler.context-refresh.plist"

if [ ! -f "$CONTEXT_REFRESH_TICK_SRC" ]; then
    echo "context-refresh install: wrapper not found at $CONTEXT_REFRESH_TICK_SRC" >&2
    exit 1
fi
if [ ! -f "$CONTEXT_REFRESH_GENERATOR_SRC" ]; then
    echo "context-refresh install: generator not found at $CONTEXT_REFRESH_GENERATOR_SRC" >&2
    exit 1
fi
if [ ! -f "$CONTEXT_REFRESH_PLIST_SRC" ]; then
    echo "context-refresh install: plist not found at $CONTEXT_REFRESH_PLIST_SRC" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Stage wrapper + generator
# ---------------------------------------------------------------------------

OSTLER_BIN_DIR="$OSTLER_DIR/bin"
mkdir -p "$OSTLER_BIN_DIR"
cp "$CONTEXT_REFRESH_TICK_SRC" "$OSTLER_BIN_DIR/context-refresh-tick.sh"
chmod 0755 "$OSTLER_BIN_DIR/context-refresh-tick.sh"
cp "$CONTEXT_REFRESH_GENERATOR_SRC" "$OSTLER_BIN_DIR/generate_pwg_context.py"
chmod 0644 "$OSTLER_BIN_DIR/generate_pwg_context.py"

# ---------------------------------------------------------------------------
# 2. Stage log dir
# ---------------------------------------------------------------------------

mkdir -p "$LOGS_DIR"

# ---------------------------------------------------------------------------
# 3. Render the plist
# ---------------------------------------------------------------------------

USER_LAUNCH_AGENTS="$CONTEXT_REFRESH_HOME_RESOLVED/Library/LaunchAgents"
mkdir -p "$USER_LAUNCH_AGENTS"
RENDERED_PLIST="$USER_LAUNCH_AGENTS/com.creativemachines.ostler.context-refresh.plist"

esc_bin="$(printf '%s' "$OSTLER_BIN_DIR"                 | sed 's/[&/\]/\\&/g')"
esc_home="$(printf '%s' "$CONTEXT_REFRESH_HOME_RESOLVED" | sed 's/[&/\]/\\&/g')"
esc_logs="$(printf '%s' "$LOGS_DIR"                      | sed 's/[&/\]/\\&/g')"

sed \
    -e "s/OSTLER_BIN/$esc_bin/g" \
    -e "s/OSTLER_HOME/$esc_home/g" \
    -e "s/OSTLER_LOGS/$esc_logs/g" \
    "$CONTEXT_REFRESH_PLIST_SRC" > "$RENDERED_PLIST"

chmod 0644 "$RENDERED_PLIST"

# ---------------------------------------------------------------------------
# 4. Load via launchctl bootstrap (idempotent: bootout if already loaded)
# ---------------------------------------------------------------------------

LABEL="com.creativemachines.ostler.context-refresh"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if launchctl bootstrap "$DOMAIN" "$RENDERED_PLIST"; then
    echo "context-refresh install: LaunchAgent bootstrapped ($LABEL)"
else
    rc=$?
    echo "context-refresh install: bootstrap returned $rc; check ${RENDERED_PLIST} and ${LOGS_DIR}/context-refresh.err" >&2
    exit "$rc"
fi
