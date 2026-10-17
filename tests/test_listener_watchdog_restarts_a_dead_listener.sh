#!/usr/bin/env bash
# The companion listener watchdog (install.sh LISTENERWDEOF, 2026-10-17
# incident: daemon alive at 0% CPU for 4 h, :8443 dead, nothing respawned it).
#
# Runs the EXACT bytes install.sh writes against a fake daemon: a python HTTP
# server on a free port that answers 401, stood in for :8443. "Dead listener,
# live process" is produced the way the incident looked, with SIGSTOP: the
# kernel still accepts the connection, nothing ever answers, curl reads 000.
# launchctl is a shim: `print` reports the fake daemon's pid, `kickstart -k`
# kills it and (optionally) starts a fresh one, and every call is recorded.
# sample, lsof, vm_stat, memory_pressure and sysctl are shimmed so this runs
# on the ubuntu runner.
#
# The Doctor half reads the state file THIS run's watchdog wrote, through the
# real vendor/doctor/agent/diagnostic_rules.py run_all_rules, so the writer
# and the reader are tested on one shared file.
#
# Then every guard is mutated out of the lifted script (and the rule out of
# ALL_RULES) and the suite must go red for each one.
#
# Usage: [REPO_ROOT]. rc 0 all pass, 1 a case failed, 2 CANNOT-RUN.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SELF="${ROOT}/tests/$(basename "${BASH_SOURCE[0]}")"
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 not on PATH" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "CANNOT-RUN: curl not on PATH" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-lwd.XXXXXX")" || { echo "CANNOT-RUN: mktemp" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

kill_daemons() {
    local p
    for p in $(cat "$WORK"/daemon.pids 2>/dev/null); do
        kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null
    done
    : > "$WORK/daemon.pids"
}
trap 'kill_daemons; rm -rf "$WORK"' EXIT
trap 'exit 143' INT TERM HUP

SCRIPT="${LWD_SCRIPT:-}"
if [ -z "$SCRIPT" ]; then
    SCRIPT="$WORK/ostler-listener-watchdog"
    awk '/<<'"'"'LISTENERWDEOF'"'"'$/{f=1;next} /^LISTENERWDEOF$/{f=0} f' "$ROOT/install.sh" > "$SCRIPT"
fi
if [ ! -s "$SCRIPT" ]; then
    bad "install.sh carries no LISTENERWDEOF watchdog heredoc"
    echo "$PASS passed, $FAIL failed"; exit 1
fi
DOCTOR_AGENT="${LWD_DOCTOR_AGENT:-$ROOT/vendor/doctor/agent}"

grep -q '<string>com.ostler.listener-watchdog</string>' "$ROOT/install.sh" \
    && ok "install.sh writes the com.ostler.listener-watchdog plist" || bad "no com.ostler.listener-watchdog plist in install.sh"
_labels="$(awk '/^OSTLER_LAUNCHAGENT_LABELS=\(/{f=1} f&&/^\)/{f=0} f' "$ROOT/install.sh")"
grep -q 'com.ostler.listener-watchdog' <<<"$_labels" \
    && ok "the uninstaller's label list names the watchdog" || bad "OSTLER_LAUNCHAGENT_LABELS does not name com.ostler.listener-watchdog"
_pl="$(awk '/<<LISTENERWDPLIST$/{f=1;next} /^LISTENERWDPLIST$/{f=0} f' "$ROOT/install.sh")"
case "$_pl" in
    *"<integer>60</integer>"*"<string>/bin/bash</string>"*|*"<string>/bin/bash</string>"*"<integer>60</integer>"*) ok "plist: StartInterval 60, absolute /bin/bash" ;;
    *) bad "plist lacks StartInterval 60 or the absolute /bin/bash interpreter" ;;
