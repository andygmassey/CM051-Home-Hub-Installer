#!/usr/bin/env bash
#
# The supervisor's systemd-logind watchdog, measured 2026-11-14 on Mini16:
# logind inside the colima VM spun at 100% of a core, and nothing restarted it.
# The watchdog must restart logind ONLY on a measured busy probe, never read a
# probe that failed or timed out as healthy, and never restart in a loop.
#
# Stubbed colima ssh (the probe and the restart are injected commands). No real
# colima, VM or launchd. Usage: [REPO_ROOT]. rc 2 = harness could not set up.

set -uo pipefail
REPO_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SUP="${REPO_ROOT}/bin/ostler-engine-supervisor.sh"
[[ -f "$SUP" && -f "${REPO_ROOT}/lib/ostler-container-engine.sh" ]] || { echo "CANNOT-RUN: supervisor or lib missing under ${REPO_ROOT}" >&2; exit 2; }

PASS=0; FAIL=0
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-sup-logind.XXXXXX")" || { echo "CANNOT-RUN: mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# A docker and colima on PATH that answer healthy, so the store-port judgement
# is not what these tests measure. The colima on PATH is never reached: the
# probe and restart are injected.
make_prefix() {
    local d="${WORK}/bin"; mkdir -p "$d"
    printf '%s' "$WORK"
    printf '#!/bin/sh\ncase "$1" in info) echo "Server Version: 27"; exit 0;; ps) echo running; exit 0;; esac\nexit 0\n' > "$d/docker"
    printf '#!/bin/sh\necho "colima $*" >> "%s/calls"\nexit 0\n' "$WORK" > "$d/colima"
    chmod +x "$d/docker" "$d/colima"
}

# run <probe_cmd> <restart_cmd> [settle_s]: runs the real supervisor once.
run() {
    rm -rf "${WORK}/state" "${WORK}/logs"; : > "${WORK}/calls"; rm -f "${WORK}/restarted"
    local P; P="$(make_prefix)"; make_prefix >/dev/null
    OSTLER_ENGINE_BREW_PREFIX="$P" OSTLER_ENGINE_ALT_PREFIX="$P" \
    OSTLER_ENGINE_ALLOW_PATH_LOOKUP=0 OSTLER_ENGINE_DESKTOP_PATH="${WORK}/none.app" \
    OSTLER_STATE_DIR="${WORK}/state" OSTLER_LOGS_DIR="${WORK}/logs" OSTLER_DIR="${WORK}/ostler" \
    OSTLER_ENGINE_PORT_PROBE_CMD="true" OSTLER_ENGINE_INSTALL_RUNNING_CMD="false" \
    OSTLER_ENGINE_KICKSTART_CMD="echo KICKSTART_CALLED; exit 0" \
    OSTLER_ENGINE_HA_PID_FILE="${WORK}/no-such-ha.pid" \
    OSTLER_ENGINE_LOGIND_PROBE_CMD="$1" \
    OSTLER_ENGINE_LOGIND_RESTART_CMD="$2" \
    OSTLER_ENGINE_LOGIND_SAMPLE_S=5 OSTLER_ENGINE_LOGIND_PROBE_TIMEOUT_S=3 \
    OSTLER_ENGINE_LOGIND_SETTLE_S="${3:-0}" \
    PATH="${P}/bin:/usr/bin:/bin" bash "$SUP" >"${WORK}/sup.out" 2>&1
}
restarted()  { [ -f "${WORK}/restarted" ]; }
verdict()    { sed -n 's/.*"verdict": "\([A-Z-]*\)".*/\1/p' "${WORK}/state/engine-supervisor/logind_health.json" 2>/dev/null | head -1; }
RESTART="touch '${WORK}/restarted'; echo RESTART_CALLED; exit 0"
# Wedged until restarted, healthy after: 500 ticks in 5 s = 100% of a core.
WEDGE_THEN_OK="if [ -f '${WORK}/restarted' ]; then echo TICKS 418 100 110; else echo TICKS 418 100 600; fi"

# 1. WEDGED: logind busy, restart is called, and the post-restart probe is healthy.
run "echo TICKS 418 100 600" "$RESTART" 0
if restarted; then pass "wedged logind (500 ticks in 5 s): restart called"; else failure "wedged logind was NOT restarted: $(tail -3 "${WORK}/sup.out")"; fi
if grep -q 'restarting it' "${WORK}/sup.out"; then pass "the restart decision is logged"; else failure "no restart decision in the log"; fi

# 2. HEALTHY: low CPU, no restart, verdict HEALTHY.
run "echo TICKS 418 100 110" "$RESTART" 0
if ! restarted && [ "$(verdict)" = "HEALTHY" ]; then pass "healthy logind (10 ticks in 5 s): no restart, verdict HEALTHY"; else failure "healthy logind acted or was misread (restarted=$(restarted && echo y || echo n), verdict=$(verdict))"; fi

# 3. Recovery: wedged, restart, probe after restart is healthy -> verdict HEALTHY.
run "$WEDGE_THEN_OK" "$RESTART" 0
if restarted && [ "$(verdict)" = "HEALTHY" ] && grep -q 'RECOVERED: logind CPU back' "${WORK}/sup.out"; then
    pass "wedged, restarted, recovered: verdict HEALTHY and the RECOVERED line is logged"
else
    failure "recovery not recorded (restarted=$(restarted && echo y || echo n), verdict=$(verdict))"
fi

# 4. Probe TIMEOUT is never healthy: a probe that hangs past the bound.
run "sleep 30" "$RESTART" 0
if ! restarted && [ "$(verdict)" = "CANNOT-RUN" ]; then pass "probe timed out: no restart, verdict CANNOT-RUN (never HEALTHY)"; else failure "a timed-out probe was read as healthy or acted (restarted=$(restarted && echo y || echo n), verdict=$(verdict))"; fi

# 5. Probe prints nothing parseable (e.g. colima ssh fails): CANNOT-RUN, no restart.
run "echo garbage; exit 1" "$RESTART" 0
if ! restarted && [ "$(verdict)" = "CANNOT-RUN" ]; then pass "unparseable probe: no restart, verdict CANNOT-RUN"; else failure "unparseable probe acted or was read as healthy (verdict=$(verdict))"; fi

# 6. logind not running in the VM: CANNOT-RUN, no restart (restarting a dead unit is not this watchdog's job).
run "echo NOPID" "$RESTART" 0
if ! restarted && [ "$(verdict)" = "CANNOT-RUN" ]; then pass "logind absent (NOPID): no restart, verdict CANNOT-RUN"; else failure "NOPID acted (verdict=$(verdict))"; fi

# 7. Restart cooldown: wedged, but restarted 60 s ago -> no second restart.
run "echo TICKS 418 100 600" "$RESTART" 0
mkdir -p "${WORK}/state/engine-supervisor"; rm -f "${WORK}/restarted"
printf '{"verdict": "WEDGED", "action": "restarted", "detail": "x", "checked": "x", "last_restart_epoch": %s}\n' "$(( $(date +%s) - 60 ))" > "${WORK}/state/engine-supervisor/logind_health.json"
OSTLER_ENGINE_BREW_PREFIX="$WORK" OSTLER_ENGINE_ALT_PREFIX="$WORK" OSTLER_ENGINE_ALLOW_PATH_LOOKUP=0 OSTLER_ENGINE_DESKTOP_PATH="${WORK}/none.app" \
OSTLER_STATE_DIR="${WORK}/state" OSTLER_LOGS_DIR="${WORK}/logs" OSTLER_DIR="${WORK}/ostler" OSTLER_ENGINE_PORT_PROBE_CMD="true" OSTLER_ENGINE_INSTALL_RUNNING_CMD="false" \
OSTLER_ENGINE_LOGIND_PROBE_CMD="echo TICKS 418 100 600" OSTLER_ENGINE_LOGIND_RESTART_CMD="$RESTART" OSTLER_ENGINE_LOGIND_SAMPLE_S=5 OSTLER_ENGINE_LOGIND_PROBE_TIMEOUT_S=3 \
PATH="${WORK}/bin:/usr/bin:/bin" bash "$SUP" >"${WORK}/sup.out" 2>&1
if ! restarted && grep -q 'cooldown' "${WORK}/sup.out"; then pass "restart 60 s ago: cooldown holds, no second restart"; else failure "restarted inside the 900 s cooldown"; fi

# 8. A restart that fails is recorded, so the cooldown applies to it too.
run "echo TICKS 418 100 600" "exit 3" 0
if grep -q 'logind restart FAILED rc=3' "${WORK}/sup.out" && grep -q '"last_restart_epoch": [1-9]' "${WORK}/state/engine-supervisor/logind_health.json"; then
    pass "failed restart: logged rc, and recorded so the cooldown applies"
else
    failure "failed restart not recorded: $(tail -3 "${WORK}/sup.out")"
fi

echo "logind selfheal: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
