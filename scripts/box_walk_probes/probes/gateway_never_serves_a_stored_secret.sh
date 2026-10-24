#!/usr/bin/env bash
# gateway_never_serves_a_stored_secret -- BLOCKING (scripts/walk_promote_scope.tsv).
# Security, v1.0.109 thin walk.
#
# Does any gateway or companion route hand back a secret the box stores in
# ${OSTLER_DIR}/assistant-config/config.toml ([gateway].paired_tokens and the
# Vane password inside vane_url)? Every gateway route in the hub contract
# (generated from the daemon's router) is requested on the LAN :8443, loopback
# :8443 and loopback :8000, once with no credential and once with a paired
# bearer, and each secret is COUNTED in body and headers (exact, URL-encoded,
# base64). PASS = 0 everywhere; FAIL names the route, never the value.
#
# The sweep runs ON the box: the secret values never cross the ssh link,
# are never printed and never written; only labels and counts come back.
# Positive control first: the same counter must find every secret in the
# config file itself, or the probe is CANNOT-RUN. CANNOT-RUN also when
# config.toml is unreadable, no paired token is accepted, or a base answers
# nothing. Judge: lib/stored_secret_sweep.py.
#
# Also the licence id (${OSTLER_DIR}/license/license.json) and the registered
# fingerprint (${OSTLER_DIR}/state/fingerprint.txt), which the Hub uses to
# proxy POST /api/v1/invites/{mint,rewards}. Those two routes are always
# swept, in both arms. Absent files are reported NOT INSTRUMENTED.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="gateway_never_serves_a_stored_secret"
PROBE_QUESTION="does any gateway or companion route (LAN :8443, loopback :8443 and :8000), with no credential or with a paired bearer, serve a paired token or the Vane password from config.toml, or the licence id or device fingerprint (invite routes included)?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_REPO="$(cd "${_HERE}/../.." && pwd)"
LIB="${_HERE}/lib/stored_secret_sweep.py"
CONTRACT="${OSTLER_HUB_CONTRACT:-${_REPO}/vendor/cm041/assistant_api/hub_contract.yaml}"

self_test() {
    if python3 "${LIB}" --self-test; then
        probe_examined 11 "fake-gateway arms"
        probe_fail "negative control behaved: a planted token, URL-encoded token, base64 Vane password, and a fingerprint and licence id echoed on the invite routes each went red naming the route, and a blind control went CANNOT-RUN"
    fi
    probe_examined 11 "fake-gateway arms"
    probe_pass "SELF-TEST BROKEN: the sweep let a planted secret through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was requested"
    [ -r "${CONTRACT}" ] || probe_cannot_run "hub contract not found at ${CONTRACT}: no route list to sweep"
    local remote cap rc out n bases_arg="" routes
    routes="$(mktemp)"
    python3 -c "import json,sys; c=json.load(open(sys.argv[1])); r=[x for x in c.get('routes',[]) if x.get('listener')=='gateway']; json.dump({'routes':r},open(sys.argv[2],'w')); print(len(r))" "${CONTRACT}" "${routes}" | grep -qE '^[1-9]' \
        || { rm -f "${routes}"; probe_cannot_run "the hub contract at ${CONTRACT} lists no gateway routes"; }
    remote="$(box_run 'mktemp -d /tmp/ostler-probe-secret.XXXXXX')"
    [ -n "${remote}" ] || probe_cannot_run "could not make a staging directory on the box"
    box_run "chmod 700 '${remote}' && printf %s '$(base64 < "${LIB}" | tr -d '\n')' | base64 -d > '${remote}/s.py' && printf %s '$(base64 < "${routes}" | tr -d '\n')' | base64 -d > '${remote}/c.json' && echo staged" | grep -q '^staged$' \
        || { rm -f "${routes}"; box_run "rm -rf '${remote}'"; probe_cannot_run "could not stage the sweep on the box"; }
    if [ -n "${OSTLER_SECRET_SWEEP_BASES:-}" ]; then
        local b; for b in ${OSTLER_SECRET_SWEEP_BASES//,/ }; do bases_arg="${bases_arg} --base '${b}'"; done
    fi
    rm -f "${routes}"
    cap="$(mktemp)"
    box_run "umask 077; CFG=\"\${OSTLER_DIR:-\$HOME/.ostler}/assistant-config/config.toml\"; OSTLER_PAIR_PROBE_HOST='${OSTLER_PAIR_PROBE_HOST:-}' python3 '${remote}/s.py' sweep --config \"\$CFG\" --license \"\${OSTLER_DIR:-\$HOME/.ostler}/license/license.json\" --fingerprint \"\${OSTLER_DIR:-\$HOME/.ostler}/state/fingerprint.txt\" --contract '${remote}/c.json'${bases_arg}; rm -rf '${remote}'" > "${cap}"
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side sweep returned no capture (is python3 on the box?)"; }
    out="$(python3 "${LIB}" judge "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "judge lines"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed nothing; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "no route served a stored secret; see the counts above" ;;
        78) probe_cannot_run "see the CANNOT line above" ;;
        *)  probe_fail "see the FAIL lines above: each names the route that served a stored secret" ;;
    esac
}

probe_main "$@"
