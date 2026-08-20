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
#
# It ENFORCES THE BEARER, because the real one does (v1.0.10 #200) and a
# fixture that does not is how this whole chain stayed green while the
# generator sent no Authorization header and never once produced a digest
# on a real install. It also stands in for Oxigraph on POST /query so a
# clean run here is genuinely clean rather than quietly degraded.
cat > "$WORKDIR/fake_ical.py" <<'PYEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

EXPECTED_TOKEN = sys.argv[2]

SUGGESTIONS = {
    "recent_meetings": [
        {"name": "Jordan Blake", "role": "VP Engineering",
         "organisation": "Northwind Labs", "last_contact": "2026-05-30"},
    ]
}
EMPTY_SPARQL = {"head": {"vars": []}, "results": {"bindings": []}}

class H(BaseHTTPRequestHandler):
    def _send(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _authorised(self):
        raw = self.headers.get("Authorization") or ""
        return raw.startswith("Bearer ") and raw[7:].strip() == EXPECTED_TOKEN

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        # Mirrors the real _PUBLIC_GET_PATHS: /health needs no credential.
        if path == "/health":
            return self._send(200, {"status": "ok"})
        if not self._authorised():
            return self._send(
                401, {"error": "Unauthorized: missing or invalid service token"})
        return self._send(
            200, SUGGESTIONS if path == "/api/v1/suggestions" else {})

    def do_POST(self):
        # Oxigraph stand-in: unauthenticated, deliberately empty.
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        return self._send(200, EMPTY_SPARQL)

    def log_message(self, *a):
        pass

port = int(sys.argv[1])
HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF

# Synthetic, fixed, obviously fake.
FAKE_TOKEN="synthetic-service-token-for-tests-0000"

# Pick a free port.
PORT="$("$PYTHON_BIN" - <<'PYEOF'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PYEOF
)"

"$PYTHON_BIN" "$WORKDIR/fake_ical.py" "$PORT" "$FAKE_TOKEN" &
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
rc=0
OSTLER_DIR="$WORKDIR" \
OSTLER_ICAL_BASE_URL="http://127.0.0.1:$PORT" \
OXIGRAPH_URL="http://127.0.0.1:$PORT" \
OSTLER_SERVICE_TOKEN="$FAKE_TOKEN" \
    bash "$TICK" || rc=$?

WS="$WORKDIR/assistant-config/workspace"
[ -f "$WS/CONTEXT.md" ] \
    || fail "tick did not write CONTEXT.md into \$OSTLER_DIR/assistant-config/workspace ($WS)"
grep -q "Jordan Blake" "$WS/CONTEXT.md" \
    || fail "CONTEXT.md did not include the synthetic person from the ical-server"
[ "$rc" -eq 0 ] \
    || fail "a fully-served run exited $rc, expected 0 (every source answered)"
echo "functional check: tick wrote CONTEXT.md into the assistant-config/workspace dir (proxy bypassed)"

# ---------------------------------------------------------------------------
# 7. The exit code has to carry the verdict.
#
# This section used to assert the OPPOSITE -- that a run which produced
# nothing exits 0, described as "a graceful no-op". That was the defect,
# written down as a requirement and tested for. On a real v1.0.36 install
# the generator produced zero of six sections on every tick, said so in a
# log line naming two causes it had never measured, and returned 0, so
# launchd, the Doctor and this test all reported success over a digest
# that had never existed. Exit 2 now means "nothing produced".
# ---------------------------------------------------------------------------
rc=0
OSTLER_DIR="$WORKDIR/down" \
OSTLER_ICAL_BASE_URL="http://127.0.0.1:1" \
OXIGRAPH_URL="http://127.0.0.1:1" \
OSTLER_SERVICE_TOKEN="$FAKE_TOKEN" \
    bash "$TICK" || rc=$?
[ ! -f "$WORKDIR/down/assistant-config/workspace/CONTEXT.md" ] \
    || fail "tick wrote a digest when no source was reachable"
