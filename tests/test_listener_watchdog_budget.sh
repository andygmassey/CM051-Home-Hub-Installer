#!/usr/bin/env bash
# v1.0.116c: probe listener_watchdog_recovers_a_wedged_listener FAILED although the
# watchdog recovered (STRIKE 1/3 03:07:38, 3/3 03:10:14, CAPTURE took 60 s, RESTART
# 03:11:14, RECOVERED 03:11:57; the probe's fixed 300 s window expired first).
# Pins: (1) the diagnostic capture is bounded and the restart does not wait behind a
# hung sample/lsof; (2) strike spacing is logged; (3) the probe's budget is DERIVED
# from the shipped config and covers the 116c timeline; (4) a listener that never
# recovers still FAILs inside that budget; (5) an unreadable config is CANNOT-RUN.
# Then mutants. Usage: [REPO_ROOT]. rc 0 pass, 1 fail, 2 CANNOT-RUN.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SELF="${ROOT}/tests/$(basename "${BASH_SOURCE[0]}")"
INSTALL="${LWB_INSTALL:-$ROOT/install.sh}"
PROBE="${LWB_PROBE:-$ROOT/scripts/box_walk_probes/probes/listener_watchdog_recovers_a_wedged_listener.sh}"
command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 and curl needed" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-lwb.XXXXXX")" || { echo "CANNOT-RUN: mktemp" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
cleanup() {
    local p; for p in $(cat "$WORK"/pids 2>/dev/null); do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 143' INT TERM HUP
: > "$WORK/pids"

WD="$WORK/watchdog"
awk '/<<'"'"'LISTENERWDEOF'"'"'$/{f=1;next} /^LISTENERWDEOF$/{f=0} f' "$INSTALL" > "$WD"
[ -s "$WD" ] || { echo "  FAIL install.sh carries no LISTENERWDEOF heredoc"; exit 1; }

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
DEADPORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
cat > "$WORK/fake_daemon.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer.allow_reuse_address = True
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
mkdir -p "$WORK/bin"
cat > "$WORK/bin/launchctl" <<EOF2
#!/usr/bin/env bash
case "\$1" in
  print)
    case "\$2" in
      *listener-watchdog) echo "state = waiting"; exit 0 ;;
    esac
    printf '\tstate = running\n\tpid = %s\n' "\$(cat "$WORK/daemon.pid")"; exit 0 ;;
  kickstart)
    echo "kickstart \$(date +%s)" >> "$WORK/ks.log"
    [ -e "$WORK/ks.noop" ] && exit 0
    [ -e "$WORK/ks.dead" ] && { p="\$(cat "$WORK/daemon.pid")"; kill -CONT "\$p" 2>/dev/null; kill "\$p" 2>/dev/null; exit 0; }
    p="\$(cat "$WORK/daemon.pid")"; kill -CONT "\$p" 2>/dev/null; kill "\$p" 2>/dev/null
    python3 "$WORK/fake_daemon.py" "$PORT" >/dev/null 2>&1 &
    echo \$! > "$WORK/daemon.pid"; echo \$! >> "$WORK/pids"; exit 0 ;;
esac
exit 0
EOF2
# sample and lsof HANG when $WORK/hang exists (the wedged daemon: 60 s in 116c); exec so
# the pid the watchdog signals is the sleeper itself.
cat > "$WORK/bin/sample" <<'EOF2'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = -file ] && out="$2"; shift; done
[ -e "$(dirname "$0")/../hang" ] && exec sleep 60
[ -n "$out" ] && echo "Call graph: fake" > "$out"
EOF2
cat > "$WORK/bin/lsof" <<'EOF2'
#!/usr/bin/env bash
[ -e "$(dirname "$0")/../hang" ] && exec sleep 60
echo "fake 1 7u IPv4 TCP *:8443 (LISTEN)"
EOF2
for t in vm_stat memory_pressure sysctl; do printf '#!/usr/bin/env bash\necho fake\n' > "$WORK/bin/$t"; done
chmod +x "$WORK/bin/"*

