#!/usr/bin/env bash
#
# tests/test_derive_tick_records_every_exit_and_has_a_ceiling.sh
#
# THE DEFECT (v1.0.120, cold 16GB walk box). derive-preferences.log held eight
# "deferred (load); the next tick tries again" lines over 8.5h, and nothing
# else. state/derived-preferences.json was never written, so the Doctor said
# "not run yet", the walk probe said CANNOT-RUN, and /api/v1/preferences/derived
# answered degraded with no reason anywhere. The tick wrapper exited 0 on a
# resource-tier deferral and wrote no record, and nothing ever lifted it.
#
# WHAT THIS RUNS. The REAL _install_derive_preferences_agent is lifted out of
# install.sh and run in a sandbox HOME (launchctl stubbed), and the wrapper it
# GENERATES is executed, never a hand copy. The tier lib is the copy install.sh
# embeds, run for real; only `sysctl` is stubbed, so the load it reads is ours.
# The cm019 interpreter is a stub that records how it was invoked and writes a
# record in the runner's own shape (json.dumps indent=2, sort_keys).
#
#   1  load held above the ceiling: a status file appears, outcome deferred,
#      writer tick, consecutive 1, and the reason and the log name the measured
#      load, the cores and the tier ceiling.          (RED on v1.0.120: no file)
#   2  NEGATIVE: ticks 2 and 3 still defer; the runner is not invoked.
#   3  CEILING: tick 4 runs the runner under taskpolicy -b; the runner's record
#      stands; the in-a-row count resets.
#   4  a later deferral carries the completed pass forward (last_run_at, node
#      count, last_completed_at), so last_run_at does not move on a deferral.
#   5  12h: a last pass 13h ago forces; NEGATIVE: 11h ago defers.
#   6  an operator Pause is never overridden, even past the ceiling.
#   7  the ingest slot is never bypassed: ceiling reached + slot busy = yielded,
#      runner not invoked, the after-import marker kept.
#   8  the after-import marker forces one pass and is consumed.
#   9  no venv writes cannot_start; a runner that leaves no record is recorded
#      as not_written with its rc.
#  10  CONTRACT, both readers: the record the wrapper writes is read by the REAL
#      Doctor module (vendor/doctor/agent/derived_preferences_status.py) and the
#      REAL walk probe (scripts/box_walk_probes/lib/smart_prefs.py box-runs +
#      judge): deferred N times with no pass is FAIL naming the reason, not
#      CANNOT; a deferral after a completed pass is ok.
#
# INSTALL_SH may point at another copy (how the red was watched). Exit 0 pass,
# 1 fail, 2 cannot-run. Bash 3.2 portable. Synthetic only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-${REPO}/install.sh}"
[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: $INSTALL_SH unreadable"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 for the runner stub and the readers"; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

SANDBOX="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd)/derive-tick.XXXXXX")" || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT

lift_function() { # name -> stdout (first column-0 } at which the text parses)
    local name="$1" start end
    start="$(grep -nE "^${name}\(\) \{" "$INSTALL_SH" | head -1 | cut -d: -f1)"
    [ -n "$start" ] || return 1
    for end in $(awk -v s="$start" 'NR > s && /^\}/ { print NR }' "$INSTALL_SH"); do
        sed -n "${start},${end}p" "$INSTALL_SH" > "${SANDBOX}/lift.sh"
        if bash -n "${SANDBOX}/lift.sh" 2>/dev/null; then cat "${SANDBOX}/lift.sh"; return 0; fi
    done
    return 1
}
lift_function _install_derive_preferences_agent > "${SANDBOX}/agent.sh" \
    || { echo "CANNOT-RUN: could not lift _install_derive_preferences_agent"; exit 2; }
# The tier lib exactly as install.sh embeds it.
sed -n '/<<.OSTLER_RESOURCE_TIER_EOF.$/,/^OSTLER_RESOURCE_TIER_EOF$/p' "$INSTALL_SH" | sed '1d;$d' > "${SANDBOX}/tier.sh"
grep -q '^ostler_resource_tier_should_defer_nonessential()' "${SANDBOX}/tier.sh" \
    || { echo "CANNOT-RUN: the embedded tier lib was not found in $INSTALL_SH"; exit 2; }

BIN="${SANDBOX}/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "${BIN}/launchctl"
# sysctl: a 16GB, 10-core box whose 1-minute load is whatever LOAD says.
cat > "${BIN}/sysctl" <<'EOF'
#!/bin/sh
case "$*" in
    *vm.loadavg*) echo "{ $(cat "$FAKE_LOAD_FILE") 1.00 1.00 }" ;;
    *hw.memsize*) echo 17179869184 ;;
    *hw.ncpu*) echo 10 ;;
    *perflevel0.physicalcpu*) echo 4 ;;
    *hw.physicalcpu*) echo 10 ;;
    *) exit 1 ;;
