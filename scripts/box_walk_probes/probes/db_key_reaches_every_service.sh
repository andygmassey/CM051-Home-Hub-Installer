#!/usr/bin/env bash
# db_key_reaches_every_service -- does the installed database key actually
# reach every service that opens an encrypted store, and is the store it
# unlocks genuinely encrypted? (v1.0.107, FLOW_CENSUS gap #1)
#
# PR #1956 fixed install.sh never setting OSTLER_DB_KEY at all: both ical-
# server and the CM048 ingest pipeline took their plaintext fallback on every
# install ever shipped, one line after the installer printed "Databases
# encrypted". That fix has ridden through 7 walks with no box-walk probe
# naming a failure -- an absence of failure is not a standing guarantee, it is
# an absence of anyone looking. This probe looks.
#
# Four assertions, graded by lib/db_key_probe.py from counts and booleans
# only, never from key material or row contents:
#   (a)/(b) each service's own security-posture self-attestation says
#       encryption=enabled, backend=sqlcipher;
#   (c) a synthetic row, seeded with the SAME resolver + SQLCipher helper the
#       real writer uses, increases the real coach-db row count;
#   (d) a DIFFERENT process (ical-server, its own resolved key, over its own
#       authenticated HTTP API) reads that row back -- the only arm proving
#       both services end up using the SAME key, not two that merely work in
#       isolation;
#   (e) the database file is not openable as plain SQLite without any key.
#
# The seed, the read-back and the cleanup all happen inside this one probe
# run; nothing is left on the box unless OSTLER_DB_KEY_PROBE_KEEP=1, and the
# delete prints the row count before and after so a delete that matched
# nothing is visible, not silent.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="db_key_reaches_every_service"
PROBE_QUESTION="does the installed database key reach ical-server and the CM048 ingest pipeline, do both end up using the SAME key, and is the store they open genuinely encrypted rather than a posture marker saying so over a plaintext file?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/db_key_probe.py" --self-test; then
        probe_examined 5 "mutated db-key facts"
        probe_fail "negative control behaved: each mutant (disabled posture, a seed that did not increase the count, a cross-process read-back that found nothing, a database that opened unkeyed, and a missing posture marker) was caught by its own assertion"
    fi
    probe_examined 5 "mutated db-key facts"
    probe_pass "SELF-TEST BROKEN: the db-key judge let a known-bad fixture through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; the database key was never read"
    local remote token svc_token facts out rc n
    token="ostler-walk-dbkey-$$-$(date +%s 2>/dev/null || echo 0)"
    remote="/tmp/ostler-probe-dbkey-$$.py"
    box_run "printf %s '$(base64 < "${_HERE}/lib/db_key_probe.py" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the db-key reader on the box"

    # The box's OWN venv, the same interpreter ical-server and the CM048
    # pipeline run under (sqlcipher3 + ostler_security are installed there,
    # not in a bare system python3).
    local venv_py
    venv_py="$(box_run "VP=\${OSTLER_DIR:-\$HOME/.ostler}/.venv/bin/python3; [ -x \"\$VP\" ] && printf %s \"\$VP\" || printf %s python3")"
    [ -n "${venv_py}" ] || venv_py="python3"

    svc_token="$(box_run 'cat "${OSTLER_DIR:-$HOME/.ostler}/secrets/service_token" 2>/dev/null' | tr -d '\n')"

    facts="$(mktemp)"
    # ical-server's base comes from the harness variable every other ical-server
    # caller here already reads (README env table), not a literal: walk #11 hit
    # :8089 (the Doctor), which refuses the service token.
    box_run "'${venv_py}' ${remote} box --token '${token}' --service-token '${svc_token}' --api-base '${OSTLER_PROBE_API_BASE:-http://127.0.0.1:8090}'" > "${facts}" 2>/dev/null

    # Cleanup runs regardless of the verdict: a left-behind synthetic row is a
    # tidiness bug, not a measurement, so it is removed before this function
    # can exit either way. Prints the count before and after; a delete that
    # matched nothing is visible, never silent.
    if [ "${OSTLER_DB_KEY_PROBE_KEEP:-0}" != "1" ]; then
        box_run "'${venv_py}' ${remote} forget --token '${token}'" 2>/dev/null | sed 's/^/  forget: /'
    else
        probe_note "kept on the box (OSTLER_DB_KEY_PROBE_KEEP=1): ${token}"
    fi
    box_run "rm -f ${remote}" >/dev/null 2>&1

    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${facts}" 2>/dev/null \
        || { rm -f "${facts}"; probe_cannot_run "the box-side reader returned no facts"; }
    out="$(python3 "${_HERE}/lib/db_key_probe.py" judge "${facts}")"; rc=$?
    rm -f "${facts}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT|N/A) ')"
    probe_examined "${n}" "db-key assertions"
    [ "${n}" -gt 0 ] || probe_fail "the db-key judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "the installed database key reaches both services, they agree on it, and the store is genuinely encrypted" ;;
        78) probe_cannot_run "a db-key assertion could not be measured (see the CANNOT lines above)" ;;
        *)  probe_fail "the database key does not reach every service, or the store is not genuinely encrypted (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
