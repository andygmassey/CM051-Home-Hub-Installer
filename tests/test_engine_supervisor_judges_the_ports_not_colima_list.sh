#!/usr/bin/env bash
#
# Ostler #30: a colima VM killed with its hostagent alive (colima list says
# Running, `colima start` says "already running") was never recovered in
# 1200 s. The supervisor must judge health by the STORE PORTS answering
# through the proxy auth, force `colima stop -f` before the daemon restarts
# it, never kill a slow boot, back off from 60 s, and stand down while the
# installer runs.
#
# Fake colima, fake docker, fake ports (synthetic). Usage: [REPO_ROOT]
# rc 2 = harness could not set itself up.

set -uo pipefail
REPO_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SUP="${REPO_ROOT}/bin/ostler-engine-supervisor.sh"
[[ -f "$SUP" && -f "${REPO_ROOT}/lib/ostler-container-engine.sh" ]] || { echo "CANNOT-RUN: supervisor or lib missing under ${REPO_ROOT}" >&2; exit 2; }

PASS=0; FAIL=0
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-sup-ports.XXXXXX")" || { echo "CANNOT-RUN: mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# make_prefix <name> <docker_info_rc>: fake docker + fake colima that log calls.
make_prefix() {
    local d="${WORK}/$1/bin"; mkdir -p "$d"
    cat > "$d/docker" <<STUB
case "\$1" in
  info) [ $2 -eq 0 ] && { echo "Server Version: 27"; exit 0; }; echo "cannot connect to the docker API" >&2; exit $2 ;;
  ps) [ $2 -eq 0 ] || exit 1; echo running; exit 0 ;;
esac
exit 0
STUB
    cat > "$d/colima" <<STUB
echo "colima \$*" >> "${WORK}/calls"
case "\$1" in
  list) echo "default  Running"; exit 0 ;;
  start) echo "already running, ignoring"; exit 0 ;;
  stop) touch "${WORK}/stopped"; exit 0 ;;
esac
exit 0
STUB
    chmod +x "$d/docker" "$d/colima"
    printf '%s' "${WORK}/$1"
}

# run <prefix> <probe_cmd> <install_running_cmd> -> rc; output in sup.out
run() {
    rm -f "${WORK}/calls" "${WORK}/stopped" "${WORK}/kicked"; touch "${WORK}/calls"
    OSTLER_ENGINE_BREW_PREFIX="$1" OSTLER_ENGINE_ALT_PREFIX="$1" \
    OSTLER_ENGINE_ALLOW_PATH_LOOKUP=0 OSTLER_ENGINE_DESKTOP_PATH="${WORK}/none.app" \
    OSTLER_STATE_DIR="${WORK}/state" OSTLER_LOGS_DIR="${WORK}/logs" OSTLER_DIR="${WORK}/ostler" \
    OSTLER_ENGINE_KICKSTART_CMD="echo KICKSTART_CALLED; touch '${WORK}/kicked'; exit 0" \
    OSTLER_ENGINE_PORT_PROBE_CMD="$2" \
    OSTLER_ENGINE_INSTALL_RUNNING_CMD="${3:-false}" \
    OSTLER_ENGINE_HA_PID_FILE="${OSTLER_ENGINE_HA_PID_FILE:-${WORK}/no-such-ha.pid}" \
    OSTLER_ENGINE_PORT_FAIL_N=4 OSTLER_ENGINE_PORT_FAIL_INTERVAL_S=0 \
    OSTLER_ENGINE_RECOVERY_SETTLE_S=2 OSTLER_ENGINE_SETTLE_POLL_S=1 \
    PATH="/usr/bin:/bin" bash "$SUP" >"${WORK}/sup.out" 2>&1
}
stop_called() { grep -q 'colima stop -f' "${WORK}/calls"; }
kicked()      { grep -q KICKSTART_CALLED "${WORK}/sup.out"; }

# Ports come back only after BOTH the forced stop and the daemon restart.
RECOVER_PROBE="[ -f '${WORK}/stopped' ] && [ -f '${WORK}/kicked' ]"

# 1. Hung VM: docker answers nothing, colima list says Running, ports dead.
rm -rf "${WORK}/state"
P="$(make_prefix hung 1)"
run "$P" "$RECOVER_PROBE"; rc=$?
if stop_called && kicked && [[ $rc -eq 0 ]] && grep -q 'RECOVERED after' "${WORK}/sup.out"; then
    pass "hung VM (list says Running, ports dead): colima stop -f, daemon restart, recovered, rc=0"
