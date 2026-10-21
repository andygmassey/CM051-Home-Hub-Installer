#!/usr/bin/env bash
#
# tests/test_the_generated_digest_names_derived_preferences.sh
#
# smart-prefs: derived preferences must reach CONTEXT.md. This runs the REAL
# shipped generator (context-refresh/bin/generate_pwg_context.py) against a
# fake Hub that serves /api/v1/preferences/derived, then runs the REAL walk
# probe derived_preferences_reach_digest_and_tool (via run_box_walk.sh) over the
# CONTEXT.md the generator wrote. Nothing hand-writes the digest.
#
#   D1  route serves a derived label  -> the generated digest names it, and the
#       probe's digest arm is ok (the chat arm is CANNOT-RUN: no assistant)
#   D2  route is degraded (nothing derived) -> probe route arm FAILs, the
#       generator still exits 0 or 3 but never invents a label
#
# Synthetic labels only. Runs under bash 3.2.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${REPO}/scripts/box_walk_probes/run_box_walk.sh"
GEN="${REPO}/context-refresh/bin/generate_pwg_context.py"
PROBE=derived_preferences_reach
PY="$(command -v python3 || true)"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
[ -n "$PY" ] && [ -f "$RUNNER" ] && [ -f "$GEN" ] || { echo "CANNOT-RUN: python3, the runner or the generator is missing"; exit 2; }
echo "test_the_generated_digest_names_derived_preferences"

WORK="$(mktemp -d)"; HUBPID=""
trap '[ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null; rm -rf "$WORK"' EXIT
cat > "$WORK/hub.py" <<'PYEOF'
import http.server, json, sys
mode = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n: self.rfile.read(n)
        self._send({"results": {"bindings": []}, "head": {"vars": []}})
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/v1/preferences/derived":
            if mode == "serves":
                self._send({"degraded": False, "items": [
                    {"dimension": "media.film.genre", "label": "science fiction", "strength": 0.7,
                     "confidence": 0.8, "intensity": "strong", "because": ["Synthetic Film"]}]})
            else:
                self._send({"degraded": True, "items": [], "cannot_check": "no derived preferences materialized yet"})
        elif path == "/api/v1/preferences":
            self._send({"interests": [{"subject": "Synthetic Kayaking", "domain": "Sport", "polarity": "positive", "privacy": "L2"}]})
        else:
            self._send({})
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF

run() {  # $1 = mode; sets OUT (probe output), GRC (generator rc), DIGEST
    [ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null
    local port=$((20000 + RANDOM % 20000)) H="$WORK/home-$1"
    mkdir -p "$H/.ostler/assistant-config/workspace" "$H/.ostler/secrets"
    "$PY" "$WORK/hub.py" "$port" "$1" & HUBPID=$!
    sleep 1
    env -u OSTLER_SERVICE_TOKEN -u PWG_SERVICE_TOKEN no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost \
        ZEROCLAW_WORKSPACE_DIR="$H/.ostler/assistant-config/workspace" OSTLER_DIR="$WORK/no-ostler-dir" \
        OSTLER_SERVICE_TOKEN=synthetic-token OSTLER_OXIGRAPH_TOKEN_FILE="$WORK/none" \
        OSTLER_ICAL_BASE_URL="http://127.0.0.1:${port}" OXIGRAPH_URL="http://127.0.0.1:${port}" \
        "$PY" "$GEN" >/dev/null 2>&1; GRC=$?
    DIGEST="$H/.ostler/assistant-config/workspace/CONTEXT.md"
    OUT="$(HOME="$H" OSTLER_HUB_URL="http://127.0.0.1:${port}" OSTLER_DERIVED_WAIT_S=0 \
        OSTLER_BOX_HOST= bash "$RUNNER" --only "$PROBE" --read-only 2>&1)"
}

run serves
if [ -s "$DIGEST" ] && /usr/bin/grep -q -- '- Likes: science fiction' "$DIGEST"; then ok "D1a: the generated CONTEXT.md carries '- Likes: science fiction' (generator rc=${GRC})"; else bad "D1a: the generated CONTEXT.md does not name the served derived label (generator rc=${GRC})"; fi
if /usr/bin/grep -qE '^ +ok +digest:' <<< "$OUT" && ! /usr/bin/grep -qE '^ +FAIL +(route|digest):' <<< "$OUT"; then ok "D1b: the walk probe's digest arm is ok over the generated digest"; else bad "D1b: the probe's digest arm is not ok: $(/usr/bin/grep -E 'digest:|route:' <<< "$OUT" | head -2 | tr '\n' '|')"; fi

run degraded
if [ -s "$DIGEST" ] && ! /usr/bin/grep -q -- '- Likes:' "$DIGEST" && /usr/bin/grep -q 'Synthetic Kayaking' "$DIGEST"; then ok "D2a: a degraded route adds no 'Likes' line and the interest profile still renders"; else bad "D2a: degraded route handled wrongly (digest present: $([ -s "$DIGEST" ] && echo yes || echo no))"; fi
if /usr/bin/grep -qE '^ +FAIL +route:' <<< "$OUT"; then ok "D2b: the probe still FAILs the route arm when nothing is derived (never a pass)"; else bad "D2b: expected FAIL route on a degraded route"; fi

echo "  $pass passed, $fail failed (real generator + real run_box_walk.sh, fake Hub)"
[ "$fail" -eq 0 ]
