#!/bin/bash
#
# ostler-whatsapp-keepalive.sh
#
# The WhatsApp keepalive. Runs twice a day from
# com.creativemachines.ostler.whatsapp-keepalive, 10 minutes before the
# morning brief (09:00) and the evening wrap (18:00).
#
#
# WHAT THIS REPLACED, AND WHY THE OLD SHAPE COULD NEVER WORK
# ----------------------------------------------------------
# The LaunchAgent used to invoke `ostler-assistant channel doctor` directly.
# That is a job called "keepalive" that could not keep anything alive, and it
# was wrong in three independent ways at once. Each was measured in the
# ostler-assistant source, not inferred:
#
#   1. IT MEASURED AN OBJECT IT HAD JUST BUILT ITSELF, NOT THE RUNNING CHANNEL.
#      `channel doctor` is a SEPARATE, SHORT-LIVED PROCESS. It calls
#      collect_configured_channels(), which does
#      `WhatsAppWebChannel::new(...)` -- a fresh, never-connected object. Its
#      health_check() delegates to is_ready(), whose whole body is
#      `self.client.lock().is_some()`. On a freshly constructed channel that
#      field is None. The upstream repo has a test named
#      `is_ready_is_false_before_client_connects` that asserts exactly this.
#
#      So the WhatsApp arm of `channel doctor` reports UNHEALTHY on 100% of
#      runs, on every box, whatever the customer's channel is actually doing.
#      That is not a channel that keeps failing; it is a probe that cannot
#      pass. It matches the field evidence exactly: unhealthy on 3 of 3 runs
#      while whatsapp-bundle.log showed the SAME DAY's messages ingested,
#      13 chats scanned and 12 dispatched.
#
#   2. IT NEVER RECONNECTED ANYTHING. The old plist comment claimed
#      health_check "exercises the socket and triggers an automatic reconnect
#      on a stale connection. Side effect we want". There is no such side
#      effect. is_ready() is a pure read of a struct field. The keepalive
#      exercised nothing.
#
#   3. IT EXITED 0 REGARDLESS. `doctor_channels()` counts healthy / unhealthy /
#      timed-out, prints a summary line and then returns `Ok(())`
#      unconditionally. So launchctl showed `last exit code = 0` while the
#      job's own log said unhealthy every time, and nobody knew.
#
# A job that reports success while the thing it was supposed to guarantee is
# untrue is worse than no job. The name promised remediation; the code only
# diagnosed, and it diagnosed the wrong object.
#
#
# WHAT THIS DOES INSTEAD
# ----------------------
# ASK THE PROCESS THAT HOLDS THE SOCKET. The running daemon supervises each
# channel in a loop that calls the LIVE channel's health_check() and records
# the verdict in its own health registry under the key `channel:WhatsApp`.
# That registry is served, unauthenticated, on loopback at GET /health as
# `runtime.components`. It is the only surface in the product that can tell a
# live WhatsApp socket from a dead one, and reading it costs one HTTP request.
#
# Then, and only when that surface says the channel is in error, remediate:
# restart the assistant LaunchAgent, which is exactly what a person does by
# hand. Re-check afterwards. Report the outcome where a person will see it.
#
#
# WHAT THIS DELIBERATELY WILL NOT DO
# ----------------------------------
# NOTHING HERE TOUCHES THE CUSTOMER'S WHATSAPP SESSION. No re-pair, no logout,
# no deletion of the session store, no pair-code request. A linked WhatsApp
# account is a thing the customer set up on their own phone, and silently
# unlinking it to make a health probe go green would be a far worse defect
# than the one this script exists to fix.
#
# So when the channel is down BECAUSE the session is gone, this script stops.
# It does not retry, because retrying cannot work: only the customer, holding
# their phone, can re-link. It writes `needs_customer` and says so on the
# Doctor page. Saying "I need you" once is the correct behaviour; looping
# forever on something a machine cannot fix is not.
#
# The discriminator is not a guess. When wa-rs reports Event::LoggedOut the
# daemon purges the session and reconnects, which makes it request a FRESH
# pairing code and publish it to ~/.ostler/state/whatsapp_pair.json. A recent,
# unexpired pair code sitting next to an unhealthy channel means the daemon is
# waiting for the customer's phone, not for a restart.
#
#
# EXIT CODES, AND WHY "RECOVERED" IS NOT 0
# ----------------------------------------
#   0  HEALTHY          the channel was already up. Nothing was done.
#   2  RECOVERED        it was down, the restart fixed it, it is up now.
#   3  CANNOT-RUN       we could not reach a verdict. Not a pass, not a fail.
#   4  NEEDS CUSTOMER   down, and only the customer can fix it (re-link).
#   5  STILL UNHEALTHY  down, we tried, it is still down.
#
# RECOVERED is 2 and not 0 on purpose. `last exit code = 0` is the exact
# reading that hid this defect for three runs. A box quietly repairing itself
# twice a day every day is NOT the same fact as a box that never needed
# repairing, and if both print 0 then the second failure looks like the first
# success. A non-zero code makes the repair visible in `launchctl print`.
#
# CANNOT-RUN is 3 and is neither 0 nor a failure code. A check that could not
# run has not passed. This script never manufactures a clean input: if the
# daemon does not answer, if the payload will not parse, or if there is no
# interpreter to parse it with, it says so and returns 3.
#
# StartCalendarInterval jobs are one-shot fires with no KeepAlive, so a
# non-zero exit here does not throttle or respawn anything.
#
#
# Inputs, all rendered into the plist by INSTALL_SNIPPET.sh, all overridable
# in a test:
#   OSTLER_DIR                artefact root. Default ~/.ostler
#   OSTLER_GATEWAY_URL        daemon gateway base. Default http://127.0.0.1:8000
#   OSTLER_ASSISTANT_LABEL    LaunchAgent label to restart
#   OSTLER_KEEPALIVE_MAX_REPAIRS_PER_DAY   default 1
#   OSTLER_KEEPALIVE_RECHECK_SECONDS       default 90
#
# British English throughout.

