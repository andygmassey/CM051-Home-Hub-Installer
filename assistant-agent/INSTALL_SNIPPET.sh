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
# extract OstlerAssistant.app to $OSTLER_DIR/OstlerAssistant.app/).
# The inner Mach-O lives at
# $OSTLER_DIR/OstlerAssistant.app/Contents/MacOS/ostler-assistant.
# This snippet is the launchctl half of the install -- mirrors
# the email-ingest and wiki-recompile snippets so the install
# integration looks symmetric across LaunchAgents.
#
# v0.4.3+ shape: the daemon is wrapped in OstlerAssistant.app so
# macOS TCC + Activity Monitor render the Ostler v4 icon. The
# launchd plist points OSTLER_BIN at the inner MacOS dir; the
# runtime semantics are identical to the legacy bare-binary
# shape (launchd execs the Mach-O directly; the bundle wrapper
# exists for metadata surfaces, not for process model).
#
# Inputs (set by the installer before sourcing):
#   OSTLER_INSTALL_ROOT      absolute path to the installed
#                            assistant-agent/ dir (defaults to the
#                            dir this file lives in)
#   OSTLER_DIR               artefact root (default ~/.ostler)
#   LOGS_DIR                 log directory (default $OSTLER_DIR/logs)
#   ASSISTANT_CONFIG_DIR     config dir produced by Phase D
#                            (default $OSTLER_DIR/assistant-config)
#   INSTALL_WHATSAPP_KEEPALIVE  "true" to also install the
#                            whatsapp-keepalive LaunchAgent (kicks
#                            `channel doctor` at 08:50 + 17:50 to
#                            keep the WhatsApp Web socket warm
#                            ahead of the morning brief and evening
#                            wrap). Default unset => skip. Only
#                            meaningful when the customer enabled
#                            the WhatsApp channel during install.
#   OSTLER_IMESSAGE_SELF_HANDLES  the customer's OWN iMessage handles
#                            (comma-separated phone + email), rendered
#                            into the plist EnvironmentVariables so the
#                            daemon's self-echo loop guard is armed
#                            (#646). Default empty => guard inactive
#                            (the daemon's content-based backstop still
#                            applies). Must be the user's own identity
#                            only, NOT the allowed-contacts list.
#   OSTLER_ASSISTANT_DEFER_START  "true" => render + clean up the
#                            LaunchAgent but do NOT bootstrap it, so the
#                            plist's RunAtLoad start does not fire yet.
#                            The installer defers the daemon start until
#                            AFTER the Full Disk Access grant flow so the
#                            FDA-less daemon cannot touch ~/Documents and
#                            raise the per-folder Documents TCC prompt on
#                            top of the FDA windows (BW3-1 pile-up). The
#                            installer bootstraps the agent itself once all
#                            permission flows have finished. Default unset
#                            => bootstrap immediately (legacy behaviour).
#
# Side effects:
#   - Renders com.creativemachines.ostler.assistant.plist into
#     ~/Library/LaunchAgents/ with placeholders replaced.
#   - Loads the LaunchAgent via launchctl bootstrap gui/$(id -u).
#   - Optionally renders + loads
#     com.creativemachines.ostler.whatsapp-keepalive.plist (gated
#     on INSTALL_WHATSAPP_KEEPALIVE).
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
# v0.4.3+ shape: the daemon binary lives inside the .app
# bundle. Resolve the inner MacOS dir + the binary path here so
# the placeholder substitution + executable check below both
# operate on the new layout.
ASSISTANT_APP_BUNDLE="$OSTLER_DIR/OstlerAssistant.app"
ASSISTANT_MACOS_DIR="$ASSISTANT_APP_BUNDLE/Contents/MacOS"
ASSISTANT_BINARY="$ASSISTANT_MACOS_DIR/ostler-assistant"

if [ ! -f "$ASSISTANT_PLIST_SRC" ]; then
    echo "ostler-assistant install: plist not found at $ASSISTANT_PLIST_SRC" >&2
    exit 1
fi

if [ ! -x "$ASSISTANT_BINARY" ]; then
    echo "ostler-assistant install: binary not staged at $ASSISTANT_BINARY" >&2
    echo "                          Section 3.14e of install.sh should have downloaded" >&2
    echo "                          and extracted the release tarball before this" >&2
    echo "                          snippet was sourced. Re-run the installer or stage" >&2
    echo "                          the .app bundle manually before retrying." >&2
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

esc_bin="$(printf '%s' "$ASSISTANT_MACOS_DIR"          | sed 's/[&/\]/\\&/g')"
esc_home="$(printf '%s' "$ASSISTANT_HOME_RESOLVED"     | sed 's/[&/\]/\\&/g')"
esc_logs="$(printf '%s' "$LOGS_DIR"                    | sed 's/[&/\]/\\&/g')"
esc_assistant_cfg="$(printf '%s' "$ASSISTANT_CONFIG_DIR" | sed 's/[&/\]/\\&/g')"

