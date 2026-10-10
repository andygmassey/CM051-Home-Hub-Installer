#!/usr/bin/env bash
# pair_endpoints_refuse_off_window -- BLOCKING (scripts/walk_promote_scope.tsv). Security, #17.
#
# From a NON-loopback LAN address (this walk driver, against OSTLER_BOX_HOST),
# with no pairing window open, POST /api/pair and POST /pair on the companion
# listener (:8443) must be refused at the router, 404 or 403, WITHOUT a code
# being evaluated: no code-validation text in the body, and no code-check line
# added to ~/.ostler/logs/ostler-assistant.err while the requests ran. A 403 is
# not enough on its own: the code-checking path also answers 403.
#
# The ostler-assistant gateway offers no way to open a pairing window today, so
# the 6-wrong-codes lockout arm is reported NOT INSTRUMENTED, never passed.
# Two requests, one bogus code each: well under any rate limit.
# CANNOT-RUN: no OSTLER_BOX_HOST (a request from the box itself is loopback),
# no HTTP answer, or the daemon log unreadable. Judge: lib/pair_offwindow.py.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="pair_endpoints_refuse_off_window"
PROBE_QUESTION="from the LAN with no pairing window open, are POST /api/pair and POST /pair on :8443 refused at the router (404/403) without any code being checked?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${OSTLER_COMPANION_PORT:-8443}"

self_test() {
    if python3 "${_HERE}/lib/pair_offwindow.py" --self-test; then
        probe_examined 9 "canned responses"
        probe_fail "negative control behaved: the canned 400 'Invalid or expired pairing code', a code-checking 403 and a logged code check all went red"
    fi
    probe_examined 9 "canned responses"
    probe_pass "SELF-TEST BROKEN: the judge let a code-checking response through"
}

run_probe() {
    [ -n "${OSTLER_BOX_HOST:-}" ] || probe_cannot_run "OSTLER_BOX_HOST is unset: a request from the box itself is loopback and proves nothing about the LAN"
    box_reachable || probe_cannot_run "cannot reach the box"
    local host log before cap
    host="${OSTLER_PAIR_PROBE_HOST:-${OSTLER_BOX_HOST##*@}}"
    log='$HOME/.ostler/logs/ostler-assistant.err'
    before="$(box_run "wc -c < ${log}" | tr -dc '0-9')"
    cap="$(mktemp)"
    {
        printf '{"source": "lan", "window": "none-offered", "endpoints": ['
        sep=""
        for path in /api/pair /pair; do
            out="$(curl -sk --noproxy '*' -m 15 -o - -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
                   -H 'X-Pairing-Code: 000000' --data '{"code":"000000"}' "https://${host}:${PORT}${path}" 2>/dev/null)"
            st="${out##*$'\n'}"; body="${out%$'\n'*}"
            printf '%s{"path": "%s", "status": %s, "body": %s}' "$sep" "$path" "${st:-0}" \
                "$(printf '%s' "$body" | head -c 400 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
            sep=", "
        done
        printf '], '
        if [ -n "$before" ]; then
            hits="$(box_run "tail -c +$((before + 1)) ${log}" | grep -aE 'Pairing attempt with invalid code|Pairing locked out|Pairing auth rate limit exceeded|/pair rate limit exceeded' \
                    | python3 -c 'import json,sys; print(json.dumps([l.strip()[:160] for l in sys.stdin]))')"
            printf '"log_readable": true, "log_hits": %s}' "${hits:-[]}"
        else
            printf '"log_readable": false, "log_hits": []}'
        fi
    } > "$cap"
    local out rc n
    out="$(python3 "${_HERE}/lib/pair_offwindow.py" judge "$cap")"; rc=$?
    rm -f "$cap"
    printf '%s\n' "$out"
    n="$(printf '%s\n' "$out" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "$n" "assertions"
    [ "$n" -gt 0 ] || probe_fail "the judge printed nothing; a silent probe is not a pass"
    case "$rc" in
        0)  probe_pass "both pair endpoints were refused at the router with no code checked" ;;
        78) probe_cannot_run "see the CANNOT line above" ;;
        *)  probe_fail "see the FAIL lines above" ;;
    esac
}

probe_main "$@"
