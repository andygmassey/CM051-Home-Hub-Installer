#!/usr/bin/env bash
#
# INSTALL_SNIPPET.sh
#
# Sourced by the CM051 Ostler installer to install the HR015 WhatsApp
# CONVERSATION-MEMORY LaunchAgent (the four-artefact body feed) on the
# user's Mac. Do NOT run standalone unless you know what you are doing --
# it writes to ~/Library/LaunchAgents/ and calls launchctl.
#
# Mirrors email-ingest/INSTALL_SNIPPET.sh's shape so the installer
# integration in CM051 looks symmetric across LaunchAgents. This is the
# scaffolding pattern the iMessage / email / meeting-voice body feeds
# replicate (step 2).
#
# SEPARATE from the hydrate_whatsapp install sub-phase, which runs
# ostler_fda.whatsapp_history for people-graph FACTS (metadata only).
# Distinct label, wrapper, venv, state file, output, so the two feeds
# never collide. This feed reads message BODIES; hydrate never does.
#
# Inputs (set by the installer before sourcing):
#   OSTLER_INSTALL_ROOT       absolute path to the installed whatsapp_source/
#                             dir (defaults to the dir this file lives in)
#   OSTLER_DIR                artefact root (default ~/.ostler)
#   LOGS_DIR                  log directory (default $OSTLER_DIR/logs)
#   OSTLER_VENV_PYTHON        absolute path to the whatsapp-source venv
#                             python3 (has ostler_fda + pyyaml). Falls back
#                             to literal "python3" if unset (degraded but
#                             the agent still loads).
#   OSTLER_WA_SOURCE_DIR      parent of the whatsapp_source package the
#                             wrapper cd's into (default
#                             $OSTLER_DIR/services/whatsapp-source)
#   OSTLER_WA_PWG_CONVO_CMD   absolute pwg-convo invocation (CM048 venv).
#                             The pipeline appends "process <t> <m>" itself.
#   OSTLER_WA_USER_NAME       operator display name (own messages -> "You")
#
# Side effects:
#   - Copies whatsapp-bundle-tick.sh into $OSTLER_DIR/bin/ (chmod 0755)
#   - Ensures $OSTLER_DIR/workspace exists (watermark state file)
#   - Renders com.creativemachines.ostler.whatsapp-bundle.plist into
#     ~/Library/LaunchAgents/ with placeholders replaced
#   - Loads the LaunchAgent via launchctl bootstrap gui/$(id -u)
#
# British English throughout.

set -euo pipefail

WA_HOME_RESOLVED="${HOME}"
WA_INSTALL_ROOT="${OSTLER_INSTALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"

# Artefact roots. The installer sets these; we default for a manual
# run during dev.
OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"
LOGS_DIR="${LOGS_DIR:-$OSTLER_DIR/logs}"

WA_BIN_SRC="$WA_INSTALL_ROOT/bin/whatsapp-bundle-tick.sh"
WA_PLIST_SRC="$WA_INSTALL_ROOT/launchd/com.creativemachines.ostler.whatsapp-bundle.plist"

if [ ! -f "$WA_BIN_SRC" ]; then
    echo "whatsapp-bundle install: wrapper not found at $WA_BIN_SRC" >&2
    exit 1
fi
if [ ! -f "$WA_PLIST_SRC" ]; then
    echo "whatsapp-bundle install: plist not found at $WA_PLIST_SRC" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Stage wrapper script (verbatim -- all config rides plist env)
# ---------------------------------------------------------------------------

OSTLER_BIN_DIR="$OSTLER_DIR/bin"
mkdir -p "$OSTLER_BIN_DIR"
cp "$WA_BIN_SRC" "$OSTLER_BIN_DIR/whatsapp-bundle-tick.sh"
chmod 0755 "$OSTLER_BIN_DIR/whatsapp-bundle-tick.sh"

# ---------------------------------------------------------------------------
# 2. Stage workspace (watermark) + log dir so the first tick can write
# ---------------------------------------------------------------------------

mkdir -p "$LOGS_DIR"
mkdir -p "$OSTLER_DIR/workspace"

