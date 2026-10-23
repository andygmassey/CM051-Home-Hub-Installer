#!/usr/bin/env bash
# The early pass's budget must kill the REMOTE probe, not only the local wrapper.
#
# THE DEFECT (v1.0.117 thin walk, W4). scripts/early_repeat_fail_pass.sh ran
# the probe runner under `perl -e 'alarm ...; exec'`. The alarm killed the
# local runner, but an ssh session has no pty, so sshd does not signal the
# remote command when the client goes: an orphan data_conservation probe kept
# running on the walk box for 81 CPU-minutes after the alarm fired.
#
# WHAT THIS DOES. Drives the REAL early_repeat_fail_pass.sh with a fixture
# walk record (one failed probe), a fake runner that sources the REAL
# lib/probe.sh and calls box_run with a remote command that would run for
# minutes, and a fake `ssh` that behaves like sshd in the one way that
# matters: it runs the remote command in its own process group, so killing
# the ssh client does NOT kill the remote work. The "box" is this machine.
#
#   TIMEOUT:  budget 5s. After the pass returns, the remote work must be gone,
#             and the pass must say the cleanup found and killed it.
#   STUBBORN: the remote work ignores SIGTERM; the KILL escalation must end it.
#   CONTROL:  the remote command finishes inside the budget. The pass must
#             report survivors=0 and must not claim a timeout.
#
# Every process this test starts carries a unique path in its command line;
# the EXIT trap kills only those.
#
# Exit: 0 pass, 1 fail, 2 cannot-run.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EP="${EARLY_PASS_SH:-$REPO/scripts/early_repeat_fail_pass.sh}"
PROBE_LIB="$REPO/scripts/box_walk_probes/lib/probe.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

for f in "$EP" "$PROBE_LIB"; do [ -r "$f" ] || { echo "CANNOT-RUN: $f missing" >&2; exit 2; }; done
command -v perl >/dev/null 2>&1 || { echo "CANNOT-RUN: no perl" >&2; exit 2; }

WORK="$(mktemp -d)"
MARK="${WORK}/remote_work_marker"
cleanup() {
    pkill -9 -f "$MARK" 2>/dev/null
    # The tag is the PASS's (early<epoch>p<its pid>), printed in its cleanup
    # line, not this test's $$. Remove only pidfiles under tags this test saw.
    for _t in $(grep -ho 'tag early[0-9]*p[0-9]*' "$WORK"/out* 2>/dev/null | sed 's/^tag //' | sort -u); do
        rm -f /tmp/ostler-walk-pg."$_t".* 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

# The remote work: a script with a unique path, so pgrep finds it and nothing
# else. It sleeps in a child, like a probe waiting on a store.
printf '#!/bin/bash\nsleep "${1:-300}"\n' > "$MARK"; chmod +x "$MARK"

# fake ssh = sshd semantics: run the last argument under $SHELL -c in a NEW
# process group, wait for it. Killing this process leaves the remote running.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/ssh" <<'EOF'
#!/bin/bash
cmd="${@: -1}"
SHELL=/bin/bash perl -e 'setpgrp(0,0); exec @ARGV' /bin/bash -c "$cmd" &
wait $!
EOF
chmod +x "$WORK/bin/ssh"

# fixture record + empty walk log dir
mkdir -p "$WORK/walks" "$WORK/runner/probes"
printf 'version\tv1.0.117\nwalked_at\t2026-10-22T10:00:00Z\nverdict\tFAIL\nfailed_probe_names_recorded\tyes\nfailed_probe\tslow_probe\n' \
    > "$WORK/walks/v1.0.117-20261022T100000Z.tsv"
printf '#!/bin/bash\n' > "$WORK/runner/probes/slow_probe.sh"

mk_runner() {  # $1 = seconds the remote work runs
    cat > "$WORK/runner/run_box_walk.sh" <<EOF
#!/bin/bash
SEED_DEPENDENT_PROBES="some_other_probe"
. "$PROBE_LIB"
echo "runner: calling box_run"
box_run "$MARK $1; echo remote-done"
echo "runner: box_run returned"
EOF
}

run_pass() {  # $1 = budget -> output in $WORK/out
    PATH="$WORK/bin:/usr/bin:/bin" OSTLER_EARLY_PASS_BUDGET_S="$1" \
        /bin/bash "$EP" --host fake@walkbox.invalid --walks-dir "$WORK/walks" \
        --prev-record "$WORK/walks/v1.0.117-20261022T100000Z.tsv" \
        --runner "$WORK/runner/run_box_walk.sh" > "$WORK/out" 2>&1
    grep -o 'tag early[0-9]*p[0-9]*' "$WORK/out" >> "$WORK/out.tags" 2>/dev/null
}

remote_alive() { pgrep -f "$MARK" >/dev/null 2>&1; }

# ── TIMEOUT ───────────────────────────────────────────────────────────────
# Budget 5s: long enough that the remote work has certainly started (and been
# recorded) before the alarm, which is the walk-box shape.
mk_runner 300
t0=$(date +%s); run_pass 5; t1=$(date +%s)
sleep 1
if remote_alive; then
    bad "TIMEOUT: the remote probe work is STILL RUNNING after the pass returned ($((t1-t0))s)"
    pkill -f "$MARK" 2>/dev/null
else
    ok "TIMEOUT: no remote probe work survives the budget ($((t1-t0))s)"
fi
if grep -q 'remote cleanup: groups=1 alive=1 killed=1 survivors=0' "$WORK/out"; then
    ok "TIMEOUT: the pass says it found the remote group alive and killed it"
else
    bad "TIMEOUT: no verified-kill line: $(grep -iE 'cleanup|ORPHAN|budget' "$WORK/out" | head -2 | tr '\n' ' ')"
fi
if [ $((t1-t0)) -lt 60 ]; then ok "TIMEOUT: the pass returned promptly"; else bad "TIMEOUT: the pass took $((t1-t0))s"; fi

# ── STUBBORN: the remote work ignores SIGTERM, so only a KILL ends it ─────
printf '#!/bin/bash\ntrap "" TERM\nsleep "${1:-300}" &\nwait $!\nwait $!\n' > "$MARK"
mk_runner 300
run_pass 5
sleep 1
if remote_alive; then
    bad "STUBBORN: TERM-ignoring remote work survived the cleanup"
    pkill -9 -f "$MARK" 2>/dev/null
else
    ok "STUBBORN: TERM-ignoring remote work is escalated to KILL and gone"
fi
printf '#!/bin/bash\nsleep "${1:-300}"\n' > "$MARK"

# ── CONTROL ───────────────────────────────────────────────────────────────
mk_runner 0
run_pass 30
if grep -q 'early| remote-done' "$WORK/out" && grep -q 'survivors=0' "$WORK/out" && ! grep -q 'budget of' "$WORK/out"; then
    ok "CONTROL: a probe that finishes in budget runs to completion, nothing is killed, no timeout claimed"
else
    bad "CONTROL: $(grep -E 'early\||cleanup|budget' "$WORK/out" | head -4 | tr '\n' ' ')"
fi
if remote_alive; then bad "CONTROL: something of ours is still running"; else ok "CONTROL: nothing left running"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