esac
EOF
cat > "${BIN}/taskpolicy" <<'EOF'
#!/bin/sh
[ "$1" = "-b" ] || { echo "taskpolicy called without -b: $*" >&2; exit 64; }
shift
TP_BACKGROUND=1 exec "$@"
EOF
chmod +x "${BIN}/launchctl" "${BIN}/sysctl" "${BIN}/taskpolicy"

# One sandbox box: HOME, the generated wrapper, the tier lib, the stub venv.
new_box() { # name -> sets H (home), W (wrapper), O (OSTLER_DIR)
    H="${SANDBOX}/$1"; O="${H}/.ostler"
    mkdir -p "$O/logs" "${H}/.ostler/lib"
    (
        export HOME="$H" PATH="${BIN}:${PATH}"
        OSTLER_DIR="$O"; LOGS_DIR="${O}/logs"
        ok() { :; }; warn() { :; }; info() { :; }; _ks_bounded() { :; }
        # shellcheck source=/dev/null
        . "${SANDBOX}/agent.sh"
        _install_derive_preferences_agent
    ) >/dev/null 2>&1
    W="${O}/bin/ostler-derive-preferences-tick"
    cp "${SANDBOX}/tier.sh" "${H}/.ostler/lib/ostler-resource-tier.sh"
    mkdir -p "${O}/services/cm019/.venv/bin"
    cat > "${O}/services/cm019/.venv/bin/python3" <<'EOF'
#!/bin/sh
# Stub cm019 interpreter. Import checks (-c) pass. A runner call is recorded
# with whether it ran under taskpolicy -b, then writes the runner's record.
if [ "${1:-}" = "-c" ]; then exit 0; fi
echo "runner bg=${TP_BACKGROUND:-0} args=$*" >> "${OSTLER_DIR}/runs.log"
[ "${RUNNER_MODE:-write}" = "silent" ] && exit 1
exec /usr/bin/env python3 -c '
import json, os, time
p = os.path.join(os.environ["OSTLER_DIR"], "state", "derived-preferences.json")
rec = {"schema": 1, "last_run_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
       "derived_graph": "https://schema.ostler.ai/derived/graph/preferences", "outcome": "written",
       "readers_total": 3, "readers_failed": 0, "nodes_derived": 5, "graph_node_count": 5,
       "derivation_version": "synthetic", "reason": ""}
open(p, "w").write(json.dumps(rec, indent=2, sort_keys=True) + "\n")
'
EOF
    chmod +x "${O}/services/cm019/.venv/bin/python3"
    echo "40.00" > "${H}/load"
}
tick() { # run the generated wrapper once on box H, with env overrides as args
    env HOME="$H" PATH="${BIN}:/usr/bin:/bin" OSTLER_DIR="$O" FAKE_LOAD_FILE="${H}/load" \
        OSTLER_TASKPOLICY_BIN="${BIN}/taskpolicy" "$@" /bin/bash "$W" >/dev/null 2>&1
}
field() { # key -> value from the status file (python-parsed, so it is valid JSON)
    python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception as e:
    v = "UNPARSEABLE:%s" % type(e).__name__
print("" if v is None else v)' "${O}/state/derived-preferences.json" "$1" 2>/dev/null
}
runs() { [ -f "${O}/runs.log" ] && grep -c 'runner' "${O}/runs.log" || echo 0; }

