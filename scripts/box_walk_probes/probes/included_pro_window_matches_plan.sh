#!/usr/bin/env bash
# scripts/box_walk_probes/probes/included_pro_window_matches_plan.sh
#
# Did the INSTALL grant the included Ostler Pro window the licence's plan buys?
# A founding licence buys 180 days (vendor/cm041/assistant_api/subscription_gate.py
# INCLUDED_DAYS); no licence buys none. install.sh calls
# activate_first_month_free(..., included_plan=OSTLER_LICENCE_PLAN), which writes
# ~/.ostler/state/subscription_state.json.
#
# v1.0.133 box proof (2026-11-17): a signed plan=founding licence with no tier
# field got NO window (tier_state absent was not counted as signed). #3579 is the
# fix. This probe reads what the installer actually wrote, so it proves the
# shipped path, not the gate called by hand.
#
# READ-ONLY. The licence file is tested for existence only, never opened. Only
# these state fields leave the box: status, source, included_plan,
# included_days, included_provisional, included_from, expires_at.
#
# REQUIRED: OSTLER_INCPRO_EXPECT = founding | ff | standard | none, set by the
# walker from how the box was installed (the signed test licence staged before
# the install, or no licence). Unset is CANNOT-RUN: the box cannot say which
# plan it was meant to have.
#
#   PASS        founding: active, plan founding, 180 days (+-1); none: no active window
#   FAIL        the window does not match the plan (including 0 days for a founding licence)
#   CANNOT-RUN  expectation unset, licence staging contradicts it, state unreadable,
#               or the transport failed
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="included_pro_window_matches_plan"
PROBE_QUESTION="does ~/.ostler/state/subscription_state.json carry the included Pro window the installed licence's plan buys (founding 180 days, no licence 0)?"

_JUDGE="$(cd "$(dirname "$0")/.." && pwd)/lib/included_pro.py"

# Box side. $HOME expands on the box. /usr/bin/python3 reads JSON only.
_BOX_READ='if [ -f "$HOME/.ostler/license/license.json" ]; then echo LICENCE=present; else echo LICENCE=absent; fi
s="$HOME/.ostler/state/subscription_state.json"
if [ ! -e "$s" ]; then echo STATE=absent
elif [ ! -r "$s" ]; then echo STATE=unreadable
else /usr/bin/python3 - "$s" <<'"'"'PY'"'"'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert isinstance(d, dict)
except Exception:
    print("STATE=unparseable"); sys.exit(0)
print("STATE=ok")
for k in ("status", "source", "included_plan", "included_days", "included_provisional", "included_from", "expires_at"):
    print("%s=%s" % (k, d.get(k, "")))
PY
fi'

self_test() {
    python3 "${_JUDGE}" --self-test >/dev/null 2>&1 || {
        printf 'VERDICT: BROKEN -- %s self-test: the judge put a known case on the wrong verdict (run lib/included_pro.py --self-test)\n' "${PROBE_NAME}"
        exit 2
    }
    # The known-bad capture: the v1.0.133 shape, a founding licence and no window.
    local cap why rc; cap="$(mktemp)"
    printf 'LICENCE=present\nSTATE=absent\n' > "${cap}"
    probe_examined 1 "known-bad capture (founding licence, no state written)"
    why="$(python3 "${_JUDGE}" "${cap}" founding)"; rc=$?
    rm -f "${cap}"
    [ "${rc}" -eq 1 ] || {
        printf 'VERDICT: BROKEN -- %s self-test: the 133 shape came back rc=%s, not FAIL\n' "${PROBE_NAME}" "${rc}"
        exit 2
    }
    probe_fail "negative control behaved: a founding licence with no window written went red (${why}), and every judge case landed on its own verdict"
}

run_probe() {
    [ -n "${OSTLER_INCPRO_EXPECT:-}" ] \
        || probe_cannot_run "OSTLER_INCPRO_EXPECT is unset (founding | none): the walker must say how this box was installed"
    box_reachable || probe_cannot_run "cannot reach the box; nothing was read"
    local cap why rc; cap="$(mktemp)"
    box_run "${_BOX_READ}" > "${cap}" \
        || { rm -f "${cap}"; probe_cannot_run "the box read failed; nothing was judged"; }
    why="$(python3 "${_JUDGE}" "${cap}" "${OSTLER_INCPRO_EXPECT}")"; rc=$?
    rm -f "${cap}"
    probe_examined 1 "subscription_state.json (expectation ${OSTLER_INCPRO_EXPECT})"
    case "${rc}" in
        0) probe_pass "${why}" ;;
        1) probe_fail_or_advisory "${why}" ;;
        *) probe_cannot_run "${why}" ;;
    esac
}

probe_main "$@"
