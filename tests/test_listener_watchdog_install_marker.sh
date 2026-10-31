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
#   5 Sparkle upgrade (OSTLER_UPGRADE_MODE=1, real install.sh upgrade block): a watchdog
#     tick fired from inside the upgrade's launchctl bootout, listener down -> holds off
#   6 the upgrade block clears its marker on EVERY exit: success, early exit 10,
#     codesign exit 21, rollback success, rollback exit 50
#   7 an upgrade killed -9 (trap cannot run) leaves a marker with a dead pid -> no deferral
# Usage: [REPO_ROOT]. rc 0 all pass, 1 a case failed, 2 CANNOT-RUN.
# Progress: one "@HH:MM:SS start|end <case>" line per case, on stdout AND appended to
# $STEP_PROGRESS_FILE when set (scripts/bounded_step.sh cats it when the step hangs).
# LWD_SELFTEST_HANG=1 plants a hang as the very first thing the script does (before any case, so any
# host reaches it in under 1 s; used only by tests/test_bounded_step.sh).
# LWD_PHASE picks what runs (the macos runner is ~3x slower than a laptop, so CI runs one phase per
# bounded step): unset/all = 14 cases then the 3 mutants; cases = the 14 cases only (same as
# LWD_NO_MUTANTS=1); mutant-pgrep | mutant-write | mutant-trap = that one mutant run, no cases.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SELF="${ROOT}/tests/$(basename "${BASH_SOURCE[0]}")"
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 not on PATH" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "CANNOT-RUN: curl not on PATH" >&2; exit 2; }
command -v pgrep >/dev/null 2>&1 || { echo "CANNOT-RUN: pgrep not on PATH" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || { echo "CANNOT-RUN: the real install.sh upgrade block uses BSD stat; run on macOS" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-lwdm.XXXXXX")" || { echo "CANNOT-RUN: mktemp" >&2; exit 2; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "CANNOT-RUN: mktemp gave no directory" >&2; exit 2; }
PASS=0; FAIL=0
PROGRESS="${STEP_PROGRESS_FILE:-}"
prog()  { local l; l="@$(date -u +%H:%M:%S) $*"; echo "$l"; [ -z "$PROGRESS" ] || echo "$l" >> "$PROGRESS"; }
begin() { prog "start $*"; }
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; prog "end   ok ${1%% *}"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; prog "end   FAIL ${1%% *}"; }
cleanup() {
    local p
    for p in $(cat "$WORK"/pids 2>/dev/null); do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    # the stub leads its own process group: kill the group too, or its `sleep 600` leaks for 10 min
    for p in $(cat "$WORK"/pgids 2>/dev/null); do kill -- "-$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 143' INT TERM HUP

[ -z "${LWD_SELFTEST_HANG:-}" ] || { begin hang-planted; bash -c 'sleep 86400; :'; }

PHASE="${LWD_PHASE:-all}"
case "$PHASE" in all|cases|mutant-pgrep|mutant-write|mutant-trap) ;; *) echo "CANNOT-RUN: unknown LWD_PHASE '${PHASE}'" >&2; exit 2 ;; esac
[ "$PHASE" != cases ] || LWD_NO_MUTANTS=1
want_mutant() { [ "$PHASE" = all ] || [ "$PHASE" = "mutant-$1" ]; }
run_cases() { [ "$PHASE" = all ] || [ "$PHASE" = cases ]; }

