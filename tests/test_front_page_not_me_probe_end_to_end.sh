#!/usr/bin/env bash
# CM051 #2470: the front_page_not_me_is_saved walk probe, driven end to end.
#
# The probe POSTs a Not me from Origin tauri://localhost, re-reads the stores,
# and judges. This runs the REAL probe against:
#   A  the real Doctor (web_ui.py, real editor_feedback, real CM059 store)  -> PASS
#   B  a fake server that answers "recorded" and writes nothing             -> FAIL
#   C  a server that refuses the app origin (the v1.0.105 bug)              -> FAIL
#   D  a mutant of the real Doctor with the app origin removed              -> FAIL
#   E  nothing listening                                                    -> CANNOT-RUN (78)
# plus the probe's own --self-test, and that the suite glob sees the probe.
# Exit 0 all pass, 1 any fail, 2 CANNOT-RUN.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="${REPO}/scripts/box_walk_probes/probes/front_page_not_me_is_saved.sh"
PY="${OSTLER_TEST_PYTHON:-python3}"
"$PY" -c 'import fastapi, uvicorn, httpx, qrcode' 2>/dev/null || {
    echo "  [CANNOT-RUN] fastapi uvicorn httpx qrcode not importable by ${PY}. NOTHING examined."; exit 2; }

TMP="$(mktemp -d)"; PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
port() { "$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
waitup() { for _ in $(seq 1 100); do curl -s --noproxy '*' -o /dev/null "http://127.0.0.1:$1/api/v1/sources" && return 0; sleep 0.3; done; return 1; }

# probe_rc <port> <editor_dir> -> prints verdict line, sets RC
run_probe() {
    OUT="$(OSTLER_BOX_HOST= OSTLER_DOCTOR_URL="http://127.0.0.1:$1" OSTLER_EDITOR_DIR="$2" bash "$PROBE" 2>&1)"; RC=$?
    printf '%s\n' "$OUT" | grep '^VERDICT' | sed 's/^/        /'
}
start_doctor() {  # <agent dir> <editor dir> -> sets P
    P="$(port)"; mkdir -p "$2"
    ( cd "$1" && unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
      no_proxy='*' DOCTOR_PORT="$P" OSTLER_EDITOR_HOME="${REPO}/vendor/cm059_editor" \
      OSTLER_EDITOR_DIR="$2" exec "$PY" web_ui.py ) > "${TMP}/doctor-$P.log" 2>&1 &
    PIDS="$PIDS $!"
    waitup "$P" || { echo "  [CANNOT-RUN] Doctor did not start; see ${TMP}/doctor-$P.log"; tail -5 "${TMP}/doctor-$P.log"; exit 2; }
}

echo "== A real Doctor: saved =="
mkdir -p "${TMP}/edA"; start_doctor "${REPO}/vendor/doctor/agent" "${TMP}/edA"; run_probe "$P" "${TMP}/edA"
[ "$RC" = 0 ] && ok "A: real route + real store -> probe PASS" || bad "A: rc=$RC"
grep -q 'walkprobe-' "${TMP}/edA/interest_corrections.json" 2>/dev/null \
  && bad "A: synthetic ids left in the store after the probe" || ok "A: the probe cleaned its synthetic ids"

echo "== B fake no-persist server =="
cat > "${TMP}/fake.py" <<'PYF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
mode, port = sys.argv[1], int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if mode == "refuse_app":
            code, body = 403, {"error": "this write is only accepted from the Hub itself"}
        else:  # nopersist: claims success, writes nothing
            code, body = (200, {"status": "recorded"}) if "tauri" in (self.headers.get("Origin") or "") else (403, {"error": "no"})
        d = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
HTTPServer(("127.0.0.1", port), H).serve_forever()
PYF
for mode in nopersist refuse_app; do
  FP="$(port)"; "$PY" "${TMP}/fake.py" "$mode" "$FP" & PIDS="$PIDS $!"; waitup "$FP" || { echo "  [CANNOT-RUN] fake server"; exit 2; }
  mkdir -p "${TMP}/ed-$mode"; run_probe "$FP" "${TMP}/ed-$mode"
  [ "$RC" = 1 ] && ok "$mode server -> probe FAIL" || bad "$mode server: rc=$RC (want 1)"
done

echo "== D mutant: real Doctor with the app origin removed =="
cp -R "${REPO}/vendor/doctor/agent" "${TMP}/agent_mut"
"$PY" - "${TMP}/agent_mut/editor_feedback.py" <<'PYM'
import sys; p = sys.argv[1]; s = open(p).read()
t = s.replace('_APP_WEBVIEW_ORIGINS = ("tauri://localhost", "http://tauri.localhost", "https://tauri.localhost")', '_APP_WEBVIEW_ORIGINS = ()')
assert t != s, "mutation did not apply"; open(p, "w").write(t)
PYM
mkdir -p "${TMP}/edD"; start_doctor "${TMP}/agent_mut" "${TMP}/edD"; run_probe "$P" "${TMP}/edD"
[ "$RC" = 1 ] && ok "D: mutant (the v1.0.105 bug) -> probe FAIL" || bad "D: rc=$RC (want 1)"

echo "== E nothing listening =="
run_probe "$(port)" "${TMP}/edE"
[ "$RC" = 78 ] && ok "E: unreachable Doctor -> CANNOT-RUN" || bad "E: rc=$RC (want 78)"

echo "== the probe's own self-test, and the suite sees it =="
OUT="$(bash "$PROBE" --self-test 2>&1)"; RC=$?
{ [ "$RC" = 1 ] && grep -q 'negative control behaved' <<<"$OUT"; } && ok "self-test: known-bad inputs all fail" || bad "self-test rc=$RC"
ls "${REPO}"/scripts/box_walk_probes/probes/*.sh | grep -q front_page_not_me_is_saved.sh && ok "in probes/ (the run_box_walk.sh glob)" || bad "not in probes/"
grep -q '^front_page_not_me_is_saved	blocking' "${REPO}/scripts/walk_promote_scope.tsv" && ok "scope row is blocking" || bad "no blocking scope row"

echo "$PASS pass, $FAIL fail"; [ "$FAIL" = 0 ]
