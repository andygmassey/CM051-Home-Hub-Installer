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

mkdir -p "$WORK/ologs"; printf 'ollama log line %s\n' 1 2 3 > "$WORK/ologs/ollama.err"
# run <case-name> <state-dir>; environment carries the SHIM_* knobs.
run() {
    PATH="$WORK/bin:$PATH" SHIM_CALLS="$WORK/calls.$1" OSTLER_WATCHDOG_STATE_DIR="$2" \
        OSTLER_WATCHDOG_EVIDENCE_DIR="$2/evidence" OSTLER_WATCHDOG_OLLAMA_LOG_DIR="$WORK/ologs" \
        OSTLER_WATCHDOG_PROBE_S=1 "$SCRIPT" >> "$WORK/log.$1" 2>&1
}
evcount() { ls -1 "$1"/evidence/wedge-*.txt 2>/dev/null | wc -l | tr -d ' '; }
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
[ "$(evcount "$WORK/s3")" = 1 ] && ok "wedged: one evidence file written before the restart" || bad "wedged: expected 1 evidence file, got $(evcount "$WORK/s3")"
EVF=$(ls -1 "$WORK"/s3/evidence/wedge-*.txt 2>/dev/null | head -1)
for _sec in '== /api/ps' '== lsof :11434' '== ollama processes' '== ollama open log files' '== tail -n 200 ollama.err'; do
    grep -qF -- "$_sec" "$EVF" 2>/dev/null && ok "evidence carries: $_sec" || bad "evidence missing: $_sec"
done
grep -q 'ollama log line 3' "$EVF" 2>/dev/null && ok "evidence carries the Ollama log tail" || bad "evidence lacks the Ollama log tail"

# 4. busy: two failed probes but Ollama is working -> no restart
S="$WORK/s4"; SHIM_EMBED=000 SHIM_CPU=85.0 run busy "$S"; SHIM_EMBED=000 SHIM_CPU=85.0 run busy "$S"
[ "$(restarts busy)" = 0 ] && ok "busy (2 fails, 85% cpu): no restart" || bad "restarted a busy server"
[ "$(evcount "$WORK/s4")" = 0 ] && ok "busy: no evidence file (nothing was restarted)" || bad "busy wrote evidence"

# 5. down: /api/version fails -> launchd's job, no restart
S="$WORK/s5"; for i in 1 2 3; do SHIM_VERSION=down SHIM_EMBED=000 run down "$S"; done
[ "$(restarts down)" = 0 ] && ok "down (/api/version fails): no restart" || bad "restarted a server that was down"

# 6. cooldown: a second wedge right after a restart is not restarted again
S="$WORK/s6"; for i in 1 2 3 4; do SHIM_EMBED=000 run cooldown "$S"; done
[ "$(restarts cooldown)" = 1 ] && ok "cooldown: 4 failed idle probes give 1 restart, not 2" || bad "cooldown ignored: $(restarts cooldown) restarts"

# 7. recovery resets the count: fail, heal, fail -> no restart
S="$WORK/s7"; SHIM_EMBED=000 run reset "$S"; SHIM_EMBED=200 run reset "$S"; SHIM_EMBED=000 run reset "$S"
[ "$(restarts reset)" = 0 ] && ok "a healthy probe between failures resets the count" || bad "failures were not reset by a healthy probe"

# 8. retention: 12 wedges with no cooldown keep only the newest 10 evidence files
S="$WORK/s8"; for i in $(seq 1 24); do SHIM_EMBED=000 OSTLER_WATCHDOG_COOLDOWN_S=0 run keep "$S"; done
[ "$(restarts keep)" = 12 ] && ok "retention case: 12 restarts" || bad "retention case: expected 12 restarts, got $(restarts keep)"
[ "$(evcount "$S")" = 10 ] && ok "retention: 10 evidence files kept of 12" || bad "retention: expected 10 evidence files, got $(evcount "$S")"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