begin setup
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
    local t0=$SECONDS
    mkdir -p "$1/logs" "$1/state"
    [ -z "${2:-}" ] || export OSTLER_LISTENER_WD_INSTALL_RUNNING_CMD="$2"
    PATH="$WORK/bin:$PATH" \
    OSTLER_LISTENER_WD_OSTLER_DIR="$1" \
    OSTLER_LISTENER_WD_URL="http://127.0.0.1:${PORT}/api/sessions" \
    OSTLER_LISTENER_WD_LAUNCHCTL="$WORK/bin/launchctl" \
    OSTLER_LISTENER_WD_CONNECT_S=1 OSTLER_LISTENER_WD_MAX_S=1 \
    OSTLER_LISTENER_WD_VERIFY_S=6 OSTLER_LISTENER_WD_VERIFY_POLL_S=1 OSTLER_LISTENER_WD_SAMPLE_S=1 \
    /bin/bash "$SCRIPT" >> "$1/run.log" 2>&1
    local rc=$?; unset OSTLER_LISTENER_WD_INSTALL_RUNNING_CMD
    prog "tick ${1##*/} rc=${rc} took $((SECONDS - t0))s"
    return $rc
}
kicks() { grep -c '^kickstart -k' "$WORK/lc.calls" 2>/dev/null || true; }
field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1/state/listener_watchdog.json" "$2" 2>/dev/null; }
kill_daemons() { local p; for p in $(cat "$WORK/daemons" 2>/dev/null); do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; : > "$WORK/daemons"; sleep 0.3; }
fresh() { kill_daemons; : > "$WORK/lc.calls"; rm -rf "${WORK:?}/h$1"; start_daemon; kill -STOP "$(cat "$WORK/daemon.pid")"; printf '%s' "$WORK/h$1"; }
three() { run "$1" "${2:-}"; run "$1" "${2:-}"; run "$1" "${2:-}"; }
# A stub whose argv carries /install.sh, as a leftover installer child does.
stub() { set -m; bash -c 'sleep 600; :' "$WORK/fake/install.sh" >/dev/null 2>&1 & STUB=$!; set +m; echo "$STUB" >> "$WORK/pids"; echo "$STUB" >> "$WORK/pgids"; }
marker() { mkdir -p "$1/state"; printf 'pid=%s\n' "$2" > "$1/state/install-in-progress"; }

if run_cases; then
echo "== watchdog install detection (port ${PORT})"
begin 0
stub
sleep 0.3
pgrep -f '/install\.sh' | grep -qx "$STUB" && ok "0 control: the stub's argv matches pgrep -f /install.sh (pid ${STUB})" || bad "0 control: pgrep does not see the stub"

begin 1
H="$(fresh 1)"; three "$H"
[ "$(field "$H" state)" != install_running ] && [ "$(kicks)" = 1 ] \
    && ok "1 /install.sh in a stray argv, no marker: not install_running, wedged listener restarted" \
    || bad "1 stray argv deferred the watchdog: state=$(field "$H" state) kicks=$(kicks)"

begin 2
H="$(fresh 2)"; marker "$H" "$STUB"; three "$H"
[ "$(field "$H" state)" = install_running ] && [ "$(kicks)" = 0 ] \
    && ok "2 live marker, live pid: install_running, 0 restarts" || bad "2 live marker did not defer: state=$(field "$H" state) kicks=$(kicks)"

begin 3a
H="$(fresh 3a)"; marker "$H" "$STUB"; touch -t 202001010000 "$H/state/install-in-progress"; three "$H"
[ "$(field "$H" state)" != install_running ] && [ "$(kicks)" = 1 ] \
    && ok "3a marker over 6 h old: no deferral, restarted" || bad "3a stale marker deferred: state=$(field "$H" state) kicks=$(kicks)"

begin 3b
( exit 0 ) & DEAD=$!; wait "$DEAD" 2>/dev/null
H="$(fresh 3b)"; marker "$H" "$DEAD"; three "$H"
[ "$(field "$H" state)" != install_running ] && [ "$(kicks)" = 1 ] \
    && ok "3b marker names a dead pid: no deferral, restarted" || bad "3b dead pid deferred: state=$(field "$H" state) kicks=$(kicks)"

begin 3c
H="$(fresh 3c)"; mkdir -p "$H/state"; : > "$H/state/install-in-progress"; three "$H"
[ "$(field "$H" state)" != install_running ] && [ "$(kicks)" = 1 ] \
    && ok "3c marker with no pid: no deferral, restarted" || bad "3c pidless marker deferred: state=$(field "$H" state) kicks=$(kicks)"

begin 4
H="$(fresh 4)"; three "$H" true
[ "$(field "$H" state)" = install_running ] && [ "$(kicks)" = 0 ] \
    && ok "4 OSTLER_LISTENER_WD_INSTALL_RUNNING_CMD seam still wins" || bad "4 seam ignored: state=$(field "$H" state)"

