#!/bin/sh
# scripts/box_walk_probes/probes/enrichment_switch_on_reaches_clients.sh
# ============================================================================
# READ-ONLY. R02: after the owner turned enrichment back ON in the Doctor
# (POST /api/v1/enrichment {"enabled": true}), the NEXT enrich batch must look up
# above zero for every client. Same judge as enrichment_reaches_clients:
# judge enrich (PASS only when all seven per-client counts are above zero).
#
# THE WALK HARNESS DOES THE WRITES: POST enabled=true, then one enrich batch on
# the seed fixture, then this probe reads ~/.ostler/logs/enrich.log.
# Requires the recurring enrich job to exist on the box; if the Mac declined at
# install, the job was never installed and this is CANNOT-RUN, not PASS.
# ============================================================================
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/walk134_common.sh"

PROBE_NAME="enrichment_switch_on_reaches_clients"
PROBE_QUESTION="after the owner switched enrichment on, does the next enrich batch look up above zero for all seven clients?"
PROBE_UNIT="log lines"

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing inspected"
    if [ -z "$(box_run 'test -r "$HOME/.ostler/logs/enrich.log" && echo YES')" ]; then
        probe_examined 0 "enrich.log"
        probe_cannot_run "no readable ~/.ostler/logs/enrich.log on the box: no enrich batch has written a log here"
    fi
    _tmp="$(mktemp)"
    box_run 'tail -n 4000 "$HOME/.ostler/logs/enrich.log"' > "${_tmp}"
    walk134_judge_and_report enrich "${_tmp}"
}

self_test() {
    walk134_self_judge_selftest
    _tmp="$(mktemp)"
    printf 'creators dropped: contact store unreadable: 0\ncreators looked up: 0\n' > "${_tmp}"
    walk134_self_red enrich "${_tmp}"
    rm -f "${_tmp}"
    probe_examined 1 "known-bad enrich log (batch looked up 0 creators)"
    probe_fail "negative control: a switched-on batch that looked up 0 creators is a FAIL"
}

probe_main "$@"