H="$WORK/home"
fresh_home() { rm -rf "$H"; mkdir -p "$H/.ostler/bin" "$H/.ostler/logs" "$H/.ostler/state" "$H/Library/LaunchAgents"; cp "$WD" "$H/.ostler/bin/ostler-listener-watchdog"; chmod +x "$H/.ostler/bin/ostler-listener-watchdog"; }
wd_env() { # env for the watchdog; $1 = URL
    echo "PATH=$WORK/bin:$PATH HOME=$H OSTLER_LISTENER_WD_URL=$1 OSTLER_LISTENER_WD_LAUNCHCTL=$WORK/bin/launchctl OSTLER_LISTENER_WD_CONNECT_S=1 OSTLER_LISTENER_WD_MAX_S=1 OSTLER_LISTENER_WD_VERIFY_S=2 OSTLER_LISTENER_WD_VERIFY_POLL_S=1 OSTLER_LISTENER_WD_SAMPLE_S=1 OSTLER_LISTENER_WD_INSTALL_RUNNING_CMD=false"
}
sleep 300 & echo $! > "$WORK/daemon.pid"; echo $! >> "$WORK/pids"

echo "== T1 a hung sample/lsof does not hold the restart (cap 2 s; hang is 60 s)"
fresh_home; : > "$WORK/hang"; rm -f "$WORK/ks.log"
echo 2 > "$H/.ostler/state/listener_watchdog.fails"
t0=$(date +%s)
# shellcheck disable=SC2046
env $(wd_env "http://127.0.0.1:${DEADPORT}/api/sessions") OSTLER_LISTENER_WD_CAPTURE_MAX_S=2 \
    /bin/bash "$H/.ostler/bin/ostler-listener-watchdog" > "$WORK/t1.log" 2>&1 &
WP=$!
i=0; while [ "$i" -lt 150 ] && ! grep -q 'RESTART' "$WORK/t1.log" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
dt=$(( $(date +%s) - t0 ))
grep -q 'RESTART' "$WORK/t1.log" && [ "$dt" -le 25 ] && ok "T1 RESTART ${dt}s after the 3rd strike with sample+lsof hung 60 s (cap 2 s)" || bad "T1 restart took ${dt}s or never came (cap 2 s, hang 60 s): $(tr '\n' '|' < "$WORK/t1.log" | cut -c1-300)"
kill "$WP" 2>/dev/null; wait "$WP" 2>/dev/null; pkill -P "$WP" 2>/dev/null
cap="$(sed -n 's/.*CAPTURE \([^ ]*\).*/\1/p' "$WORK/t1.log" | head -1)"
[ -s "$cap/sample.txt" ] && [ -s "$cap/lsof.txt" ] && ok "T1 a timed-out capture still leaves a non-empty sample.txt and lsof.txt (the probe requires both)" || bad "T1 capture files empty or missing in '${cap}'"
rm -f "$WORK/hang"

echo "== T2 strike spacing is logged"
fresh_home; echo 1 > "$H/.ostler/state/listener_watchdog.fails"; echo $(( $(date +%s) - 70 )) > "$H/.ostler/state/listener_watchdog.fails_at"
env $(wd_env "http://127.0.0.1:${DEADPORT}/api/sessions") /bin/bash "$H/.ostler/bin/ostler-listener-watchdog" > "$WORK/t2.log" 2>&1
grep -Eq 'PROBE-FAIL 2/3.*, 7[0-3]s since the previous strike' "$WORK/t2.log" && ok "T2 PROBE-FAIL 2/3 carries the gap since strike 1" || bad "T2 no gap in: $(cat "$WORK/t2.log")"

echo "== T3 --print-config exposes what the probe derives from"
fresh_home
out="$(env $(wd_env x) /bin/bash "$H/.ostler/bin/ostler-listener-watchdog" --print-config 2>&1)"
[ "$(printf '%s\n' "$out" | sed -n 's/^fail_n=//p')" = 3 ] && printf '%s\n' "$out" | grep -q '^capture_max_s=[0-9]' && ok "T3 --print-config: $(printf '%s' "$out" | tr '\n' ' ')" || bad "T3 --print-config gave: $out"

echo "== T4 the budget is derived and covers the 116c timeline"
eval "$(sed -n '/^_lwr_budget() {/,/^}/p' "$PROBE")" 2>/dev/null
if declare -F _lwr_budget >/dev/null; then
    # 116c: SIGSTOP ~03:06:50, RECOVERED 03:11:57 with a 60 s capture = 307 s after the stop.
    # Shipped config: StartInterval 60, 3 strikes, curl 5 s, capture cap 10 s, verify 60 s, margin 30 s.
    b="$(_lwr_budget 60 3 5 10 60 30)"
    [ "$b" -ge 307 ] && ok "T4 derived budget ${b}s >= the 307 s the 116c recovery actually took (old fixed window: 300 s)" || bad "T4 derived budget ${b}s < 307 s"
    [ "$(_lwr_budget 60 3 5 10 60 30)" -gt "$(_lwr_budget 30 3 5 10 60 30)" ] && [ "$(_lwr_budget 60 3 5 10 60 30)" -gt "$(_lwr_budget 60 2 5 10 60 30)" ] && [ "$(_lwr_budget 60 3 5 20 60 30)" -gt "$(_lwr_budget 60 3 5 10 60 30)" ] && ok "T4 budget grows with interval, strikes and the capture cap" || bad "T4 budget is not monotonic in its inputs"