echo "== upgrade block (OSTLER_UPGRADE_MODE) install marker"
begin upgrade-setup
UPG_SH="${UPG_INSTALL_SH:-$ROOT/install.sh}"
mkdir -p "$WORK/ubin" "$WORK/pay/assistant-agent/OstlerAssistant.app/Contents/MacOS"
echo 1.0.1 > "$WORK/pay/VERSION"
echo x > "$WORK/pay/assistant-agent/OstlerAssistant.app/Contents/MacOS/ostler-assistant"
cat > "$WORK/pay/assistant-agent/INSTALL_SNIPPET.sh" <<'SNIPEND'
mkdir -p "$HOME/Library/LaunchAgents"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>x</string><key>EnvironmentVariables</key><dict/></dict></plist>\n' > "$HOME/Library/LaunchAgents/com.creativemachines.ostler.assistant.plist"
SNIPEND
# The upgrade's own launchctl: at the first bootout (step 3, listener going down) it snapshots the
# marker and, when asked, fires three watchdog ticks from inside the upgrade, or kill -9s the upgrade.
cat > "$WORK/tick.sh" <<TICKEND
#!/usr/bin/env bash
mkdir -p "\$HOME/.ostler/logs" "\$HOME/.ostler/state"
for i in 1 2 3; do
    PATH="$WORK/bin:\$PATH" OSTLER_LISTENER_WD_OSTLER_DIR="\$HOME/.ostler" \\
    OSTLER_LISTENER_WD_URL="http://127.0.0.1:${PORT}/api/sessions" \\
    OSTLER_LISTENER_WD_LAUNCHCTL="$WORK/bin/launchctl" \\
    OSTLER_LISTENER_WD_CONNECT_S=1 OSTLER_LISTENER_WD_MAX_S=1 \\
    OSTLER_LISTENER_WD_VERIFY_S=6 OSTLER_LISTENER_WD_VERIFY_POLL_S=1 OSTLER_LISTENER_WD_SAMPLE_S=1 \\
    /bin/bash "$SCRIPT" >> "\$HOME/.ostler/run.log" 2>&1
done
TICKEND
cat > "$WORK/ubin/launchctl" <<UBEND
#!/usr/bin/env bash
if [ "\$1" = bootout ] && [ ! -e "\$HOME/.snap-done" ]; then
    : > "\$HOME/.snap-done"
    cat "\$HOME/.ostler/state/install-in-progress" > "\$HOME/.snap" 2>/dev/null
    [ -z "\${UPG_TICK:-}" ] || /bin/bash "$WORK/tick.sh"
    [ -z "\${UPG_KILL9:-}" ] || kill -9 "\$PPID"
fi
exit 0
UBEND
printf '#!/usr/bin/env bash\nexit "${UPG_CODESIGN_RC:-0}"\n' > "$WORK/ubin/codesign"
chmod +x "$WORK/ubin/launchctl" "$WORK/ubin/codesign"
upg() { # upg <home> [VAR=val ...]: one real upgrade-block run; rc on stdout line "rc=N"
    local h="$1"; shift
    mkdir -p "$h/.ostler/OstlerAssistant.app" "$h/Library/LaunchAgents"
    env PATH="$WORK/ubin:$PATH" HOME="$h" OSTLER_UPGRADE_PAYLOAD_DIR="$WORK/pay" "$@" \
        /bin/bash "$UPG_SH" > "$h/upg.out" 2>&1
    echo "rc=$?"
}
marker_gone() { [ ! -e "$1/.ostler/state/install-in-progress" ]; }

begin 5
H="$(fresh 5)"; R="$(upg "$H" OSTLER_UPGRADE_MODE=1 UPG_TICK=1)"
SNAP="$(cat "$H/.snap" 2>/dev/null)"
[ "$R" = rc=0 ] && [[ "$SNAP" =~ ^pid=[0-9]+$ ]] && [ "$(field "$H/.ostler" state)" = install_running ] && [ "$(kicks)" = 0 ] \
    && ok "5 upgrade mode, listener down, marker present at bootout (${SNAP}): watchdog holds off, 0 restarts" \
    || bad "5 watchdog did not hold off during the upgrade: $R snap='${SNAP}' state=$(field "$H/.ostler" state) kicks=$(kicks)"