echo "1: load held above the ceiling leaves a record that says why"
new_box b1
[ -x "$W" ] || { echo "CANNOT-RUN: the real installer function wrote no wrapper at $W"; exit 2; }
ok "control: the generated wrapper exists ($(wc -l < "$W" | tr -d ' ') lines)"
tick
if [ -f "${O}/state/derived-preferences.json" ]; then
    ok "a status file exists after a deferred tick"
else
    bad "NO status file after a deferred tick (the v1.0.120 shape); log: $(tail -1 "${O}/logs/derive-preferences.log" 2>/dev/null)"
fi
[ "$(field outcome)" = "deferred" ] && ok "outcome deferred" || bad "outcome is '$(field outcome)'"
[ "$(field writer)" = "tick" ] && ok "writer tick" || bad "writer is '$(field writer)'"
[ "$(field consecutive)" = "1" ] && ok "consecutive 1" || bad "consecutive is '$(field consecutive)'"
case "$(field ts)" in 20[0-9][0-9]-*T*Z) ok "ts set ($(field ts))" ;; *) bad "no ts: '$(field ts)'" ;; esac
reason="$(field reason)"
case "$reason" in
    *"1m load 40.00 over 10 cores is 4.00 per core"*"ceiling of 2.0 per core"*) ok "reason names load, cores and ceiling: $reason" ;;
    *) bad "reason does not name the measurement: '$reason'" ;;
esac
grep -q 'deferred (load: 1m load 40.00 over 10 cores' "${O}/logs/derive-preferences.log" \
    && ok "the log line names the measurement" || bad "log: $(tail -1 "${O}/logs/derive-preferences.log" 2>/dev/null)"
[ "$(runs)" = "0" ] && ok "runner not invoked" || bad "runner invoked $(runs) time(s) while deferred"

echo "2: NEGATIVE, under the ceiling it still defers"
tick; tick
[ "$(field outcome)" = "deferred" ] && [ "$(field consecutive)" = "3" ] && ok "ticks 2 and 3 deferred, consecutive 3" \
    || bad "after 3 ticks: outcome '$(field outcome)' consecutive '$(field consecutive)'"
[ "$(runs)" = "0" ] && ok "runner still not invoked after 3 ticks" || bad "runner invoked $(runs) time(s) under the ceiling"

echo "3: CEILING, the 4th tick runs under taskpolicy -b"
tick
[ "$(runs)" = "1" ] && ok "runner invoked once" || bad "runner invoked $(runs) time(s)"
grep -q 'runner bg=1 args=-m services.enrich.src.derive_runner --user-id' "${O}/runs.log" 2>/dev/null \
    && ok "it ran under taskpolicy -b" || bad "not under taskpolicy -b: $(cat "${O}/runs.log" 2>/dev/null)"
[ "$(field outcome)" = "written" ] && [ "$(field writer)" = "" ] && ok "the runner's own record stands (written)" \
    || bad "record after the forced pass: outcome '$(field outcome)' writer '$(field writer)'"
grep -q 'ceiling reached (3 ticks in a row with no pass); running anyway under taskpolicy -b' "${O}/logs/derive-preferences.log" \
    && ok "the log says the ceiling forced it" || bad "no ceiling line in the log"
grep -q '^consecutive=0$' "${O}/state/derive-preferences-tick.state" && ok "in-a-row count reset" \
    || bad "state: $(cat "${O}/state/derive-preferences-tick.state" 2>/dev/null)"

