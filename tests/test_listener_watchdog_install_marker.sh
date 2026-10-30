#!/usr/bin/env bash
# The listener watchdog decides "an install is running" from the installer's own
# marker (state/install-in-progress: exists, under 6 h old, pid alive), NOT from
# `pgrep -f /install.sh`, which matched any process holding that string in its
# argv and parked a wedged listener as install_running for good.
#
# Runs the EXACT bytes install.sh writes (LISTENERWDEOF), with the real
# detection (no OSTLER_LISTENER_WD_INSTALL_RUNNING_CMD seam), against a wedged
# fake daemon. launchctl and the capture tools are shims.
#   1 stub with /install.sh in argv, NO marker  -> not install_running, restarts
#   2 live marker, live pid                     -> install_running, no restart
#   3a marker older than 6 h                    -> no deferral, restarts
#   3b marker naming a dead pid                 -> no deferral, restarts
#   3c marker with no pid                       -> no deferral, restarts
#   4 seam still wins over the marker
# Usage: [REPO_ROOT]. rc 0 all pass, 1 a case failed, 2 CANNOT-RUN.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SELF="${ROOT}/tests/$(basename "${BASH_SOURCE[0]}")"
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 not on PATH" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "CANNOT-RUN: curl not on PATH" >&2; exit 2; }
command -v pgrep >/dev/null 2>&1 || { echo "CANNOT-RUN: pgrep not on PATH" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-lwdm.XXXXXX")" || { echo "CANNOT-RUN: mktemp" >&2; exit 2; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "CANNOT-RUN: mktemp gave no directory" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
cleanup() {
    local p
    for p in $(cat "$WORK"/pids 2>/dev/null); do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 143' INT TERM HUP

SCRIPT="${LWD_SCRIPT:-$WORK/ostler-listener-watchdog}"
[ -n "${LWD_SCRIPT:-}" ] || awk '/<<'"'"'LISTENERWDEOF'"'"'$/{f=1;next} /^LISTENERWDEOF$/{f=0} f' "$ROOT/install.sh" > "$SCRIPT"
[ -s "$SCRIPT" ] || { echo "CANNOT-RUN: no LISTENERWDEOF heredoc in install.sh" >&2; exit 2; }

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
cat > "$WORK/fake_daemon.py" <<'PYEND'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer.allow_reuse_address = True
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEND
start_daemon() {
    python3 "$WORK/fake_daemon.py" "$PORT" >/dev/null 2>&1 &
    echo $! > "$WORK/daemon.pid"; echo $! >> "$WORK/pids"; echo $! >> "$WORK/daemons"
    local i=0
    while [ "$i" -lt 50 ]; do
        [ "$(curl -s --noproxy '*' -m 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null)" = 401 ] && return 0
        sleep 0.1; i=$((i + 1))
    done
    echo "CANNOT-RUN: fake daemon did not answer on ${PORT}" >&2; exit 2
}
mkdir -p "$WORK/bin"
cat > "$WORK/bin/launchctl" <<SHIMEND
#!/usr/bin/env bash
echo "\$*" >> "$WORK/lc.calls"
case "\$1" in
  print) printf 'gui/501/x = {\n\tstate = running\n\tpid = %s\n}\n' "\$(cat "$WORK/daemon.pid")"; exit 0 ;;
  kickstart)
    p="\$(cat "$WORK/daemon.pid")"; kill -CONT "\$p" 2>/dev/null; kill "\$p" 2>/dev/null
    python3 "$WORK/fake_daemon.py" "$PORT" >/dev/null 2>&1 &
    echo \$! > "$WORK/daemon.pid"; echo \$! >> "$WORK/pids"; echo \$! >> "$WORK/daemons"; exit 0 ;;
esac
exit 0
SHIMEND
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/sample"
for t in lsof vm_stat memory_pressure sysctl; do printf '#!/usr/bin/env bash\necho "fake %s"\n' "$t" > "$WORK/bin/$t"; done
chmod +x "$WORK/bin/"*

run() { # run <home> [seam]: one watchdog tick, real install detection unless a seam is given
    mkdir -p "$1/logs" "$1/state"
    [ -z "${2:-}" ] || export OSTLER_LISTENER_WD_INSTALL_RUNNING_CMD="$2"
    PATH="$WORK/bin:$PATH" \
    OSTLER_LISTENER_WD_OSTLER_DIR="$1" \
    OSTLER_LISTENER_WD_URL="http://127.0.0.1:${PORT}/api/sessions" \
    OSTLER_LISTENER_WD_LAUNCHCTL="$WORK/bin/launchctl" \
    OSTLER_LISTENER_WD_CONNECT_S=1 OSTLER_LISTENER_WD_MAX_S=1 \
    OSTLER_LISTENER_WD_VERIFY_S=6 OSTLER_LISTENER_WD_VERIFY_POLL_S=1 OSTLER_LISTENER_WD_SAMPLE_S=1 \
    /bin/bash "$SCRIPT" >> "$1/run.log" 2>&1
    local rc=$?; unset OSTLER_LISTENER_WD_INSTALL_RUNNING_CMD; return $rc
}
kicks() { grep -c '^kickstart -k' "$WORK/lc.calls" 2>/dev/null || true; }
field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1/state/listener_watchdog.json" "$2" 2>/dev/null; }
kill_daemons() { local p; for p in $(cat "$WORK/daemons" 2>/dev/null); do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; : > "$WORK/daemons"; sleep 0.3; }
fresh() { kill_daemons; : > "$WORK/lc.calls"; rm -rf "${WORK:?}/h$1"; start_daemon; kill -STOP "$(cat "$WORK/daemon.pid")"; printf '%s' "$WORK/h$1"; }
three() { run "$1" "${2:-}"; run "$1" "${2:-}"; run "$1" "${2:-}"; }
# A stub whose argv carries /install.sh, as a leftover installer child does.
stub() { bash -c 'sleep 600; :' "$WORK/fake/install.sh" >/dev/null 2>&1 & STUB=$!; echo "$STUB" >> "$WORK/pids"; }
marker() { mkdir -p "$1/state"; printf 'pid=%s\n' "$2" > "$1/state/install-in-progress"; }

echo "== watchdog install detection (port ${PORT})"
stub
sleep 0.3
pgrep -f '/install\.sh' | grep -qx "$STUB" && ok "0 control: the stub's argv matches pgrep -f /install.sh (pid ${STUB})" || bad "0 control: pgrep does not see the stub"

H="$(fresh 1)"; three "$H"
[ "$(field "$H" state)" != install_running ] && [ "$(kicks)" = 1 ] \
    && ok "1 /install.sh in a stray argv, no marker: not install_running, wedged listener restarted" \
    || bad "1 stray argv deferred the watchdog: state=$(field "$H" state) kicks=$(kicks)"

H="$(fresh 2)"; marker "$H" "$STUB"; three "$H"
[ "$(field "$H" state)" = install_running ] && [ "$(kicks)" = 0 ] \
    && ok "2 live marker, live pid: install_running, 0 restarts" || bad "2 live marker did not defer: state=$(field "$H" state) kicks=$(kicks)"

H="$(fresh 3a)"; marker "$H" "$STUB"; touch -t 202001010000 "$H/state/install-in-progress"; three "$H"
[ "$(field "$H" state)" != install_running ] && [ "$(kicks)" = 1 ] \
    && ok "3a marker over 6 h old: no deferral, restarted" || bad "3a stale marker deferred: state=$(field "$H" state) kicks=$(kicks)"

( exit 0 ) & DEAD=$!; wait "$DEAD" 2>/dev/null
H="$(fresh 3b)"; marker "$H" "$DEAD"; three "$H"
[ "$(field "$H" state)" != install_running ] && [ "$(kicks)" = 1 ] \
    && ok "3b marker names a dead pid: no deferral, restarted" || bad "3b dead pid deferred: state=$(field "$H" state) kicks=$(kicks)"

H="$(fresh 3c)"; mkdir -p "$H/state"; : > "$H/state/install-in-progress"; three "$H"
[ "$(field "$H" state)" != install_running ] && [ "$(kicks)" = 1 ] \
    && ok "3c marker with no pid: no deferral, restarted" || bad "3c pidless marker deferred: state=$(field "$H" state) kicks=$(kicks)"

H="$(fresh 4)"; three "$H" true
[ "$(field "$H" state)" = install_running ] && [ "$(kicks)" = 0 ] \
    && ok "4 OSTLER_LISTENER_WD_INSTALL_RUNNING_CMD seam still wins" || bad "4 seam ignored: state=$(field "$H" state)"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ -n "${LWD_NO_MUTANTS:-}" ] && exit 0