else
    bad "T4 the probe has no _lwr_budget function (budget not derived)"
fi
grep -Eq 'OSTLER_LWR_BUDGET_S:-[0-9]+' "$PROBE" && bad "T4 the probe still hard-codes a default budget" || ok "T4 no numeric default budget in the probe"

echo "== T5 the real probe, fake box: derived budget, never-recovering listener, unreadable config"
PL="$H/Library/LaunchAgents/com.ostler.listener-watchdog.plist"
mkplist() { awk '/^cat > "\$LISTENER_WD_PLIST" <<LISTENERWDPLIST$/{f=1;next} /^LISTENERWDPLIST$/{f=0} f' "$INSTALL" | sed -e "s|\${HOME}|$H|g" -e "s|\${_ollama_rot_logs}|$H/.ostler/logs|g" -e "s|<integer>60</integer>|<integer>1</integer>|" > "$PL"; }
setup() { # fresh home with watchdog + plist, daemon up
    fresh_home; mkplist; rm -f "$WORK/ks.noop" "$WORK/ks.dead"
    local p; for p in $(cat "$WORK/pids"); do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; : > "$WORK/pids"
    python3 "$WORK/fake_daemon.py" "$PORT" >/dev/null 2>&1 & echo $! > "$WORK/daemon.pid"; echo $! >> "$WORK/pids"
    local i=0; while [ "$i" -lt 50 ]; do
        [ "$(curl -s --noproxy '*' -m 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/")" = 401 ] && return 0
        sleep 0.1; i=$((i + 1)); done
    echo "CANNOT-RUN: fake daemon did not start" >&2; exit 2
}
start_loop() {
    ( while :; do
        env $(wd_env "http://127.0.0.1:${PORT}/api/sessions") OSTLER_LISTENER_WD_CAPTURE_MAX_S=2 \
            /bin/bash "$H/.ostler/bin/ostler-listener-watchdog" >> "$WORK/loop.log" 2>&1
        sleep 1
      done ) &
    LOOP_PID=$!
}
stop_loop() { kill "$LOOP_PID" 2>/dev/null; wait "$LOOP_PID" 2>/dev/null; }
run_probe() {
    env HOME="$H" PATH="$WORK/bin:$PATH" OSTLER_PROBE_LAUNCHCTL="$WORK/bin/launchctl" \
        OSTLER_LWR_URL="http://127.0.0.1:${PORT}/api/sessions" OSTLER_LWR_POLL_S=1 OSTLER_LWR_MARGIN_S=2 \
        OSTLER_LISTENER_WD_CAPTURE_MAX_S=2 OSTLER_LISTENER_WD_MAX_S=1 OSTLER_LISTENER_WD_VERIFY_S=2 \
        bash "$PROBE" > "$WORK/p.out" 2>&1; echo $?
}
verdict() { sed -n 's/^VERDICT: \([A-Z-]*\).*/\1/p' "$WORK/p.out" | tail -1; }
# expected budget from the inputs: interval 1, 3 strikes, curl 1, cap 2, verify 2, margin 2 = (1*3*3+1)/2 + 3 + 2 + 2 + 2
EXPECT=$(( (1 * 3 * 3 + 1) / 2 + 3 * 1 + 2 + 2 + 2 ))
setup; start_loop; rc="$(run_probe)"; stop_loop
nb="$(sed -n 's/.*wait budget \([0-9]*\)s = .*/\1/p' "$WORK/p.out" | head -1)"
[ "$nb" = "$EXPECT" ] && ok "T5 probe derived budget ${nb}s from the plist + --print-config (expected ${EXPECT}s)" || bad "T5 probe budget '${nb}', expected ${EXPECT}: $(grep -i budget "$WORK/p.out" | head -2)"
[ "$rc" = 0 ] && [ "$(verdict)" = PASS ] && ok "T5 working watchdog: PASS" || bad "T5 working watchdog gave rc=$rc $(verdict): $(tail -4 "$WORK/p.out")"
# control A: the restart never happens (watchdog only un-stops the daemon) -> must FAIL
setup; : > "$WORK/ks.noop"; start_loop; rc="$(run_probe)"; stop_loop
[ "$rc" = 1 ] && [ "$(verdict)" = FAIL ] && grep -q 'resumed, not restarted' "$WORK/p.out" && ok "T5 CONTROL A a restart that never happens still FAILs" || bad "T5 CONTROL A gave rc=$rc $(verdict): $(tail -2 "$WORK/p.out")"
# control B: restarted but the listener never comes back -> must FAIL at the derived budget
setup; : > "$WORK/ks.dead"; start_loop; t0=$(date +%s); rc="$(run_probe)"; stop_loop; dt=$(( $(date +%s) - t0 ))
[ "$rc" = 1 ] && [ "$(verdict)" = FAIL ] && grep -q 'answered HTTP 000' "$WORK/p.out" && [ "$dt" -le $((EXPECT + 12)) ] && ok "T5 CONTROL B a listener that never recovers FAILs within the derived budget (${dt}s of ${EXPECT}s)" || bad "T5 CONTROL B gave rc=$rc $(verdict) in ${dt}s: $(tail -2 "$WORK/p.out")"
# unreadable config -> CANNOT-RUN, daemon untouched
setup; rm -f "$PL"; rc="$(run_probe)"
st="$(ps -o stat= -p "$(cat "$WORK/daemon.pid")" 2>/dev/null)"
[ "$rc" = 78 ] && [ "$(verdict)" = CANNOT-RUN ] && case "$st" in T*) false ;; *) true ;; esac && ok "T5 no plist: CANNOT-RUN, daemon not stopped" || bad "T5 no plist gave rc=$rc $(verdict) stat=$st"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ -n "${LWB_NO_MUTANTS:-}" ] && exit 0

