#!/usr/bin/env bash
# probes/listener_watchdog_recovers_a_wedged_listener.sh
# ============================================================================
# QUESTION: when the daemon's :8443 listener dies while its process stays
#           alive, does com.ostler.listener-watchdog capture diagnostics,
#           restart the daemon, and bring :8443 back?
#
# THE INCIDENT (Andy's box, 2026-10-17). com.creativemachines.ostler.assistant
# was alive at 0% CPU for 4 h with :8443 dead. launchd saw a running process,
# so KeepAlive never fired, and the iPhone app showed "Hub unreachable" until a
# manual `launchctl kickstart -k`. This probe reproduces that state exactly:
# SIGSTOP on the daemon pid. The kernel still accepts the TCP connection, the
# process never answers, and launchd still reads it as running.
#
# THE BUDGET IS DERIVED, NEVER A NUMBER. v1.0.116c: the watchdog recovered, but
# at 307 s, and a fixed 300 s window had already expired (FAIL on a working
# watchdog). The wait is now computed from the config the product ships:
#   interval x strikes x 3/2   (StartInterval from the installed plist; 3/2 is
#                               the strike drift seen under load, 74-82 s on 60)
# + strikes x curl --max-time  (each strike's own probe)
# + the capture cap            (ostler-listener-watchdog --print-config)
# + the post-restart verify window + a margin (default 30 s).
# OSTLER_LWR_BUDGET_S overrides it for tests only. If the config cannot be
# read the probe is CANNOT-RUN, never a fallback number.
#
# PASS needs ALL of, within that budget:
#   - :8443 answers HTTP 401 again (an unauthenticated GET /api/sessions)
#   - the watchdog's state file records a restart at or after the SIGSTOP
#   - a capture dir from this run holds a non-empty sample.txt and lsof.txt
#   - the daemon pid changed (it was restarted, not merely resumed)
#
# The watchdog ABSENT (no script, or its LaunchAgent not loaded) is FAIL, not
# CANNOT-RUN: an install that should carry it and does not is the defect.
#
# THE BOX IS NEVER LEFT WITH A STOPPED DAEMON. Four layers, because a stopped
# daemon is a dead Hub: (1) the on-box script's EXIT/INT/TERM/HUP trap sends
# SIGCONT; (2) a nohup'd sleeper on the box sends SIGCONT after budget + 30 s
# even if the ssh session and the script are killed outright; (3) this
# driver's own EXIT/INT/TERM trap sends SIGCONT over a fresh box_run; (4) the
# on-box wait runs in the background and this driver `wait`s on it, so a
# signal to the probe runs the trap at once instead of after the ssh returns.
#
# WALK_WRITES: SIGSTOPs the daemon and lets the listener watchdog kickstart it.
# Refused (CANNOT-RUN) on a --read-only walk.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="listener_watchdog_recovers_a_wedged_listener"
PROBE_QUESTION="with the daemon SIGSTOPped (process alive, :8443 silent, the 2026-10-17 incident), does the listener watchdog capture sample/lsof, restart the daemon and bring :8443 back to 401 within the budget derived from its shipped config?"

LWR_LABEL="${OSTLER_DAEMON_LABEL:-com.creativemachines.ostler.assistant}"
LWR_WD_LABEL="${OSTLER_LISTENER_WD_AGENT_LABEL:-com.ostler.listener-watchdog}"
LWR_LAUNCHCTL="${OSTLER_PROBE_LAUNCHCTL:-/bin/launchctl}"
LWR_URL="${OSTLER_LWR_URL:-https://127.0.0.1:${OSTLER_COMPANION_PORT:-8443}/api/sessions}"
LWR_BUDGET_S="${OSTLER_LWR_BUDGET_S:-}"
LWR_MARGIN_S="${OSTLER_LWR_MARGIN_S:-30}"
LWR_PLIST="${OSTLER_LWR_PLIST:-\$HOME/Library/LaunchAgents/${LWR_WD_LABEL}.plist}"
LWR_POLL_S="${OSTLER_LWR_POLL_S:-10}"
LWR_PID=""
LWR_BG=""

# _lwr_classify <present> <pre_http> <stopped> <post_http> <restart_recorded> <capture_ok> <pid_changed>
# THE ONE DECISION FUNCTION: run_probe adjudicates through it and self_test
# drives it with synthetic readings, so a mutation here breaks both.
_lwr_classify() {
    local present="$1" pre="$2" stopped="$3" post="$4" restarted="$5" cap="$6" newpid="$7"
    if [ "$present" != 1 ]; then echo FAIL-ABSENT; return; fi
    case "$pre" in 000|"") echo CANNOT-RUN-NOT-UP; return ;; esac
    if [ "$stopped" != 1 ]; then echo CANNOT-RUN-NO-STOP; return; fi
    if [ "$restarted" != 1 ]; then echo FAIL-NO-RESTART; return; fi
    if [ "$post" != 401 ]; then echo FAIL-NOT-BACK; return; fi
    if [ "$cap" != 1 ]; then echo FAIL-NO-CAPTURE; return; fi
    if [ "$newpid" != 1 ]; then echo FAIL-NOT-RESTARTED; return; fi
    echo PASS
}

