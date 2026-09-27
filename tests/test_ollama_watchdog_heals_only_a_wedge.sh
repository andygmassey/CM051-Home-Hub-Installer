#!/usr/bin/env bash
# The Ollama wedge watchdog (#2432) must restart com.ostler.ollama when, and
# only when, the server is WEDGED: /api/version answers, a tiny embed fails
# twice in a row, and Ollama makes NO PROGRESS (the serve process's stderr,
# read by size through its open fd, has not grown since the last probe). It
# must NOT restart a server that is merely busy (log growing, even at 0% CPU:
# Apple Silicon runs inference on the GPU), down (launchd owns that), healthy, on its first
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
case "$*" in
  *-Fs*) [ "${SHIM_LOGSIZE:-}" = unreadable ] && exit 1
         f="${SHIM_SIZEFILE:-}"; n=100
         if [ -n "$f" ]; then n=$(cat "$f" 2>/dev/null || echo 100); [ "${SHIM_GROW:-0}" = 1 ] && echo $((n+500)) > "$f"; [ "${SHIM_SHRINK:-0}" = 1 ] && echo $((n/2)) > "$f"; fi
         printf 'p4242\nf2\ns%s\n' "$n"; exit 0 ;;
esac
echo "COMMAND PID"; echo "ostler-as 1"; echo "ostler-as 1"
EOF
cat > "$WORK/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
echo 4242
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

# 4. busy ON THE GPU: failed probes, 0% CPU, but the serve log keeps growing
# -> no restart. This is the v1.0.103 candidate 4 false heal (07:09Z).
S="$WORK/s4"; echo 1000 > "$WORK/size4"
for i in 1 2 3; do SHIM_EMBED=000 SHIM_CPU=0.0 SHIM_GROW=1 SHIM_SIZEFILE="$WORK/size4" run busy "$S"; done
[ "$(restarts busy)" = 0 ] && ok "busy on the GPU (3 fails, 0% cpu, log growing): no restart" || bad "restarted a busy server whose log was growing"
[ "$(evcount "$WORK/s4")" = 0 ] && ok "busy: no evidence file (nothing was restarted)" || bad "busy wrote evidence"
grep -q 'serve stderr changed' "$WORK/log.busy" && ok "busy is logged as progress, with the byte counts" || bad "no progress line logged"

# 4b. MUTANT: restore the CPU-only guard; the GPU-busy case must now restart,
# or case 4 proves nothing about the progress check.
MUT="$WORK/mutant"
sed -e 's/if \[ -n "\$cur_size" \] \&\& \[ -n "\$prev_size" \]; then/if false; then/' "$SCRIPT" > "$MUT"; chmod +x "$MUT"
grep -q '^if false; then' "$MUT" && ok "mutation applied" || bad "mutation did not apply"
S="$WORK/s4m"; echo 1000 > "$WORK/size4m"
for i in 1 2; do
    PATH="$WORK/bin:$PATH" SHIM_CALLS="$WORK/calls.mut" OSTLER_WATCHDOG_STATE_DIR="$S" \
        OSTLER_WATCHDOG_EVIDENCE_DIR="$S/evidence" OSTLER_WATCHDOG_OLLAMA_LOG_DIR="$WORK/ologs" \
        OSTLER_WATCHDOG_PROBE_S=1 SHIM_EMBED=000 SHIM_CPU=0.0 SHIM_GROW=1 SHIM_SIZEFILE="$WORK/size4m" \
        "$MUT" >> "$WORK/log.mut" 2>&1
done
[ "$(restarts mut)" = 1 ] && ok "MUST-FAIL mutant (CPU-only guard) restarts the GPU-busy server" || bad "the CPU-only mutant did not restart: case 4 is not a real assertion"

# 4d. the rotation truncated the log: size SHRANK between probes. That is
# change, so BUSY -> no restart. A -gt check would read it as idle.
S="$WORK/s4d"; echo 100000 > "$WORK/size4d"
for i in 1 2 3; do SHIM_EMBED=000 SHIM_CPU=0.0 SHIM_SHRINK=1 SHIM_SIZEFILE="$WORK/size4d" run shrink "$S"; done
[ "$(restarts shrink)" = 0 ] && ok "log shrank (rotation) + failed probes: no restart" || bad "restarted after a rotation shrank the log"
MUT2="$WORK/mutant_gt"; sed -e 's/if \[ "\$cur_size" != "\$prev_size" \]; then/if [ "$cur_size" -gt "$prev_size" ]; then/' "$SCRIPT" > "$MUT2"; chmod +x "$MUT2"
grep -q 'cur_size" -gt "\$prev_size' "$MUT2" && ok "-gt mutation applied" || bad "-gt mutation did not apply"
S="$WORK/s4dm"; echo 100000 > "$WORK/size4dm"
for i in 1 2 3; do PATH="$WORK/bin:$PATH" SHIM_CALLS="$WORK/calls.gt" OSTLER_WATCHDOG_STATE_DIR="$S" OSTLER_WATCHDOG_EVIDENCE_DIR="$S/evidence" OSTLER_WATCHDOG_OLLAMA_LOG_DIR="$WORK/ologs" OSTLER_WATCHDOG_PROBE_S=1 SHIM_EMBED=000 SHIM_CPU=0.0 SHIM_SHRINK=1 SHIM_SIZEFILE="$WORK/size4dm" "$MUT2" >> "$WORK/log.gt" 2>&1; done
[ "$(restarts gt)" -ge 1 ] && ok "MUST-FAIL mutant (-gt) restarts the busy engine whose log shrank" || bad "the -gt mutant did not restart: arm 4d is not a real assertion"

# 4c. progress unreadable: fall back to CPU, and say so.
S="$WORK/s4c"; for i in 1 2; do SHIM_EMBED=000 SHIM_CPU=85.0 SHIM_LOGSIZE=unreadable run fallback "$S"; done
[ "$(restarts fallback)" = 0 ] && ok "progress unreadable + 85% cpu: CPU fallback, no restart" || bad "fallback restarted a CPU-busy server"
grep -q 'progress unreadable; fallback cpu' "$WORK/log.fallback" && ok "the fallback is named in the log" || bad "fallback not named"

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
