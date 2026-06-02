#!/usr/bin/env bash
#
# context-refresh-tick.sh
#
# One LaunchAgent tick of the personal-context digest refresh.
# Driven by com.creativemachines.ostler.context-refresh.plist
# (RunAtLoad once on login, then on a calendar schedule).
#
# What it does:
#   Runs generate_pwg_context.py, which queries the local
#   ical-server (the Hub's personal-graph API on 127.0.0.1:8090)
#   and writes a compact CONTEXT.md digest. The ostler-assistant
#   daemon injects CONTEXT.md verbatim into every system prompt,
#   so the chat assistant has baseline awareness of the customer's
#   people, meetings and preferences. Without this tick the digest
#   is never produced and the assistant answers "I have no access
#   to your data" -- the v1.0.1 #608 launch blocker.
#
# THE CONTRACT THAT MATTERS (and was the original silent failure):
#   - The daemon resolves its workspace from the ZEROCLAW_WORKSPACE
#     env (set by the assistant LaunchAgent to the assistant-config
#     dir) and reads CONTEXT.md from there.
#   - generate_pwg_context.py resolves its OUTPUT dir from a
#     DIFFERENT env, ZEROCLAW_WORKSPACE_DIR, falling back to
#     ~/.zeroclaw/workspace.
#   Those two names do not match. If we let the script fall back to
#   its default, CONTEXT.md lands in ~/.zeroclaw/workspace where the
#   daemon never looks. So this wrapper sets ZEROCLAW_WORKSPACE_DIR
#   explicitly to the SAME dir the daemon uses as its workspace
#   ($OSTLER_DIR/assistant-config), so the digest lands where the
#   prompt builder reads it.
#
# Idempotent and safe: the script exits 0 and leaves any prior
# CONTEXT.md untouched when the ical-server is down or the graph is
# empty, so a tick during a stack restart is a clean no-op rather
# than a launchd-flagged failure.
#
# Configuration (env, set by the installer or the LaunchAgent):
#   OSTLER_DIR  (default ~/.ostler) -- artefact root. The assistant
#               config dir is $OSTLER_DIR/assistant-config and the
#               vendored script sits beside this wrapper in
#               $OSTLER_DIR/bin.
#
# British English throughout.

set -euo pipefail

# LaunchAgents inherit only the bare system PATH. Prepend the usual
# Homebrew + system locations so a python3 is resolvable even when
# the plist's EnvironmentVariables.PATH is missing on a hand-edited
# install.
export PATH="/usr/local/bin:/opt/homebrew/bin:${PATH:-/usr/bin:/bin}"

OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GENERATOR="${SCRIPT_DIR}/generate_pwg_context.py"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

if [ ! -f "$GENERATOR" ]; then
    log "ERROR: generate_pwg_context.py not found at $GENERATOR."
    log "       Re-run the Ostler installer to restage the context-refresh helper."
    exit 1
fi

# Resolve a Python interpreter. Prefer the installer's venv python
# (stable, present on every Ostler install) and fall back to any
# python3 on PATH. The generator is pure standard library, so any
# python3 works.
PYTHON_BIN=""
if [ -x "${OSTLER_DIR}/.venv/bin/python3" ]; then
    PYTHON_BIN="${OSTLER_DIR}/.venv/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
elif [ -x /usr/bin/python3 ]; then
    PYTHON_BIN="/usr/bin/python3"
else
    log "ERROR: no python3 interpreter found; cannot refresh the context digest."
    exit 1
fi

# The ical-server is strictly loopback. If the customer has a
# corporate http_proxy / https_proxy set in their environment, a
# bare urllib request to 127.0.0.1 would route THROUGH the proxy and
# fail (the generator would then log "no data" and never write a
# digest). Force loopback to bypass any proxy. Belt-and-braces: a
# LaunchAgent's minimal env usually has no proxy set, but a
# hand-edited plist or a manual run from a proxied shell would.
export no_proxy="127.0.0.1,localhost,::1${no_proxy:+,$no_proxy}"
export NO_PROXY="$no_proxy"

# The contract: write CONTEXT.md into the daemon's workspace dir
# (== assistant-config dir), NOT the script's ~/.zeroclaw default.
export ZEROCLAW_WORKSPACE_DIR="${OSTLER_DIR}/assistant-config"
# Pin the digest source to the loopback ical-server. This is also
# the script's default; set explicitly so the contract is visible
# and a future ical-server port move is a one-line change here.
export OSTLER_ICAL_BASE_URL="${OSTLER_ICAL_BASE_URL:-http://127.0.0.1:8090}"

mkdir -p "$ZEROCLAW_WORKSPACE_DIR"

log "Refreshing personal-context digest -> ${ZEROCLAW_WORKSPACE_DIR}/CONTEXT.md"
# The generator never raises and returns 0 on a graceful no-op, so a
# non-zero exit here is a genuine failure worth surfacing to launchd.
exec "$PYTHON_BIN" "$GENERATOR"