set -uo pipefail

OSTLER_DIR="${OSTLER_DIR:-$HOME/.ostler}"
GATEWAY_URL="${OSTLER_GATEWAY_URL:-http://127.0.0.1:8000}"
ASSISTANT_LABEL="${OSTLER_ASSISTANT_LABEL:-com.creativemachines.ostler.assistant}"
STATE_DIR="${OSTLER_DIR}/state"
STATE_FILE="${STATE_DIR}/whatsapp_keepalive.json"
PAIR_FILE="${STATE_DIR}/whatsapp_pair.json"

# The component key the daemon's own supervisor writes. Built as
# format!("channel:{}", ch.name()) where name() is "WhatsApp".
COMPONENT_KEY="channel:WhatsApp"

# BOUNDED SO IT CANNOT LOOP OR SPAM. At most this many daemon restarts in a
# rolling 24 hours, counted from the state file this script itself writes. The
# job fires twice a day, so 1 means: try once, and if the second fire of the
# day still finds it down, report instead of restarting again. A restart that
# did not work the first time is not more likely to work the second, and a
# daemon bounced on a schedule is its own outage.
MAX_REPAIRS_PER_DAY="${OSTLER_KEEPALIVE_MAX_REPAIRS_PER_DAY:-1}"

# How long to give the daemon to come back and re-establish the socket before
# calling the repair failed. wa-rs reconnect was observed at about 60s, so 90
# leaves headroom without letting the job sit for minutes.
RECHECK_SECONDS="${OSTLER_KEEPALIVE_RECHECK_SECONDS:-90}"
RECHECK_INTERVAL_SECONDS="${OSTLER_KEEPALIVE_RECHECK_INTERVAL_SECONDS:-5}"

EXIT_HEALTHY=0
EXIT_RECOVERED=2
EXIT_CANNOT_RUN=3
EXIT_NEEDS_CUSTOMER=4
EXIT_STILL_UNHEALTHY=5

