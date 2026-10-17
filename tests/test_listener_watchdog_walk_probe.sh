#!/usr/bin/env bash
# Drives the REAL walk probe listener_watchdog_recovers_a_wedged_listener
# against the fake-daemon harness, with the REAL watchdog (lifted from
# install.sh's LISTENERWDEOF heredoc) ticking every second in the background.
# The probe runs locally (OSTLER_BOX_HOST unset, so box_run is `bash -lc`).
#
# Cases: a working watchdog PASSes; an absent watchdog (no script, or agent
# not loaded) is FAIL, not CANNOT-RUN; a watchdog that never ticks FAILs and
# the daemon is NOT left stopped; a listener already down is CANNOT-RUN; a
# --read-only walk is CANNOT-RUN; the probe killed mid-wait leaves the daemon
# running; --self-test reports its negative control. Then mutants.
#
# Usage: [REPO_ROOT]. rc 0 pass, 1 fail, 2 CANNOT-RUN.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SELF="${ROOT}/tests/$(basename "${BASH_SOURCE[0]}")"
PROBE="${LWP_PROBE:-$ROOT/scripts/box_walk_probes/probes/listener_watchdog_recovers_a_wedged_listener.sh}"
[ -f "$PROBE" ] || { echo "  FAIL probe missing: $PROBE"; exit 1; }
command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 and curl needed" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-lwp.XXXXXX")" || { echo "CANNOT-RUN: mktemp" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
LOOP_PID=""
cleanup() {
    [ -n "$LOOP_PID" ] && kill "$LOOP_PID" 2>/dev/null
    local p; for p in $(cat "$WORK"/daemon.pids 2>/dev/null); do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

WD="$WORK/watchdog"
awk '/<<'"'"'LISTENERWDEOF'"'"'$/{f=1;next} /^LISTENERWDEOF$/{f=0} f' "$ROOT/install.sh" > "$WD"
[ -s "$WD" ] || { echo "  FAIL install.sh carries no LISTENERWDEOF heredoc"; exit 1; }

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
mkdir -p "$WORK/bin"
cat > "$WORK/bin/launchctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  print)
    case "\$2" in
      *listener-watchdog) [ -e "$WORK/wd.loaded" ] && { echo "state = waiting"; exit 0; }; echo 'Could not find service "w" in domain for user gui: 501'; exit 113 ;;
    esac
    printf '\tstate = running\n\tpid = %s\n' "\$(cat "$WORK/daemon.pid")"; exit 0 ;;
  kickstart)
    p="\$(cat "$WORK/daemon.pid")"; kill -CONT "\$p" 2>/dev/null; kill "\$p" 2>/dev/null
    python3 "$WORK/fake_daemon.py" "$PORT" >/dev/null 2>&1 &
    echo \$! > "$WORK/daemon.pid"; echo \$! >> "$WORK/daemon.pids"; exit 0 ;;
esac
exit 0
EOF
cat > "$WORK/bin/sample" <<'EOF'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = -file ] && out="$2"; shift; done
[ -n "$out" ] && echo "Call graph: fake" > "$out"
EOF
printf '#!/usr/bin/env bash\necho "fake 1 7u IPv4 TCP *:8443 (LISTEN)"\n' > "$WORK/bin/lsof"
for t in vm_stat memory_pressure sysctl; do printf '#!/usr/bin/env bash\necho fake\n' > "$WORK/bin/$t"; done
chmod +x "$WORK/bin/"*

