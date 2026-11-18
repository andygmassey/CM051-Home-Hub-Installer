#!/bin/sh
# scripts/box_walk_probes/probes/enrichment_decline_survives_upgrade.sh
# ============================================================================
# READ-ONLY. A Hub whose install declined public look-ups must still be
# declined, with no enrichment agent loaded, after the upgrade.
#
# WHAT IT MEASURES: the decision the installer recorded in config/.env
# (OSTLER_CONSENT_ENRICHMENT_DECISION, written by install.sh's consent step and
# carried through reuse by the "UNTRUNCATED CONSENT" block), and whether
# com.ostler.enrich is loaded. The reader is the same rule install.sh and the
# enrich tick use: only the recorded "accepted" agrees, anything else is off.
#
# WHAT IT DOES NOT MEASURE: the upgrade itself. A walk cannot replay 133 -> 134.
# This reads the state an upgrade leaves behind. A box that is NOT in the
# declined state returns CANNOT-RUN, never PASS. The upgrade replay is a
# separate unit test (tests/test_walk134_thin_walk_probes.sh) over a fixture
# written the way the earlier version wrote it.
# ============================================================================
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/walk134_common.sh"

PROBE_NAME="enrichment_decline_survives_upgrade"
PROBE_QUESTION="on a Hub that recorded a decline to public look-ups, is the decline still recorded and is com.ostler.enrich absent after the upgrade?"
PROBE_UNIT="config lines and launchd labels"

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing inspected"
    _env="$(mktemp)"; _agent="$(mktemp)"
    if [ -z "$(box_run 'test -r "$HOME/.ostler/config/.env" && echo YES')" ]; then
        printf '' > "${_env}"
    else
        box_run 'cat "$HOME/.ostler/config/.env"' > "${_env}"
    fi
    box_run 'if launchctl print "gui/$(id -u)/com.ostler.enrich" >/dev/null 2>&1; then echo LOADED; else echo ABSENT; fi' > "${_agent}"
    _state="$(tr -d '\r\n ' < "${_agent}")"
    case "${_state}" in
        LOADED) _loaded=1 ;;
        ABSENT) _loaded=0 ;;
        *) rm -f "${_env}" "${_agent}"
           probe_examined 0 "launchd labels"
           probe_cannot_run "launchd answered neither LOADED nor ABSENT for com.ostler.enrich (got '${_state}'): the agent state is unmeasured" ;;
    esac
    walk134_judge_and_report decline "${_env}" "${_loaded}"
}

self_test() {
    walk134_self_judge_selftest
    _env="$(mktemp)"
    printf 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"\n' > "${_env}"
    walk134_self_red decline "${_env}" 1
    rm -f "${_env}"
    probe_examined 2 "known-bad state (declined, agent still loaded)"
    probe_fail "negative control: a declined Hub with com.ostler.enrich loaded is a FAIL"
}

probe_main "$@"
