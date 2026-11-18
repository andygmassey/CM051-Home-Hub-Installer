#!/bin/sh
# scripts/box_walk_probes/probes/proxy_reads_are_owner_own_brief.sh
# ============================================================================
# READ-ONLY. A read through the Doctor proxy that carries an owner_local claim
# (X-Ostler-Destination header, or ?destination= query) must be served as
# owner_own_brief, and the L3 row must be absent from the body.
#
# Three arms, each an HTTP read ISSUED ON THE BOX (lib/probe.sh box_run):
#   control  the ical-server on its own loopback, owner_local claimed. Loopback
#            is the one peer the server honours the claim from, so this proves
#            the instrument can SEE owner_local and sees a private-labelled row.
#            Without that the absence below is not provable.
#   header   the Doctor (:8089) with X-Ostler-Destination: owner_local.
#   query    the Doctor (:8089) with ?destination=owner_local.
# The proxy's upstream is the gateway (DOCTOR_GATEWAY_URL, default :8000), so
# the served_for value the proxy relays is the one the gateway answered with.
#
# Verdicts: a control that is not owner_local or shows no private row is
# CANNOT-RUN. A proxy arm that serves anything but owner_own_brief, or carries a
# private-labelled row, is FAIL. An arm that does not answer 200 is CANNOT-RUN.
#
# The ical-server requires the service token on /api/v1 routes. The token is
# read on the box into the remote shell's variable and never printed here.
# ============================================================================
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/walk134_common.sh"

PROBE_NAME="proxy_reads_are_owner_own_brief"
PROBE_QUESTION="does a Doctor-proxied read carrying owner_local (header or query) get served as owner_own_brief with no L3 row, when the owner_local control shows the L3 row exists?"
PROBE_UNIT="HTTP reads"
_ICAL_TIMELINE="http://127.0.0.1:8090/api/v1/timeline?days=30"

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing inspected"
    _c="$(mktemp)"; _h="$(mktemp)"; _q="$(mktemp)"
    # Token read on the box, same process-environment reader running_config_matches_disk uses.
    box_run "P=\$(pgrep -u \"\$(id -u)\" -f ical-server.py | head -1); T=\$(ps -Eww -p \"\$P\" 2>/dev/null | tr ' ' '\\n' | grep -m1 -E '^(OSTLER|PWG)_SERVICE_TOKEN=' | sed 's/^[A-Z_]*=//'); curl -s -i --noproxy '*' --max-time 8 -H \"X-Ostler-Destination: owner_local\" -H \"Authorization: Bearer \$T\" '${_ICAL_TIMELINE}'" > "${_c}"
    box_run "curl -s -i --noproxy '*' --max-time 8 -H 'X-Ostler-Destination: owner_local' '${DOCTOR_URL}/api/v1/timeline?days=30'" > "${_h}"
    box_run "curl -s -i --noproxy '*' --max-time 8 '${DOCTOR_URL}/api/v1/timeline?days=30&destination=owner_local'" > "${_q}"
    walk134_judge_and_report proxy "${_c}" "${_h}" "${_q}"
}

self_test() {
    walk134_self_judge_selftest
    _c="$(mktemp)"; _h="$(mktemp)"; _q="$(mktemp)"
    printf 'HTTP/1.1 200 OK\nX-Ostler-Served-For: owner_local\n\n{"events": [{"privacy_label": "private"}]}\n' > "${_c}"
    printf 'HTTP/1.1 200 OK\nX-Ostler-Served-For: owner_local\n\n{"events": [{"privacy_label": "private"}]}\n' > "${_h}"
    printf 'HTTP/1.1 200 OK\nX-Ostler-Served-For: owner_own_brief\n\n{"events": []}\n' > "${_q}"
    walk134_self_red proxy "${_c}" "${_h}" "${_q}"
    rm -f "${_c}" "${_h}" "${_q}"
    probe_examined 3 "known-bad proxy arms (header arm served owner_local)"
    probe_fail "negative control: a header claim served owner_local through the proxy is a FAIL"
}

probe_main "$@"