log() {
    # One line per event, timestamped. launchd points stdout at
    # ~/.ostler/logs/whatsapp-keepalive.log.
    printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die_cannot_run() {
    # A check that could not run has not passed. Say which check, say what
    # would be needed to run it, and return the CANNOT-RUN code -- never 0.
    log "CANNOT-RUN: $1"
    write_state "cannot_run" "$1" "0"
    exit "$EXIT_CANNOT_RUN"
}

# ---------------------------------------------------------------------------
# Interpreter
# ---------------------------------------------------------------------------
#
# The /health payload is nested JSON. Parsing it with sed or awk would be a
# guess dressed as a measurement, and a mis-parse here reads as "unhealthy",
# which would restart a perfectly good daemon twice a day. So: a real JSON
# parser or nothing.
#
# install.sh builds ~/.ostler/.venv and every other Ostler Python surface runs
# from it, so it is the interpreter this product actually ships. /usr/bin/python3
# is NOT a safe fallback on a Mac with no Command Line Tools: it is an Apple
# stub that prompts rather than runs (install.sh:1983 records this). So the
# stub is probed by RUNNING it, never by testing that the path exists.
resolve_python() {
    local candidate
    for candidate in \
        "${OSTLER_KEEPALIVE_PYTHON:-}" \
        "${OSTLER_DIR}/.venv/bin/python3" \
        "/usr/bin/python3"
    do
        [ -n "$candidate" ] || continue
        [ -x "$candidate" ] || continue
        # Must actually execute. An Apple CLT stub is executable and does not run.
        if "$candidate" -c 'import json,sys' >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# State file
# ---------------------------------------------------------------------------
#
# Written temp-then-rename so the Doctor can never read a half-written file.
# Lives beside whatsapp_pair.json in ~/.ostler/state, which is the engine zone
# Doctor already resolves (agent/whatsapp_pair.py:state_path).
#
# Carries NO message content, NO phone number and NO pair code. The verdict,
# the time, the repair count. Nothing a support bundle should not hold.
write_state() {
    local verdict="$1" detail="$2" repairs_today="$3"
    local tmp
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    chmod 0700 "$STATE_DIR" 2>/dev/null || true
    tmp="${STATE_FILE}.tmp.$$"
    if ! "$PYTHON_BIN" - "$tmp" "$verdict" "$detail" "$repairs_today" <<'PY'
import json, sys, time
tmp, verdict, detail, repairs = sys.argv[1:5]
payload = {
    "verdict": verdict,
    "detail": detail,
    "checked_at": int(time.time()),
    "repairs_last_24h": int(repairs),
}
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)
PY
    then
        log "WARN: could not write state file ${STATE_FILE}"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null || {
        log "WARN: could not install state file ${STATE_FILE}"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    return 0
}

# Repairs recorded in the last 24 hours, from our own previous state file.
# Prints 0 when there is no readable prior state: a first run is zero repairs,
# which is a real answer and not a manufactured one.
repairs_in_last_24h() {
    local out
    [ -f "$STATE_FILE" ] || { printf '0'; return 0; }
    out="$("$PYTHON_BIN" - "$STATE_FILE" <<'PY'
import json, sys, time
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        raise ValueError
    checked = int(d.get("checked_at", 0))
    n = int(d.get("repairs_last_24h", 0))
except Exception:
    sys.stdout.write("0")
else:
    sys.stdout.write(str(n if (time.time() - checked) < 86400 else 0))
PY
)"
    case "$out" in
        ''|*[!0-9]*) printf '0' ;;
        *)           printf '%s' "$out" ;;
    esac
}