H="$WORK/home"
setup() { # setup <watchdog-present 0|1> <agent-loaded 0|1>
    local p; for p in $(cat "$WORK"/daemon.pids 2>/dev/null); do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    : > "$WORK/daemon.pids"
    rm -rf "$H"; mkdir -p "$H/.ostler/bin" "$H/.ostler/logs"
    [ "$1" = 1 ] && cp "$WD" "$H/.ostler/bin/ostler-listener-watchdog" && chmod +x "$H/.ostler/bin/ostler-listener-watchdog"
    rm -f "$WORK/wd.loaded"; [ "$2" = 1 ] && : > "$WORK/wd.loaded"
    python3 "$WORK/fake_daemon.py" "$PORT" >/dev/null 2>&1 &
    echo $! > "$WORK/daemon.pid"; echo $! >> "$WORK/daemon.pids"
    local i=0; while [ "$i" -lt 50 ]; do
        [ "$(curl -s --noproxy '*' -m 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/")" = 401 ] && return 0
        sleep 0.1; i=$((i + 1)); done
    echo "CANNOT-RUN: fake daemon did not start" >&2; exit 2
}
start_loop() {
    ( while :; do
        PATH="$WORK/bin:$PATH" HOME="$H" \
        OSTLER_LISTENER_WD_URL="http://127.0.0.1:${PORT}/api/sessions" \
        OSTLER_LISTENER_WD_LAUNCHCTL="$WORK/bin/launchctl" \
        OSTLER_LISTENER_WD_CONNECT_S=1 OSTLER_LISTENER_WD_MAX_S=1 \
        OSTLER_LISTENER_WD_VERIFY_S=10 OSTLER_LISTENER_WD_VERIFY_POLL_S=1 OSTLER_LISTENER_WD_SAMPLE_S=1 \
        OSTLER_LISTENER_WD_INSTALL_RUNNING_CMD=false \
        /bin/bash "$H/.ostler/bin/ostler-listener-watchdog" >> "$WORK/loop.log" 2>&1
        sleep 1
      done ) &
    LOOP_PID=$!
}
stop_loop() { [ -n "$LOOP_PID" ] && kill "$LOOP_PID" 2>/dev/null; wait "$LOOP_PID" 2>/dev/null; LOOP_PID=""; }
probe() { # probe [extra env assignments...]; output in $WORK/p.out, rc echoed
    env HOME="$H" OSTLER_PROBE_LAUNCHCTL="$WORK/bin/launchctl" \
        OSTLER_LWR_URL="http://127.0.0.1:${PORT}/api/sessions" \
        OSTLER_LWR_BUDGET_S="${BUDGET:-30}" OSTLER_LWR_POLL_S=1 "$@" \
        bash "$PROBE" > "$WORK/p.out" 2>&1
    echo $?
}
verdict() { sed -n 's/^VERDICT: \([A-Z-]*\).*/\1/p' "$WORK/p.out" | tail -1; }
daemon_stopped() { # any fake daemon in state T?
    local p s; for p in $(cat "$WORK"/daemon.pids); do s="$(ps -o stat= -p "$p" 2>/dev/null)"; case "$s" in T*) echo 1; return ;; esac; done; echo 0
}

echo "== walk probe against the fake :8443 (port ${PORT})"
# P1 working watchdog -> PASS
setup 1 1; start_loop; rc="$(probe)"; stop_loop
[ "$rc" = 0 ] && [ "$(verdict)" = PASS ] && ok "P1 working watchdog: PASS ($(grep -m1 '^VERDICT' "$WORK/p.out" | cut -c1-110))" || { bad "P1 working watchdog gave rc=$rc $(verdict)"; sed 's/^/      /' "$WORK/p.out" | tail -8; }
[ "$(daemon_stopped)" = 0 ] && ok "P1 no daemon left stopped" || bad "P1 a daemon was left SIGSTOPped"

# P2 watchdog script absent -> FAIL, daemon untouched
setup 0 1; rc="$(probe)"
[ "$rc" = 1 ] && [ "$(verdict)" = FAIL ] && grep -q ABSENT "$WORK/p.out" && ok "P2 absent watchdog script: FAIL (not CANNOT-RUN)" || bad "P2 absent script gave rc=$rc $(verdict)"
[ "$(daemon_stopped)" = 0 ] && ok "P2 daemon untouched" || bad "P2 daemon left stopped"
# P2b agent not loaded -> FAIL
setup 1 0; rc="$(probe)"
[ "$rc" = 1 ] && [ "$(verdict)" = FAIL ] && ok "P2b watchdog agent not loaded: FAIL" || bad "P2b not-loaded agent gave rc=$rc $(verdict)"

# P3 present + loaded but never ticks -> FAIL-NO-RESTART, daemon resumed
setup 1 1; BUDGET=4 rc="$(BUDGET=4 probe)"
[ "$rc" = 1 ] && grep -q 'NO restart' "$WORK/p.out" && ok "P3 watchdog that never acts: FAIL, no restart recorded" || bad "P3 gave rc=$rc $(verdict)"
[ "$(daemon_stopped)" = 0 ] && ok "P3 daemon resumed after a failed run (never left stopped)" || bad "P3 daemon left SIGSTOPped after the probe returned"

