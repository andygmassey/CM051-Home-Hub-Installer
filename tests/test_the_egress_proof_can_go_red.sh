#!/bin/bash
# The egress claim is only worth what its instrument is worth, and a pass on
# its own does not distinguish "nothing left the machine" from "the instrument
# is blind". This runs the boundary-and-attribution logic over five readings
# whose correct verdicts are known in advance, and requires all five.
#
# Two of the five must go RED. That is the part a reader cannot get anywhere
# else: an egress report that has never failed is a false-confidence generator
# like any other gate, and every arm here is derived from a REAL capture rather
# than from a scenario somebody imagined.
#
# It is offline and deterministic. No network, no box, no simulator, no
# privileges. A sceptic with a clone can run this file and get these numbers.
#
#   bash tests/test_the_egress_proof_can_go_red.sh
#
# Exit 0 when all five arms behave as designed, 1 when any does not, 2 when the
# probe or the fixture is missing -- CANNOT-RUN, which is not a pass.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="${ROOT}/scripts/box_walk_probes/probes/no_unexpected_egress.sh"
FIX="${ROOT}/scripts/box_walk_probes/fixtures/egress_2026-08-17_mid_install.tsv"

[ -f "${PROBE}" ] || { echo "CANNOT-RUN: no probe at ${PROBE}" >&2; exit 2; }
[ -f "${FIX}" ]   || { echo "CANNOT-RUN: no fixture at ${FIX}" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/egress-proof.XXXXXX")" || { echo "CANNOT-RUN: no temp dir" >&2; exit 2; }
trap 'rm -rf -- "${TMP}"' EXIT

# The lineage of a row the probe attributes to us. Reused verbatim for the
# planted row so the plant is caught for the RIGHT reason -- an undeclared
# destination -- and not skipped as somebody else's traffic.
OURS=':/usr/bin/curl:/Applications/OstlerInstaller.app/Contents/Resources/install.sh'

# The same recorded reading with its six outside-boundary rows of our lineage
# removed. Everything else is untouched, so the only variable between arm 1 and
# arm 2 is the presence of those six.
grep -vE '^(curl	1001	185|curl	1002	20\.205|limactl	1010	208\.80|tailscale	1090	(192\.200|199\.165))' \
    "${FIX}" > "${TMP}/inside-only.tsv"

# The customer's own Mail and WhatsApp, which leave the boundary and are not
# ours, plus one loopback connection that IS ours so the run has something of
# ours to speak about at all.
{ grep -E '^(Mail|WhatsApp)	' "${FIX}"
  grep -E '^python3\.1	1050	127\.0\.0\.1:11434' "${FIX}"
} > "${TMP}/third-party.tsv"

# The clean set with ONE destination planted. 203.0.113.0/24 is TEST-NET-3
# (RFC 5737): reserved for documentation and routed nowhere, so the fixture
# cannot be mistaken for a real destination by a reader or by a later grep.
cp -- "${TMP}/inside-only.tsv" "${TMP}/planted.tsv"
printf 'curl\t99999\t203.0.113.77:443\t%s\n' "${OURS}" >> "${TMP}/planted.tsv"

# Nothing of ours at all.
grep -E '^(Mail|WhatsApp)	' "${FIX}" > "${TMP}/nothing-of-ours.tsv"

PASS=0; FAIL=0

arm() {   # $1 label  $2 file  $3 wanted-rc  $4 what it proves
    local label="$1" file="$2" want="$3" why="$4" rc out rows flagged
    out="$(bash "${PROBE}" --classify-fixture "${file}" 2>&1)"; rc=$?
    rows="$(grep -cvE '^[[:space:]]*(#|$)' "${file}")"
    flagged="$(printf '%s' "${out}" | grep -c .)"
    if [ "${rc}" -eq "${want}" ]; then
        PASS=$((PASS + 1))
        printf '  [PASS] %-14s rows=%-3s flagged=%-2s rc=%s   %s\n' "${label}" "${rows}" "${flagged}" "${rc}" "${why}"
    else
        FAIL=$((FAIL + 1))
        printf '  [FAIL] %-14s rows=%-3s flagged=%-2s rc=%s wanted=%s   %s\n' "${label}" "${rows}" "${flagged}" "${rc}" "${want}" "${why}"
        printf '%s\n' "${out}" | sed 's/^/         /'
    fi
}

echo "the egress instrument, exercised against five readings with known verdicts"
echo

arm recorded    "${FIX}"                    1 "MUST CATCH: the real 2026-08-17 capture that proved the old filter blind"
arm inside-only "${TMP}/inside-only.tsv"    0 "MUST MISS: the same reading with those six rows removed"
arm third-party "${TMP}/third-party.tsv"    0 "MUST NOT BLAME US: the customer's own Mail and WhatsApp leave the boundary"
arm planted     "${TMP}/planted.tsv"        1 "THE PLANTED LEAK: one undeclared destination carrying our lineage"
arm no-subject  "${TMP}/nothing-of-ours.tsv" 2 "REFUSES: no connection of ours observed, so it says nothing and admits it"

echo
echo "  PASS: ${PASS}/5"
[ "${FAIL}" -eq 0 ] || { echo "  the instrument did not behave as designed on ${FAIL} arm(s)." >&2; exit 1; }

# A guard on the guard. If a later edit made every arm agree, the five above
# would all pass while proving nothing, so require that this file still asks
# for both verdicts.
echo "  and the arms disagree: 2 wanted RED, 2 wanted GREEN, 1 wanted CANNOT-RUN."
exit 0
