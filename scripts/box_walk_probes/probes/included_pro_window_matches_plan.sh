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
# TWO ARMS, both required for a PASS.
#   A  the installed state (~/.ostler/state/subscription_state.json) against
#      OSTLER_INCPRO_EXPECT (founding | ff | standard), which the walker sets from
#      the signed test licence it staged at ~/.ostler/license/license.json before
#      the install. Read-only.
#   B  NO LICENCE gets 0 days. A box cannot be installed without a licence
#      (install.sh ERR-02-LICENCE-REQUIRED), so B calls the INSTALLED gate
#      (~/.ostler/services/ical-server/subscription_gate.py) exactly as install.sh
#      does with nothing verified (tier_state unverified, no plan), with
#      OSTLER_SUBSCRIPTION_STATE pointed at a temporary file. WALK_WRITES: that
#      temporary directory only, removed in the same call; the real state is
#      never touched.
#
# The licence file is tested for existence only, never opened. Only these
# state fields leave the box: status, source, included_plan, included_days,
# included_provisional, included_from, expires_at.
#
#   PASS        A: active, plan as expected, 180 days (+-1) for founding; and B: no active window
#   FAIL        either arm's window is wrong (including 0 days for a founding licence)
#   CANNOT-RUN  expectation unset, no licence staged, state unreadable, gate missing,
#               or the transport failed
#
# WALK_READ_ONLY: arm B writes one state file into a mktemp -d directory on the box and removes it in the same call; nothing another probe reads is changed.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="included_pro_window_matches_plan"
PROBE_QUESTION="does the installed state carry the window the staged licence's plan buys (founding 180 days), and does the installed gate grant 0 days with no licence?"

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
fi
g="$HOME/.ostler/services/ical-server/subscription_gate.py"
if [ ! -f "$g" ]; then echo NOLIC_GATE=absent
else
  echo NOLIC_GATE=present
  t="$(mktemp -d)"
  OSTLER_SUBSCRIPTION_STATE="$t/state.json" /usr/bin/python3 - "$(dirname "$g")" >/dev/null 2>&1 <<'"'"'PY'"'"'
import sys
from datetime import datetime, timezone
sys.path.insert(0, sys.argv[1])
from subscription_gate import activate_first_month_free
activate_first_month_free(datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                          licence_tier=None, licence_tier_state="unverified",
                          licence_expires_at=None, included_plan=None)
PY
  echo "NOLIC_RC=$?"
  if [ ! -e "$t/state.json" ]; then echo NOLIC_STATE=absent
  else /usr/bin/python3 - "$t/state.json" <<'"'"'PY'"'"'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert isinstance(d, dict)
except Exception:
    print("NOLIC_STATE=unparseable"); sys.exit(0)
print("NOLIC_STATE=ok")
for k in ("status", "source", "included_plan"):
    print("NOLIC_%s=%s" % (k, d.get(k, "")))
PY
  fi
  rm -rf "$t"
fi'

self_test() {
    python3 "${_JUDGE}" --self-test >/dev/null 2>&1 || {
        printf 'VERDICT: BROKEN -- %s self-test: the judge put a known case on the wrong verdict (run lib/included_pro.py --self-test)\n' "${PROBE_NAME}"
        exit 2
    }
    # The known-bad capture: the v1.0.133 shape, a founding licence and no window.
    local cap why rc; cap="$(mktemp)"
    printf 'LICENCE=present\nSTATE=absent\nNOLIC_GATE=present\nNOLIC_RC=0\nNOLIC_STATE=absent\n' > "${cap}"
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
    box_reachable || probe_cannot_run "cannot reach the box; nothing was read"
    local cap why rc; cap="$(mktemp)"
    box_run "${_BOX_READ}" > "${cap}" \
        || { rm -f "${cap}"; probe_cannot_run "the box read failed; nothing was judged"; }
    why="$(python3 "${_JUDGE}" "${cap}" "${OSTLER_INCPRO_EXPECT:-}")"; rc=$?
    rm -f "${cap}"
    probe_examined 2 "arms: installed subscription_state.json (expect ${OSTLER_INCPRO_EXPECT:-unset}) and the installed gate with no licence"
    case "${rc}" in
        0) probe_pass "${why}" ;;
        1) probe_fail_or_advisory "${why}" ;;
        *) probe_cannot_run "${why}" ;;
    esac
}

probe_main "$@"
