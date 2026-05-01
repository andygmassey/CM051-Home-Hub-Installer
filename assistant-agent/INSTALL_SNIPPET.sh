#!/usr/bin/env bash
#
# INSTALL_SNIPPET.sh
#
# Sourced by the CM051 Ostler installer to register the
# ostler-assistant LaunchAgent on the user's Mac. Do NOT run
# standalone unless you know what you are doing -- it writes to
# ~/Library/LaunchAgents/ and calls launchctl.
#
# The binary itself is installed by section 3.14e of install.sh
# BEFORE this snippet is sourced (download tarball, verify SHA-256,
# extract to $OSTLER_DIR/bin/ostler-assistant). This snippet is the
# launchctl half of the install -- mirrors the email-ingest and
# wiki-recompile snippets so the install integration looks
# symmetric across LaunchAgents.
#
# Inputs (set by the installer before sourcing):
#   OSTLER_INSTALL_ROOT      absolute path to the installed
#                            assistant-agent/ dir (defaults to the
#                            dir this file lives in)
#   OSTLER_DIR               artefact root (default ~/.ostler)
#   LOGS_DIR                 log directory (default $OSTLER_DIR/logs)
#   ASSISTANT_CONFIG_DIR     config dir produced by Phase D
#                            (default $OSTLER_DIR/assistant-config)
#
# Side effects:
#   - Renders com.creativemachines.ostler.assistant.plist into
#     ~/Library/LaunchAgents/ with placeholders replaced.
#   - Loads the LaunchAgent via launchctl bootstrap gui/$(id -u).
#
# Refuses to register the LaunchAgent if the binary is missing.
# That is not a silent fallback: a misregistered agent that points
# at a nonexistent binary just thrashes ThrottleInterval forever
# and produces a log file full of "no such file" errors. Better
# to surface the staging gap to the installer than swallow it.
#
# British English throughout.

set -euo pipefail

ASSISTANT_HOME_RESOLVED="${HOME}"
ASSISTANT_INSTALL_ROOT="${OSTLER_INSTALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"

OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"
LOGS_DIR="${LOGS_DIR:-$OSTLER_DIR/logs}"
ASSISTANT_CONFIG_DIR="${ASSISTANT_CONFIG_DIR:-$OSTLER_DIR/assistant-config}"

ASSISTANT_PLIST_SRC="$ASSISTANT_INSTALL_ROOT/launchd/com.creativemachines.ostler.assistant.plist"
ASSISTANT_BINARY="$OSTLER_DIR/bin/ostler-assistant"

if [ ! -f "$ASSISTANT_PLIST_SRC" ]; then
    echo "ostler-assistant install: plist not found at $ASSISTANT_PLIST_SRC" >&2
    exit 1
fi

if [ ! -x "$ASSISTANT_BINARY" ]; then
    echo "ostler-assistant install: binary not staged at $ASSISTANT_BINARY" >&2
    echo "                          Section 3.14e of install.sh should have downloaded" >&2
    echo "                          and extracted the v0.1 release tarball before this" >&2
    echo "                          snippet was sourced. Re-run the installer or stage" >&2
    echo "                          the binary manually before retrying." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Stage log dir
# ---------------------------------------------------------------------------

mkdir -p "$LOGS_DIR"

# ---------------------------------------------------------------------------
# 2. Render the plist
# ---------------------------------------------------------------------------

USER_LAUNCH_AGENTS="$ASSISTANT_HOME_RESOLVED/Library/LaunchAgents"
mkdir -p "$USER_LAUNCH_AGENTS"
RENDERED_PLIST="$USER_LAUNCH_AGENTS/com.creativemachines.ostler.assistant.plist"

esc_bin="$(printf '%s' "$OSTLER_DIR/bin"               | sed 's/[&/\]/\\&/g')"
esc_home="$(printf '%s' "$ASSISTANT_HOME_RESOLVED"     | sed 's/[&/\]/\\&/g')"
esc_logs="$(printf '%s' "$LOGS_DIR"                    | sed 's/[&/\]/\\&/g')"
esc_assistant_cfg="$(printf '%s' "$ASSISTANT_CONFIG_DIR" | sed 's/[&/\]/\\&/g')"

# Order matters: the OSTLER_ASSISTANT_CONFIG token contains the
# OSTLER_HOME prefix in the default install layout
# ($HOME/.ostler/assistant-config). Substitute the most specific
# token first so a later OSTLER_HOME pass cannot eat its prefix.
sed \
    -e "s/OSTLER_ASSISTANT_CONFIG/$esc_assistant_cfg/g" \
    -e "s/OSTLER_LOGS/$esc_logs/g" \
    -e "s/OSTLER_BIN/$esc_bin/g" \
    -e "s/OSTLER_HOME/$esc_home/g" \
    "$ASSISTANT_PLIST_SRC" > "$RENDERED_PLIST"

chmod 0644 "$RENDERED_PLIST"

# ---------------------------------------------------------------------------
# 3. Load via launchctl bootstrap (idempotent: bootout if already loaded)
# ---------------------------------------------------------------------------

LABEL="com.creativemachines.ostler.assistant"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if launchctl bootstrap "$DOMAIN" "$RENDERED_PLIST"; then
    echo "ostler-assistant install: LaunchAgent bootstrapped ($LABEL)"
else
    rc=$?
    echo "ostler-assistant install: bootstrap returned $rc; check ${RENDERED_PLIST} and ${LOGS_DIR}/ostler-assistant.err" >&2
    exit "$rc"
fi
