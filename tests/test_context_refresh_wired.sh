#!/usr/bin/env bash
# context-refresh (personal-context digest) wiring guard (#608)
# ============================================================
#
# The chat assistant only knows about the customer's people, meetings
# and preferences if CONTEXT.md exists in the assistant's workspace
# dir, where the daemon injects it into every system prompt. That file
# is produced by generate_pwg_context.py, run by the context-refresh
# LaunchAgent. This guard fails if any link in that chain is lost in a
# future edit or a stale re-vendor:
#
#   1. The vendored generator is present and intact.
#   2. The tick wrapper writes CONTEXT.md into the assistant-config/
#      workspace dir (the ZEROCLAW_WORKSPACE_DIR contract -- the original
#      silent failure: the script's default env name does NOT match the
#      daemon's, so an unset value lands the digest where the daemon
#      never looks. A second sweep found the explicit value was also
#      one level too high -- missing the /workspace segment the identity
#      belt writes IDENTITY.md/SOUL.md into -- now corrected).
#   3. install.sh enables the http_request tool to reach loopback
#      (allow_private_hosts), so the assistant can do live lookups.
#   4. install.sh actually sources the context-refresh snippet
#      (no ship-dark), after the assistant binary is staged.
#   5. The plist and snippet agree on label + wrapper.
#   6. Functional: the generator, pointed at a synthetic loopback
#      ical-server, writes a digest to the ZEROCLAW_WORKSPACE_DIR it
#      is given (proves the contract end to end).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INSTALL="install.sh"
SNIPPET="context-refresh/INSTALL_SNIPPET.sh"
TICK="context-refresh/bin/context-refresh-tick.sh"
GENERATOR="context-refresh/bin/generate_pwg_context.py"
PLIST="context-refresh/launchd/com.creativemachines.ostler.context-refresh.plist"
LABEL="com.creativemachines.ostler.context-refresh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Vendored generator present + intact
# ---------------------------------------------------------------------------
[ -f "$GENERATOR" ] || fail "$GENERATOR missing (vendored generator absent)"
grep -qE "^def build_digest" "$GENERATOR" \
    || fail "$GENERATOR missing build_digest (stale or corrupt vendor)"
grep -q "ZEROCLAW_WORKSPACE_DIR" "$GENERATOR" \
    || fail "$GENERATOR no longer reads ZEROCLAW_WORKSPACE_DIR (upstream contract changed; revisit the tick)"
echo "vendor check: generate_pwg_context.py present and reads ZEROCLAW_WORKSPACE_DIR"

# ---------------------------------------------------------------------------
# 2. The contract: tick writes into the daemon's workspace dir, which is
#    the assistant-config/workspace subdir -- the SAME dir the installer's
#    identity belt seeds IDENTITY.md/SOUL.md into. generate_pwg_context.py
#    uses ZEROCLAW_WORKSPACE_DIR verbatim as its output dir (no /workspace
#    append), so the value MUST include the /workspace segment.
# ---------------------------------------------------------------------------
[ -f "$TICK" ] || fail "$TICK missing"
grep -qE 'export ZEROCLAW_WORKSPACE_DIR="\$\{OSTLER_DIR\}/assistant-config/workspace"' "$TICK" \
    || fail "$TICK must export ZEROCLAW_WORKSPACE_DIR=\$OSTLER_DIR/assistant-config/workspace so CONTEXT.md lands where the daemon reads it (same dir as IDENTITY.md/SOUL.md)"
echo "contract check: tick pins ZEROCLAW_WORKSPACE_DIR to the assistant-config/workspace dir"

# ---------------------------------------------------------------------------
# 3. install.sh enables http_request for loopback
# ---------------------------------------------------------------------------
grep -q '\[http_request\]' "$INSTALL" \
    || fail "$INSTALL config generation missing [http_request] section"
grep -q 'allow_private_hosts = true' "$INSTALL" \
    || fail "$INSTALL must set allow_private_hosts = true so http_request can reach 127.0.0.1:8090"
echo "wiring check: install.sh writes [http_request] allow_private_hosts = true"

# ---------------------------------------------------------------------------
# 4. install.sh sources the snippet (no ship-dark)
# ---------------------------------------------------------------------------
[ -f "$SNIPPET" ] || fail "$SNIPPET missing"
grep -q "context-refresh/INSTALL_SNIPPET.sh" "$INSTALL" \
    || fail "$INSTALL never references context-refresh/INSTALL_SNIPPET.sh (ship-dark)"
grep -q 'bash "${OSTLER_CONTEXT_REFRESH_DIR}/INSTALL_SNIPPET.sh"' "$INSTALL" \
    || fail "$INSTALL never invokes the context-refresh snippet (ship-dark)"

