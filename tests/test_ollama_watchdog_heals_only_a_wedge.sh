#!/usr/bin/env bash
# The Ollama wedge watchdog (#2432) must restart com.ostler.ollama when, and
# only when, the server is WEDGED: /api/version answers, a tiny embed fails
# twice in a row, and every Ollama process is idle on CPU. It must NOT restart
# a server that is merely busy, down (launchd owns that), healthy, on its first
# failed probe, or inside the cooldown after a restart.
#
# The script under test is lifted from install.sh's OLLAMAWDEOF heredoc, so the
# test runs the exact bytes the installer writes. curl, ps, lsof and launchctl
# are shimmed on PATH; the shim for launchctl records every call it receives.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

SCRIPT="$WORK/ostler-ollama-watchdog"
awk '/<<'"'"'OLLAMAWDEOF'"'"'$/{f=1;next} /^OLLAMAWDEOF$/{f=0} f' "$ROOT/install.sh" > "$SCRIPT"
if [ ! -s "$SCRIPT" ]; then
    bad "install.sh carries no OLLAMAWDEOF watchdog heredoc"
    echo "$PASS passed, $FAIL failed"; exit 1
fi
chmod +x "$SCRIPT"
grep -q 'com.ostler.ollama-watchdog' "$ROOT/install.sh" && ok "install.sh writes the com.ostler.ollama-watchdog plist" || bad "no com.ostler.ollama-watchdog plist in install.sh"
awk '/^OSTLER_LAUNCHAGENT_LABELS=\(/{f=1} f&&/^\)/{f=0} f' "$ROOT/install.sh" | grep -q 'com.ostler.ollama-watchdog' \
    && ok "the uninstaller's label list names the watchdog" || bad "OSTLER_LAUNCHAGENT_LABELS does not name com.ostler.ollama-watchdog"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  */api/version*) [ "${SHIM_VERSION:-up}" = up ] && exit 0 || exit 7 ;;
  */api/embed*)   printf '%s' "${SHIM_EMBED:-200}"; [ "${SHIM_EMBED:-200}" = 200 ] && exit 0 || exit 28 ;;
esac
exit 0
EOF
cat > "$WORK/bin/ps" <<'EOF'
#!/usr/bin/env bash
printf '%s ollama\n%s llama-server\n' "${SHIM_CPU:-0.0}" "0.0"
EOF
cat > "$WORK/bin/lsof" <<'EOF'
#!/usr/bin/env bash
echo "COMMAND PID"; echo "ostler-as 1"; echo "ostler-as 1"
EOF
cat > "$WORK/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SHIM_CALLS"
EOF
chmod +x "$WORK/bin/"*

# run <case-name> <state-dir>; environment carries the SHIM_* knobs.
run() {
    PATH="$WORK/bin:$PATH" SHIM_CALLS="$WORK/calls.$1" OSTLER_WATCHDOG_STATE_DIR="$2" \
        OSTLER_WATCHDOG_PROBE_S=1 "$SCRIPT" >> "$WORK/log.$1" 2>&1
}
restarts() { [ -f "$WORK/calls.$1" ] && grep -c 'kickstart -k' "$WORK/calls.$1" || echo 0; }

# 1. healthy: never restarts, however often it runs
S="$WORK/s1"; for i in 1 2 3; do SHIM_EMBED=200 run healthy "$S"; done
[ "$(restarts healthy)" = 0 ] && ok "healthy server: 0 restarts in 3 runs" || bad "healthy server was restarted"

# 2. one failed probe: no restart yet
S="$WORK/s2"; SHIM_EMBED=000 run onefail "$S"
[ "$(restarts onefail)" = 0 ] && ok "first failed probe alone: no restart" || bad "restarted on a single failed probe"

# 3. wedged: two failed probes while idle -> exactly one restart
S="$WORK/s3"; SHIM_EMBED=000 SHIM_CPU=0.0 run wedged "$S"; SHIM_EMBED=000 SHIM_CPU=0.0 run wedged "$S"
[ "$(restarts wedged)" = 1 ] && ok "wedged (2 fails, idle): exactly 1 restart" || bad "wedged server: expected 1 restart, got $(restarts wedged)"
grep -q 'WEDGED' "$WORK/log.wedged" && ok "wedged restart is logged with its evidence" || bad "no WEDGED log line"

# 4. busy: two failed probes but Ollama is working -> no restart
S="$WORK/s4"; SHIM_EMBED=000 SHIM_CPU=85.0 run busy "$S"; SHIM_EMBED=000 SHIM_CPU=85.0 run busy "$S"
[ "$(restarts busy)" = 0 ] && ok "busy (2 fails, 85% cpu): no restart" || bad "restarted a busy server"

# 5. down: /api/version fails -> launchd's job, no restart
S="$WORK/s5"; for i in 1 2 3; do SHIM_VERSION=down SHIM_EMBED=000 run down "$S"; done
[ "$(restarts down)" = 0 ] && ok "down (/api/version fails): no restart" || bad "restarted a server that was down"

# 6. cooldown: a second wedge right after a restart is not restarted again
S="$WORK/s6"; for i in 1 2 3 4; do SHIM_EMBED=000 run cooldown "$S"; done
[ "$(restarts cooldown)" = 1 ] && ok "cooldown: 4 failed idle probes give 1 restart, not 2" || bad "cooldown ignored: $(restarts cooldown) restarts"

# 7. recovery resets the count: fail, heal, fail -> no restart
S="$WORK/s7"; SHIM_EMBED=000 run reset "$S"; SHIM_EMBED=200 run reset "$S"; SHIM_EMBED=000 run reset "$S"
[ "$(restarts reset)" = 0 ] && ok "a healthy probe between failures resets the count" || bad "failures were not reset by a healthy probe"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
