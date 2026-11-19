#!/bin/sh
# scripts/box_walk_probes/probes/enrichment_switch_off_reaches_clients.sh
# ============================================================================
# READ-ONLY. R02: with the owner's switch OFF, the enricher's own per-client
# look-up line reads 0 on the box. The instrument is the enricher's counts-only line
#   enrichment looked up per client: music=N books=N films=N podcasts=N places=N food=N interests=N
# (enricher.py, the logger.info call near line 1142), read after one enrich batch has
# run with enrichment off, plus the enricher's refusal line
#   refused: owner has not accepted enrichment
#
# THE WALK HARNESS DOES THE WRITES, THIS PROBE ONLY READS:
#   1. POST /api/v1/enrichment {"enabled": false} on the box (owner session)
#   2. run ONE enrich batch on the seed fixture THROUGH THE ENRICHER (not only the tick:
#      a tick that stands down writes no per-client line, and that is CANNOT-RUN here)
#   3. this probe reads the tail of ~/.ostler/logs/enrich.log
#
# PASS only when the last per-client line names all seven clients at 0 AND the refusal
# line is on the record. FAIL on any per-client count above zero. CANNOT-RUN when no
# per-client line exists. A tick stand-down line is NOT an instrument.
# Judge: scripts/box_walk_probes/lib/walk134_judges.py switch-off.
# Mutant of the judge and of the consent gate: tests/test_doctor_enrichment_switch.py (J2, J8, E1).
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
