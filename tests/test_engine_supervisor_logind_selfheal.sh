#!/usr/bin/env bash
#
# The supervisor's background-service watchdog, end to end.
#
# The REAL supervisor (bin/ostler-engine-supervisor.sh) runs. Only the probe and
# the restart command are injected, through the same variables the shipped code
# reads. The Doctor row is rendered by the REAL module from the record the
# supervisor wrote.
#
# Arms:
#   1 injected wedge        -> one heal, Doctor says so, customer words only
#   2 healthy (control)      -> no heal, Doctor says "running normally"
#   3 wedge that never clears -> exactly MAX heals, then no more, then "needs attention"
#   4 cooldown               -> a second wedge inside the cooldown is not healed
#   5 CANNOT-RUN             -> never healed, never shown as running
# Mutants, each applied to a copy of the real supervisor or module, must turn
# the matching arm red: heal removed, budget removed, cooldown removed,
# escalation removed, and a customer-copy leak.
#
# Usage: [REPO_ROOT]. rc 2 = harness could not set itself up.

set -uo pipefail
REPO_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SUP="${REPO_ROOT}/bin/ostler-engine-supervisor.sh"
DOC="${REPO_ROOT}/vendor/doctor/agent"
[[ -f "$SUP" && -f "${REPO_ROOT}/lib/ostler-container-engine.sh" && -f "${DOC}/engine_watchdog_status.py" ]] \
  || { echo "CANNOT-RUN: supervisor, lib or Doctor module missing under ${REPO_ROOT}" >&2; exit 2; }

