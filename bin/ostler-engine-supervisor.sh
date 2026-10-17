#!/usr/bin/env bash
#
# ostler-engine-supervisor.sh -- keep the container runtime ALIVE, not just
# watched.
#
# ══════════════════════════════════════════════════════════════════════
# THE DEFECT, IN ONE SENTENCE, MEASURED
# ══════════════════════════════════════════════════════════════════════
#
# A supervisor that runs once at process launch cannot recover a mid-life
# death.
#
# Andrews-Mac-mini, 2026-08-23, read off the box's own logs:
#
#   ~/.ostler/logs/ostler-assistant.err carries exactly SIX colima lines,
#   three start/success pairs, the last at
#
#       2026-08-22T09:57:58.960Z  Colima not running - starting it
#                                 (daemon-owned, inherits FDA), attempt 1/5
#       2026-08-22T09:57:59.312Z  Colima started; Docker runtime available
#
#   The daemon (pid 19647) started at 2026-08-22T09:57:56Z and has
#   `last exit code = (never exited)`. ensure_colima_running() is called
#   ONCE, at startup. So the last time anything checked the engine was two
#   seconds after that daemon booted.
#
#   Jetsam then killed the Colima VM ~31 hours later, on 2026-08-23 between
#   16:10 and 17:33 local -- eight JetsamEvent reports in
#   /Library/Logs/DiagnosticReports/ -- because the installer's unbounded
#   output buffer had taken the machine to 4.27 GB and macOS ran out of
#   application memory. No reboot: uptime was 2 days.
#
#   `pgrep -f 'limactl|qemu'` -> 0. Socket gone. :8044 and :7878 -> 000,
#   while :8000 -> 200 and :8089 -> 302 (the native launchd services, and
#   the control that makes the zero trustworthy).
#
#   The ONE periodic thing that touches the runtime is the wiki-recompile
#   agent, and its plist on that box says `StartInterval = 86400`. Once a
#   DAY. Its last tick, 2026-08-23 20:07:06, waited 120 s, logged "not ready
#   ... Exiting 0 (no launchd failure)", and did nothing. A daily tick is
#   exactly a day of latency, which is exactly how long the wiki was dark.
#
# The recovery primitive is NOT broken. It worked three times, in under half
# a second each time. Its TRIGGER is the defect.
#
# ══════════════════════════════════════════════════════════════════════
# WHY IT KICKSTARTS THE DAEMON INSTEAD OF RUNNING `colima start`
# ══════════════════════════════════════════════════════════════════════
#
# This is the whole design and it is not incidental. install.sh (~9245)
# deliberately does NOT create a bare `com.ostler.colima` LaunchAgent, and
# records why: a plain launchd agent has NO Full Disk Access, so Colima
# cannot mount ~/Documents, so the wiki's bind-mount fails and the wiki dies
# on every reboot. That exact agent was deleted to fix that exact bug.
#
# The signed daemon HOLDS FDA and a child it fork-execs inherits it, which is
# why `ensure_colima_running()` lives there and why its log line says
# "(daemon-owned, inherits FDA)".
#
# So this supervisor must not start Colima itself. It asks launchd to restart
# the FDA holder, which re-runs the proven primitive with the right
# privileges. Recovery stays inside the existing mechanism; only the cadence
# is new.
#
# ══════════════════════════════════════════════════════════════════════
# EXIT CODES
# ══════════════════════════════════════════════════════════════════════
#   0  the engine is up (or recovery brought it back)
#   1  a fault persists after the action this state allows
#   2  CANNOT-RUN -- could not determine the state. Never a pass.

set -uo pipefail

OSTLER_DIR="${OSTLER_DIR:-${HOME}/.ostler}"
LOGS_DIR="${OSTLER_LOGS_DIR:-${OSTLER_DIR}/logs}"
STATE_DIR="${OSTLER_STATE_DIR:-${OSTLER_DIR}/state}/engine-supervisor"
STATE_FILE="${STATE_DIR}/state.json"
LOG_FILE="${LOGS_DIR}/engine-supervisor.log"

