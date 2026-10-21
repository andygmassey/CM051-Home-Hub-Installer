#!/usr/bin/env bash
# CM051 #2470: the front_page_not_me_is_saved walk probe, driven end to end.
#
# The probe POSTs a Not me from Origin tauri://localhost, re-reads the stores,
# and judges. This runs the REAL probe against:
#   A  the real Doctor (web_ui.py, real editor_feedback, real CM059 store)  -> PASS
#   B  a fake server that answers "recorded" and writes nothing             -> FAIL
#   C  a server that refuses the app origin (the v1.0.105 bug)              -> FAIL
#   D  a mutant of the real Doctor with the app origin removed              -> FAIL
#   E  nothing listening (connection refused)                               -> CANNOT-RUN (78)
#   F  a server that accepts then hangs up / sends a bad status line / hangs
#      past the timeout (present but broken)                                -> FAIL, never CANNOT-RUN
#   G  the env proxy answers 503 for everything (Privoxy)                   -> still PASS
#   H  the scrub cannot write                                               -> FAIL
#   I  files the probe created are removed; pre-existing owner data is kept
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
LEFT="$(ls -A "${TMP}/edA")"
[ -z "$LEFT" ] && ok "I: files the probe created were removed (editor dir empty again)" \
  || bad "I: the probe left files that did not exist before it ran: $(echo $LEFT)"

echo "== B fake no-persist server =="
cat > "${TMP}/fake.py" <<'PYF'
import json, os, socket, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
mode, port = sys.argv[1], int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if mode == "disconnect":  # accepts, reads, hangs up with no reply
            self.close_connection = True
            self.request.shutdown(socket.SHUT_RDWR)
            return
        if mode == "badstatus":
            self.wfile.write(b"GARBAGE NOT HTTP\r\n\r\n"); self.close_connection = True
            return
        if mode == "hang":
            time.sleep(60); return
        if mode == "proxy503":
            d = b"Privoxy: no"
            self.send_response(503); self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
            return
        if mode == "persist_lock":  # writes the stores like the real route, then locks the dir so the scrub cannot
            ed = os.environ["FAKE_EDITOR_DIR"]
            b = json.loads(raw or b"{}")
            if "tauri" in (self.headers.get("Origin") or ""):
                json.dump({"drop": [b["interest_id"]]}, open(os.path.join(ed, "interest_corrections.json"), "w"))
                json.dump({b["card_id"]: {"state": "dismissed_forever"}}, open(os.path.join(ed, "card_states.json"), "w"))
                os.chmod(ed, 0o555)
                code, body = 200, {"status": "recorded"}
            else:
                code, body = 403, {"error": "no"}
        elif mode == "refuse_app":
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

echo "== F a server that is present but broken is FAIL, not CANNOT-RUN =="
for mode in disconnect badstatus hang; do
  FP="$(port)"; "$PY" "${TMP}/fake.py" "$mode" "$FP" & PIDS="$PIDS $!"
  for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$FP") 2>/dev/null && break; sleep 0.2; done
  mkdir -p "${TMP}/ed-$mode"
  OSTLER_NOT_ME_TIMEOUT=2 run_probe "$FP" "${TMP}/ed-$mode"
  [ "$RC" = 1 ] && ok "F: $mode server -> probe FAIL" || bad "F: $mode server: rc=$RC (want 1, FAIL)"
done

echo "== G the env proxy answers 503 for everything =="
XP="$(port)"; "$PY" "${TMP}/fake.py" proxy503 "$XP" & PIDS="$PIDS $!"; waitup "$XP" || { echo "  [CANNOT-RUN] proxy stub"; exit 2; }
mkdir -p "${TMP}/edG"; start_doctor "${REPO}/vendor/doctor/agent" "${TMP}/edG"
# the driver directly: the probe's bash -lc wrapper can re-export no_proxy from the login profile and hide the bug
LIB="${REPO}/scripts/box_walk_probes/lib/front_page_not_me.py"
DRV="$(env -u no_proxy -u NO_PROXY http_proxy="http://127.0.0.1:$XP" HTTP_PROXY="http://127.0.0.1:$XP" \
  "$PY" "$LIB" drive "http://127.0.0.1:$P" "${TMP}/edG")"
VERD="$(printf '%s' "$DRV" | "$PY" "$LIB" judge)"; printf '        %s\n' "$VERD"
case "$VERD" in PASS*) ok "G: the driver ignores the env proxy and reaches the Doctor -> PASS" ;; *) bad "G: $VERD" ;; esac

echo "== H the scrub cannot write: the probe must FAIL =="
HP="$(port)"; mkdir -p "${TMP}/edH"
FAKE_EDITOR_DIR="${TMP}/edH" "$PY" "${TMP}/fake.py" persist_lock "$HP" & PIDS="$PIDS $!"; waitup "$HP" || { echo "  [CANNOT-RUN] fake server"; exit 2; }
run_probe "$HP" "${TMP}/edH"; chmod 755 "${TMP}/edH"
[ "$RC" = 1 ] && ok "H: scrub failure -> probe FAIL" || bad "H: rc=$RC (want 1)"

echo "== I pre-existing owner data is kept =="
mkdir -p "${TMP}/edI"
printf '{"drop": ["owner-real-interest"]}' > "${TMP}/edI/interest_corrections.json"
printf '{"owner-card": {"state": "dismissed_forever"}}' > "${TMP}/edI/card_states.json"
start_doctor "${REPO}/vendor/doctor/agent" "${TMP}/edI"; run_probe "$P" "${TMP}/edI"
[ "$RC" = 0 ] && ok "I: probe PASS against a populated editor dir" || bad "I: rc=$RC"
grep -q 'owner-real-interest' "${TMP}/edI/interest_corrections.json" && grep -q 'owner-card' "${TMP}/edI/card_states.json" \
  && ok "I: the owner's own entries are still there" || bad "I: owner data was deleted"
grep -q 'walkprobe-' "${TMP}/edI"/*.json && bad "I: synthetic ids left behind" || ok "I: synthetic ids gone from a populated dir"

echo "== the probe's own self-test, and the suite sees it =="
OUT="$(bash "$PROBE" --self-test 2>&1)"; RC=$?
{ [ "$RC" = 1 ] && grep -q 'negative control behaved' <<<"$OUT"; } && ok "self-test: known-bad inputs all fail" || bad "self-test rc=$RC"
ls "${REPO}"/scripts/box_walk_probes/probes/*.sh | grep -q front_page_not_me_is_saved.sh && ok "in probes/ (the run_box_walk.sh glob)" || bad "not in probes/"
grep -q '^front_page_not_me_is_saved	blocking' "${REPO}/scripts/walk_promote_scope.tsv" && ok "scope row is blocking" || bad "no blocking scope row"

echo "$PASS pass, $FAIL fail"; [ "$FAIL" = 0 ]