else
    failure "hung VM not recovered (rc=${rc}, stop=$(stop_called && echo y || echo n), kick=$(kicked && echo y || echo n)): $(tail -5 "${WORK}/sup.out")"
fi
if grep -q 'RECOVERED after [0-9]*s: store ports answering' "${WORK}/sup.out"; then
    pass "the success line reports the MEASURED outcome (ports answering)"
else
    failure "no measured-outcome success line"
fi

# 2. Slow boot: ports dead for 2 probes then answer. Must NOT be killed.
rm -rf "${WORK}/state"; rm -f "${WORK}/n"
P="$(make_prefix slow 1)"
run "$P" "n=\$(cat '${WORK}/n' 2>/dev/null || echo 0); echo \$((n+1)) > '${WORK}/n'; [ \$n -ge 2 ]"; rc=$?
if ! stop_called && ! kicked && [[ $rc -eq 0 ]]; then
    pass "slow boot (ports answer on probe 3 of 4): no stop, no restart, rc=0"
else
    failure "a slow boot was killed mid-boot (rc=${rc}, stop=$(stop_called && echo y || echo n), kick=$(kicked && echo y || echo n))"
fi

# 3. Fully dead: docker down, ports dead until the daemon restart.
rm -rf "${WORK}/state"
P="$(make_prefix dead 1)"
run "$P" "[ -f '${WORK}/kicked' ]"; rc=$?
if kicked && [[ $rc -eq 0 ]]; then
    pass "fully dead colima: daemon restarted, recovered, rc=0"
else
    failure "fully dead colima not recovered (rc=${rc}): $(tail -5 "${WORK}/sup.out")"
fi

# 4. Install-running guard: ports dead, installer running -> hands off.
rm -rf "${WORK}/state"
P="$(make_prefix inst 1)"
run "$P" "false" "true"; rc=$?
if ! stop_called && ! kicked && [[ $rc -eq 0 ]]; then
    pass "install-running guard: dead ports during an install trigger no stop and no restart"
else
    failure "the supervisor acted while the installer was running (rc=${rc})"
fi

# 5. Healthy ports with docker info failing: not restarted (ports are truth).
rm -rf "${WORK}/state"
P="$(make_prefix healthy 1)"
run "$P" "true"; rc=$?
if ! stop_called && ! kicked && [[ $rc -eq 0 ]]; then
    pass "negative control: ports answering means no restart, whatever docker info says"
else
    failure "restarted a box whose ports answer (rc=${rc})"
fi

# 6. Backoff: base 60 s, doubling, capped at 900 s, never a permanent give-up.
seed() { # seed <failures> <seconds_ago>
    mkdir -p "${WORK}/state/engine-supervisor"
    printf '{"state": "installed_stopped", "detail": "x", "last_action": "x", "consecutive_failures": %s, "last_attempt_epoch": %s, "first_seen": "2026-01-01T00:00:00Z", "last_seen": "2026-01-01T00:00:00Z"}\n' \
        "$1" "$(( $(date +%s) - $2 ))" > "${WORK}/state/engine-supervisor/state.json"
}
P="$(make_prefix bo 1)"
rm -rf "${WORK}/state"; seed 0 30;  run "$P" "false"
if ! kicked; then pass "backoff: 30s after a first attempt is inside the 60s cooldown"; else failure "restarted inside the 60s base cooldown"; fi
rm -rf "${WORK}/state"; seed 0 70;  run "$P" "$RECOVER_PROBE"
if kicked; then pass "backoff: 70s after a first attempt is past the 60s cooldown, acts"; else failure "still waiting at 70s with 0 prior failures (cooldown is 60s)"; fi
rm -rf "${WORK}/state"; seed 2 200; run "$P" "false"
if ! kicked; then pass "backoff: after 2 failures the cooldown is 240s, 200s is still inside it"; else failure "ignored the exponential backoff (2 failures, 200s)"; fi
rm -rf "${WORK}/state"; seed 20 1000; run "$P" "$RECOVER_PROBE"
if kicked; then pass "backoff is capped at 900s and never gives up (20 failures, 1000s ago, acts)"; else failure "20 failures stopped the supervisor for good, or the cap exceeds 900s"; fi

# 6b. Booting window: hostagent PROCESS age from ps, via its pid file.
# A real sleep is the hostagent; its age is genuinely young. The old-process
# case seams the clock because a 10-minute-old process cannot be conjured.
sleep 600 & HA=$!
echo "$HA" > "${WORK}/ha.pid"
P="$(make_prefix boot 1)"
rm -rf "${WORK}/state"
OSTLER_ENGINE_HA_PID_FILE="${WORK}/ha.pid" run "$P" "false"; rc=$?
if ! stop_called && ! kicked && [[ $rc -eq 1 ]] && grep -q 'VM is BOOTING' "${WORK}/sup.out"; then
    pass "fresh hostagent (real ps age, ports dead): BOOTING, no forced stop, no restart"
