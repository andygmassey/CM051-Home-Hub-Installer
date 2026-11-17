#!/usr/bin/env bash
# scripts/box_walk_probes/probes/tool_call_log_line_per_call.sh
#
# Does the shipped daemon log ONE tool_call line per tool call, carrying only
# tool, outcome and duration_ms (ostler-assistant #749)? Before #749 a tool's
# outcome and time were visible only inside the turn summary, and nothing
# showed which call failed.
#
# READ-ONLY. Run it AFTER the chat probes (it sorts after the assistant_* and
# chat_* probes), so the window holds real turns. The collector
# (lib/tool_call_log.py) runs on the box against ~/.ostler/logs/ostler-assistant.err
# and prints counts and key NAMES only; no tool_call field value leaves the box.
#
# DENOMINATOR: the sum of tool_calls=<n> over the turn_latency "assistant turn
# settled" lines in the same window (the daemon's own count of calls made).
# OSTLER_TOOLCALL_SINCE (ISO-8601 UTC, optional) limits the window, so an
# upgraded box does not count turns from an older daemon. On a cold box the
# whole log is the 134 install.
#
#   PASS        lines >= calls, and every line is exactly tool/outcome/duration_ms
#   FAIL        calls made and fewer (or no) lines; or any line with another field
#   CANNOT-RUN  no settled turn, no tool call in the window, log unreadable, transport
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="tool_call_log_line_per_call"
PROBE_QUESTION="for every tool call the daemon made (turn_latency tool_calls), is there one tool_call log line with exactly tool, outcome and duration_ms?"

_LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/tool_call_log.py"

self_test() {
    python3 "${_LIB}" --self-test >/dev/null 2>&1 || {
        printf 'VERDICT: BROKEN -- %s self-test: a collector/judge case landed on the wrong verdict (run lib/tool_call_log.py --self-test)\n' "${PROBE_NAME}"
        exit 2
    }
    # Known-bad, end to end through the same collect + judge the box run uses:
    # a pre-#749 log (turns that called tools, no tool_call line).
    local d why rc; d="$(mktemp -d)"
    printf '2026-11-18T01:00:00.1Z  INFO turn_latency: assistant turn settled turn_id=a outcome=ok total_ms=9 tool_calls=2 tools=pwg_topics:3:ok,pwg_decisions:1:ok\n' > "${d}/err"
    python3 "${_LIB}" collect "${d}/err" > "${d}/cap"
    probe_examined 1 "known-bad log (2 tool calls, 0 tool_call lines)"
    why="$(python3 "${_LIB}" judge "${d}/cap")"; rc=$?
    rm -rf "${d}"
    [ "${rc}" -eq 1 ] || {
        printf 'VERDICT: BROKEN -- %s self-test: the pre-#749 log came back rc=%s, not FAIL\n' "${PROBE_NAME}" "${rc}"
        exit 2
    }
    probe_fail "negative control behaved: ${why}; and every collector/judge case landed on its own verdict"
}

run_probe() {
    if [ -n "${OSTLER_TOOLCALL_SINCE:-}" ]; then
        [[ "${OSTLER_TOOLCALL_SINCE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]] \
            || probe_cannot_run "OSTLER_TOOLCALL_SINCE is not an ISO-8601 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ)"
    fi
    box_reachable || probe_cannot_run "cannot reach the box; nothing was read"
    local src cap why rc
    src="$(cat "${_LIB}")" || probe_cannot_run "cannot read ${_LIB}"
    cap="$(mktemp)"
    box_run "/usr/bin/python3 - collect \"\$HOME/.ostler/logs/ostler-assistant.err\" ${OSTLER_TOOLCALL_SINCE:-} <<'OSTLER_TOOLCALL_PY'
${src}
OSTLER_TOOLCALL_PY" > "${cap}" \
        || { rm -f "${cap}"; probe_cannot_run "the box collector failed; nothing was judged"; }
    why="$(python3 "${_LIB}" judge "${cap}")"; rc=$?
    probe_examined "$(sed -n 's/^TL_TOOL_CALLS=//p' "${cap}" | head -1)" "tool calls (turn_latency) against $(sed -n 's/^TC_LINES=//p' "${cap}" | head -1) tool_call lines"
    rm -f "${cap}"
    case "${rc}" in
        0) probe_pass "${why}" ;;
        1) probe_fail_or_advisory "${why}" ;;
        *) probe_cannot_run "${why}" ;;
    esac
}

probe_main "$@"
