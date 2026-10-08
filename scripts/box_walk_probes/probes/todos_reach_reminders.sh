#!/usr/bin/env bash
# todos_reach_reminders -- a conversation with a synthetic commitment
# produces a todo, and it lands in Apple Reminders. (v1.0.107, FLOW_CENSUS
# gap #6: "has no coverage at all")
#
# CM048's reminders_push.py owns the decision + state machine; the actual
# EventKit call lives in the closed-source ostler-assistant binary, reading
# the SAME ~/.ostler/reminders_map.db this probe writes to through the real
# shipped function (apply_push_status_to_todos). So this probe tests the
# WHOLE seam: write through the gate, wait for the installed daemon to claim
# the row, then try to read the result back from Reminders.app itself --
# never trusting the mapping table's "pushed" status alone.
#
# A read of Reminders.app from an ssh session needs the Automation TCC grant
# AppleScript needs to send Apple events to Reminders.app, the same class of
# gap ttywalk.sh already documents and shims for the iMessage Automation
# probe. When osascript is refused for that reason (-1743 / "not authorized
# to send Apple events"), the read-back arm is CANNOT-RUN and this probe is
# added to console_only_probes.tsv so an ssh walk's CANNOT-RUN here is not
# read as coverage lost. It is never reported PASS on the mapping table's
# word alone.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="todos_reach_reminders"
PROBE_QUESTION="does a synthetic commitment, run through the shipped writer and gate, land a pending row the installed daemon claims, and does the resulting reminder actually become visible in Reminders.app?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/todo_reminders_probe.py" --self-test; then
        probe_examined 4 "mutated todo-reminders facts"
        probe_fail "negative control behaved: a failed write, a row never claimed, a permission_denied daemon, a TCC-blocked read and a pushed-but-invisible reminder were each caught by their own assertion"
    fi
    probe_examined 4 "mutated todo-reminders facts"
    probe_pass "SELF-TEST BROKEN: the todo-reminders judge let a known-bad fixture through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; no commitment was ever written"
    local remote venv_py token text facts out rc n
    token="ostler-walk-todo-$$-$(date +%s 2>/dev/null || echo 0)"
    text="SYNTHETIC WALK PROBE ${token}: email Jane Doe about the Fictionville report by Friday"
    remote="/tmp/ostler-probe-todoreminders-$$.py"
    box_run "printf %s '$(base64 < "${_HERE}/lib/todo_reminders_box.py" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the todo-reminders box script on the box"

    # pwg-convo's own venv interpreter, read off its shebang, is the one that
    # has the shipped CM048 package (src.conversation_writer, src.reminders_push)
    # importable -- a bare system python3 does not.
    venv_py="$(box_run "CLI=\${OSTLER_CONVO_SEED_CLI:-/usr/local/bin/pwg-convo}; [ -e \"\$CLI\" ] && head -1 \"\$CLI\" | sed -n 's/^#!//p'")"
    if [ -z "${venv_py}" ] || ! box_run "[ -x '${venv_py}' ]"; then
        box_run "rm -f ${remote}" >/dev/null 2>&1
        probe_cannot_run "could not resolve the pwg-convo venv interpreter (no /usr/local/bin/pwg-convo, or its shebang does not point at an executable)"
    fi

    facts="$(mktemp)"
    box_run "'${venv_py}' ${remote} run --token '${token}' --text '${text}' --wait-s '${OSTLER_TODO_PROBE_WAIT_S:-90}'" > "${facts}" 2>/dev/null

    box_run "'${venv_py}' ${remote} forget --token '${token}' --text '${text}'" 2>/dev/null | sed 's/^/  forget: /'
    box_run "rm -f ${remote}" >/dev/null 2>&1

    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${facts}" 2>/dev/null \
        || { rm -f "${facts}"; probe_cannot_run "the box-side writer returned no facts"; }
    out="$(python3 "${_HERE}/lib/todo_reminders_probe.py" judge "${facts}")"; rc=$?
    rm -f "${facts}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT|N/A) ')"
    probe_examined "${n}" "todo-reminders assertions"
    [ "${n}" -gt 0 ] || probe_fail "the todo-reminders judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "the synthetic commitment reached a pending row, the daemon claimed it, and the reminder is visible in Reminders.app" ;;
        78) if printf '%s\n' "${out}" | grep -q 'Automation permission (TCC)'; then
                probe_cannot_run "TCC: Automation permission refused osascript's read of Reminders.app over this ssh session; only a console session can grant it (console_only_probes.tsv)"
            else
                probe_cannot_run "a todo-reminders assertion could not be measured (see the CANNOT lines above)"
            fi
            ;;
        *)  probe_fail "the commitment did not reach a working reminder (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
