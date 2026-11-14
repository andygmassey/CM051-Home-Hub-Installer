#!/usr/bin/env bash
# Pause must free the chat model, not only stop the ingest ticks.
#
# The chain under test is the real one, end to end:
#   1. pause_control.set_pause() (the Doctor route's backend, the same call
#      api_pause_post makes) writes governor.env;
#   2. the Ollama watchdog script, lifted byte-for-byte from install.sh's
#      OLLAMAWDEOF heredoc, runs one healthy probe;
#   3. the watchdog reads governor.env through the shipped lib and posts
#      POST /api/generate {"model": ..., "keep_alive": 0} for every model
#      Ollama reports as loaded.
# Ollama is a fake HTTP server on localhost that keeps a loaded-model set,
# unloads a model on keep_alive 0 and loads one on any other request. So the
# assertion is on the bytes the watchdog sends, and on what the server holds
# afterwards, not on a helper's return value.
#
# INSTALL_SH=<path> points the test at another install.sh (used to show the
# test is RED on the pre-fix installer). Negative controls: not paused, and
# paused with nothing loaded, must both send no unload.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$ROOT/install.sh}"
PLIST="$ROOT/assistant-agent/launchd/com.creativemachines.ostler.assistant.plist"
WORK="$(mktemp -d)"
FAKE_PID=""
cleanup() { if [ -n "$FAKE_PID" ]; then kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; fi; rm -rf "$WORK"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

SCRIPT="$WORK/ostler-ollama-watchdog"
awk '/<<'"'"'OLLAMAWDEOF'"'"'$/{f=1;next} /^OLLAMAWDEOF$/{f=0} f' "$INSTALL_SH" > "$SCRIPT"
if [ ! -s "$SCRIPT" ]; then
    bad "install.sh carries no OLLAMAWDEOF watchdog heredoc"
    echo "$PASS passed, $FAIL failed"; exit 1
fi
mkdir -p "$WORK/home" "$WORK/state"
GOV="$WORK/governor.env"
export HOME="$WORK/home"

# -- fake Ollama ----------------------------------------------------------
cat > "$WORK/fake_ollama.py" <<'PY'
import http.server, json, os, sys
D = sys.argv[1]
PORT = int(sys.argv[2])
def load():
    try:
        return [l.strip() for l in open(os.path.join(D, "loaded")) if l.strip()]
    except OSError:
        return []
def save(models):
    open(os.path.join(D, "loaded"), "w").write("".join(m + "\n" for m in models))
def log(line):
    open(os.path.join(D, "requests.log"), "a").write(line + "\n")
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
    def do_GET(self):
        if self.path == "/api/version":
            return self._send(200, b'{"version":"0.0.0-test"}')
        if self.path == "/api/ps":
            if os.path.exists(os.path.join(D, "ps_broken")):
                return self._send(500, b"")
            models = [{"name": m, "model": m} for m in load()]
            return self._send(200, json.dumps({"models": models}).encode())
        self._send(404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/api/embed":
            log("EMBED " + json.dumps(body, sort_keys=True))
            return self._send(200, b'{"embeddings":[[0.0]]}')
        if self.path == "/api/generate":
            log("GENERATE " + json.dumps(body, sort_keys=True))
            m = body.get("model", "")
            models = load()
            if body.get("keep_alive") == 0:
                models = [x for x in models if x != m]
            elif m and m not in models:
                models.append(m)
            save(models)
            return self._send(200, b'{"done":true}')
        self._send(404)
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY
FAKE_DIR="$WORK/fake"; mkdir -p "$FAKE_DIR"
PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -I "$WORK/fake_ollama.py" "$FAKE_DIR" "$PORT" > "$WORK/fake.out" 2>"$WORK/fake.err" &
FAKE_PID=$!
URL="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "$URL/api/version" && break; sleep 0.1; done
curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$URL/api/version" | grep -qF 200 \
    && ok "fake Ollama answers /api/version on 127.0.0.1:$PORT" \
    || { bad "fake Ollama did not start: $(cat "$WORK/fake.err" 2>/dev/null)"; echo "$PASS passed, $FAIL failed"; exit 1; }

set_loaded() { printf '%s\n' "$@" > "$FAKE_DIR/loaded"; : > "$FAKE_DIR/requests.log"; }
loaded_now() { cat "$FAKE_DIR/loaded" 2>/dev/null | tr '\n' ' '; }
unload_sent() { grep -c '^GENERATE .*"keep_alive": 0' "$FAKE_DIR/requests.log" 2>/dev/null || true; }
run_watchdog() {
    OSTLER_OLLAMA_URL="$URL" \
    OSTLER_WATCHDOG_STATE_DIR="$WORK/state" \
    OSTLER_WATCHDOG_RT_LIB="$ROOT/lib/ostler-resource-tier.sh" \
    OSTLER_GOVERNOR_SETTINGS="$GOV" \
    bash "$SCRIPT" 2>&1
}
pause_real() {
    # The real writer: the same set_pause() the Doctor POST /api/v1/pause calls.
    OSTLER_GOVERNOR_ENV_FILE="$GOV" OSTLER_PAUSE_SKIP_MIRROR=1 \
    PYTHONPATH="$ROOT/vendor/doctor/agent" python3 -c \
    'import pause_control as p; s = p.set_pause("indefinite"); print(s["paused"])' 2>"$WORK/pause.err"
}
resume_real() {
    OSTLER_GOVERNOR_ENV_FILE="$GOV" OSTLER_PAUSE_SKIP_MIRROR=1 \
    PYTHONPATH="$ROOT/vendor/doctor/agent" python3 -c \
    'import pause_control as p; s = p.resume(); print(s["paused"])' 2>"$WORK/resume.err"
}

# -- 1. Pause frees the model (the case that was broken) -------------------
echo "case 1: Pause unloads the loaded chat model"
rm -f "$GOV" "$FAKE_DIR/ps_broken"; set_loaded "qwen3.5:9b"
[ "$(pause_real)" = "True" ] && ok "set_pause wrote governor.env paused=True" || bad "set_pause did not pause: $(cat "$WORK/pause.err")"
out=$(run_watchdog); echo "$out" | sed 's/^/        /'
[ "$(unload_sent)" = "1" ] && ok "one POST /api/generate with keep_alive 0 reached Ollama" \
    || bad "no unload request for the loaded model (keep_alive 0 count: $(unload_sent)); the model stays resident"
case "$(loaded_now)" in *qwen3.5:9b*) bad "model still loaded after the unload: $(loaded_now)";; *) ok "fake Ollama holds no model after the pause tick";; esac