ASSISTANT_LABEL="${OSTLER_ASSISTANT_LABEL:-com.creativemachines.ostler.assistant}"

# ══════════════════════════════════════════════════════════════════════
# HEALTH IS THE STORE PORTS ANSWERING, NOT `colima list` (Ostler #30)
# ══════════════════════════════════════════════════════════════════════
# Measured on a Studio install (lifecycle_studio29): the VM process was
# killed with the limactl hostagent still alive. `colima list` said Running,
# `colima start` said "already running", the daemon logged a false "Colima
# started", and the 600 s cooldown outlasted the whole 1200 s window. A fully
# dead colima, by contrast, recovered in 23 s. So the verdict is now the walk
# predicate (scripts/box_walk_probes/probes/no_store_port_is_tcp_reachable.sh,
# arm 2): the Qdrant and Oxigraph ports answer 2xx THROUGH the store proxy
# WITH the install's own credential (secrets/store-curl.conf).
#
# TIMING, justified against the measured boot. A fully dead colima was back in
# 23 s; a cold VM is budgeted at ~60 s. A restart is only taken when the
# ports have been dead for N=6 consecutive probes 15 s apart (90 s of
# continuous silence, 1.5x the cold budget and ~4x the measured recovery), so
# a slow boot is never killed mid-boot. After the restart the supervisor
# waits up to 120 s (2x the cold budget) for the ports. Worst case per tick
# is 90 + 120 = 210 s, inside the 300 s StartInterval.
PORT_FAIL_N="${OSTLER_ENGINE_PORT_FAIL_N:-6}"
PORT_FAIL_INTERVAL_S="${OSTLER_ENGINE_PORT_FAIL_INTERVAL_S:-15}"
# Rationed, not forbidden: 60 s base, doubling per consecutive failed
# recovery, capped at 900 s. There is no permanent give-up: a supervisor that
# stops trying is the 1200 s outage again, just slower.
RECOVERY_COOLDOWN_S="${OSTLER_ENGINE_RECOVERY_COOLDOWN_S:-60}"
RECOVERY_COOLDOWN_CAP_S="${OSTLER_ENGINE_RECOVERY_COOLDOWN_CAP_S:-900}"
# How long to wait for the ports after asking for a restart.
RECOVERY_SETTLE_S="${OSTLER_ENGINE_RECOVERY_SETTLE_S:-120}"
SETTLE_POLL_S="${OSTLER_ENGINE_SETTLE_POLL_S:-5}"
# BOOTING WINDOW. On a loaded 16 GB Mac at login a boot can exceed the 90 s
# dead-probe window, and killing a booting VM in a loop is worse than the
# outage. So while the lima hostagent is younger than this, the supervisor
# only waits. Age comes from the PROCESS START TIME (ps), never from this
# script's own memory, so a supervisor restart cannot reset it.
BOOT_GRACE_S="${OSTLER_ENGINE_BOOT_GRACE_S:-300}"
COLIMA_HOME_DIR="${OSTLER_ENGINE_COLIMA_HOME:-${HOME}/.colima}"
HA_PID_FILE="${OSTLER_ENGINE_HA_PID_FILE:-${COLIMA_HOME_DIR}/_lima/colima/ha.pid}"

# Injectable so the tests can drive every branch without a real launchd, a
# real engine or real ports. Production leaves them empty.
OSTLER_ENGINE_KICKSTART_CMD="${OSTLER_ENGINE_KICKSTART_CMD:-}"
# rc 0 = both store ports answered 2xx through the proxy auth.
OSTLER_ENGINE_PORT_PROBE_CMD="${OSTLER_ENGINE_PORT_PROBE_CMD:-}"
# rc 0 = the installer is running right now.
OSTLER_ENGINE_INSTALL_RUNNING_CMD="${OSTLER_ENGINE_INSTALL_RUNNING_CMD:-}"
STORE_CURL_CONF="${OSTLER_ENGINE_STORE_CURL_CONF:-${OSTLER_DIR}/secrets/store-curl.conf}"