esac

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
cat > "$WORK/fake_daemon.py" <<'EOF'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer.allow_reuse_address = True
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
start_daemon() {
    python3 "$WORK/fake_daemon.py" "$PORT" >/dev/null 2>&1 &
    echo $! > "$WORK/daemon.pid"; echo $! >> "$WORK/daemon.pids"
    local i=0
    while [ "$i" -lt 50 ]; do
        [ "$(curl -s --noproxy '*' -m 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null)" = 401 ] && return 0
        sleep 0.1; i=$((i + 1))
    done
    echo "CANNOT-RUN: fake daemon did not answer on ${PORT}" >&2; exit 2
}
wedge_daemon() { kill -STOP "$(cat "$WORK/daemon.pid")"; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$WORK/lc.calls"
case "\$1" in
  print)
    [ "\${FAKE_LC_MODE:-loaded}" = notloaded ] && { echo 'Could not find service "x" in domain for user gui: 501'; exit 113; }
    [ "\${FAKE_LC_MODE:-loaded}" = broken ] && { echo 'Bootstrap failed: 5: Input/output error'; exit 5; }
    printf 'gui/501/x = {\n\tstate = running\n\tpid = %s\n}\n' "\$(cat "$WORK/daemon.pid")"; exit 0 ;;
  kickstart)
    p="\$(cat "$WORK/daemon.pid")"; kill -CONT "\$p" 2>/dev/null; kill "\$p" 2>/dev/null
    if [ "\${FAKE_REVIVES:-1}" = 1 ]; then
      python3 "$WORK/fake_daemon.py" "$PORT" >/dev/null 2>&1 &
      echo \$! > "$WORK/daemon.pid"; echo \$! >> "$WORK/daemon.pids"
    fi
    exit 0 ;;
esac
exit 0
EOF
cat > "$WORK/bin/sample" <<'EOF'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = -file ] && out="$2"; shift; done
[ -n "$out" ] && echo "Call graph: fake sample of the wedged daemon" > "$out"
EOF
cat > "$WORK/bin/lsof" <<'EOF'
#!/usr/bin/env bash
echo "COMMAND PID FD TYPE NAME"; echo "fake 1 7u IPv4 TCP *:8443 (LISTEN)"
EOF
for t in vm_stat memory_pressure; do printf '#!/usr/bin/env bash\necho "fake %s"\n' "$t" > "$WORK/bin/$t"; done
cat > "$WORK/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
echo "{ 1.00 1.00 1.00 }"
EOF
chmod +x "$WORK/bin/"*

# run <home>: one watchdog tick. Knobs come from the environment.
run() {
    mkdir -p "$1/logs"
    printf 'daemon err line %s\n' 1 2 3 > "$1/logs/ostler-assistant.err"
    PATH="$WORK/bin:$PATH" \
    OSTLER_LISTENER_WD_OSTLER_DIR="$1" \
    OSTLER_LISTENER_WD_URL="http://127.0.0.1:${PORT}/api/sessions" \
    OSTLER_LISTENER_WD_LAUNCHCTL="$WORK/bin/launchctl" \
    OSTLER_LISTENER_WD_CONNECT_S=1 OSTLER_LISTENER_WD_MAX_S=1 \
    OSTLER_LISTENER_WD_VERIFY_S="${VERIFY_S:-6}" OSTLER_LISTENER_WD_VERIFY_POLL_S=1 \
    OSTLER_LISTENER_WD_SAMPLE_S=1 \
    OSTLER_LISTENER_WD_INSTALL_RUNNING_CMD="${INSTALL_RUNNING:-false}" \
    /bin/bash "$SCRIPT" >> "$1/run.log" 2>&1
}
kicks() { grep -c '^kickstart -k' "$WORK/lc.calls" 2>/dev/null || true; }
field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1/state/listener_watchdog.json" "$2" 2>/dev/null; }
fresh() { kill_daemons; : > "$WORK/lc.calls"; rm -rf "$WORK/h$1"; start_daemon; printf '%s' "$WORK/h$1"; }

echo "== watchdog cases (port ${PORT})"
# 1. alive: no restart
H="$(fresh 1)"; run "$H"; run "$H"; run "$H"
[ "$(kicks)" = 0 ] && [ "$(field "$H" state)" = ok ] && [ "$(field "$H" last_http_code)" = 401 ] \
    && ok "1 alive (401): 3 ticks, 0 restarts, state ok" || bad "1 alive listener: kicks=$(kicks) state=$(field "$H" state)"

