#!/usr/bin/env bash
#
# INSTALL_SNIPPET.sh
#
# Sourced by the CM051 Ostler installer to install the wiki-
# recompile LaunchAgent on the user's Mac. Do NOT run standalone
# unless you know what you are doing -- it writes to
# ~/Library/LaunchAgents/ and calls launchctl.
#
# Mirrors hub-power and email-ingest INSTALL_SNIPPET.sh shape so
# the installer integration looks symmetric across LaunchAgents.
#
# Inputs (set by the installer before sourcing):
#   OSTLER_INSTALL_ROOT  absolute path to the installed wiki-
#                        recompile/ dir (defaults to the dir this
#                        file lives in)
#   OSTLER_DIR           artefact root (default ~/.ostler)
#   LOGS_DIR             log directory (default $OSTLER_DIR/logs)
#
# Side effects:
#   - Copies wiki-recompile-tick.sh into $OSTLER_DIR/bin/ (chmod 0755)
#   - Renders com.creativemachines.ostler.wiki-recompile.plist into
#     ~/Library/LaunchAgents/ with placeholders replaced
#   - Loads the LaunchAgent via launchctl bootstrap gui/$(id -u)
#
# British English throughout.

set -euo pipefail

WIKI_RECOMPILE_HOME_RESOLVED="${HOME}"
WIKI_RECOMPILE_INSTALL_ROOT="${OSTLER_INSTALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"

OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"
LOGS_DIR="${LOGS_DIR:-$OSTLER_DIR/logs}"

WIKI_RECOMPILE_BIN_SRC="$WIKI_RECOMPILE_INSTALL_ROOT/bin/wiki-recompile-tick.sh"
WIKI_RECOMPILE_PLIST_SRC="$WIKI_RECOMPILE_INSTALL_ROOT/launchd/com.creativemachines.ostler.wiki-recompile.plist"

if [ ! -f "$WIKI_RECOMPILE_BIN_SRC" ]; then
    echo "wiki-recompile install: wrapper not found at $WIKI_RECOMPILE_BIN_SRC" >&2
    exit 1
fi
if [ ! -f "$WIKI_RECOMPILE_PLIST_SRC" ]; then
    echo "wiki-recompile install: plist not found at $WIKI_RECOMPILE_PLIST_SRC" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Stage wrapper script
# ---------------------------------------------------------------------------

OSTLER_BIN_DIR="$OSTLER_DIR/bin"
mkdir -p "$OSTLER_BIN_DIR"
cp "$WIKI_RECOMPILE_BIN_SRC" "$OSTLER_BIN_DIR/wiki-recompile-tick.sh"
chmod 0755 "$OSTLER_BIN_DIR/wiki-recompile-tick.sh"

# ---------------------------------------------------------------------------
# 2. Stage log dir
# ---------------------------------------------------------------------------

mkdir -p "$LOGS_DIR"

# ---------------------------------------------------------------------------
# 3. Render the plist
# ---------------------------------------------------------------------------

USER_LAUNCH_AGENTS="$WIKI_RECOMPILE_HOME_RESOLVED/Library/LaunchAgents"
mkdir -p "$USER_LAUNCH_AGENTS"
RENDERED_PLIST="$USER_LAUNCH_AGENTS/com.creativemachines.ostler.wiki-recompile.plist"

esc_bin="$(printf '%s' "$OSTLER_BIN_DIR"                | sed 's/[&/\]/\\&/g')"
esc_home="$(printf '%s' "$WIKI_RECOMPILE_HOME_RESOLVED"  | sed 's/[&/\]/\\&/g')"
esc_logs="$(printf '%s' "$LOGS_DIR"                      | sed 's/[&/\]/\\&/g')"

sed \
    -e "s/OSTLER_BIN/$esc_bin/g" \
    -e "s/OSTLER_HOME/$esc_home/g" \
    -e "s/OSTLER_LOGS/$esc_logs/g" \
    "$WIKI_RECOMPILE_PLIST_SRC" > "$RENDERED_PLIST"

chmod 0644 "$RENDERED_PLIST"

# ---------------------------------------------------------------------------
# 4. Load via launchctl bootstrap (idempotent: bootout if already loaded)
# ---------------------------------------------------------------------------

LABEL="com.creativemachines.ostler.wiki-recompile"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if launchctl bootstrap "$DOMAIN" "$RENDERED_PLIST"; then
    echo "wiki-recompile install: LaunchAgent bootstrapped ($LABEL)"
else
    rc=$?
    echo "wiki-recompile install: bootstrap returned $rc; check ${RENDERED_PLIST} and ${LOGS_DIR}/wiki-recompile.err" >&2
    exit "$rc"
fi