# #646 self-echo loop guard: the customer's OWN iMessage handles
# (comma-separated phone + email), passed in by install.sh from the
# me-card identity captured during the wizard. Rendered into the plist
# EnvironmentVariables so the daemon's OSTLER_IMESSAGE_SELF_HANDLES guard
# is armed and the assistant cannot reply to its own output echoing back.
# Empty/unset is safe: the guard stays inactive and the daemon's
# content-based backstop still applies. The token OSTLER_IMESSAGE_SELF_
# HANDLES_VALUE differs from every other sed pattern (none is a substring
# of it) so its substitution cannot collide with the passes below.
esc_self_handles="$(printf '%s' "${OSTLER_IMESSAGE_SELF_HANDLES:-}" | sed 's/[&/\]/\\&/g')"

# Order matters: the OSTLER_ASSISTANT_CONFIG token contains the
# OSTLER_HOME prefix in the default install layout
# ($HOME/.ostler/assistant-config). Substitute the most specific
# token first so a later OSTLER_HOME pass cannot eat its prefix.
sed \
    -e "s/OSTLER_IMESSAGE_SELF_HANDLES_VALUE/$esc_self_handles/g" \
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

# BW3-1 (2026-07-23): defer the daemon's RunAtLoad start until FDA is
# granted. The rendered plist sets RunAtLoad=true + KeepAlive, so
# `launchctl bootstrap` starts the daemon PROCESS immediately. On a fresh
# install this snippet runs BEFORE the daemon's Full Disk Access has been
# granted (the daemon FDA grant flow runs later in install.sh), so the
# freshly started, FDA-less daemon touches ~/Documents and macOS raises
# the per-folder "OstlerAssistant would like to access files in your
# Documents folder" TCC prompt -- which stacks on top of the FDA grant
# flow (System Settings + Finder + the Allow/Done modal), the window
# pile-up seen on the .98 box-walk. When the installer sets
# OSTLER_ASSISTANT_DEFER_START=true we render + bootout the agent here but
# leave it UNLOADED; install.sh bootstraps it once, after every permission
# flow has finished (see _ostler_start_assistant_daemon in install.sh).
if [ "${OSTLER_ASSISTANT_DEFER_START:-}" = "true" ]; then
    echo "ostler-assistant install: plist rendered; RunAtLoad start deferred until FDA granted ($LABEL)"
elif launchctl bootstrap "$DOMAIN" "$RENDERED_PLIST"; then
    echo "ostler-assistant install: LaunchAgent bootstrapped ($LABEL)"
else
    rc=$?
    echo "ostler-assistant install: bootstrap returned $rc; check ${RENDERED_PLIST} and ${LOGS_DIR}/ostler-assistant.err" >&2
    exit "$rc"
fi

# ---------------------------------------------------------------------------
# 4. Optional: WhatsApp keepalive LaunchAgent
# ---------------------------------------------------------------------------
#
# Gated on INSTALL_WHATSAPP_KEEPALIVE=true. Without it, the morning
# brief (09:00) and evening wrap (18:00) fire against a potentially
# disconnected WhatsApp socket and the deliver_announcement either
# stalls or surfaces as an unready-channel error. The keepalive
# kicks `channel doctor` at 08:50 + 17:50 so the WhatsApp arm
# reconnects (if needed) before the brief is due.
#
# Same render/bootstrap pattern as the assistant agent above.
# Reuses the same OSTLER_BIN / OSTLER_HOME / OSTLER_LOGS /
# OSTLER_ASSISTANT_CONFIG placeholders, so the substitution
# surface is identical.

if [ "${INSTALL_WHATSAPP_KEEPALIVE:-}" = "true" ]; then
    KEEPALIVE_PLIST_SRC="$ASSISTANT_INSTALL_ROOT/launchd/com.creativemachines.ostler.whatsapp-keepalive.plist"
    if [ ! -f "$KEEPALIVE_PLIST_SRC" ]; then
        echo "ostler-assistant install: whatsapp-keepalive plist not found at $KEEPALIVE_PLIST_SRC" >&2
        echo "                          Skipping keepalive registration; brief delivery will work but may" >&2
        echo "                          drop messages if the WhatsApp socket idles out between fires." >&2
    else
        KEEPALIVE_RENDERED="$USER_LAUNCH_AGENTS/com.creativemachines.ostler.whatsapp-keepalive.plist"
        sed \
            -e "s/OSTLER_ASSISTANT_CONFIG/$esc_assistant_cfg/g" \
            -e "s/OSTLER_LOGS/$esc_logs/g" \
            -e "s/OSTLER_BIN/$esc_bin/g" \
            -e "s/OSTLER_HOME/$esc_home/g" \
            "$KEEPALIVE_PLIST_SRC" > "$KEEPALIVE_RENDERED"
        chmod 0644 "$KEEPALIVE_RENDERED"

        KEEPALIVE_LABEL="com.creativemachines.ostler.whatsapp-keepalive"
        launchctl bootout "$DOMAIN/$KEEPALIVE_LABEL" 2>/dev/null || true
        if launchctl bootstrap "$DOMAIN" "$KEEPALIVE_RENDERED"; then
            echo "ostler-assistant install: whatsapp-keepalive bootstrapped ($KEEPALIVE_LABEL)"
        else
            rc=$?
            echo "ostler-assistant install: keepalive bootstrap returned $rc; check ${KEEPALIVE_RENDERED} and ${LOGS_DIR}/whatsapp-keepalive.err" >&2
            # Non-fatal: the assistant agent loaded; without keepalive
            # the brief still tries to fire. Surface the error to the
            # operator but don't fail the whole install.
        fi
    fi
fi