else
    failure "a booting VM (hostagent seconds old) was force-stopped or not reported (rc=${rc}): $(tail -3 "${WORK}/sup.out")"
fi
rm -rf "${WORK}/state"
OSTLER_ENGINE_HA_PID_FILE="${WORK}/ha.pid" OSTLER_ENGINE_BOOT_GRACE_S=0 run "$P" "$RECOVER_PROBE"; rc=$?
if stop_called && kicked && [[ $rc -eq 0 ]]; then
    pass "hostagent older than the grace window (grace 0), same dead ports: recovered"
else
    failure "an old hostagent with dead ports was not recovered (rc=${rc})"
fi
kill "$HA" 2>/dev/null; wait "$HA" 2>/dev/null
# etime parser: dd-hh:mm:ss, hh:mm:ss, mm:ss (BSD ps).
for pair in "10:00=600" "01:02:03=3723" "2-00:00:05=172805" "00:07=7"; do
    et="${pair%%=*}"; want="${pair##*=}"
    fake_et="$et"
    got="$(ps() { echo "$fake_et"; }; eval "$(sed -n '/^hostagent_age_s()/,/^}/p' "$SUP")"; HA_PID_FILE="${WORK}/ha.pid"; echo 4242 > "$HA_PID_FILE"; hostagent_age_s)"
    if [[ "$got" == "$want" ]]; then pass "etime ${et} parses to ${want}s"; else failure "etime ${et} parsed to '${got}', want ${want}"; fi
done

# 7. Still never runs `colima start` itself (FDA constraint).
SUP_CODE="$(sed 's/#.*//' "$SUP")"
if grep -qE '(^|[^-])colima[[:space:]]+start' <<<"$SUP_CODE"; then
    failure "the supervisor runs 'colima start' itself (no Full Disk Access under launchd)"
else
    pass "the supervisor does not run 'colima start' itself"
fi

# 8. --probe-ports: the ONE canonical store-port check. Other tools (the
# catch-up adapters, via ostler_fda/sink_health.py) call it instead of
# re-implementing it, so the two cannot drift. rc 0 both answer 2xx through the
# proxy credential, 1 a store did not, 2 no credential (could not judge).
mkdir -p "${WORK}/fakecurl"
cat > "${WORK}/fakecurl/curl" <<'STUB'
#!/bin/sh
for a in "$@"; do u="$a"; done
case "$u" in
  *6333*) printf '%s' "${FAKE_QDRANT:-200}" ;;
  *7878*) printf '%s' "${FAKE_OXIGRAPH:-200}" ;;
esac
STUB
chmod +x "${WORK}/fakecurl/curl"
: > "${WORK}/store-curl.conf"
probe() {
    FAKE_QDRANT="$1" FAKE_OXIGRAPH="$2" OSTLER_ENGINE_STORE_CURL_CONF="${3:-${WORK}/store-curl.conf}" \
    OSTLER_STATE_DIR="${WORK}/pstate" OSTLER_LOGS_DIR="${WORK}/plogs" OSTLER_DIR="${WORK}/ostler" \
    OSTLER_ENGINE_BREW_PREFIX="${WORK}/hung" OSTLER_ENGINE_ALT_PREFIX="${WORK}/hung" \
    PATH="${WORK}/fakecurl:/usr/bin:/bin" bash "$SUP" --probe-ports >/dev/null 2>&1
}
probe 200 200; r_ok=$?
probe 200 502; r_ox=$?
probe 000 200; r_qd=$?
probe 200 200 "${WORK}/no-such.conf"; r_nocred=$?
# A pure probe: it must judge and exit, not run the recovery flow, so it
# leaves no supervisor state and no kickstart behind.
side_effects="$(find "${WORK}/pstate" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [[ $r_ok -eq 0 && $r_ox -eq 1 && $r_qd -eq 1 && $r_nocred -eq 2 && "$side_effects" == "0" ]]; then
    pass "--probe-ports: both 2xx=0, oxigraph down=1, qdrant down=1, no credential=2"
else
    failure "--probe-ports rcs wrong: ok=${r_ok} oxigraph_down=${r_ox} qdrant_down=${r_qd} no_cred=${r_nocred} (want 0 1 1 2) state_files=${side_effects} (want 0)"
fi

echo; echo "=== ${PASS} passed / ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
