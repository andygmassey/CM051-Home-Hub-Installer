#!/usr/bin/env bash
#
# INSTALL_SNIPPET.sh
#
# Sourced by the CM051 Ostler installer to install the iMessage bridge
# LaunchAgent on the customer's Mac. Do NOT run standalone unless you
# know what you are doing -- it writes to ~/Library/LaunchAgents/, to
# /Users/Shared/imessage-bridge/, and calls launchctl.
#
# Mirrors email-ingest/INSTALL_SNIPPET.sh's shape so the installer
# integration in CM051 looks symmetric across LaunchAgents.
#
# Inputs (set by the installer before sourcing):
#   OSTLER_INSTALL_ROOT  absolute path to the installed imessage-bridge/
#                        dir (defaults to the dir this file lives in)
#   OSTLER_DIR           artefact root (default ~/.ostler)
#   LOGS_DIR             log directory (default $OSTLER_DIR/logs)
#   OSTLER_PYTHON        python interpreter (default python3)
#
# Side effects:
#   - Copies bridge.py into $OSTLER_DIR/bin/ (chmod 0755)
#   - Creates /Users/Shared/imessage-bridge/ (mode 0775)
#   - Renders com.ostler.imessage-bridge.plist into
#     ~/Library/LaunchAgents/ with placeholders replaced
#   - Loads the LaunchAgent via launchctl bootstrap gui/$(id -u)
#
# British English throughout.

set -euo pipefail

IMESSAGE_BRIDGE_HOME_RESOLVED="${HOME}"
IMESSAGE_BRIDGE_INSTALL_ROOT="${OSTLER_INSTALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"

# Artefact roots. The installer sets these; we default for a manual run.
OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"
LOGS_DIR="${LOGS_DIR:-$OSTLER_DIR/logs}"
OSTLER_PYTHON="${OSTLER_PYTHON:-python3}"

IMESSAGE_BRIDGE_PY_SRC="$IMESSAGE_BRIDGE_INSTALL_ROOT/bin/bridge.py"
IMESSAGE_BRIDGE_PLIST_SRC="$IMESSAGE_BRIDGE_INSTALL_ROOT/launchd/com.ostler.imessage-bridge.plist"

if [ ! -f "$IMESSAGE_BRIDGE_PY_SRC" ]; then
    echo "imessage-bridge install: producer not found at $IMESSAGE_BRIDGE_PY_SRC" >&2
    exit 1
fi
if [ ! -f "$IMESSAGE_BRIDGE_PLIST_SRC" ]; then
    echo "imessage-bridge install: plist not found at $IMESSAGE_BRIDGE_PLIST_SRC" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Stage producer script
# ---------------------------------------------------------------------------

OSTLER_BIN_DIR="$OSTLER_DIR/bin"
mkdir -p "$OSTLER_BIN_DIR"
cp "$IMESSAGE_BRIDGE_PY_SRC" "$OSTLER_BIN_DIR/bridge.py"
chmod 0755 "$OSTLER_BIN_DIR/bridge.py"

# ---------------------------------------------------------------------------
# 2. Stage drain directory at /Users/Shared/imessage-bridge/
# ---------------------------------------------------------------------------
#
# /Users/Shared/ is world-readable on stock macOS. The directory mode
# is 0775 so any local user can read inbox.jsonl (the assistant runs
# under the same account as the installer in v1.0 single-user mode;
# this leaves the door open for future split-identity installs without
# requiring an installer re-run). We do NOT set the sticky bit; if a
# future split-identity install adds a separate assistant account,
# that PR layers the sticky bit + an explicit group ACL on top.

SHARED_BRIDGE_DIR="/Users/Shared/imessage-bridge"
if [ ! -d "$SHARED_BRIDGE_DIR" ]; then
    mkdir -p "$SHARED_BRIDGE_DIR"
    chmod 0775 "$SHARED_BRIDGE_DIR"
fi

# Ensure the LaunchAgent can write to the drain even on a fresh install
# where the directory was created above. mkdir under /Users/Shared/ is
# allowed for any user; chmod is a no-op if the directory already
# existed with the expected mode.
chmod 0775 "$SHARED_BRIDGE_DIR" || true

# ---------------------------------------------------------------------------
# 3. Stage log dir so the first tick has somewhere to write
# ---------------------------------------------------------------------------

mkdir -p "$LOGS_DIR"

# ---------------------------------------------------------------------------
# 4. Render the plist
# ---------------------------------------------------------------------------

USER_LAUNCH_AGENTS="$IMESSAGE_BRIDGE_HOME_RESOLVED/Library/LaunchAgents"
mkdir -p "$USER_LAUNCH_AGENTS"
RENDERED_PLIST="$USER_LAUNCH_AGENTS/com.ostler.imessage-bridge.plist"

# Resolve the python interpreter to its absolute path so the
# LaunchAgent does not depend on PATH at load time.
if PYTHON_ABS="$(command -v "$OSTLER_PYTHON" 2>/dev/null)"; then
    OSTLER_PYTHON_RESOLVED="$PYTHON_ABS"
else
    OSTLER_PYTHON_RESOLVED="/usr/bin/python3"
fi

esc_bin="$(printf '%s' "$OSTLER_BIN_DIR"                   | sed 's/[&/\]/\\&/g')"
esc_home="$(printf '%s' "$IMESSAGE_BRIDGE_HOME_RESOLVED"    | sed 's/[&/\]/\\&/g')"
esc_logs="$(printf '%s' "$LOGS_DIR"                         | sed 's/[&/\]/\\&/g')"
esc_python="$(printf '%s' "$OSTLER_PYTHON_RESOLVED"         | sed 's/[&/\]/\\&/g')"

sed \
    -e "s/OSTLER_BIN/$esc_bin/g" \
    -e "s/OSTLER_HOME/$esc_home/g" \
    -e "s/OSTLER_LOGS/$esc_logs/g" \
    -e "s/OSTLER_PYTHON/$esc_python/g" \
    "$IMESSAGE_BRIDGE_PLIST_SRC" > "$RENDERED_PLIST"

chmod 0644 "$RENDERED_PLIST"

# Syntactic sanity check. plutil -lint catches XML parse / DTD errors
# before launchctl tries (and silently fails) to load the agent.
if command -v plutil >/dev/null 2>&1; then
    if ! plutil -lint "$RENDERED_PLIST" >/dev/null 2>&1; then
        echo "imessage-bridge install: rendered plist failed plutil -lint" >&2
        plutil -lint "$RENDERED_PLIST" >&2 || true
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 5. Load via launchctl bootstrap (idempotent: bootout if already loaded)
# ---------------------------------------------------------------------------

LABEL="com.ostler.imessage-bridge"
DOMAIN="gui/$(id -u)"

# Bootout silently if already loaded; bootstrap is not idempotent on
# its own so we have to flush a stale agent first. Don't fail the
# install if the bootout returns non-zero (unloaded state).
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if launchctl bootstrap "$DOMAIN" "$RENDERED_PLIST"; then
    echo "imessage-bridge install: LaunchAgent bootstrapped ($LABEL)"
else
    rc=$?
    echo "imessage-bridge install: bootstrap returned $rc; check ${RENDERED_PLIST} and ${LOGS_DIR}/imessage-bridge.err" >&2
    exit "$rc"
fi