# P4 listener already down -> CANNOT-RUN, nothing stopped
setup 1 1; kill "$(cat "$WORK/daemon.pid")"; sleep 0.3; rc="$(probe)"
[ "$rc" = 78 ] && [ "$(verdict)" = CANNOT-RUN ] && ok "P4 listener down before the probe: CANNOT-RUN" || bad "P4 gave rc=$rc $(verdict)"

# P5 read-only walk -> CANNOT-RUN
setup 1 1; rc="$(probe OSTLER_WALK_READ_ONLY=1)"
[ "$rc" = 78 ] && [ "$(daemon_stopped)" = 0 ] && ok "P5 --read-only walk: CANNOT-RUN, daemon untouched" || bad "P5 read-only gave rc=$rc"

# P6 the probe is killed mid-wait -> daemon resumed
setup 1 1
env HOME="$H" OSTLER_PROBE_LAUNCHCTL="$WORK/bin/launchctl" OSTLER_LWR_URL="http://127.0.0.1:${PORT}/api/sessions" \
    OSTLER_LWR_BUDGET_S=60 OSTLER_LWR_POLL_S=1 bash "$PROBE" > "$WORK/p6.out" 2>&1 &
PP=$!
i=0; while [ "$i" -lt 50 ] && [ "$(daemon_stopped)" = 0 ]; do sleep 0.2; i=$((i + 1)); done
was="$(daemon_stopped)"
kill -TERM "$PP"; wait "$PP" 2>/dev/null; sleep 1
[ "$was" = 1 ] && [ "$(daemon_stopped)" = 0 ] && ok "P6 probe SIGTERMed mid-wait: daemon resumed" || bad "P6 was_stopped=${was} still_stopped=$(daemon_stopped)"

# P7 self-test
bash "$PROBE" --self-test > "$WORK/st.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'negative control behaved correctly' "$WORK/st.out" && ok "P7 --self-test: negative control fires (rc 1, as the runner requires)" || bad "P7 self-test rc=$rc"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ -n "${LWP_NO_MUTANTS:-}" ] && exit 0

echo "== mutants"
mut() { # mut <name> <old> <new> [<old2> <new2> ...]
    local name="$1" m="$WORK/mut-$1.sh"; shift
    python3 - "$PROBE" "$m" "$@" <<'EOF' || { bad "mutant did not apply: $name"; return; }
import sys
s=open(sys.argv[1]).read(); a=sys.argv[3:]
for old,new in zip(a[0::2],a[1::2]):
    if s.count(old) != 1: sys.exit(1)
    s=s.replace(old,new)
open(sys.argv[2],"w").write(s)
EOF
    # the copied probe sources ../lib/probe.sh relative to itself
    mkdir -p "$WORK/mp/probes"; ln -sfn "$ROOT/scripts/box_walk_probes/lib" "$WORK/mp/lib"
    cp "$m" "$WORK/mp/probes/x.sh"
    if LWP_PROBE="$WORK/mp/probes/x.sh" LWP_NO_MUTANTS=1 bash "$SELF" "$ROOT" > "$WORK/mut-$name.out" 2>&1; then
        bad "mutant survived: $name"
    else
        ok "mutant killed: $name ($(grep -c '^  FAIL' "$WORK/mut-$name.out") red)"
    fi
}
mut absent_is_cannot_run 'if [ "$present" != 1 ]; then echo FAIL-ABSENT; return; fi' 'if [ "$present" != 1 ]; then echo CANNOT-RUN-NOT-UP; return; fi'
mut no_cont_layers 'trap '"'"'kill -CONT "$PID" 2>/dev/null; kill "$SLEEPER" 2>/dev/null'"'"' EXIT' 'trap '"'"'kill "$SLEEPER" 2>/dev/null'"'"' EXIT' \
    'if [ -n "$LWR_PID" ]; then box_run "kill -CONT ${LWR_PID} 2>/dev/null; true" >/dev/null 2>&1; fi' ':'
mut restart_not_required 'if [ "$restarted" != 1 ]; then echo FAIL-NO-RESTART; return; fi' ':'
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