PASS=0; FAIL=0
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-sup-logind.XXXXXX")" || { echo "CANNOT-RUN: mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# A docker and colima that answer healthy, so the store-port judgement is not
# what these arms measure.
mkbin() {
    mkdir -p "${WORK}/bin"
    printf '#!/bin/sh\ncase "$1" in info) echo "Server Version: 27"; exit 0;; ps) echo running; exit 0;; esac\nexit 0\n' > "${WORK}/bin/docker"
    printf '#!/bin/sh\nexit 0\n' > "${WORK}/bin/colima"
    chmod +x "${WORK}/bin/docker" "${WORK}/bin/colima"
}
mkbin

# run_sup <sup_path> <probe_cmd> [env assignments...]: one real supervisor tick.
# Restarts are counted in ${WORK}/restarts, one line per restart.
run_sup() {
    local sup="$1" probe="$2"; shift 2
    env -i PATH="${WORK}/bin:/usr/bin:/bin" HOME="$WORK" \
        OSTLER_ENGINE_BREW_PREFIX="$WORK" OSTLER_ENGINE_ALT_PREFIX="$WORK" \
        OSTLER_ENGINE_ALLOW_PATH_LOOKUP=0 OSTLER_ENGINE_DESKTOP_PATH="${WORK}/none.app" \
        OSTLER_STATE_DIR="${WORK}/state" OSTLER_LOGS_DIR="${WORK}/logs" OSTLER_DIR="${WORK}/ostler" \
        OSTLER_ENGINE_PORT_PROBE_CMD="true" OSTLER_ENGINE_INSTALL_RUNNING_CMD="false" \
        OSTLER_ENGINE_KICKSTART_CMD="exit 0" \
        OSTLER_ENGINE_HA_PID_FILE="${WORK}/no-such-ha.pid" \
        OSTLER_ENGINE_LOGIND_PROBE_CMD="$probe" \
        OSTLER_ENGINE_LOGIND_RESTART_CMD="echo restart >> '${WORK}/restarts'; exit 0" \
        OSTLER_ENGINE_LOGIND_SAMPLE_S=5 OSTLER_ENGINE_LOGIND_PROBE_TIMEOUT_S=3 \
        OSTLER_ENGINE_LOGIND_SETTLE_S=0 OSTLER_ENGINE_LOGIND_RESTART_COOLDOWN_S=0 \
        OSTLER_ENGINE_LOGIND_MAX_HEALS_PER_DAY=3 "$@" \
        bash "$sup" >>"${WORK}/sup.out" 2>&1
}
reset() { rm -rf "${WORK}/state" "${WORK}/logs" "${WORK}/restarts" "${WORK}/sup.out"; mkdir -p "${WORK}/logs"; }
restarts() { [ -f "${WORK}/restarts" ] && wc -l < "${WORK}/restarts" | tr -d ' ' || echo 0; }
record()   { cat "${WORK}/state/engine-supervisor/logind_health.json" 2>/dev/null; }
verdict()  { record | sed -n 's/.*"verdict": "\([A-Z-]*\)".*/\1/p' | head -1; }
escalated(){ record | grep -q '"escalated": true'; }

# doctor_row <record_path> [module_dir]: the Doctor row rendered by the real module.
doctor_row() {
    python3 - "$1" "${2:-$DOC}" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
import engine_watchdog_status as ew
print(ew.render_engine_watchdog_status(ew.read_engine_watchdog_status(sys.argv[1])))
PY
}
STATE_JSON="${WORK}/state/engine-supervisor/logind_health.json"
WEDGED_PROBE="echo TICKS 418 3000 3500"      # 500 ticks in 5 s: 100% of a core
HEALTHY_PROBE="echo TICKS 418 3000 3010"     # 10 ticks in 5 s
CANNOT_PROBE="echo garbage; exit 1"
# Still wedged after every restart: the stub never reports a recovery.

# ---- Arm 1: injected wedge, one heal, customer words -----------------------
reset
run_sup "$SUP" "$WEDGED_PROBE"
if [ "$(restarts)" = 1 ]; then pass "arm 1: injected wedge takes exactly one heal action"; else failure "arm 1: expected 1 restart, got $(restarts)"; fi
ROW="$(doctor_row "$STATE_JSON")"
HEAL_AT="$(record | sed -n 's/.*"heal_epochs": "\([0-9]*\).*/\1/p')"
WANT_TIME="$(python3 -c "import time,sys; print(time.strftime('%H:%M', time.localtime(int(sys.argv[1]))))" "$HEAL_AT")"
if printf '%s' "$ROW" | grep -q "restarted a stuck background service at ${WANT_TIME}"; then
    pass "arm 1: Doctor says 'restarted a stuck background service at ${WANT_TIME}' (local time of the heal)"
else
    failure "arm 1: Doctor row wrong: ${ROW}"
fi
if printf '%s' "$ROW" | grep -qiE 'logind|systemd|colima|VM|supervisor|probe|tick|ssh'; then
    failure "arm 1: internals leaked into customer copy: ${ROW}"
else
    pass "arm 1: customer copy names no internals"
fi

# ---- Arm 2: healthy control, no heal --------------------------------------
reset
run_sup "$SUP" "$HEALTHY_PROBE"
if [ "$(restarts)" = 0 ] && printf '%s' "$(doctor_row "$STATE_JSON")" | grep -q 'running normally'; then
    pass "arm 2 (control): healthy reading takes no heal and the Doctor says running normally"
else
    failure "arm 2: healthy reading acted or was misreported (restarts=$(restarts))"
fi

# ---- Arm 3: never clears. Exactly MAX heals, then none, then escalation ----
reset
for _ in 1 2 3 4 5 6; do run_sup "$SUP" "$WEDGED_PROBE"; done
if [ "$(restarts)" = 3 ]; then pass "arm 3: wedge that never clears gets exactly 3 heals over 6 ticks, then none"; else failure "arm 3: expected exactly 3 heals, got $(restarts)"; fi
if escalated; then pass "arm 3: budget spent, the record is escalated"; else failure "arm 3: not escalated after the budget was spent"; fi
if printf '%s' "$(doctor_row "$STATE_JSON")" | grep -q 'needs attention'; then pass "arm 3: Doctor row says needs attention"; else failure "arm 3: Doctor row does not escalate"; fi

# ---- Arm 4: cooldown. A second wedge inside the cooldown is not healed ----
reset
run_sup "$SUP" "$WEDGED_PROBE" OSTLER_ENGINE_LOGIND_RESTART_COOLDOWN_S=900
run_sup "$SUP" "$WEDGED_PROBE" OSTLER_ENGINE_LOGIND_RESTART_COOLDOWN_S=900
if [ "$(restarts)" = 1 ]; then pass "arm 4: second wedge inside the 900 s cooldown is not healed"; else failure "arm 4: cooldown not enforced (restarts=$(restarts))"; fi

# ---- Arm 5: a probe that could not run is never healed and never "running" -
reset
run_sup "$SUP" "$CANNOT_PROBE"
if [ "$(restarts)" = 0 ] && printf '%s' "$(doctor_row "$STATE_JSON")" | grep -q "couldn't check"; then
    pass "arm 5: unparseable probe: no heal, Doctor says couldn't check"
else
    failure "arm 5: a probe that could not run acted or was shown as running"
fi

# ---- Mutants: each must turn its arm red ----------------------------------
# mutant_sup <name> <python-replace-old> <python-replace-new> -> path to a mutated supervisor copy
mutant_sup() {
    local d="${WORK}/mut-$1"; mkdir -p "$d/bin" "$d/lib"
    cp "${REPO_ROOT}/lib/ostler-container-engine.sh" "$d/lib/"
    python3 - "${REPO_ROOT}/bin/ostler-engine-supervisor.sh" "$d/bin/ostler-engine-supervisor.sh" "$2" "$3" <<'PY'
import sys
s = open(sys.argv[1]).read()
old, new = sys.argv[3], sys.argv[4]
assert s.count(old) == 1, "mutant anchor not found exactly once: %r" % old
open(sys.argv[2], "w").write(s.replace(old, new))
PY
    printf '%s' "$d/bin/ostler-engine-supervisor.sh"
}

# M1: the heal call removed. Arm 1 must see no restart.
reset
M="$(mutant_sup heal '    logind_restart >/dev/null 2>&1; rc=$?
' '    rc=0
')"
run_sup "$M" "$WEDGED_PROBE"
if [ "$(restarts)" = 0 ]; then pass "mutant M1 (heal removed): arm 1 goes red"; else failure "mutant M1 still restarted: the arm cannot see a heal"; fi

# M2: the daily budget removed. Arm 3 must see more than 3 heals.
reset; M="$(mutant_sup budget '    if [ "$n" -ge "$LOGIND_MAX_HEALS_PER_DAY" ]; then
' '    if false; then
')"
for _ in 1 2 3 4 5 6; do run_sup "$M" "$WEDGED_PROBE"; done
if [ "$(restarts)" != 3 ]; then pass "mutant M2 (budget removed): arm 3 goes red (restarts=$(restarts))"; else failure "mutant M2 still capped at 3: arm 3 cannot see the budget"; fi

# M3: the cooldown removed. Arm 4 must see two heals.
reset; M="$(mutant_sup cooldown '    if [ "$last" -gt 0 ] && [ $(( now - last )) -lt "$LOGIND_RESTART_COOLDOWN_S" ]; then
' '    if false; then
')"
run_sup "$M" "$WEDGED_PROBE" OSTLER_ENGINE_LOGIND_RESTART_COOLDOWN_S=900
run_sup "$M" "$WEDGED_PROBE" OSTLER_ENGINE_LOGIND_RESTART_COOLDOWN_S=900
if [ "$(restarts)" != 1 ]; then pass "mutant M3 (cooldown removed): arm 4 goes red (restarts=$(restarts))"; else failure "mutant M3 still cooled down: arm 4 cannot see the cooldown"; fi

# M4: escalation removed from the Doctor module. Arm 3's row must lose "needs attention".
MD="${WORK}/mut-doctor"; mkdir -p "$MD"; cp "${DOC}/engine_watchdog_status.py" "$MD/"
python3 - "$MD/engine_watchdog_status.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s2 = s.replace('    if escalated:', '    if False:')
assert s2 != s, "escalation anchor not found"
open(p, "w").write(s2)
PY
reset; for _ in 1 2 3 4 5 6; do run_sup "$SUP" "$WEDGED_PROBE"; done
if printf '%s' "$(doctor_row "$STATE_JSON" "$MD")" | grep -q 'needs attention'; then failure "mutant M4 still escalates: arm 3 cannot see escalation"; else pass "mutant M4 (escalation removed): arm 3 row goes red"; fi

# M5: a customer-copy leak. The no-internals check must catch "logind" in the row.
MC="${WORK}/mut-copy"; mkdir -p "$MC"; cp "${DOC}/engine_watchdog_status.py" "$MC/"
python3 - "$MC/engine_watchdog_status.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'restarted a stuck background service at %s%s.'
assert s.count(old) == 1
open(p, "w").write(s.replace(old, 'restarted logind at %s%s.'))
PY
reset; run_sup "$SUP" "$WEDGED_PROBE"
if printf '%s' "$(doctor_row "$STATE_JSON" "$MC")" | grep -qiE 'logind|systemd|colima|VM|supervisor|probe|tick|ssh'; then pass "mutant M5 (internals in copy): the no-internals check goes red"; else failure "mutant M5 leak not caught"; fi

echo "logind selfheal: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