# ---------------------------------------------------------------------------
# The oracle: the RUNNING daemon's own health registry
# ---------------------------------------------------------------------------
#
# GET /health is public by design (handle_health: "always public, no secrets
# leaked"), so this needs no credential. --noproxy '*' because a configured
# local proxy will otherwise answer for every host probed, including loopback,
# and a proxy's answer is not the daemon's answer.
#
# SETS THE GLOBAL `CHANNEL_HEALTH`. It does NOT print its answer.
#
# It used to print the verdict on stdout, which is also where log() writes, so
# the caller's `verdict="$(read_channel_health)"` swallowed the log line and
# the verdict became "<timestamp> curl rc=7 ...unreachable". That matches none
# of the cases below and fell through to the error branch, so a daemon that
# was simply not running would have been reported as a broken channel and
# restarted for it. One value channel, one log channel, and they must not be
# the same channel. Caught by running the test, not by reading the code.
#
# CHANNEL_HEALTH is set to one of:
#   ok            the component is registered and healthy
#   error:<why>   the component is registered and in error
#   absent        the daemon answered but registers no WhatsApp component
#   unreachable   the daemon did not answer
#   unparseable   the daemon answered with something that is not our payload
#
# The response body goes to a FILE and the file's path is passed as argv.
# `python3 - <<'PY'` already owns stdin (that is where the program comes from),
# so a pipe into it is silently discarded and the parser reads an empty
# program's idea of the payload. That mistake reads as "unparseable", i.e. as
# CANNOT-RUN, on a daemon that answered perfectly -- the same shape of lie this
# whole script exists to remove. Caught by running the test.
#
# curl's stderr is captured and LOGGED, never sent to /dev/null. A probe that
# throws away the one line explaining why it failed is not a probe.
CHANNEL_HEALTH=""
read_channel_health() {
    local body_file err_file rc
    body_file="${TMPDIR:-/tmp}/ostler-keepalive-health.$$"
    err_file="${body_file}.err"
    curl --noproxy '*' -sS --max-time 15 -o "$body_file" "${GATEWAY_URL}/health" 2>"$err_file"
    rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$body_file" ]; then
        if [ -s "$err_file" ]; then
            log "  curl rc=${rc}: $(tr '\n' ' ' < "$err_file")"
        else
            log "  curl rc=${rc} with an empty body and no error text"
        fi
        rm -f "$body_file" "$err_file"
        CHANNEL_HEALTH="unreachable"
        return 0
    fi
    CHANNEL_HEALTH="$("$PYTHON_BIN" - "$body_file" "$COMPONENT_KEY" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    components = doc["runtime"]["components"]
    if not isinstance(components, dict):
        raise ValueError("components is not an object")
except Exception:
    sys.stdout.write("unparseable")
    sys.exit(0)
entry = components.get(key)
if not isinstance(entry, dict):
    sys.stdout.write("absent")
    sys.exit(0)
status = str(entry.get("status", "")).strip()
if status == "ok":
    sys.stdout.write("ok")
else:
    reason = str(entry.get("last_error") or status or "no reason recorded")
    # One line, no newlines, bounded -- it goes into a log and a state file.
    reason = " ".join(reason.split())[:200]
    sys.stdout.write("error:" + reason)
PY
)"
    rc=$?
    rm -f "$body_file" "$err_file"
    if [ "$rc" -ne 0 ] || [ -z "$CHANNEL_HEALTH" ]; then
        CHANNEL_HEALTH="unparseable"
    fi
    return 0
}

# Is the daemon waiting for the customer's phone rather than for a restart?
#
# TRUE only when a pair code exists and has NOT expired. The daemon publishes
# one after wa-rs reports Event::LoggedOut and it purges the session, so an
# unexpired code next to an unhealthy channel means the link is gone and the
# customer has to re-scan. Restarting cannot help and would churn the code.
#
# expires_at is the writer's MEASURED value, bound to WhatsApp's own validity.
# No TTL policy is applied here on top of it.
pair_code_is_pending() {
    [ -f "$PAIR_FILE" ] || return 1
    # Exit status only. NOTHING from the pairing file is read into a variable,
    # logged or written to the state file: it holds a live pair code, which is
    # credential-equivalent while it lives.
    "$PYTHON_BIN" - "$PAIR_FILE" <<'PY' >/dev/null
import json, sys, time
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
    expires = int(d["expires_at"])
except Exception:
    # An unreadable pairing file is not evidence that a re-link is pending.
    sys.exit(1)
sys.exit(0 if expires > int(time.time()) else 1)
PY
}

# ---------------------------------------------------------------------------
# The remediation
# ---------------------------------------------------------------------------
#
# `launchctl kickstart -k` stops the running assistant and starts it again in
# one call. That is precisely the manual fix, and it is the whole of it: the
# daemon reloads its config, re-reads the EXISTING WhatsApp session store and
# re-establishes the socket. The session is not touched, so the customer's
# linked device survives the restart.
restart_assistant() {
    local domain
    domain="gui/$(id -u)"
    log "repair: restarting ${ASSISTANT_LABEL} (the WhatsApp session store is NOT touched)"
    if launchctl kickstart -k "${domain}/${ASSISTANT_LABEL}" 2>&1 | sed 's/^/    launchctl: /'; then
        return 0
    fi
    return 1
}

# Poll the live health surface until it goes ok or we run out of patience.
wait_for_healthy() {
    local deadline elapsed=0 verdict
    deadline="$RECHECK_SECONDS"
    while [ "$elapsed" -lt "$deadline" ]; do
        sleep "$RECHECK_INTERVAL_SECONDS"
        elapsed=$(( elapsed + RECHECK_INTERVAL_SECONDS ))
        read_channel_health
        verdict="$CHANNEL_HEALTH"
        case "$verdict" in
            ok)
                log "recheck at ${elapsed}s: healthy"
                return 0
                ;;
            unreachable)
                log "recheck at ${elapsed}s: daemon not answering yet"
                ;;
            *)
                log "recheck at ${elapsed}s: ${verdict}"
                ;;
        esac
    done
    return 1
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