echo "== mutant: pgrep restored in lwd_install_running must turn this suite red"
python3 - "$SCRIPT" "$WORK/mut" <<'PYEND' || { bad "mutant did not apply (anchor moved)"; echo "$PASS passed, $FAIL failed"; exit 1; }
import sys
s = open(sys.argv[1]).read()
i = s.index("lwd_install_running() {")
j = s.index("\n}\n", i)
new = ("lwd_install_running() {\n"
       "    if [ -n \"$INSTALL_RUNNING_CMD\" ]; then eval \"$INSTALL_RUNNING_CMD\"; return $?; fi\n"
       "    pgrep -f '/install\\.sh' >/dev/null 2>&1 && return 0\n"
       "    pgrep -f 'ostler-uninstall' >/dev/null 2>&1 && return 0\n"
       "    return 1")
open(sys.argv[2], "w").write(s[:i] + new + s[j:])
PYEND
if LWD_SCRIPT="$WORK/mut" LWD_NO_MUTANTS=1 bash "$SELF" "$ROOT" > "$WORK/mut.out" 2>&1; then
    bad "mutant survived: pgrep restored"
else
    grep -q '^  FAIL 1 ' "$WORK/mut.out" \
        && ok "mutant killed: pgrep restored ($(grep -c '^  FAIL' "$WORK/mut.out") case(s) red, case 1 among them)" \
        || bad "mutant went red but not on case 1"
fi
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
