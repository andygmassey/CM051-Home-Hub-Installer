#!/usr/bin/env bash
# no_python_is_tcc_responsible -- since this install started, was the bundled
# python (~/.ostler/python, ~/.ostler/.venv) ever the RESPONSIBLE process for a
# TCC request? (NEW-119, diag118 Mini16 on macOS 27.2, 2026-10-29)
#
# Every scheduled job that reads Full Disk Access data must run as a child of
# the FDA holder (`ostler-assistant run-source <src>`), so TCC charges the
# request to ai.ostler.assistant. A job that launchd starts as bare python is
# its own responsible process, has no grant, and is DENIED silently: studio29
# (2026-10-15) proved that shape for ical-server's reply-debt read of chat.db.
#
# WHY THE LOG AND NOT TCC.db. The system TCC.db keeps Ostler rows across a
# "cold" reset (diag118: a python3.11 row from 2026-09-14 on a box re-colded
# on 2026-10-28), and last_modified does not refresh on use. A row proves its
# age, never the absence of a later request. The unified log over the install
# window is the only surface that answers this.
#
#   PASS        0 python-responsible requests AND the control is > 0
#   FAIL        >= 1 request with the bundled python responsible
#   CANNOT-RUN  the install start is not recorded, `log show` failed or
#               returned no AUTHREQ line, OR the control is 0
#
# THE CONTROL: requests where ai.ostler.assistant is responsible and a python
# child is accessing (diag118 counted 5). 0 means the predicate never saw the
# shape it judges, so a 0 python count proves nothing: CANNOT-RUN, never PASS.
# fda_rerun_second_tick_lands_a_new_row sorts first and kickstarts the re-run,
# which makes the control on a healthy walk.
#
# /usr/bin/log by absolute path: zsh's `log` builtin shadows it.
#
# WALK_READ_ONLY: reads ~/.ostler/.install-harness and the unified log.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="no_python_is_tcc_responsible"
PROBE_QUESTION="since this install started, was the bundled python ever the RESPONSIBLE process for a TCC request? Control: requests charged to ai.ostler.assistant for a python child; 0 of those is CANNOT-RUN."

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
JUDGE="${_HERE}/lib/fda_refresh_tcc.py"
LOG_BIN="${OSTLER_PROBE_LOG_BIN:-/usr/bin/log}"

self_test() {
    if python3 "$JUDGE" --self-test >/dev/null; then
        probe_examined 20 "TCC and second-tick judge fixtures"
        probe_fail "negative control behaved: python responsible with and without a responsible block is FAIL, sshd-responsible python and DeveloperTool preflights are not counted, and 0 daemon-attributed requests is CANNOT-RUN, never PASS"
    fi
    probe_examined 20 "TCC and second-tick judge fixtures"
    probe_pass "SELF-TEST BROKEN: the judge let a known-bad fixture through (run lib/fda_refresh_tcc.py --self-test)"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; no TCC request was examined"

    local start raw work out rc n reason
    start="$(box_run 'f="$HOME/.ostler/.install-harness"; [ -r "$f" ] && awk "NR==1{print \$2}" "$f"' | tr -d '\r\n ')"
    case "$start" in
        ''|*[!0-9]*) probe_cannot_run "~/.ostler/.install-harness carries no install start (got '${start}'); ttywalk writes it as the install begins, so the install window is unknown and nothing was examined" ;;
    esac
    probe_note "install window: from epoch ${start} (box clock, ~/.ostler/.install-harness) to now"

    work="$(mktemp -d)"
    box_run "S=\"\$(date -r ${start} '+%Y-%m-%d %H:%M:%S')\" || exit 0
\"${LOG_BIN}\" show --style compact --start \"\$S\" --predicate 'subsystem == \"com.apple.TCC\" AND eventMessage BEGINSWITH \"AUTHREQ_\"'
echo \"__LOGRC=\$?\"" > "${work}/log.txt"
    if ! /usr/bin/grep -q '^__LOGRC=0$' "${work}/log.txt"; then
        raw="$(/usr/bin/grep '^__LOGRC=' "${work}/log.txt" | tail -1)"
        rm -rf "$work"
        probe_cannot_run "${LOG_BIN} show did not complete (${raw:-no exit code came back}); nothing was examined"
    fi

    out="$(python3 "$JUDGE" tcc "${work}/log.txt")"; rc=$?
    rm -rf "$work"
    printf '%s\n' "$out" | /usr/bin/grep -v '^EXAMINED_N=\|^REASON='
    n="$(printf '%s\n' "$out" | sed -n 's/^EXAMINED_N=//p')"
    reason="$(printf '%s\n' "$out" | sed -n 's/^REASON=//p')"
    probe_examined "${n:-0}" "TCC attribution(s) in the install window"
    case "$rc" in
        0)  probe_pass "$reason" ;;
        78) probe_cannot_run "$reason" ;;
        1)  probe_fail_or_advisory "$reason" ;;
        *)  probe_cannot_run "the TCC judge crashed (rc=${rc}); nothing adjudicated" ;;
    esac
}

probe_main "$@"