[ "$rc" -ne 0 ] \
    || fail "tick exited 0 after producing no digest at all -- this is the original defect"
[ "$rc" -eq 2 ] \
    || fail "expected exit 2 (nothing produced) when no source is reachable, got $rc"
echo "functional check: a run that produces no digest exits non-zero (2), not 0"

# And the same, for the reason that actually shipped: the server is UP and
# answering, the credential is simply missing. This is the case the old
# message misdiagnosed as "ical-server down".
rc=0
OSTLER_DIR="$WORKDIR/noauth" \
OSTLER_ICAL_BASE_URL="http://127.0.0.1:$PORT" \
OXIGRAPH_URL="http://127.0.0.1:$PORT" \
OSTLER_SERVICE_TOKEN_FILE="$WORKDIR/no-such-token-file" \
    bash "$TICK" > "$WORKDIR/noauth.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] \
    || fail "tick exited 0 with no service token; every /api/v1 read was 401"
grep -q "HTTP 401" "$WORKDIR/noauth.out" \
    || fail "the report does not name the 401 it observed: $(cat "$WORKDIR/noauth.out")"
grep -q "ical-server down or empty graph" "$WORKDIR/noauth.out" \
    && fail "the invented-cause message is back (the server was up and answering)"
echo "functional check: an unauthenticated run fails loudly and names the measured 401"

# ---------------------------------------------------------------------------
# 6. #5 -- EVERY /api/v1 CALL MUST CARRY THE PARAMETERS THE SERVER REQUIRES
#
# MEASURED on a live v1.0.37 box 2026-08-20, against BASE_URL (127.0.0.1:8090),
# with a valid service token:
#
#   /api/v1/coach/recent?hours=336&limit=8            -> 400
#                        {"error": "user_id query parameter is required"}
#   /api/v1/coach/recent?hours=336&limit=8&user_id=me -> 200
#   /api/v1/timeline?days=7                           -> 200
#   /api/v1/suggestions                               -> 200
#
# Auth was fine; exactly one call of six was malformed. It hid inside the
# earlier 401 sweep -- while every endpoint returned 401, a call that was ALSO
# missing a required parameter looked identical to the rest. Fixing a whole
# class at once conceals any member that was broken twice.
#
# This asserts the PARAMETER IS PRESENT AT THE CALL SITE. It deliberately does
# NOT assert a live 400/200: that needs a running Hub, and a check that
# CANNOT-RUNs on every CI runner proves nothing.
#
# Non-zero = BLOCK THE CUT. The digest silently loses its preferences section
# and the tick exits non-zero on every fire.
# ---------------------------------------------------------------------------
_coach_calls="$(grep -c '_get_json("/api/v1/coach/recent' "$GENERATOR" || true)"
_coach_with_user="$(grep -c '_get_json("/api/v1/coach/recent[^"]*user_id=' "$GENERATOR" || true)"
[ "${_coach_calls:-0}" -gt 0 ] \
    || fail "coach/recent call site not found in $GENERATOR -- it moved, and this check is now blind"
[ "${_coach_with_user:-0}" -eq "${_coach_calls:-0}" ] \
    || fail "$(( _coach_calls - _coach_with_user )) of ${_coach_calls} coach/recent call site(s) omit user_id -- the server answers 400 and the preferences section is silently dropped"

# ANTI-VACUITY: the predicate must be able to MISS. A pattern that matched
# anything would report every call site compliant while measuring nothing.
if grep -q '_get_json("/api/v1/coach/recent[^"]*user_id=' <<< '    data = _get_json("/api/v1/coach/recent?hours=336&limit=8")'; then
    fail "ANTI-VACUITY FAILED: the user_id pattern matched a call site that has no user_id, so the check above is meaningless"
fi
echo "param check: all ${_coach_calls} coach/recent call site(s) send user_id, and the predicate provably misses when it is absent"

echo "PASS: context-refresh wiring guard (#608)"