# Ordering: the context-refresh source must come AFTER the assistant
# binary is staged (it needs the assistant-config dir + a running
# stack to produce a non-empty first digest at RunAtLoad).
assistant_line="$(grep -n 'OSTLER_ASSISTANT_DIR}/INSTALL_SNIPPET.sh" 2>"\$_snippet_stderr"' "$INSTALL" | head -1 | cut -d: -f1)"
context_line="$(grep -n 'bash "${OSTLER_CONTEXT_REFRESH_DIR}/INSTALL_SNIPPET.sh"' "$INSTALL" | head -1 | cut -d: -f1)"
[ -n "$assistant_line" ] || fail "could not locate the assistant snippet invocation"
[ -n "$context_line" ]   || fail "could not locate the context-refresh snippet invocation"
[ "$context_line" -gt "$assistant_line" ] \
    || fail "context-refresh (line $context_line) must be sourced AFTER the assistant snippet (line $assistant_line)"
echo "wiring check: install.sh sources context-refresh after the assistant agent"

# ---------------------------------------------------------------------------
# 5. Plist <-> snippet agreement
# ---------------------------------------------------------------------------
[ -f "$PLIST" ] || fail "$PLIST missing"
grep -q "<string>$LABEL</string>" "$PLIST" \
    || fail "$PLIST label is not $LABEL"
grep -q "$LABEL" "$SNIPPET" \
    || fail "$SNIPPET label does not match the plist ($LABEL)"
grep -q "OSTLER_BIN/context-refresh-tick.sh" "$PLIST" \
    || fail "$PLIST does not run context-refresh-tick.sh"
grep -q "<true/>" <(grep -A1 "RunAtLoad" "$PLIST") \
    || fail "$PLIST RunAtLoad must be true so the first digest is produced at install"
echo "wiring check: plist label + wrapper + RunAtLoad agree with the snippet"

# ---------------------------------------------------------------------------
# 6. Functional: generator writes into the workspace dir it is given
# ---------------------------------------------------------------------------
PYTHON_BIN="$(command -v python3 || true)"
if [ -z "$PYTHON_BIN" ]; then
    echo "SKIP functional digest test: no python3 on PATH"
    echo "PASS: context-refresh wiring guard (static checks only)"
    exit 0
fi

WORKDIR="$(mktemp -d -t context-refresh-test.XXXXXX)"
trap 'kill "${SERVER_PID:-}" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

# A synthetic loopback ical-server serving just enough for the people
# section. Synthetic data only (Rule zero); no real records.
cat > "$WORKDIR/fake_ical.py" <<'PYEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SUGGESTIONS = {
    "recent_meetings": [
        {"name": "Jordan Blake", "role": "VP Engineering",
         "organisation": "Northwind Labs", "last_contact": "2026-05-30"},
    ]
}

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        body = SUGGESTIONS if path == "/api/v1/suggestions" else {}
        payload = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *a):
        pass

port = int(sys.argv[1])
HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF

# Pick a free port.
PORT="$("$PYTHON_BIN" - <<'PYEOF'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PYEOF
)"

"$PYTHON_BIN" "$WORKDIR/fake_ical.py" "$PORT" &
SERVER_PID=$!

# Wait for the server to accept connections (max ~3s).
for _ in $(seq 1 30); do
    if "$PYTHON_BIN" - "$PORT" <<'PYEOF' 2>/dev/null
import socket, sys
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    sys.exit(0)
except OSError:
    sys.exit(1)
PYEOF
    then break; fi
    sleep 0.1
done

# Drive the TICK end to end (not the generator directly): this proves
# the full contract -- the tick derives ZEROCLAW_WORKSPACE_DIR from
# OSTLER_DIR, bypasses any proxy for loopback, and runs the generator.
# A live ical-server -> CONTEXT.md under
# $OSTLER_DIR/assistant-config/workspace (the daemon's workspace dir).
OSTLER_DIR="$WORKDIR" \
OSTLER_ICAL_BASE_URL="http://127.0.0.1:$PORT" \
    bash "$TICK"

WS="$WORKDIR/assistant-config/workspace"
[ -f "$WS/CONTEXT.md" ] \
    || fail "tick did not write CONTEXT.md into \$OSTLER_DIR/assistant-config/workspace ($WS)"
grep -q "Jordan Blake" "$WS/CONTEXT.md" \
    || fail "CONTEXT.md did not include the synthetic person from the ical-server"
echo "functional check: tick wrote CONTEXT.md into the assistant-config/workspace dir (proxy bypassed)"

# No-data path: server down -> exit 0, no file written (graceful no-op).
OSTLER_DIR="$WORKDIR/down" \
OSTLER_ICAL_BASE_URL="http://127.0.0.1:1" \
    bash "$TICK"
[ ! -f "$WORKDIR/down/assistant-config/workspace/CONTEXT.md" ] \
    || fail "tick wrote a digest when the ical-server was unreachable (should be a no-op)"
echo "functional check: tick is a clean no-op when the ical-server is down"

echo "PASS: context-refresh wiring guard (#608)"
