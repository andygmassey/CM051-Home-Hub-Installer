#!/usr/bin/env bash
#
# INSTALL_SNIPPET.sh
#
# Sourced by the CM051 Ostler installer to install the Hub power policy
# LaunchAgent on the user's Mac. Do NOT run standalone unless you know what
# you are doing – it writes to ~/Library/LaunchAgents/ and calls launchctl.
#
# Inputs (set by the installer before sourcing):
#   OSTLER_INSTALL_ROOT    absolute path to the installed hub-power/ dir
#                          (defaults to the dir this file lives in)
#
# Side effects:
#   - Copies com.creativemachines.ostler.hub-power.plist into
#     ~/Library/LaunchAgents/ with placeholders replaced
#   - Loads the LaunchAgent via launchctl bootstrap
#   - Creates ~/.ostler/ if absent (with default power.conf)
#
# British English throughout.

set -euo pipefail

# Resolve install root. The installer may set it; otherwise we infer from
# the snippet's own location.
HUB_POWER_HOME_RESOLVED="${HOME}"
HUB_POWER_INSTALL_ROOT="${OSTLER_INSTALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"

HUB_POWER_BIN_DIR="$HUB_POWER_INSTALL_ROOT/bin"
HUB_POWER_PLIST_SRC="$HUB_POWER_INSTALL_ROOT/launchd/com.creativemachines.ostler.hub-power.plist"

if [ ! -d "$HUB_POWER_BIN_DIR" ]; then
    echo "hub-power install: bin directory not found at $HUB_POWER_BIN_DIR" >&2
    exit 1
fi
if [ ! -f "$HUB_POWER_PLIST_SRC" ]; then
    echo "hub-power install: plist not found at $HUB_POWER_PLIST_SRC" >&2
    exit 1
fi

# Make sure the scripts are executable. The installer may have unpacked from
# a tar that stripped the bits.
chmod 0755 "$HUB_POWER_BIN_DIR"/*.sh

# Ensure ~/.ostler exists with a default power.conf if the user has none.
OSTLER_SETTINGS_DIR="$HUB_POWER_HOME_RESOLVED/.ostler"
mkdir -p "$OSTLER_SETTINGS_DIR"
if [ ! -f "$OSTLER_SETTINGS_DIR/power.conf" ]; then
    cat > "$OSTLER_SETTINGS_DIR/power.conf" <<'EOF'
# Ostler Hub power policy.
#
# Values:
#   normal      - default. Pause PWG + stop Ollama at battery <=30%.
#                 Stop ZeroClaw at battery <=15%.
#   aggressive  - never throttle. Battery life will suffer. Use when you
#                 know you're on mains but macOS thinks you're on battery
#                 (e.g. a dock reporting flaky).
#   eco         - pause at battery <=50%, critical at <=20%. Good for
#                 long travel days when you don't need your assistant alive.
POWER_POLICY=normal
EOF
fi

# Render the plist with the real paths substituted in. We leave the source
# untouched and write the rendered copy to ~/Library/LaunchAgents/.
USER_LAUNCH_AGENTS="$HUB_POWER_HOME_RESOLVED/Library/LaunchAgents"
mkdir -p "$USER_LAUNCH_AGENTS"

RENDERED_PLIST="$USER_LAUNCH_AGENTS/com.creativemachines.ostler.hub-power.plist"

# Simple sed: escape slashes in the paths so sed doesn't choke.
esc_bin="$(printf '%s' "$HUB_POWER_BIN_DIR"           | sed 's/[&/\]/\\&/g')"
esc_home="$(printf '%s' "$HUB_POWER_HOME_RESOLVED"    | sed 's/[&/\]/\\&/g')"

sed \
    -e "s/HUB_POWER_BIN/$esc_bin/g" \
    -e "s/HUB_POWER_HOME/$esc_home/g" \
    "$HUB_POWER_PLIST_SRC" > "$RENDERED_PLIST"

chmod 0644 "$RENDERED_PLIST"

# Load (or reload) the agent.
UID_NUM="$(id -u)"
LABEL="com.creativemachines.ostler.hub-power"

if launchctl list 2>/dev/null | grep -q "$LABEL"; then
    launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || \
        launchctl unload "$RENDERED_PLIST"  2>/dev/null || true
fi

if ! launchctl bootstrap "gui/$UID_NUM" "$RENDERED_PLIST" 2>/dev/null; then
    # Fallback for older macOS where bootstrap isn't accepted.
    launchctl load "$RENDERED_PLIST"
fi

echo "hub-power: installed and loaded (label=$LABEL)"
echo "hub-power: settings at $OSTLER_SETTINGS_DIR/power.conf"
echo "hub-power: log at      $OSTLER_SETTINGS_DIR/hub-power.log"