echo "4: a later deferral carries the completed pass forward"
ran_at="$(field last_run_at)"
tick
[ "$(field outcome)" = "deferred" ] && [ "$(field consecutive)" = "1" ] && ok "deferred again, consecutive 1" \
    || bad "outcome '$(field outcome)' consecutive '$(field consecutive)'"
[ -n "$ran_at" ] && [ "$(field last_run_at)" = "$ran_at" ] && ok "last_run_at unchanged by the deferral ($ran_at)" \
    || bad "last_run_at moved: '$ran_at' -> '$(field last_run_at)'"
[ "$(field graph_node_count)" = "5" ] && [ "$(field last_completed_at)" = "$ran_at" ] && ok "node count 5 and last_completed_at carried" \
    || bad "carried: nodes '$(field graph_node_count)' last_completed_at '$(field last_completed_at)'"
cp "${O}/state/derived-preferences.json" "${SANDBOX}/after-pass-deferred.json"

echo "5: 12h since the last completed pass forces; 11h does not"
now="$(date +%s)"
new_box b5a
mkdir -p "${O}/state"
printf 'consecutive=0\nstreak_started_epoch=0\nlast_completed_epoch=%s\n' "$((now - 13 * 3600))" > "${O}/state/derive-preferences-tick.state"
tick
[ "$(runs)" = "1" ] && grep -q 'bg=1' "${O}/runs.log" && ok "13h: forced pass under taskpolicy -b" || bad "13h: runner runs $(runs)"
new_box b5b
mkdir -p "${O}/state"
printf 'consecutive=0\nstreak_started_epoch=0\nlast_completed_epoch=%s\n' "$((now - 11 * 3600))" > "${O}/state/derive-preferences-tick.state"
tick
[ "$(runs)" = "0" ] && [ "$(field outcome)" = "deferred" ] && ok "11h: still deferred" || bad "11h: runs $(runs) outcome '$(field outcome)'"

echo "6: an operator Pause is never overridden"
new_box b6
mkdir -p "${O}/state"
printf 'consecutive=9\nstreak_started_epoch=1\n' > "${O}/state/derive-preferences-tick.state"
: > "${O}/state/derive-preferences.after-import"
tick OSTLER_PAUSED=1
[ "$(runs)" = "0" ] && ok "paused past the ceiling and with an import marker: not run" || bad "ran $(runs) time(s) while paused"
case "$(field reason)" in paused*) ok "reason: $(field reason)" ;; *) bad "reason '$(field reason)'" ;; esac

echo "7: the ingest slot is never bypassed"
new_box b7
mkdir -p "${O}/state"
printf 'consecutive=5\nstreak_started_epoch=1\n' > "${O}/state/derive-preferences-tick.state"
: > "${O}/state/derive-preferences.after-import"
cat > "${H}/.ostler/lib/ostler-ingest-slot.sh" <<'EOF'
ostler_slot_acquire() { return 1; }
ostler_slot_run() { echo "slot_run $*" >> "${OSTLER_DIR}/slot.log"; "$@"; }
EOF
tick
[ "$(runs)" = "0" ] && ok "ceiling reached, slot busy: runner not invoked" || bad "runner invoked $(runs) time(s) past a busy slot"
[ "$(field outcome)" = "yielded" ] && [ "$(field consecutive)" = "6" ] && ok "outcome yielded, consecutive 6" \
    || bad "outcome '$(field outcome)' consecutive '$(field consecutive)'"
[ -f "${O}/state/derive-preferences.after-import" ] && ok "import marker kept for the next tick" || bad "import marker consumed with no pass"
printf 'ostler_slot_acquire() { return 0; }\nostler_slot_run() { echo "slot_run $*" >> "${OSTLER_DIR}/slot.log"; "$@"; }\n' > "${H}/.ostler/lib/ostler-ingest-slot.sh"
tick
grep -q 'slot_run .*taskpolicy -b .*derive_runner' "${O}/slot.log" 2>/dev/null && ok "slot free: the forced pass ran THROUGH ostler_slot_run" \
    || bad "slot log: $(cat "${O}/slot.log" 2>/dev/null)"

