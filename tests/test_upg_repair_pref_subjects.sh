#!/usr/bin/env bash
# Exercises install.sh _upg_repair_pref_subject_duplicates on its APPLY branch:
# the real vendored repair module, run by the real function, against a stub
# store that serves one two-subject node and records the update it receives.
# Synthetic data only. Covers: dry run then apply, marker written, second run a
# no-op, and a store that refuses the update leaves no marker.
set -uo pipefail
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)" || exit 78
trap 'kill "${SRV:-0}" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME/.ostler/secrets"
: > "$HOME/.ostler/secrets/store-curl.conf"
OSD="$WORK/ostler"; SRC="$OSD/services/cm019/services/ingest"
mkdir -p "$SRC/src" && cp "$HERE/vendor/cm019_preferences/services/ingest/src/repair_pref_subjects.py" "$SRC/src/" \
  && touch "$SRC/src/__init__.py" || exit 78
LOG="$WORK/upgrade.log"; : > "$LOG"

cat > "$WORK/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
UPD = sys.argv[2]; MODE = sys.argv[3]   # MODE: ok | refuse
NODE = "https://schema.ostler.ai/ontology#pref_11111111-2222-5333-8444-555555555555"
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body):
        b = body.encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n).decode()
        if self.path == "/query":
            rows = [{"s": {"value": NODE}, "subj": {"value": v}} for v in ("synthetic-widget-deluxe-series", "synthetic-widget-dlx-ser")]
            return self._send(200, json.dumps({"results": {"bindings": rows}}))
        if self.path.startswith("/collections/"):
            return self._send(200, json.dumps({"result": [{"payload": {"subject": "synthetic-widget-deluxe-series"}}]}))
        if self.path == "/update":
            with open(UPD, "a") as fh: fh.write(body + "\n---\n")
            if MODE == "refuse":
                return self._send(500, "refused")
            return self._send(204, "")
        self._send(404, "")
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
UPD="$WORK/updates.txt"; : > "$UPD"
python3 "$WORK/stub.py" "$PORT" "$UPD" ok & SRV=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

# Run the REAL function, extracted from install.sh (same extraction the upgrade path uses).
sed -n '/^    _upg_repair_pref_subject_duplicates() {/,/^    }$/p' "$HERE/install.sh" | sed 's/^    //' > "$WORK/fn.sh"
[ -s "$WORK/fn.sh" ] || { echo "FAIL: function not found in install.sh"; exit 1; }
run_fn() {
  bash -c '
    set -u
    _upg_log(){ printf "%s\n" "$*" >> "'"$LOG"'"; }
    . "'"$WORK/fn.sh"'"
    _UPG_OSTLER_DIR="'"$OSD"'" _upg_repair_pref_subject_duplicates
  '
}
export OSTLER_OXIGRAPH_URL="http://127.0.0.1:$PORT" OSTLER_QDRANT_URL="http://127.0.0.1:$PORT"
MARK="$HOME/.ostler/state/repairs/pref-subjects-two-value.done"

run_fn
grep -q "pref-subject repair dry run (rc=0): two-subject nodes: 1 fixable" "$LOG" || { echo "FAIL: dry run not logged clean"; cat "$LOG"; exit 1; }
grep -q "pref-subject repair: applied; marker written" "$LOG" || { echo "FAIL: apply not logged"; cat "$LOG"; exit 1; }
[ -f "$MARK" ] || { echo "FAIL: marker not written"; exit 1; }
grep -q "DELETE DATA" "$UPD" || { echo "FAIL: no DELETE DATA reached the store"; exit 1; }
grep -q "synthetic-widget-dlx-ser" "$UPD" || { echo "FAIL: the non-matching subject was not the one deleted"; exit 1; }
echo "PASS apply branch: dry run, delete of the non-matching subject, marker"

# Second run: marker present, no second update.
before=$(grep -c "DELETE DATA" "$UPD"); run_fn
after=$(grep -c "DELETE DATA" "$UPD")
[ "$before" = "$after" ] || { echo "FAIL: second run re-applied"; exit 1; }
echo "PASS idempotent: second run did not re-apply"

# Refusing store: no marker, retried next upgrade.
kill "$SRV" 2>/dev/null; rm -f "$MARK"; : > "$UPD"; : > "$LOG"
python3 "$WORK/stub.py" "$((PORT+1))" "$UPD" refuse & SRV2=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$((PORT+1))/" && break; sleep 0.1; done
OSTLER_OXIGRAPH_URL="http://127.0.0.1:$((PORT+1))" OSTLER_QDRANT_URL="http://127.0.0.1:$((PORT+1))" run_fn
kill "$SRV2" 2>/dev/null
[ ! -f "$MARK" ] || { echo "FAIL: marker written after refused update"; exit 1; }
grep -q "apply FAILED; marker not written" "$LOG" || { echo "FAIL: refusal not logged"; cat "$LOG"; exit 1; }
echo "PASS refusal: no marker, logged, retried next upgrade"
