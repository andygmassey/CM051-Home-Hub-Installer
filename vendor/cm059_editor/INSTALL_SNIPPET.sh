#!/usr/bin/env bash
#
# INSTALL_SNIPPET.sh  (vendor/cm059_editor)
#
# Sourced by the CM051 Ostler installer to install The Editor's Front Page
# refresh LaunchAgent (CM059). Do NOT run standalone unless you know what
# you are doing -- it writes to ~/Library/LaunchAgents/ and calls launchctl.
#
# Mirrors the wiki-recompile / email-ingest INSTALL_SNIPPET.sh shape so the
# installer integration looks symmetric across LaunchAgents.
#
# Inputs (set by the installer before sourcing):
#   OSTLER_INSTALL_ROOT  absolute path to the installed cm059_editor tree
#                        (defaults to the dir this file lives in). Must
#                        contain compiler/, bin/ and launchd/.
#   OSTLER_DIR           artefact root (default ~/.ostler)
#   LOGS_DIR             log directory (default $OSTLER_DIR/logs)
#   OSTLER_EDITOR_PYTHON absolute python3 (>=3.10) to run the emitter with.
#                        Falls back to `command -v python3`.
#
# Side effects:
#   - Stages the compiler/ package under $OSTLER_DIR/services/cm059-editor/
#   - Renders editor-frontpage-tick.sh into $OSTLER_DIR/bin/ (chmod 0755)
#     with the python + source-dir placeholders substituted
#   - Renders com.creativemachines.ostler.editor-frontpage.plist into
#     ~/Library/LaunchAgents/ with the OSTLER_BIN/HOME/LOGS placeholders
#   - Loads the LaunchAgent via launchctl bootstrap gui/$(id -u); RunAtLoad
#     fires the first emit, so front_page.json exists straight away.
#
# British English throughout.

set -euo pipefail

EDITOR_HOME_RESOLVED="${HOME}"
EDITOR_INSTALL_ROOT="${OSTLER_INSTALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"

OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"
LOGS_DIR="${LOGS_DIR:-$OSTLER_DIR/logs}"
EDITOR_PYTHON="${OSTLER_EDITOR_PYTHON:-$(command -v python3 || true)}"

EDITOR_TICK_SRC="$EDITOR_INSTALL_ROOT/bin/editor-frontpage-tick.sh"
EDITOR_PLIST_SRC="$EDITOR_INSTALL_ROOT/launchd/com.creativemachines.ostler.editor-frontpage.plist"
EDITOR_PKG_SRC="$EDITOR_INSTALL_ROOT/compiler"

if [ ! -f "$EDITOR_TICK_SRC" ]; then
    echo "editor-frontpage install: wrapper not found at $EDITOR_TICK_SRC" >&2
    exit 1
fi
if [ ! -f "$EDITOR_PLIST_SRC" ]; then
    echo "editor-frontpage install: plist not found at $EDITOR_PLIST_SRC" >&2
    exit 1
fi
if [ ! -f "$EDITOR_PKG_SRC/emit_frontpage.py" ]; then
    echo "editor-frontpage install: compiler package not found at $EDITOR_PKG_SRC" >&2
    exit 1
fi
if [ -z "$EDITOR_PYTHON" ]; then
    echo "editor-frontpage install: no python3 found (set OSTLER_EDITOR_PYTHON)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Stage the compiler/ package (the producer runs with PYTHONPATH here)
# ---------------------------------------------------------------------------

EDITOR_SERVICE_DIR="$OSTLER_DIR/services/cm059-editor"
mkdir -p "$EDITOR_SERVICE_DIR"
# Refresh the staged copy in place (idempotent reinstall).
rm -rf "$EDITOR_SERVICE_DIR/compiler"
cp -R "$EDITOR_PKG_SRC" "$EDITOR_SERVICE_DIR/compiler"

# ---------------------------------------------------------------------------
# 2. Render the tick wrapper (substitute python + source-dir placeholders)
# ---------------------------------------------------------------------------

OSTLER_BIN_DIR="$OSTLER_DIR/bin"
mkdir -p "$OSTLER_BIN_DIR"
mkdir -p "$LOGS_DIR"

esc_py="$(printf '%s' "$EDITOR_PYTHON"       | sed 's/[&/\]/\\&/g')"
esc_src="$(printf '%s' "$EDITOR_SERVICE_DIR"  | sed 's/[&/\]/\\&/g')"

sed \
    -e "s/__OSTLER_PYTHON__/$esc_py/g" \
    -e "s/__OSTLER_SOURCE_DIR__/$esc_src/g" \
    "$EDITOR_TICK_SRC" > "$OSTLER_BIN_DIR/editor-frontpage-tick.sh"
chmod 0755 "$OSTLER_BIN_DIR/editor-frontpage-tick.sh"

# ---------------------------------------------------------------------------
# 3. Render the plist
# ---------------------------------------------------------------------------

USER_LAUNCH_AGENTS="$EDITOR_HOME_RESOLVED/Library/LaunchAgents"
mkdir -p "$USER_LAUNCH_AGENTS"
RENDERED_PLIST="$USER_LAUNCH_AGENTS/com.creativemachines.ostler.editor-frontpage.plist"

esc_bin="$(printf '%s' "$OSTLER_BIN_DIR"        | sed 's/[&/\]/\\&/g')"
esc_home="$(printf '%s' "$EDITOR_HOME_RESOLVED"  | sed 's/[&/\]/\\&/g')"
esc_logs="$(printf '%s' "$LOGS_DIR"              | sed 's/[&/\]/\\&/g')"

sed \
    -e "s/OSTLER_BIN/$esc_bin/g" \
    -e "s/OSTLER_HOME/$esc_home/g" \
    -e "s/OSTLER_LOGS/$esc_logs/g" \
    "$EDITOR_PLIST_SRC" > "$RENDERED_PLIST"

chmod 0644 "$RENDERED_PLIST"

# ---------------------------------------------------------------------------
# 4. Load via launchctl bootstrap (idempotent: bootout if already loaded)
# ---------------------------------------------------------------------------

LABEL="com.creativemachines.ostler.editor-frontpage"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if launchctl bootstrap "$DOMAIN" "$RENDERED_PLIST"; then
    echo "editor-frontpage install: LaunchAgent bootstrapped ($LABEL)"
else
    rc=$?
    echo "editor-frontpage install: bootstrap returned $rc; check ${RENDERED_PLIST} and ${LOGS_DIR}/editor-frontpage.err" >&2
    exit "$rc"
fi