# 2. two failures: no restart
H="$(fresh 2)"; wedge_daemon; run "$H"; run "$H"
[ "$(kicks)" = 0 ] && [ "$(field "$H" consecutive_failures)" = 2 ] && [ "$(field "$H" state)" = failing ] \
    && ok "2 two silent probes: 0 restarts, state failing, 2 failures" || bad "2 two failures: kicks=$(kicks) state=$(field "$H" state) fails=$(field "$H" consecutive_failures)"

# 3 + 6. third failure: capture, restart, verified recovery
run "$H"
cap="$(field "$H" last_capture)"
[ "$(kicks)" = 1 ] && ok "3 third silent probe: exactly 1 kickstart -k" || bad "3 third failure gave $(kicks) kickstarts"
if [ -n "$cap" ] && [ -s "$cap/sample.txt" ] && grep -q 'Call graph' "$cap/sample.txt" && grep -q LISTEN "$cap/lsof.txt" \
   && grep -q 'daemon err line 3' "$cap/daemon-err-tail.txt" && [ -s "$cap/load.txt" ] && grep -q vm_stat "$cap/memory.txt"; then
    ok "3 capture before restart: sample, lsof, err tail, load, memory in ${cap#$WORK/}"
else
    bad "3 capture incomplete or missing (${cap:-no last_capture})"
fi
case "$cap" in "$H/logs/listener-watchdog/"2*) ok "3 capture lives under logs/listener-watchdog/<ts>" ;; *) bad "3 capture path ${cap}" ;; esac
[ "$(field "$H" state)" = recovered ] && [ -n "$(field "$H" last_restart_at)" ] && [ "$(field "$H" restarts_last_hour)" = 1 ] \
    && grep -q 'RECOVERED' "$H/run.log" \
    && ok "6 restart verified: state recovered, last_restart_at set, restarts_last_hour 1" \
    || bad "6 restart not verified: state=$(field "$H" state) rlh=$(field "$H" restarts_last_hour)"
[ "$(curl -s --noproxy '*' -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/")" = 401 ] \
    && ok "6 the fake :8443 answers 401 again" || bad "6 listener not back"
cp "$H/state/listener_watchdog.json" "$WORK/recovered.json"

# 4. deliberate-stop marker: no restart, however long it is dead
H="$(fresh 4)"; wedge_daemon; mkdir -p "$H"; : > "$H/deliberate-stop"
run "$H"; run "$H"; run "$H"; run "$H"
[ "$(kicks)" = 0 ] && [ "$(field "$H" state)" = stopped_deliberately ] \
    && ok "4 deliberate-stop marker: 4 dead ticks, 0 restarts" || bad "4 marker ignored: kicks=$(kicks) state=$(field "$H" state)"

# 4b. install running: no restart
H="$(fresh 4b)"; wedge_daemon
INSTALL_RUNNING=true run "$H"; INSTALL_RUNNING=true run "$H"; INSTALL_RUNNING=true run "$H"
[ "$(kicks)" = 0 ] && [ "$(field "$H" state)" = install_running ] \
    && ok "4b install running: 0 restarts" || bad "4b restarted during install: kicks=$(kicks)"

# 4c. job not loaded: no restart
H="$(fresh 4c)"; wedge_daemon
FAKE_LC_MODE=notloaded run "$H"; FAKE_LC_MODE=notloaded run "$H"; FAKE_LC_MODE=notloaded run "$H"
[ "$(kicks)" = 0 ] && [ "$(field "$H" state)" = not_loaded ] \
    && ok "4c daemon job not loaded: 0 restarts" || bad "4c restarted a not-loaded job: kicks=$(kicks)"

# 4d. launchctl unreadable: CANNOT-RUN (rc 2), no restart
H="$(fresh 4d)"; wedge_daemon
FAKE_LC_MODE=broken run "$H"; rc=$?
[ "$rc" = 2 ] && [ "$(kicks)" = 0 ] && [ "$(field "$H" state)" = cannot_run ] \
    && ok "4d unreadable launchctl: rc 2 cannot_run, 0 restarts" || bad "4d rc=$rc kicks=$(kicks) state=$(field "$H" state)"