# _lwr_budget <interval> <strikes> <curl_max> <capture_cap> <verify> <margin>
# THE ONE BUDGET FUNCTION: run_probe and self_test both call it. Prints seconds.
_lwr_budget() {
    echo $(( ($1 * $2 * 3 + 1) / 2 + $2 * $3 + $4 + $5 + $6 ))
}

# Reads the shipped config off the box and prints the budget; rc 1 and a reason
# on stderr when any input is missing or not a number.
_lwr_derive_budget() {
    local cfg interval fail_n max_s cap verify
    cfg="$(box_run "\$HOME/.ostler/bin/ostler-listener-watchdog --print-config")"
    interval="$(box_run "sed -n '/<key>StartInterval<\\/key>/{n;s/.*<integer>\\([0-9][0-9]*\\)<.*/\\1/p;}' \"${LWR_PLIST}\"" | head -1)"
    fail_n="$(kv "$cfg" fail_n)"; max_s="$(kv "$cfg" max_s)"; cap="$(kv "$cfg" capture_max_s)"; verify="$(kv "$cfg" verify_s)"
    local v
    for v in "$interval" "$fail_n" "$max_s" "$cap" "$verify"; do
        case "$v" in ''|*[!0-9]*) echo "could not read the watchdog config (interval='${interval}' fail_n='${fail_n}' max_s='${max_s}' capture_max_s='${cap}' verify_s='${verify}')" >&2; return 1 ;; esac
    done
    _lwr_budget "$interval" "$fail_n" "$max_s" "$cap" "$verify" "$LWR_MARGIN_S"
    echo "interval ${interval}s x ${fail_n} strikes x 1.5 drift + ${fail_n} x ${max_s}s curl + ${cap}s capture cap + ${verify}s verify + ${LWR_MARGIN_S}s margin"
}

_lwr_cont() {
    if [ -n "$LWR_BG" ]; then kill "$LWR_BG" 2>/dev/null; fi
    if [ -n "$LWR_PID" ]; then box_run "kill -CONT ${LWR_PID} 2>/dev/null; true" >/dev/null 2>&1; fi
}

# The on-box half. Prints key=value lines. Args: pid launchctl label wd_label url budget poll
_lwr_box_script() {
cat <<'BOXEOF'
set -u
PID="$1"; LC="$2"; LABEL="$3"; URL="$5"; BUDGET="$6"; POLL="$7"
O="$HOME/.ostler"; SF="$O/state/listener_watchdog.json"
code() { c="$(curl -sk --noproxy '*' --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null)"; echo "${c:-000}"; }
to_epoch() { date -j -u -f "$2" "$1" +%s 2>/dev/null || date -u -d "$(printf '%s' "$1" | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$/\1-\2-\3T\4:\5:\6Z/')" +%s 2>/dev/null; }
field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$SF" 2>/dev/null | head -1; }
t0="$(date +%s)"; echo "t0=${t0}"
nohup /bin/bash -c "sleep $((BUDGET + 30)); kill -CONT ${PID}" >/dev/null 2>&1 </dev/null &
SLEEPER=$!
trap 'kill -CONT "$PID" 2>/dev/null; kill "$SLEEPER" 2>/dev/null' EXIT
trap 'exit 130' INT TERM HUP
if kill -STOP "$PID" 2>/dev/null; then echo "stopped=1"; else echo "stopped=0"; exit 0; fi
waited=0; restarted=0
while [ "$waited" -lt "$BUDGET" ]; do
    sleep "$POLL"; waited=$((waited + POLL))
    la="$(field last_restart_at)"
    le=""; [ -n "$la" ] && le="$(to_epoch "$la" '%Y-%m-%dT%H:%M:%SZ')"
    if [ -n "$le" ] && [ "$le" -ge "$t0" ]; then
        restarted=1
        [ "$(code)" != 000 ] && break
    fi
done
echo "waited=${waited}"; echo "restarted=${restarted}"
echo "post_http=$(code)"
echo "state=$(field state)"
echo "last_restart_at=$(field last_restart_at)"
cap="$(field last_capture)"; echo "capture=${cap}"
capok=0
if [ -n "$cap" ] && [ -s "$cap/sample.txt" ] && [ -s "$cap/lsof.txt" ]; then
    ce="$(to_epoch "$(basename "$cap")" '%Y%m%dT%H%M%SZ')"
    [ -n "$ce" ] && [ "$ce" -ge "$t0" ] && capok=1
fi
echo "capture_ok=${capok}"
np="$("$LC" print "gui/$(id -u)/${LABEL}" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -1)"
echo "new_pid=${np}"
BOXEOF
}

kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; nothing inspected"
    fi
    if [ "${OSTLER_WALK_READ_ONLY:-0}" = 1 ]; then
        probe_cannot_run "read-only walk: this probe has to SIGSTOP the daemon and let the watchdog restart it, which is a write. Nothing measured."
    fi
    local present=0 pre pid
    if box_run "[ -x \"\$HOME/.ostler/bin/ostler-listener-watchdog\" ] && ${LWR_LAUNCHCTL} print gui/\$(id -u)/${LWR_WD_LABEL} >/dev/null 2>&1" ; then
        present=1
    fi
    probe_note "watchdog script + ${LWR_WD_LABEL} loaded : ${present}"
    if [ "$present" != 1 ]; then
        probe_examined 1 "listener watchdog installations looked for"
        probe_fail "the listener watchdog is ABSENT: ~/.ostler/bin/ostler-listener-watchdog missing or ${LWR_WD_LABEL} not loaded. Nothing would recover a daemon whose :8443 listener dies while the process lives (the 2026-10-17 incident). Daemon not touched."
    fi
    if box_run "[ -e \"\$HOME/.ostler/deliberate-stop\" ]"; then
        probe_cannot_run "the deliberate-stop marker is present, so the watchdog is correctly standing down; recovery cannot be exercised. Daemon not touched."
    fi
    pre="$(box_run "curl -sk --noproxy '*' --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' '${LWR_URL}' 2>/dev/null")"
    pre="${pre:-000}"
    pid="$(box_run "${LWR_LAUNCHCTL} print gui/\$(id -u)/${LWR_LABEL} 2>/dev/null | sed -n 's/^[[:space:]]*pid = \\([0-9][0-9]*\\).*/\\1/p' | head -1")"
    probe_note "before: ${LWR_URL} -> HTTP ${pre}; daemon pid ${pid:-none}"
    if [ "$pre" = 000 ] || [ -z "$pid" ]; then
        probe_examined 0 "wedge-and-recover cycles (the listener was not up to begin with)"
        probe_cannot_run "the listener was not answering (HTTP ${pre}) or the daemon has no pid (${pid:-none}) BEFORE the probe touched anything, so recovery from a wedge cannot be told apart from a box that was already down. Daemon not touched."
    fi
    case "$pid" in *[!0-9]*) probe_cannot_run "unparseable daemon pid '${pid}'" ;; esac

    if [ -z "$LWR_BUDGET_S" ]; then
        local why derived whyf
        whyf="$(mktemp "${TMPDIR:-/tmp}/lwr.why.XXXXXX")"
        if ! derived="$(_lwr_derive_budget 2>"$whyf")"; then
            why="$(cat "$whyf")"; rm -f "$whyf"
            probe_cannot_run "${why}; no wait budget can be derived, so recovery was not exercised. Daemon not touched."
        fi
        rm -f "$whyf"
        LWR_BUDGET_S="$(printf '%s\n' "$derived" | sed -n 1p)"
        probe_note "wait budget ${LWR_BUDGET_S}s = $(printf '%s\n' "$derived" | sed -n 2p)"
    else
        probe_note "wait budget ${LWR_BUDGET_S}s (OSTLER_LWR_BUDGET_S override)"
    fi
    LWR_PID="$pid"
    trap '_lwr_cont' EXIT
    trap '_lwr_cont; exit 130' INT TERM HUP
    local script out
    script="$(_lwr_box_script)"
    out="$(mktemp "${TMPDIR:-/tmp}/lwr.XXXXXX")"
    probe_note "SIGSTOP daemon pid ${pid}; waiting up to ${LWR_BUDGET_S}s for the watchdog"
    box_run "/bin/bash -c $(printf '%q' "$script") lwr ${pid} ${LWR_LAUNCHCTL} ${LWR_LABEL} ${LWR_WD_LABEL} '${LWR_URL}' ${LWR_BUDGET_S} ${LWR_POLL_S}" > "$out" &
    LWR_BG=$!
    wait "$LWR_BG"
    LWR_BG=""
    local r; r="$(cat "$out")"; rm -f "$out"
    _lwr_cont

    local stopped post restarted capok newpid changed=0
    stopped="$(kv "$r" stopped)"; post="$(kv "$r" post_http)"; restarted="$(kv "$r" restarted)"
    capok="$(kv "$r" capture_ok)"; newpid="$(kv "$r" new_pid)"
    [ -n "$newpid" ] && [ "$newpid" != "$pid" ] && changed=1
    probe_note "after $(kv "$r" waited)s: HTTP ${post:-none}; watchdog state $(kv "$r" state); last_restart_at $(kv "$r" last_restart_at)"
    probe_note "capture $(kv "$r" capture) (sample+lsof, newer than the SIGSTOP: ${capok:-0}); daemon pid ${pid} -> ${newpid:-none}"
    probe_examined 1 "wedge-and-recover cycle (SIGSTOP of daemon pid ${pid})"

    case "$(_lwr_classify "$present" "$pre" "${stopped:-0}" "${post:-000}" "${restarted:-0}" "${capok:-0}" "$changed")" in
        PASS) probe_pass "the watchdog captured sample+lsof at $(kv "$r" capture), restarted the daemon (pid ${pid} -> ${newpid}) and :8443 answers 401 again" ;;
        CANNOT-RUN-NO-STOP) probe_cannot_run "could not SIGSTOP daemon pid ${pid}; the incident was not reproduced" ;;
        FAIL-NO-RESTART) probe_fail "the daemon sat SIGSTOPped for ${LWR_BUDGET_S}s and the watchdog recorded NO restart (state '$(kv "$r" state)'). This is the 2026-10-17 incident, unrecovered." ;;
        FAIL-NOT-BACK) probe_fail "the watchdog restarted the daemon but :8443 answered HTTP ${post:-000}, not 401" ;;
        FAIL-NO-CAPTURE) probe_fail "the daemon was restarted but no capture from this run holds sample.txt and lsof.txt ($(kv "$r" capture)); root cause would be lost" ;;
        FAIL-NOT-RESTARTED) probe_fail ":8443 answers again but the daemon pid did not change (${pid} -> ${newpid:-none}); it was resumed, not restarted" ;;
        *) probe_fail "unclassified reading: $(printf '%s' "$r" | tr '\n' ' ')" ;;
    esac
}