# -- 2. Resume restores: a reload is not unloaded again --------------------
echo "case 2: Resume lifts the unload; a reload is kept"
[ "$(resume_real)" = "False" ] && ok "set_pause/resume round trip: resume wrote paused=False" || bad "resume did not clear the pause"
set_loaded "qwen3.5:9b"
run_watchdog >/dev/null
[ "$(unload_sent)" = "0" ] && ok "not paused: the loaded model is left alone (negative control: no keep_alive 0 sent)" \
    || bad "NEGATIVE CONTROL FAILED: unload sent while not paused ($(unload_sent))"
case "$(loaded_now)" in *qwen3.5:9b*) ok "model still loaded after a resumed tick (chat stays warm)";; *) bad "model was unloaded while not paused";; esac

# -- 3. Paused, nothing loaded: no unload, and the log says so -----------
echo "case 3: paused with nothing loaded sends nothing"
pause_real >/dev/null
set_loaded
out=$(run_watchdog)
[ "$(unload_sent)" = "0" ] && ok "no unload request when /api/ps lists no models" || bad "unload sent with nothing loaded"
case "$out" in *"PAUSED: unloaded"*) bad "claimed an unload with nothing loaded";; *) ok "no 'unloaded' line printed for an empty model list";; esac

# -- 4. /api/ps unreadable: say so, do not claim success -----------------
echo "case 4: /api/ps unreadable is reported, not read as 'nothing loaded'"
set_loaded "qwen3.5:9b"; : > "$FAKE_DIR/ps_broken"
out=$(run_watchdog)
case "$out" in *"could not read"*"nothing was unloaded"*) ok "unreadable /api/ps is logged as a failure";; *) bad "unreadable /api/ps was not reported: $out";; esac
rm -f "$FAKE_DIR/ps_broken"

# -- 5. Contract: the idle window the daemon and the prewarm use ----------
echo "case 5: idle window contract (daemon plist and watchdog prewarm)"
pv=$(awk '/<key>OLLAMA_KEEP_ALIVE<\/key>/{getline; print}' "$PLIST" | sed 's/.*<string>//; s/<\/string>.*//')
case "$pv" in
    -*) bad "plist OLLAMA_KEEP_ALIVE is '$pv': a negative value pins the model forever";;
    [0-9]*[smh]) ok "plist OLLAMA_KEEP_ALIVE is '$pv': a number with a unit, idle-unloads";;
    *) bad "plist OLLAMA_KEEP_ALIVE is '$pv': not an Ollama duration with a unit";;
esac
grep -q '\\"keep_alive\\":-1' "$INSTALL_SH" \
    && bad "watchdog prewarm still pins a model with a bare keep_alive -1" \
    || ok "watchdog prewarm does not pin with keep_alive -1"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