# 5. 4th restart in an hour refused, state degraded. Kickstart does not revive.
H="$(fresh 5)"; wedge_daemon
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do FAKE_REVIVES=0 VERIFY_S=1 run "$H"; done
[ "$(kicks)" = 3 ] && ok "5 12 dead ticks: exactly 3 restarts, the 4th refused" || bad "5 restarts in the hour: $(kicks), want 3"
[ "$(field "$H" state)" = degraded ] && [ "$(field "$H" restarts_last_hour)" = 3 ] && grep -q 'DEGRADED' "$H/run.log" \
    && ok "5 state degraded, restarts_last_hour 3" || bad "5 state=$(field "$H" state) rlh=$(field "$H" restarts_last_hour)"
grep -q 'NOT RECOVERED' "$H/run.log" && ok "5 an unanswered restart is logged NOT RECOVERED" || bad "5 no NOT RECOVERED line"
cp "$H/state/listener_watchdog.json" "$WORK/degraded.json"

# 7. capture retention: at most 5 kept
H="$(fresh 7)"; mkdir -p "$H/logs/listener-watchdog"
for d in 20200101T000001Z 20200101T000002Z 20200101T000003Z 20200101T000004Z 20200101T000005Z 20200101T000006Z 20200101T000007Z; do mkdir -p "$H/logs/listener-watchdog/$d"; done
wedge_daemon; run "$H"; run "$H"; run "$H"
n="$(ls -1d "$H/logs/listener-watchdog"/2* | wc -l | tr -d ' ')"
[ "$n" = 5 ] && [ -d "$(field "$H" last_capture)" ] && ok "7 retention: 8 captures -> 5 kept, newest kept" || bad "7 retention kept ${n}"

echo "== Doctor renders the watchdog's state"
doctor_titles() { # doctor_titles <state-json>: titles run_all_rules returns
    rm -rf "$WORK/dstate"; mkdir -p "$WORK/dstate"; cp "$1" "$WORK/dstate/listener_watchdog.json"
    OSTLER_STATE_DIR="$WORK/dstate" python3 - "$DOCTOR_AGENT" <<'EOF'
import sys, types
sys.path.insert(0, sys.argv[1])
import diagnostic_rules as dr
snap = types.SimpleNamespace(services=[], containers=[], docker_error=None)
for f in dr.run_all_rules(snap):
    print("%s|%s" % (f.get("severity"), f.get("title")))
EOF
}
DC_DEGRADED="$(python3 -c "import sys;sys.path.insert(0,'$DOCTOR_AGENT');import diagnostic_copy as c;print(c.LISTENER_DEGRADED_TITLE)" 2>/dev/null)"
DC_RECOVERED="$(python3 -c "import sys;sys.path.insert(0,'$DOCTOR_AGENT');import diagnostic_copy as c;print(c.LISTENER_RECOVERED_TITLE)" 2>/dev/null)"
DC_UNREADABLE="$(python3 -c "import sys;sys.path.insert(0,'$DOCTOR_AGENT');import diagnostic_copy as c;print(c.LISTENER_STATE_UNREADABLE_TITLE)" 2>/dev/null)"
if [ -z "$DC_DEGRADED" ]; then
    bad "D the Doctor copy carries no LISTENER_DEGRADED_TITLE"
else
    out="$(doctor_titles "$WORK/degraded.json" 2>&1)"
    grep -qxF "critical|${DC_DEGRADED}" <<<"$out" && ok "D degraded state (written by case 5) renders a CRITICAL Doctor row" || bad "D degraded state rendered no critical row: $(grep -i 'iphone\|listener' <<<"$out" | head -2)"
    out="$(doctor_titles "$WORK/recovered.json" 2>&1)"
    grep -qxF "info|${DC_RECOVERED}" <<<"$out" && ok "D recovered state (written by case 3) renders an info row" || bad "D recovered state rendered no info row"
    grep -qF "${DC_DEGRADED}" <<<"$out" && bad "D a recovered listener still shows the degraded row" || ok "D negative control: a recovered listener shows no degraded row"
    printf '{"state": "ok", "consecutive_failures": 0, "last_restart_at": "", "restarts_last_hour": 0}\n' > "$WORK/okjson"
    out="$(doctor_titles "$WORK/okjson" 2>&1)"
    grep -qiF "iphone app" <<<"$out" && bad "D a healthy, never-restarted listener rendered a row" || ok "D negative control: healthy state renders nothing"
    printf '{"state": "degr' > "$WORK/badjson"
    out="$(doctor_titles "$WORK/badjson" 2>&1)"
    grep -qxF "warning|${DC_UNREADABLE}" <<<"$out" && ok "D an unparseable state file renders couldn't check, not silence" || bad "D unparseable state rendered no couldn't-check row"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ -n "${LWD_NO_MUTANTS:-}" ] && exit 0