self_test() {
    SELF_TEST_LOCAL=1
    probe_examined 9 "synthetic reading sets (negative control)"
    [ "$(_lwr_classify 1 401 1 401 1 1 1)" = PASS ] || probe_pass "NEGATIVE CONTROL OVER-FIRED: a full recovery adjudicated as $(_lwr_classify 1 401 1 401 1 1 1)"
    [ "$(_lwr_classify 0 401 1 401 1 1 1)" = FAIL-ABSENT ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: an absent watchdog adjudicated as $(_lwr_classify 0 401 1 401 1 1 1), must be FAIL not CANNOT-RUN"
    [ "$(_lwr_classify 1 000 1 401 1 1 1)" = CANNOT-RUN-NOT-UP ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: a listener already down adjudicated as $(_lwr_classify 1 000 1 401 1 1 1)"
    [ "$(_lwr_classify 1 401 0 401 1 1 1)" = CANNOT-RUN-NO-STOP ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: a failed SIGSTOP adjudicated as $(_lwr_classify 1 401 0 401 1 1 1)"
    [ "$(_lwr_classify 1 401 1 000 0 0 0)" = FAIL-NO-RESTART ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: no restart adjudicated as $(_lwr_classify 1 401 1 000 0 0 0)"
    [ "$(_lwr_classify 1 401 1 000 1 1 1)" = FAIL-NOT-BACK ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: a restart that never answered adjudicated as $(_lwr_classify 1 401 1 000 1 1 1)"
    [ "$(_lwr_classify 1 401 1 200 1 1 1)" = FAIL-NOT-BACK ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: HTTP 200 (auth off) adjudicated as $(_lwr_classify 1 401 1 200 1 1 1), must not pass"
    [ "$(_lwr_classify 1 401 1 401 1 0 1)" = FAIL-NO-CAPTURE ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: a restart with no capture adjudicated as $(_lwr_classify 1 401 1 401 1 0 1)"
    [ "$(_lwr_classify 1 401 1 401 1 1 0)" = FAIL-NOT-RESTARTED ] || probe_pass "NEGATIVE CONTROL DID NOT FIRE: an unchanged pid adjudicated as $(_lwr_classify 1 401 1 401 1 1 0)"
    probe_fail "negative control behaved correctly on all 9 reading sets (full recovery passes; absent watchdog FAILs; no restart, no 401, no capture and an unchanged pid all fail; a listener already down and a failed SIGSTOP are CANNOT-RUN)"
}

probe_main "$@"
