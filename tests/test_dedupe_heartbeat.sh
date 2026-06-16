#!/usr/bin/env bash
# test_dedupe_heartbeat.sh -- v1.0.0 .153 cold-wipe walk, polish P3.
#
# The whole-graph dedupe (`batch_resolver --converge`) writes all output to
# a log and, on a large address book, can run for many minutes. On the .153
# walk it sat silent for ~25 minutes and read as a frozen install. The fix
# runs the pass in the background and emits a liveness heartbeat every 30 s.
#
# Structural checks assert install.sh carries the heartbeat constructs.
# Behavioural checks reproduce the loop in a sandbox (with a short interval)
# and prove it (a) chirps while a slow job runs, (b) reaps the real exit
# status on success, and (c) stays non-fatal on failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "== structural: install.sh carries the dedupe heartbeat =="
grep -q 'batch_resolver \\' "$INSTALL_SH" && grep -q ') >>"\$_DEDUPE_LOG" 2>&1 &' "$INSTALL_SH" \
    && ok "dedupe pass is backgrounded (& after the log redirect)" \
    || bad "dedupe pass is not backgrounded -- heartbeat cannot run"
grep -q 'while kill -0 "\$_DEDUPE_PID" 2>/dev/null; do' "$INSTALL_SH" \
    && ok "heartbeat loop polls the dedupe pid with kill -0" \
    || bad "heartbeat poll loop missing"
grep -q 'Still merging duplicate contacts' "$INSTALL_SH" \
    && ok "heartbeat emits a liveness line" \
    || bad "heartbeat liveness message missing"
grep -q 'if wait "\$_DEDUPE_PID"; then' "$INSTALL_SH" \
    && ok "child reaped via wait in an errexit-safe if-condition" \
    || bad "wait/reap of the dedupe child missing"

echo "== behavioural: heartbeat loop chirps + reaps real status =="
# Faithful reproduction of install.sh's heartbeat block, with a 1 s tick so
# the test is fast. Returns the dedupe exit code; prints one HEARTBEAT line
# per tick the job is still alive.
run_with_heartbeat() {
    local _cmd="$1" _interval="$2"
    bash -c "$_cmd" >/dev/null 2>&1 &
    local _pid=$! _waited=0
    while kill -0 "$_pid" 2>/dev/null; do
        sleep "$_interval"
        _waited=$(( _waited + _interval ))
        if kill -0 "$_pid" 2>/dev/null; then
            printf 'HEARTBEAT %ss\n' "$_waited"
        fi
    done
    if wait "$_pid"; then return 0; else return 1; fi
}

# 1. A ~2 s job at a 1 s tick chirps at least once, then succeeds.
out="$(run_with_heartbeat 'sleep 2; exit 0' 1)"; rc=$?
beats="$(printf '%s' "$out" | grep -c HEARTBEAT)"
[[ "$rc" -eq 0 && "$beats" -ge 1 ]] \
    && ok "slow success: ${beats} heartbeat(s) emitted, exit reaped as 0" \
    || bad "slow success wrong (rc=$rc beats=$beats)"

# 2. A failing job is reaped as non-zero (install treats this as a warn, not fatal).
run_with_heartbeat 'sleep 1; exit 3' 1 >/dev/null; rc=$?
[[ "$rc" -ne 0 ]] \
    && ok "failed pass: real non-zero status reaped (stays non-fatal upstream)" \
    || bad "failed pass: status not propagated (rc=$rc)"

# 3. A near-instant job emits no stray heartbeat (the `if` guard after sleep).
out="$(run_with_heartbeat 'exit 0' 1)"; rc=$?
beats="$(printf '%s' "$out" | grep -c HEARTBEAT)"
[[ "$rc" -eq 0 && "$beats" -eq 0 ]] \
    && ok "instant job: no stray heartbeat line, exit reaped as 0" \
    || bad "instant job emitted a stray heartbeat (rc=$rc beats=$beats)"

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