echo "== mutants: each guard removed must turn this suite red"
mutate() { # mutate <name> <python-replace-old> <new> [occurrence]
    local m="$WORK/mut-$1"
    python3 - "$SCRIPT" "$m" "$2" "$3" "${4:-1}" <<'EOF' || { bad "mutant did not apply (its anchor moved): $1"; return 2; }
import sys
src, dst, old, new, occ = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
s = open(src).read()
idx = -1
for _ in range(occ):
    idx = s.find(old, idx + 1)
    if idx < 0: sys.exit(1)
open(dst, "w").write(s[:idx] + new + s[idx + len(old):])
EOF
    if LWD_SCRIPT="$m" LWD_NO_MUTANTS=1 bash "$SELF" "$ROOT" > "$WORK/mut-$1.out" 2>&1; then
        bad "mutant survived: $1"
    else
        ok "mutant killed: $1 ($(grep -c '^  FAIL' "$WORK/mut-$1.out") case(s) red)"
    fi
}
MUTS=0
mutate fail_threshold   '[ "$n" -lt "$FAIL_N" ]'           '[ "$n" -lt 1 ]'; MUTS=$((MUTS+1))
mutate alive_check      'if [ "$LAST_CODE" != "000" ]; then' 'if false; then'; MUTS=$((MUTS+1))
mutate stop_marker      'if [ -e "$STOP_MARKER" ]; then'     'if false; then'; MUTS=$((MUTS+1))
mutate install_guard    'if lwd_install_running; then'           'if false; then'; MUTS=$((MUTS+1))
mutate not_loaded_guard '*"Could not find service"*)'        '*"never-matches"*)'; MUTS=$((MUTS+1))
mutate hourly_backoff   'if [ "$rlh" -ge "$MAX_PER_HOUR" ]; then' 'if false; then'; MUTS=$((MUTS+1))
mutate capture_sample   'sample "$PID" "$SAMPLE_S"'          'true "$PID" "$SAMPLE_S"'; MUTS=$((MUTS+1))
mutate capture_lsof     'lsof -nP -p "$PID" >'               'true >'; MUTS=$((MUTS+1))
mutate restart_verify   'if [ "$LAST_CODE" != "000" ]; then' 'if false; then' 2; MUTS=$((MUTS+1))
mutate retention        "awk -v k=\"\$CAPTURE_KEEP\" 'NR>k'" "awk 'NR>1000'"; MUTS=$((MUTS+1))
# Doctor: the rule unregistered from ALL_RULES.
rm -rf "$WORK/dmut"; cp -R "$DOCTOR_AGENT" "$WORK/dmut"
python3 - "$WORK/dmut/diagnostic_rules.py" <<'EOF'
import sys; p=sys.argv[1]; s=open(p).read()
old="    check_listener_watchdog,\n    check_redis_health,"
assert s.count(old)==1, "doctor mutant did not apply"
open(p,"w").write(s.replace(old,"    check_redis_health,"))
EOF
if LWD_DOCTOR_AGENT="$WORK/dmut" LWD_NO_MUTANTS=1 bash "$SELF" "$ROOT" > "$WORK/mut-doctor.out" 2>&1; then
    bad "mutant survived: doctor_rule_unregistered"
else
    ok "mutant killed: doctor_rule_unregistered ($(grep -c '^  FAIL' "$WORK/mut-doctor.out") case(s) red)"
fi
MUTS=$((MUTS+1))
echo "EXAMINED: ${MUTS} mutants"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