mkdir -p "$STATE_DIR" "$LOGS_DIR" 2>/dev/null || true

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _cand in "${SCRIPT_DIR}/../lib/ostler-container-engine.sh" \
             "${OSTLER_DIR}/lib/ostler-container-engine.sh"; do
    if [ -f "$_cand" ]; then
        # shellcheck source=/dev/null
        . "$_cand"
        _ENGINE_LIB="$_cand"
        break
    fi
done
if [ -z "${_ENGINE_LIB:-}" ]; then
    log "CANNOT-RUN: lib/ostler-container-engine.sh not found; nothing was checked"
    exit 2
fi

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }

read_field() {
    # read_field <key> -- integer/string field out of the state file, or ""
    [ -f "$STATE_FILE" ] || return 0
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$STATE_FILE" | head -1
}

write_state() {
    # write_state <state> <detail> <action> <consecutive_failures> <last_attempt_epoch>
    local first_seen
    first_seen="$(read_field first_seen)"
    if [ "$1" = "up" ] || [ -z "$first_seen" ]; then first_seen="$(now_iso)"; fi
    printf '{"state": "%s", "detail": "%s", "last_action": "%s", "consecutive_failures": %s, "last_attempt_epoch": %s, "first_seen": "%s", "last_seen": "%s"}\n' \
        "$1" "$(printf '%s' "$2" | tr -d '"\\' | cut -c1-400)" "$3" "$4" "$5" "$first_seen" "$(now_iso)" \
        > "${STATE_FILE}.tmp" 2>/dev/null \
        && mv -f "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null || true
}

kickstart_assistant() {
    if [ -n "$OSTLER_ENGINE_KICKSTART_CMD" ]; then
        # Test seam.
        eval "$OSTLER_ENGINE_KICKSTART_CMD"
        return $?
    fi
    # `-k` kills the running instance first, so the daemon re-executes and
    # runs ensure_colima_running() from the top. Without -k a running job is
    # a no-op and the whole recovery would silently do nothing -- the exact
    # failure class this file exists to remove.
    launchctl kickstart -k "gui/$(id -u)/${ASSISTANT_LABEL}" 2>&1
}

install_running() {
    if [ -n "$OSTLER_ENGINE_INSTALL_RUNNING_CMD" ]; then
        eval "$OSTLER_ENGINE_INSTALL_RUNNING_CMD"
        return $?
    fi
    pgrep -f '/install\.sh' >/dev/null 2>&1
}

# ports_answer: the walk predicate. rc 0 only when BOTH stores answer 2xx
# through the proxy with the install credential. rc 2 = could not judge (no
# credential file yet), which is never a verdict.
ports_answer() {
    if [ -n "$OSTLER_ENGINE_PORT_PROBE_CMD" ]; then
        eval "$OSTLER_ENGINE_PORT_PROBE_CMD"
        return $?
    fi
    [ -r "$STORE_CURL_CONF" ] || return 2
    local code url
    for url in "http://127.0.0.1:6333/collections" "http://127.0.0.1:7878/query?query=ASK%7B%7D"; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 6 -K "$STORE_CURL_CONF" "$url" 2>/dev/null)"
        case "$code" in 2??) ;; *) return 1 ;; esac
    done
    return 0
}

stop_colima_hard() {
    # `colima stop -f` needs no Full Disk Access (only START does, and that
    # stays with the daemon). It is the step that clears a hostagent that
    # outlived its VM: without it `colima start` answers "already running".
    if [ -n "${OSTLER_ENGINE_COLIMA:-}" ]; then
        local out rc
        out="$("$OSTLER_ENGINE_COLIMA" stop -f 2>&1)"; rc=$?
        log "colima stop -f rc=${rc}: ${out:-<no output>}"
    else
        log "no colima binary found; skipping colima stop -f"
    fi
}

