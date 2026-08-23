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

# A daemon restart interrupts in-flight chat, so it is rationed. Ten minutes
# is longer than a cold Colima boot (measured 0.4-3 s on this box, but a cold
# VM can take ~60 s) and short enough that an outage is minutes, not a day.
RECOVERY_COOLDOWN_S="${OSTLER_ENGINE_RECOVERY_COOLDOWN_S:-600}"
# After this many consecutive failed recoveries, STOP trying and leave the
# finding standing. A supervisor that thrashes forever is a second outage.
RECOVERY_MAX_ATTEMPTS="${OSTLER_ENGINE_RECOVERY_MAX_ATTEMPTS:-5}"
# How long to wait for the engine after asking for a restart.
RECOVERY_SETTLE_S="${OSTLER_ENGINE_RECOVERY_SETTLE_S:-60}"

# Injectable so the tests can drive every branch without a real launchd and
# without a real engine. Production leaves them empty.
OSTLER_ENGINE_KICKSTART_CMD="${OSTLER_ENGINE_KICKSTART_CMD:-}"

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

if [ "$state" = "up" ]; then
    # Clear the streak. A marker that is never cleared is a false-alarm
    # generator, and a recovered box must stop reporting an outage.
    rm -f "$STATE_FILE" 2>/dev/null || true
    exit 0
fi

failures="$(read_field consecutive_failures)"; [ -n "$failures" ] || failures=0
last_attempt="$(read_field last_attempt_epoch)"; [ -n "$last_attempt" ] || last_attempt=0
since=$(( $(now_epoch) - last_attempt ))

case "$state" in
  absent)
    # Nothing installed. This supervisor will not install software behind the
    # customer's back; the finding is the deliverable.
    log "engine ABSENT: ${detail}. No recovery is possible from here; re-run the installer."
    write_state "absent" "$detail" "none (install required)" "$failures" "$last_attempt"
    exit 1
    ;;

  installed_stopped)
    # THE MEASURED STATE, AND THE RECOVERABLE ONE.
    if [ "$failures" -ge "$RECOVERY_MAX_ATTEMPTS" ]; then
        log "engine STOPPED and ${failures} consecutive recovery attempts have failed; not trying again. The finding stands."
        write_state "installed_stopped" "$detail" "gave up after ${failures} attempts" "$failures" "$last_attempt"
        exit 1
    fi
    if [ "$last_attempt" -gt 0 ] && [ "$since" -lt "$RECOVERY_COOLDOWN_S" ]; then
        log "engine STOPPED; last recovery was ${since}s ago, inside the ${RECOVERY_COOLDOWN_S}s cooldown. Waiting."
        write_state "installed_stopped" "$detail" "cooling down (${since}s of ${RECOVERY_COOLDOWN_S}s)" "$failures" "$last_attempt"
        exit 1
    fi

    log "engine STOPPED: ${detail}"
    log "restarting ${ASSISTANT_LABEL} so its ensure_colima_running() re-runs WITH Full Disk Access -- a launchd agent starting the runtime directly would have none, and the wiki's ~/Documents bind-mount would then fail"
    ks_out="$(kickstart_assistant)"; ks_rc=$?
    # Log the restart command's own output ALWAYS, not only on failure. A
    # recovery whose only trace is "I tried" cannot be told apart from one
    # that no-oped.
    log "restart command rc=${ks_rc}: ${ks_out:-<no output>}"
    attempt_epoch="$(now_epoch)"
    if [ "$ks_rc" -ne 0 ]; then
        log "kickstart FAILED rc=${ks_rc}: ${ks_out}"
        write_state "installed_stopped" "$detail" "kickstart failed rc=${ks_rc}" "$((failures + 1))" "$attempt_epoch"
        exit 1
    fi

    waited=0
    while [ "$waited" -lt "$RECOVERY_SETTLE_S" ]; do
        sleep 5
        waited=$((waited + 5))
        if ostler_engine_state && [ "$OSTLER_ENGINE_STATE" = "up" ]; then
            log "RECOVERED after ${waited}s: ${OSTLER_ENGINE_DETAIL}"
            rm -f "$STATE_FILE" 2>/dev/null || true
            exit 0
        fi
    done
    log "engine did not come back within ${RECOVERY_SETTLE_S}s (now '${OSTLER_ENGINE_STATE}': ${OSTLER_ENGINE_DETAIL})"
    write_state "installed_stopped" "$OSTLER_ENGINE_DETAIL" "restarted the daemon; engine still down after ${RECOVERY_SETTLE_S}s" "$((failures + 1))" "$attempt_epoch"
    exit 1
    ;;

  running_no_wiki)
    # A DIFFERENT REPAIR. Restarting the engine here would be wrong: the
    # engine is fine. Start the container.
    if [ "$last_attempt" -gt 0 ] && [ "$since" -lt "$RECOVERY_COOLDOWN_S" ]; then
        log "wiki container down; last attempt ${since}s ago, inside cooldown. Waiting."
        write_state "running_no_wiki" "$detail" "cooling down" "$failures" "$last_attempt"
        exit 1
    fi
    log "engine is UP but the wiki container is not: ${detail}"
    attempt_epoch="$(now_epoch)"
    start_out="$("$OSTLER_ENGINE_DOCKER" start ostler-wiki-site 2>&1)"; start_rc=$?
    if [ "$start_rc" -eq 0 ]; then
        sleep 5
        if ostler_engine_state && [ "$OSTLER_ENGINE_STATE" = "up" ]; then
            log "RECOVERED: wiki container started"
            rm -f "$STATE_FILE" 2>/dev/null || true
            exit 0
        fi
    fi
    log "could not start the wiki container: ${start_out}"
    write_state "running_no_wiki" "$detail" "docker start failed: $(printf '%s' "$start_out" | head -1)" "$((failures + 1))" "$attempt_epoch"
    exit 1
    ;;

  *)
    log "CANNOT-RUN: unrecognised state '${state}'"
    write_state "unknown" "$detail" "none" "$failures" "$last_attempt"
    exit 2
    ;;
esac
