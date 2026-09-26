#!/usr/bin/env bash
# tests/test_the_seed_forgets_what_the_walk_taught.sh
#
# The v1.0.102 candidate 4 box answered the grounded battery's seeded question
# with NO tool call on its fourth run, because the daemon remembered the answer
# from an earlier run. grounding_seed_apply now removes daemon memory naming the
# SYNTHETIC seed person, and nothing else. This drives the real
# _gs_purge_daemon_memory against a stub of the daemon's real routes
# (GET /api/memory?query=, DELETE /api/memory/{key}, admin bearer) and checks:
#   1. entries naming the seed person are removed
#   2. an entry about someone else survives (the purge is not a wipe)
#   3. a refused read is reported as COULD NOT READ, and removes nothing
#   4. MUTATION: with the forget call removed, arm 1 fails
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$HERE/scripts/box_walk_probes/lib/grounding_seed.sh"
pass=0; fail=0
arm() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; else fail=$((fail+1)); printf '  [FAIL] %s\n         %s\n' "$1" "${3:-}"; fi; }

T="$(mktemp -d)"; trap 'kill "${SRV:-0}" 2>/dev/null; rm -rf "$T"' EXIT
printf 'test-admin-token\n' > "$T/token"
cat > "$T/srv.py" <<'PY'
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
state = sys.argv[1]
def load(): return json.load(open(state))
def save(d): json.dump(d, open(state, "w"))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _ok(self): return self.headers.get("Authorization") == "Bearer test-admin-token" and not load().get("refuse")
    def do_GET(self):
        if not self._ok(): self.send_response(401); self.end_headers(); return
        u = urllib.parse.urlparse(self.path)
        if u.path != "/api/memory": self.send_response(404); self.end_headers(); return
        q = urllib.parse.parse_qs(u.query).get("query", [""])[0].lower()
        ents = [e for e in load()["entries"] if any(w in e["content"].lower() for w in q.split())]
        b = json.dumps({"entries": ents}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
    def do_DELETE(self):
        if not self._ok(): self.send_response(401); self.end_headers(); return
        k = urllib.parse.unquote(self.path.rsplit("/", 1)[1])
        d = load(); d["entries"] = [e for e in d["entries"] if e["key"] != k]; save(d)
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b"{}")
s = HTTPServer(("127.0.0.1", 0), H); print(s.server_port, flush=True); s.serve_forever()
PY
seed_state() {
    cat > "$T/state.json" <<JSON
{"refuse": $1, "entries": [
 {"key": "daily_a", "content": "User: Who is Jane Doe and where do they work? Assistant: a cable engineer"},
 {"key": "daily_b", "content": "Jane Doe was mentioned again"},
 {"key": "core_c",  "content": "User likes sailing and knows John Smith"}]}
JSON
}
count() { python3 -c "import json,sys;d=json.load(open('$T/state.json'));print(sum(1 for e in d['entries'] if sys.argv[1].lower() in e['content'].lower()))" "$1"; }
seed_state false
python3 "$T/srv.py" "$T/state.json" > "$T/port" & SRV=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT="$(head -1 "$T/port")"

run_purge() { # run_purge <lib file>
    ( unset OSTLER_BOX_HOST
      . "$1"
      GATEWAY="http://127.0.0.1:${PORT}"; TOKEN_PATH="$T/token"; _gs_kp="Jane Doe"
      _gs_purge_daemon_memory ) 2>&1
}

printf 'THE SEED FORGETS WHAT THE WALK TAUGHT\n\n'
out="$(run_purge "$LIB")"
arm "entries naming the synthetic seed person are removed" "$([ "$(count 'jane doe')" -eq 0 ] && echo 0 || echo 1)" "left: $(count 'jane doe'); output: $out"
arm "an entry about someone else survives" "$([ "$(count 'john smith')" -eq 1 ] && echo 0 || echo 1)" "left: $(count 'john smith')"
arm "the purge says what it did" "$(printf '%s' "$out" | grep -c 'removed what an earlier run taught it' | awk '{print ($1>0)?0:1}')" "$out"

seed_state true
out="$(run_purge "$LIB")"
arm "a refused read says COULD NOT READ" "$(printf '%s' "$out" | grep -c 'COULD NOT READ' | awk '{print ($1>0)?0:1}')" "$out"
arm "and removes nothing" "$([ "$(count 'jane doe')" -eq 2 ] && echo 0 || echo 1)" "left: $(count 'jane doe')"

seed_state false
sed 's/_gs_f="$(_memory_forget_keys ${_gs_keys})"/_gs_f="mutant"/' "$LIB" > "$T/mut.sh"
cp "$HERE/scripts/box_walk_probes/lib/daemon_memory.sh" "$T/daemon_memory.sh"
landed="$(grep -c '_gs_f="mutant"' "$T/mut.sh")"
arm "the mutant really has the forget call removed" "$([ "$landed" -eq 1 ] && echo 0 || echo 1)" "matched $landed line(s)"
run_purge "$T/mut.sh" >/dev/null
arm "MUST-FAIL: without the forget call the seed person is still remembered" "$([ "$(count 'jane doe')" -gt 0 ] && echo 0 || echo 1)"

printf '\n== %d pass / %d fail / %d total ==\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
