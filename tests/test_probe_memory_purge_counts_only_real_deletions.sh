#!/usr/bin/env bash
# A 200 from DELETE /api/memory/{key} is not a deletion. The daemon answers
# {"status":"ok","deleted":false} when forget() removed nothing, and on the
# v1.0.102 candidate 5 walk box it did that for keys present in brain.db, so
# the opening-turn probe printed "FORGOT 3 0", re-read, still found the seed
# person, and stopped as CANNOT-RUN. This runs the probe's own MEMORY_PY
# against a stub daemon that always answers deleted:false, with a real SQLite
# file holding the rows, and requires the rows to be gone and the output to
# say which path removed them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${ROOT}/scripts/box_walk_probes/lib/daemon_memory.sh"
T="$(mktemp -d)"; trap 'kill "${SRV:-0}" 2>/dev/null || true; rm -rf "$T"' EXIT
awk '/^read -r -d .. MEMORY_PY/{f=1;next} /^PYMEMORY$/{f=0} f' "$LIB" > "$T/mem.py"
[ -s "$T/mem.py" ] || { echo "FAIL: could not lift MEMORY_PY from $LIB"; exit 1; }
printf 'test-token' > "$T/tok"
python3 - "$T/brain.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE memories (id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE, content TEXT NOT NULL)")
c.executemany("INSERT INTO memories VALUES (?,?,?)", [("1","core_a","Casey Example is a synthetic person"),("2","daily_b","Casey Example again"),("3","core_keep","unrelated row")])
c.commit()
PY
cat > "$T/stub.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_DELETE(self):
        b = json.dumps({"status": "ok", "deleted": False}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
python3 "$T/stub.py" > "$T/port" & SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/port" ] && break; sleep 0.3; done
PORT="$(head -1 "$T/port")"
out="$(OSTLER_PROBE_MEMORY_DB="$T/brain.db" python3 "$T/mem.py" "http://127.0.0.1:${PORT}" "$T/tok" "Casey Example" forget core_a daily_b)"
left="$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('select count(*) from memories where key in (\"core_a\",\"daily_b\")').fetchone()[0])" "$T/brain.db")"
kept="$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('select count(*) from memories where key=\"core_keep\"').fetchone()[0])" "$T/brain.db")"
fail=0
[ "$left" = "0" ] || { echo "FAIL: $left seed rows survived a purge the API refused (output: $out)"; fail=1; }
[ "$kept" = "1" ] || { echo "FAIL: an unrelated row was removed"; fail=1; }
case "$out" in "FORGOT 2 0 api=0 db=2") ;; *) echo "FAIL: output '$out' does not name the database fallback"; fail=1 ;; esac
[ "$fail" = 0 ] && echo "PASS: deleted=false is not counted; the 2 seed rows went via the database fallback, the unrelated row stayed"
exit "$fail"