PYTHON_BIN="$(resolve_python || true)"
if [ -z "$PYTHON_BIN" ]; then
    # No write_state here: write_state needs the interpreter we do not have.
    log "CANNOT-RUN: no working Python 3 found. Looked at \$OSTLER_KEEPALIVE_PYTHON, ${OSTLER_DIR}/.venv/bin/python3 and /usr/bin/python3, running each rather than testing for its presence. To measure this, install the Ostler venv (install.sh builds it) or set OSTLER_KEEPALIVE_PYTHON to a real interpreter."
    exit "$EXIT_CANNOT_RUN"
fi

log "keepalive: asking the running daemon at ${GATEWAY_URL}/health about ${COMPONENT_KEY}"

read_channel_health
HEALTH="$CHANNEL_HEALTH"
REPAIRS="$(repairs_in_last_24h)"

case "$HEALTH" in
    ok)
        log "HEALTHY: ${COMPONENT_KEY} is ok in the running daemon's registry"
        write_state "healthy" "The WhatsApp channel is connected." "$REPAIRS"
        exit "$EXIT_HEALTHY"
        ;;
    unreachable)
        die_cannot_run "the assistant daemon did not answer ${GATEWAY_URL}/health, so the WhatsApp channel's state is unknown. To measure it, start the Ostler assistant and re-run. This is NOT a report that WhatsApp is down."
        ;;
    unparseable)
        die_cannot_run "${GATEWAY_URL}/health answered with a payload that has no runtime.components object, so no verdict could be reached."
        ;;
    absent)
        # The daemon is up and registers no WhatsApp component at all. That is
        # not "unhealthy": it is what a box with the channel switched off looks
        # like, and also what a daemon that has not finished starting its
        # channels looks like. Restarting either one would be wrong.
        die_cannot_run "the daemon is running but registers no ${COMPONENT_KEY} component. Either the WhatsApp channel is not enabled on this install, or the daemon has not finished starting its channels. Nothing was restarted."
        ;;
esac

# From here the daemon is up, it registers the component, and it says error.
REASON="${HEALTH#error:}"
log "UNHEALTHY: ${COMPONENT_KEY} is in error. Daemon's own reason: ${REASON}"

if pair_code_is_pending; then
    # Do not retry. Only the customer can finish this.
    log "NEEDS CUSTOMER: an unexpired WhatsApp pairing code is waiting, which means the link to their phone is gone and the daemon is asking to be re-linked. A restart cannot fix that and would churn the code, so nothing was restarted."
    write_state "needs_customer" \
        "WhatsApp is not linked. Ostler is waiting for you to link it again from your phone." \
        "$REPAIRS"
    exit "$EXIT_NEEDS_CUSTOMER"
fi

if [ "$REPAIRS" -ge "$MAX_REPAIRS_PER_DAY" ]; then
    log "STILL UNHEALTHY: ${REPAIRS} repair(s) already attempted in the last 24h, cap is ${MAX_REPAIRS_PER_DAY}. Not restarting again."
    write_state "still_unhealthy" \
        "WhatsApp is not connected. Ostler restarted itself to try to fix it and that did not work." \
        "$REPAIRS"
    exit "$EXIT_STILL_UNHEALTHY"
fi

REPAIRS=$(( REPAIRS + 1 ))

if ! restart_assistant; then
    log "STILL UNHEALTHY: the restart of ${ASSISTANT_LABEL} did not succeed."
    write_state "still_unhealthy" \
        "WhatsApp is not connected, and Ostler could not restart itself to try to fix it." \
        "$REPAIRS"
    exit "$EXIT_STILL_UNHEALTHY"
fi

if wait_for_healthy; then
    log "RECOVERED: ${COMPONENT_KEY} came back after the restart"
    write_state "recovered" \
        "WhatsApp dropped out and Ostler reconnected it for you." \
        "$REPAIRS"
    exit "$EXIT_RECOVERED"
fi

log "STILL UNHEALTHY: ${COMPONENT_KEY} did not come back within ${RECHECK_SECONDS}s of the restart"
write_state "still_unhealthy" \
    "WhatsApp is not connected. Ostler restarted itself to try to fix it and that did not work." \
    "$REPAIRS"
exit "$EXIT_STILL_UNHEALTHY"