# hostagent_age_s: seconds since the lima hostagent PROCESS started, read from
# its pid file and `ps`. Prints nothing (rc 1) when there is no live hostagent:
# fully dead, so not booting. etime is [[dd-]hh:]mm:ss (BSD ps has no etimes).
hostagent_age_s() {
    local pid et d=0 h=0 m=0 sec=0 rest
    [ -r "$HA_PID_FILE" ] || return 1
    pid="$(tr -dc '0-9' < "$HA_PID_FILE")"
    [ -n "$pid" ] || return 1
    et="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$et" ] || return 1
    case "$et" in *-*) d="${et%%-*}"; rest="${et#*-}" ;; *) rest="$et" ;; esac
    IFS=: read -r a b c <<<"$rest"
    if [ -n "${c:-}" ]; then h=$((10#$a)); m=$((10#$b)); sec=$((10#$c)); else m=$((10#$a)); sec=$((10#${b:-0})); fi
    echo $(( 10#$d * 86400 + h * 3600 + m * 60 + sec ))
}

cooldown_for() {
    # cooldown_for <consecutive_failures> -> seconds: base * 2^failures, capped.
    local c="$RECOVERY_COOLDOWN_S" i=0
    while [ "$i" -lt "$1" ] && [ "$c" -lt "$RECOVERY_COOLDOWN_CAP_S" ]; do
        c=$((c * 2)); i=$((i + 1))
    done
    [ "$c" -gt "$RECOVERY_COOLDOWN_CAP_S" ] && c="$RECOVERY_COOLDOWN_CAP_S"
    echo "$c"
}

# ── classify ────────────────────────────────────────────────────────
ostler_engine_state
classify_rc=$?
state="$OSTLER_ENGINE_STATE"
detail="$OSTLER_ENGINE_DETAIL"

if [ "$classify_rc" -eq 2 ]; then
    log "CANNOT-RUN: ${detail}"
    write_state "unknown" "$detail" "none" "$(read_field consecutive_failures || echo 0)" "0"
    exit 2
fi

# --probe-ports: the ONE canonical store-port check, callable on its own.
# rc 0 = Qdrant and Oxigraph both answered 2xx through the proxy with the
# install credential; 1 = a store did not; 2 = could not judge (no credential).
# Prints nothing, touches no state, restarts nothing. The catch-up adapters
# (vendor/ostler_fda/sink_health.py) call THIS rather than re-implementing the
# check, so the supervisor's verdict and theirs cannot drift.
if [ "${1:-}" = "--probe-ports" ]; then
    ports_answer
    exit $?
fi

# An install in progress owns the runtime: its own colima start, image pulls
# and container creates look exactly like an outage from outside.
if install_running; then
    log "installer is running; not judging or restarting the engine"
    exit 0
fi

failures="$(read_field consecutive_failures)"; [ -n "$failures" ] || failures=0
last_attempt="$(read_field last_attempt_epoch)"; [ -n "$last_attempt" ] || last_attempt=0
since=$(( $(now_epoch) - last_attempt ))

if [ "$state" = "absent" ]; then
    # Nothing installed. This supervisor will not install software behind the
    # customer's back; the finding is the deliverable.
    log "engine ABSENT: ${detail}. No recovery is possible from here; re-run the installer."
    write_state "absent" "$detail" "none (install required)" "$failures" "$last_attempt"
    exit 1
fi

ports_answer; ports_rc=$?
if [ "$ports_rc" -eq 2 ]; then
    log "CANNOT-RUN: cannot judge the store ports (no credential at ${STORE_CURL_CONF}); nothing was restarted"
    exit 2
fi

if [ "$ports_rc" -eq 0 ]; then
    if [ "$state" = "running_no_wiki" ]; then
        # Stores answer, wiki container is down: a DIFFERENT, smaller repair.
        if [ "$last_attempt" -gt 0 ] && [ "$since" -lt "$(cooldown_for "$failures")" ]; then
            log "wiki container down; last attempt ${since}s ago, inside cooldown. Waiting."
            exit 1
        fi
        log "store ports answer but the wiki container is not running: ${detail}"
        attempt_epoch="$(now_epoch)"
        start_out="$("$OSTLER_ENGINE_DOCKER" start ostler-wiki-site 2>&1)"; start_rc=$?
        if [ "$start_rc" -eq 0 ]; then
            sleep 5
            if ostler_engine_state && [ "$OSTLER_ENGINE_STATE" = "up" ]; then
                log "RECOVERED: wiki container started (store ports answering)"
                rm -f "$STATE_FILE" 2>/dev/null || true
                exit 0
            fi
        fi
        log "could not start the wiki container: ${start_out}"
        write_state "running_no_wiki" "$detail" "docker start failed: $(printf '%s' "$start_out" | head -1)" "$((failures + 1))" "$attempt_epoch"
        exit 1
    fi
    # Ports answer: healthy, whatever `docker info` or `colima list` say.
    rm -f "$STATE_FILE" 2>/dev/null || true
    exit 0
fi

# ── ports are not answering: confirm it is not just a slow boot ─────
n=1
while [ "$n" -lt "$PORT_FAIL_N" ]; do
    sleep "$PORT_FAIL_INTERVAL_S"
    n=$((n + 1))
    if ports_answer; then
        log "store ports answering again on probe ${n}/${PORT_FAIL_N}; slow boot, not restarting"
        rm -f "$STATE_FILE" 2>/dev/null || true
        exit 0
    fi
done
log "store ports dead on ${PORT_FAIL_N} consecutive probes ${PORT_FAIL_INTERVAL_S}s apart (engine state '${state}': ${detail})"

ha_age="$(hostagent_age_s)" || ha_age=""
if [ -n "$ha_age" ] && [ "$ha_age" -lt "$BOOT_GRACE_S" ]; then
    log "VM is BOOTING: lima hostagent started ${ha_age}s ago (< ${BOOT_GRACE_S}s grace); ports still dead, waiting, no forced stop"
    exit 1
fi

cooldown="$(cooldown_for "$failures")"
if [ "$last_attempt" -gt 0 ] && [ "$since" -lt "$cooldown" ]; then
    log "last recovery was ${since}s ago, inside the ${cooldown}s cooldown (${failures} consecutive failures). Waiting."
    write_state "installed_stopped" "$detail" "cooling down (${since}s of ${cooldown}s)" "$failures" "$last_attempt"
    exit 1
fi

attempt_epoch="$(now_epoch)"
stop_colima_hard
log "restarting ${ASSISTANT_LABEL} so its ensure_colima_running() re-runs WITH Full Disk Access -- a launchd agent starting the runtime directly would have none, and the wiki's ~/Documents bind-mount would then fail"
ks_out="$(kickstart_assistant)"; ks_rc=$?
log "restart command rc=${ks_rc}: ${ks_out:-<no output>}"
if [ "$ks_rc" -ne 0 ]; then
    log "kickstart FAILED rc=${ks_rc}: ${ks_out}"
    write_state "installed_stopped" "$detail" "kickstart failed rc=${ks_rc}" "$((failures + 1))" "$attempt_epoch"
    exit 1
fi

waited=0
while [ "$waited" -lt "$RECOVERY_SETTLE_S" ]; do
    sleep "$SETTLE_POLL_S"
    waited=$((waited + SETTLE_POLL_S))
    if ports_answer; then
        log "RECOVERED after ${waited}s: store ports answering through the proxy auth"
        rm -f "$STATE_FILE" 2>/dev/null || true
        exit 0
    fi
done
log "NOT recovered: store ports still not answering ${RECOVERY_SETTLE_S}s after the restart (next attempt after $(cooldown_for "$((failures + 1))")s)"
write_state "installed_stopped" "$detail" "restarted; store ports still dead after ${RECOVERY_SETTLE_S}s" "$((failures + 1))" "$attempt_epoch"
exit 1
