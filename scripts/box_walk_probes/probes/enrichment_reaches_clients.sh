#!/bin/sh
# scripts/box_walk_probes/probes/enrichment_reaches_clients.sh
# ============================================================================
# READ-ONLY. Reads the enrich log the box wrote and asks: did the last enrich
# batch reach its creators, and did the contact loader report what it read?
#
# WHAT IT MEASURES: ~/.ostler/logs/enrich.log, the tail of it. The enricher
# prints, every batch (vendor/cm019_preferences/services/enrich/src/enricher.py
# enrich_batch, finally-block): "creators dropped: contact store unreadable: N"
# and "creators looked up: M", plus per-category "[PARALLEL] Completed <cat>:
# N enriched" lines.
#
# WHAT IT DOES NOT MEASURE, AND SAYS SO: the 134 must-check names seven clients
# (music, books, films, podcasts, places, food, interests). The enricher logs no
# per-client count, so every client is listed as NOT MEASURED and the verdict
# is CANNOT-RUN until it does. A batch that reached creators is necessary, not
# sufficient, for "every client reached".
#
# The seed: a walk that wants this to PASS runs an enrich batch on the seed
# fixture first. This probe does not write.
# ============================================================================
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/walk134_common.sh"

PROBE_NAME="enrichment_reaches_clients"
PROBE_QUESTION="after a seeded enrich batch, does enrich.log show creators looked up > 0, the contact-loader line, and a look-up count for each of the seven clients?"
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
    probe_fail "negative control: a batch that looked up 0 creators is a FAIL"
}

probe_main "$@"
