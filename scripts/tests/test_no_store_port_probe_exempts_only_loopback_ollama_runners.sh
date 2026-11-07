#!/usr/bin/env bash
# scripts/tests/test_no_store_port_probe_exempts_only_loopback_ollama_runners.sh
# ============================================================================
# Walk 124: no_store_port_is_tcp_reachable FAILED on llama-server runners that
# com.ostler.ollama spawns (ports 54447, 55034), bound to 127.0.0.1 only. The
# sweep flags any listener whose cmdline matches "ostler"; the runner lives
# under ~/.ostler. Archie r14: exempt ONLY runner + parent is `ollama serve` +
# every bind loopback. Real processes, real sockets, real lsof:
#   1 runner under `ollama serve`, bound 127.0.0.1  -> PASS, exemption printed
#   2 RED CONTROL: same runner bound 0.0.0.0        -> FAIL
#   3 non-runner loopback listener under ollama     -> FAIL
#   4 runner with NO ollama parent, loopback        -> FAIL
#   5 MUTANT: exemption ignores the bind            -> arm 2 must go green
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PROBE_DIR="$REPO_ROOT/scripts/box_walk_probes/probes"
PROBE="$PROBE_DIR/no_store_port_is_tcp_reachable.sh"
for need in python3 lsof; do command -v "$need" >/dev/null 2>&1 || { echo "CANNOT-RUN: $need not on PATH" >&2; exit 2; }; done
[[ -f "$PROBE" ]] || { echo "CANNOT-RUN: no probe" >&2; exit 2; }
pass=0; fail=0
TMP="$(mktemp -d)"; PIDS=""; MUT=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; [[ -z "$MUT" ]] || rm -f "$MUT"; }
trap cleanup EXIT
BIN="$TMP/.ostler/bin"; mkdir -p "$BIN"
# child: binds <addr>:0, writes its port. Named per role by the file name.
for role in llama-server mysvc; do
cat > "$BIN/$role" <<'PY'
#!/usr/bin/env python3
import socket, sys, time
s = socket.socket(socket.AF_INET6 if ':' in sys.argv[1] else socket.AF_INET); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], 0)); s.listen(4)
open(sys.argv[2] + '.tmp', 'w').write('%d\n' % s.getsockname()[1]); __import__('os').rename(sys.argv[2] + '.tmp', sys.argv[2])
time.sleep(120)
PY
done
# parent: `ollama serve`, owns the control port, spawns the child role.
cat > "$BIN/ollama" <<'PY'
#!/usr/bin/env python3
import socket, subprocess, sys, time, os
assert sys.argv[1] == 'serve'
c = socket.socket(); c.bind(('127.0.0.1', 0)); c.listen(4)
open(sys.argv[2] + '.ctl', 'w').write('%d\n' % c.getsockname()[1])
subprocess.Popen([os.path.join(os.path.dirname(__file__), sys.argv[3]), sys.argv[4], sys.argv[2]])
time.sleep(120)
PY
chmod +x "$BIN"/*
wait_file() { local i; for i in $(seq 1 50); do [[ -s "$1" ]] && return 0; sleep 0.1; done; return 1; }

# usage: scenario <role> <bind> <viaollama:yes|no>; sets CTRL, CPORT; LAST_OUT, RC
scenario() {
    local probe="$1" role="$2" bind="$3" via="$4" pf="$TMP/p.$RANDOM"
    rm -f "$pf" "$pf.ctl"
    if [[ "$via" = yes ]]; then
        "$BIN/ollama" serve "$pf" "$role" "$bind" & PIDS="$PIDS $!"
        wait_file "$pf.ctl" || { echo "CANNOT-RUN fixture"; return 2; }; CTRL="$(head -1 "$pf.ctl")"
    else
        # a control listener that is not part of the runner's lineage
        python3 -c "import socket,time,sys;c=socket.socket();c.bind(('127.0.0.1',0));c.listen(4);open(sys.argv[1],'w').write(str(c.getsockname()[1])+'\n');time.sleep(120)" "$pf.ctl" "$TMP/.ostler/ctl" & PIDS="$PIDS $!"
        wait_file "$pf.ctl" || return 2; CTRL="$(head -1 "$pf.ctl")"
        "$BIN/$role" "$bind" "$pf" & PIDS="$PIDS $!"
    fi
    wait_file "$pf" || { echo "CANNOT-RUN fixture child"; return 2; }
    CPORT="$(head -1 "$pf")"
    LAST_OUT="$(env -u OSTLER_BOX_HOST OSTLER_PROBE_CRED_ROUTES="" OSTLER_PROBE_OLLAMA_GUARD_PORT="" OSTLER_PROBE_OWNER_ROUTE="" \
        OSTLER_PROBE_KNOWN_LISTENERS="$CTRL" OSTLER_PROBE_LISTENER_MATCH="$TMP/.ostler" \
        OSTLER_PROBE_MUST_NOT_LISTEN="" OSTLER_PROBE_SURFACES="" OSTLER_GATEWAY_PORT="$CTRL" \
        bash "$probe" 2>&1)"; RC=$?
    # stop the fixture
    for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; PIDS=""
    sleep 0.3
}
report() { if [[ "$2" -eq 0 ]]; then printf '  [pass] %s\n' "$1"; pass=$((pass+1)); else printf '  [FAIL] %s\n' "$1"; printf '%s\n' "$LAST_OUT" | tail -12 | sed 's/^/        /'; fail=$((fail+1)); fi; }
has() { printf '%s\n' "$LAST_OUT" | grep -qF -- "$1"; }

t1() { scenario "$1" llama-server 127.0.0.1 yes; [[ $RC -eq 0 ]] && has 'EXEMPTED' && has "${CPORT}(127.0.0.1)" && ! has 'unknown-listener'; }
t2() { scenario "$1" llama-server 0.0.0.0 yes;   [[ $RC -eq 1 ]] && has "${CPORT}(unknown-listener:"; }
t3() { scenario "$1" mysvc 127.0.0.1 yes;        [[ $RC -eq 1 ]] && has "${CPORT}(unknown-listener:"; }
t4() { scenario "$1" llama-server 127.0.0.1 no;  [[ $RC -eq 1 ]] && has "${CPORT}(unknown-listener:"; }
t6() { scenario "$1" llama-server ::1 yes;       [[ $RC -eq 0 ]] && has 'EXEMPTED'; }
t1 "$PROBE"; report "1 runner under ollama serve, 127.0.0.1 -> PASS, exempted port printed" $?
t6 "$PROBE"; report "1b same, bound ::1 -> PASS" $?
t2 "$PROBE"; report "2 RED CONTROL runner bound 0.0.0.0 -> FAIL" $?
t3 "$PROBE"; report "3 non-runner loopback listener under ollama -> FAIL" $?
t4 "$PROBE"; report "4 runner with no ollama parent -> FAIL" $?
# 5 mutant: the exemption stops looking at the bind
MUT="$PROBE_DIR/.mutant_loopback_$$.sh"
sed 's/^          lo = 1; nb = split(binds, bl, ","); if (nb == 0) lo = 0$/          lo = 1; nb = 0/' "$PROBE" > "$MUT"
if cmp -s "$PROBE" "$MUT"; then echo "  [FAIL] mutant did not apply"; fail=$((fail+1))
else
    # the mutant must be caught: arm 2 (0.0.0.0) now PASSES, so t2 must go red
    if t2 "$MUT"; then echo "  [FAIL] mutant survived: 0.0.0.0 runner still FAILs"; fail=$((fail+1))
    else echo "  [pass] mutant (exemption ignores bind) killed by arm 2: rc=$RC"; pass=$((pass+1)); fi
fi
printf 'passed %d, failed %d\n' "$pass" "$fail"; [[ $fail -eq 0 ]]
