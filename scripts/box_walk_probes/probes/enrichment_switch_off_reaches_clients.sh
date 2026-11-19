#!/bin/sh
# scripts/box_walk_probes/probes/enrichment_switch_off_reaches_clients.sh
# ============================================================================
# READ-ONLY. R02: after the owner turned enrichment OFF in the Doctor
# (/config, "Public look-ups"; POST /api/v1/enrichment {"enabled": false}), the
# NEXT enrich batch must look up nothing, and the enricher must say why.
#
# THE WALK HARNESS DOES THE WRITES, THIS PROBE ONLY READS:
#   1. POST /api/v1/enrichment {"enabled": false} on the box (owner session)
#   2. run one enrich batch on the seed fixture (the enrich agent's own tick)
#   3. this probe reads the tail of ~/.ostler/logs/enrich.log
#
# PASS when EITHER the tick stood down ("standing down, nothing sent": the wrapper's
# consent gate ran before any enricher call; CB136 option b, the agent is installed
# on every box) OR the last per-client line names all seven clients at 0 AND the
# enricher's refusal line ("owner has not accepted enrichment") is on the record.
# FAIL on any per-client look-up above zero. Counts are the enricher's own outbound
# look-up counts; the tick's stand-down line is written before any network call.
# Judge: scripts/box_walk_probes/lib/walk134_judges.py switch-off.
# Emitter tests: tests/test_doctor_enrichment_switch.py (E1).
# ============================================================================
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/walk134_common.sh"

PROBE_NAME="enrichment_switch_off_reaches_clients"
PROBE_QUESTION="after the owner switched enrichment off, does the next enrich batch show 0 look-ups for all seven clients and the logged refusal reason?"
PROBE_UNIT="log lines"

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing inspected"
    if [ -z "$(box_run 'test -r "$HOME/.ostler/logs/enrich.log" && echo YES')" ]; then
        probe_examined 0 "enrich.log"
        probe_cannot_run "no readable ~/.ostler/logs/enrich.log on the box: no enrich batch has written a log here"
    fi
    _tmp="$(mktemp)"
    box_run 'tail -n 4000 "$HOME/.ostler/logs/enrich.log"' > "${_tmp}"
    walk134_judge_and_report switch-off "${_tmp}"
}

self_test() {
    _tmp="$(mktemp)"
    printf '2026-11-20 INFO enrichment looked up per client: music=0 books=0 films=0 podcasts=0 places=0 food=0 interests=0\n2026-11-20 WARNING enrich_batch refused: owner has not accepted enrichment (no outbound request made)\n' > "${_tmp}"
    python3 "${WALK134_JUDGE}" switch-off "${_tmp}" >/dev/null 2>&1
    [ "$?" = 0 ] || { rm -f "${_tmp}"; probe_cannot_run "self-test: known-good switch-off log did not PASS"; }
    printf '2026-11-20 INFO enrichment looked up per client: music=2 books=0 films=0 podcasts=0 places=0 food=0 interests=0\n' > "${_tmp}"
    python3 "${WALK134_JUDGE}" switch-off "${_tmp}" >/dev/null 2>&1
    rc=$?
    rm -f "${_tmp}"
    probe_examined 2 "known-good and known-bad switch-off logs"
    [ "$rc" = 1 ] || probe_cannot_run "self-test: a log that looked up while off did not FAIL (rc=${rc})"
    probe_fail "negative control: a look-up while switched off is a FAIL"
}

probe_main "$@"