arm() { # arm <label> <expected rc> <vars...>: run an upgrade arm, rc must match AND the marker must be gone
    local lbl="$1" want="$2" ph="$WORK/hb-$1"; shift 2
    begin "6-$lbl"
    rm -rf "$ph"; mkdir -p "$ph/.ostler"
    [ "$lbl" != rollback ] || { mkdir -p "$ph/.ostler/OstlerAssistant.app.old"; }
    local r; r="$(upg "$ph" "$@")"
    if [ "$r" = "rc=$want" ] && marker_gone "$ph"; then ok "6 ${lbl}: $r, marker gone"
    else bad "6 ${lbl}: $r (want rc=$want), marker $(marker_gone "$ph" && echo gone || echo LEFT BEHIND)"; fi
}
arm success 0 OSTLER_UPGRADE_MODE=1
arm early-exit-10 10 OSTLER_UPGRADE_MODE=1 OSTLER_UPGRADE_PAYLOAD_DIR=/nonexistent-payload-dir
arm codesign-21 21 OSTLER_UPGRADE_MODE=1 UPG_CODESIGN_RC=1
arm rollback 0 OSTLER_UPGRADE_ROLLBACK=1
arm rollback-50 50 OSTLER_UPGRADE_ROLLBACK=1

begin 7
H="$(fresh 7)"; R="$(upg "$H" OSTLER_UPGRADE_MODE=1 UPG_KILL9=1)"
LEFT="$(cat "$H/.ostler/state/install-in-progress" 2>/dev/null)"; LPID="${LEFT#pid=}"
ps -p "$LPID" >/dev/null 2>&1 && LIVE=1 || LIVE=0
[[ "$LEFT" =~ ^pid=[0-9]+$ ]] && [ "$LIVE" = 0 ] || bad "7 precondition: kill -9 should leave a marker with a dead pid (left='${LEFT}' alive=${LIVE})"
three "$H/.ostler"
[ "$(field "$H/.ostler" state)" != install_running ] && [ "$(kicks)" = 1 ] \
    && ok "7 upgrade killed -9, stale marker (${LEFT}, pid gone): no deferral, restarted" \
    || bad "7 stale marker from a killed upgrade deferred: state=$(field "$H/.ostler" state) kicks=$(kicks)"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
fi
[ -n "${LWD_NO_MUTANTS:-}" ] && exit 0

if want_mutant pgrep; then
begin mutant-pgrep
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
if STEP_PROGRESS_FILE= LWD_SCRIPT="$WORK/mut" LWD_PHASE=cases bash "$SELF" "$ROOT" > "$WORK/mut.out" 2>&1; then
    bad "mutant survived: pgrep restored"
else
    grep -q '^  FAIL 1 ' "$WORK/mut.out" \
        && ok "mutant killed: pgrep restored ($(grep -c '^  FAIL' "$WORK/mut.out") case(s) red, case 1 among them)" \
        || bad "mutant went red but not on case 1"
fi
fi
echo "== mutants: the upgrade block's marker write / trap removed must turn cases 5 / 6 red"
for M in write trap; do
    want_mutant "$M" || continue
    begin "mutant-$M"
    mkdir -p "$WORK/mroot-$M"
    python3 - "$ROOT/install.sh" "$WORK/mroot-$M/install.sh" "$M" <<'PYEND' || { bad "mutant ${M} did not apply (anchor moved)"; continue; }
import sys
L = open(sys.argv[1]).read().split("\n")
i = next(n for n, l in enumerate(L) if l.startswith("    _UPG_MARKER="))
j = i + 1
assert "trap '" in L[j], "upgrade-block marker line moved"
if sys.argv[3] == "write":   # no marker is ever written
    L[j] = L[j].replace("printf 'pid=%s\\n' \"$$\" > \"$_UPG_MARKER\"", ": > /dev/null")
    L[j] = L[j].replace("&& rm -f", "&& :")
    assert ": > /dev/null" in L[j]
else:                        # written, never cleared
    L[j] = L[j].replace("rm -f \"$_UPG_MARKER\"", ":")
    assert "&& :" in L[j]
open(sys.argv[2], "w").write("\n".join(L))
PYEND
    STEP_PROGRESS_FILE= UPG_INSTALL_SH="$WORK/mroot-$M/install.sh" LWD_PHASE=cases bash "$SELF" "$ROOT" > "$WORK/mut-$M.out" 2>&1 && rc=0 || rc=$?
    want='^  FAIL 5 '; [ "$M" = trap ] && want='^  FAIL 6 '
    if [ "$rc" = 0 ]; then bad "mutant ${M} survived"
    elif grep -q "$want" "$WORK/mut-$M.out"; then ok "mutant ${M} killed ($(grep -c '^  FAIL' "$WORK/mut-$M.out") case(s) red)"
    else bad "mutant ${M} went red but not on the expected case"; fi
done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