# ---------------------------------------------------------------------------
# 3. Render the plist
# ---------------------------------------------------------------------------

USER_LAUNCH_AGENTS="$WA_HOME_RESOLVED/Library/LaunchAgents"
mkdir -p "$USER_LAUNCH_AGENTS"
RENDERED_PLIST="$USER_LAUNCH_AGENTS/com.creativemachines.ostler.whatsapp-bundle.plist"

# whatsapp-source venv python3 (has ostler_fda + pyyaml). Fall back to
# the literal "python3" so the agent still loads if the venv setup
# upstream failed -- the wrapper then errors at runtime with a clear
# ModuleNotFoundError rather than the LaunchAgent never installing.
WA_PYTHON_VALUE="${OSTLER_VENV_PYTHON:-python3}"
WA_SOURCE_DIR_VALUE="${OSTLER_WA_SOURCE_DIR:-$OSTLER_DIR/services/whatsapp-source}"
WA_PWG_CONVO_VALUE="${OSTLER_WA_PWG_CONVO_CMD:-pwg-convo}"
WA_USER_NAME_VALUE="${OSTLER_WA_USER_NAME:-You}"

esc_bin="$(printf '%s' "$OSTLER_BIN_DIR"        | sed 's/[&/\]/\\&/g')"
esc_home="$(printf '%s' "$WA_HOME_RESOLVED"     | sed 's/[&/\]/\\&/g')"
esc_logs="$(printf '%s' "$LOGS_DIR"             | sed 's/[&/\]/\\&/g')"
esc_python="$(printf '%s' "$WA_PYTHON_VALUE"    | sed 's/[&/\]/\\&/g')"
esc_pwg="$(printf '%s' "$WA_PWG_CONVO_VALUE"     | sed 's/[&/\]/\\&/g')"
esc_srcdir="$(printf '%s' "$WA_SOURCE_DIR_VALUE" | sed 's/[&/\]/\\&/g')"
esc_username="$(printf '%s' "$WA_USER_NAME_VALUE" | sed 's/[&/\]/\\&/g')"

# Order: render the _VALUE / _PATH placeholders before the bare base
# placeholders so no substring of a longer placeholder is clobbered.
# (The plist <key> names -- OSTLER_PYTHON, PWG_CONVO_CMD,
# OSTLER_SOURCE_DIR, OSTLER_USER_DISPLAY_NAME -- carry no _VALUE/_PATH
# suffix, so they are never matched here.)
sed \
    -e "s/OSTLER_PYTHON_PATH/$esc_python/g" \
    -e "s/PWG_CONVO_CMD_VALUE/$esc_pwg/g" \
    -e "s/OSTLER_SOURCE_DIR_VALUE/$esc_srcdir/g" \
    -e "s/OSTLER_USER_DISPLAY_NAME_VALUE/$esc_username/g" \
    -e "s/OSTLER_BIN/$esc_bin/g" \
    -e "s/OSTLER_HOME/$esc_home/g" \
    -e "s/OSTLER_LOGS/$esc_logs/g" \
    "$WA_PLIST_SRC" > "$RENDERED_PLIST"

chmod 0644 "$RENDERED_PLIST"

# ---------------------------------------------------------------------------
# 4. Load via launchctl bootstrap (idempotent: bootout if already loaded)
# ---------------------------------------------------------------------------

LABEL="com.creativemachines.ostler.whatsapp-bundle"
DOMAIN="gui/$(id -u)"

# Bootout silently if already loaded; bootstrap is not idempotent on
# its own so we have to flush a stale agent first. Don't fail the
# install if the bootout returns non-zero (unloaded state).
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if launchctl bootstrap "$DOMAIN" "$RENDERED_PLIST"; then
    echo "whatsapp-bundle install: LaunchAgent bootstrapped ($LABEL)"
else
    rc=$?
    echo "whatsapp-bundle install: bootstrap returned $rc; check ${RENDERED_PLIST} and ${LOGS_DIR}/whatsapp-bundle.err" >&2
    exit "$rc"
fi