echo "8: the after-import marker forces one pass and is consumed"
new_box b8
mkdir -p "${O}/state"
: > "${O}/state/derive-preferences.after-import"
tick
[ "$(runs)" = "1" ] && grep -q 'bg=1' "${O}/runs.log" && ok "consecutive 0, load high, marker present: ran under taskpolicy -b" || bad "runs $(runs)"
[ ! -f "${O}/state/derive-preferences.after-import" ] && ok "marker consumed" || bad "marker still present"
tick
[ "$(runs)" = "1" ] && [ "$(field outcome)" = "deferred" ] && ok "next tick defers again (once, not always)" || bad "runs $(runs) outcome '$(field outcome)'"

echo "9: no venv, and a runner that leaves no record"
new_box b9
rm -f "${O}/services/cm019/.venv/bin/python3"
tick
[ "$(field outcome)" = "cannot_start" ] && ok "no venv: cannot_start ($(field reason))" || bad "no venv: outcome '$(field outcome)'"
new_box b9b
echo "0.10" > "${H}/load"
tick RUNNER_MODE=silent
[ "$(field outcome)" = "not_written" ] && case "$(field reason)" in *"rc=1 without recording"*) true ;; *) false ;; esac \
    && ok "silent runner: not_written, $(field reason)" || bad "silent runner: outcome '$(field outcome)' reason '$(field reason)'"

echo "10: CONTRACT, the Doctor and the walk probe read what the wrapper writes"
new_box b10
tick; tick; tick
DOC="$(python3 - "$O/state/derived-preferences.json" "${H}/Library/LaunchAgents/com.ostler.derive-preferences.plist" "$REPO" <<'EOF'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[3]) / "vendor" / "doctor" / "agent"))
import derived_preferences_status as d
st = d.read_derived_preferences_status(Path(sys.argv[1]), Path(sys.argv[2]))
html = d.render_derived_preferences_status(st)
print(st["status"], "|", st["reason"][:60], "|", "3 ticks in a row" in html)
EOF
)"
case "$DOC" in "deferred | load: 1m load 40.00"*"| True") ok "Doctor: $DOC" ;; *) bad "Doctor read: '$DOC'" ;; esac
probe() { # record file -> judge rc and its detail line
    cp "$1" "${O}/state/derived-preferences.json"
    env HOME="$H" OSTLER_DIR="$O" python3 "${REPO}/scripts/box_walk_probes/lib/smart_prefs.py" box-runs > "${SANDBOX}/facts.json" 2>/dev/null
    PROBE_OUT="$(python3 "${REPO}/scripts/box_walk_probes/lib/smart_prefs.py" judge derived_preferences_runs "${SANDBOX}/facts.json" 2>&1)"
    PROBE_RC=$?
}
cp "${O}/state/derived-preferences.json" "${SANDBOX}/never-passed.json"
probe "${SANDBOX}/never-passed.json"
if [ "$PROBE_RC" = "1" ] && printf '%s\n' "$PROBE_OUT" | grep -q 'FAIL.*deferred 3 tick(s) in a row.*no pass has completed.*1m load 40.00'; then
    ok "probe: deferred 3 times, never passed -> FAIL naming the cause"
else
    bad "probe rc=$PROBE_RC: $(printf '%s' "$PROBE_OUT" | grep -i 'pass completed')"
fi
probe "${SANDBOX}/after-pass-deferred.json"
[ "$PROBE_RC" = "0" ] && ok "probe: a deferral after a completed pass is ok" || bad "probe rc=$PROBE_RC after a completed pass: $(printf '%s' "$PROBE_OUT" | grep -i 'pass completed')"

echo
echo "passed ${PASS}, failed ${FAIL}"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