echo "== mutants"
mutate() { # mutate <name> <file-var: install|probe> <old> <new>
    local name="$1" kind="$2" m="$WORK/mut-$1.sh"
    local src="$INSTALL"; [ "$kind" = probe ] && src="$PROBE"
    python3 - "$src" "$m" "$3" "$4" <<'PY' || { bad "mutant did not apply: $name"; return; }
import sys
s=open(sys.argv[1]).read()
if s.count(sys.argv[3]) != 1: sys.exit(1)
open(sys.argv[2],"w").write(s.replace(sys.argv[3], sys.argv[4]))
PY
    if [ "$kind" = probe ]; then
        mkdir -p "$WORK/mp/probes"; ln -sfn "$ROOT/scripts/box_walk_probes/lib" "$WORK/mp/lib"; cp "$m" "$WORK/mp/probes/x.sh"; m="$WORK/mp/probes/x.sh"
        LWB_PROBE="$m" LWB_NO_MUTANTS=1 bash "$SELF" "$ROOT" > "$WORK/mut-$name.out" 2>&1; r=$?
    else
        LWB_INSTALL="$m" LWB_NO_MUTANTS=1 bash "$SELF" "$ROOT" > "$WORK/mut-$name.out" 2>&1; r=$?
    fi
    if [ "$r" -ne 0 ]; then ok "mutant killed: $name ($(grep -c '^  FAIL' "$WORK/mut-$name.out") red)"; else bad "mutant survived: $name"; fi
}
mutate uncap_capture install 'if [ "$ticks" -ge $((limit * 10)) ]; then' 'if [ "$ticks" -ge 99999999 ]; then'
mutate hardcode_300 probe 'LWR_BUDGET_S="${OSTLER_LWR_BUDGET_S:-}"' 'LWR_BUDGET_S="${OSTLER_LWR_BUDGET_S:-300}"'
mutate no_drift_factor probe 'echo $(( ($1 * $2 * 3 + 1) / 2 + $2 * $3 + $4 + $5 + $6 ))' 'echo $(( $1 * $2 + $2 * $3 + $4 + $5 + $6 ))'
mutate no_gap_log install 'lwd_log "PROBE-FAIL ${n}/${FAIL_N}: ${URL} gave no HTTP status (daemon pid ${PID:-none})${_gap}"' 'lwd_log "PROBE-FAIL ${n}/${FAIL_N}: ${URL} gave no HTTP status (daemon pid ${PID:-none})"'
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
