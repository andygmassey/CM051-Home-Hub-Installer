#!/usr/bin/env bash
# companion_listener_refuses_unauthenticated -- BLOCKING (scripts/walk_promote_scope.tsv).
# Security, red team DMG #27 F4-4 (walk #27 item 6c).
#
# The companion listener binds 0.0.0.0:8443. From a NON-loopback address
# (this walk driver, against OSTLER_BOX_HOST): GET /health must answer 200,
# and GET /api/sessions with no bearer, and with a made-up one, must answer
# 401. The box's assistant config must state require_pairing = true and a
# pair rate limit above zero under [gateway]. Read-only: three GETs, one
# file read. CANNOT-RUN: no OSTLER_BOX_HOST, or no HTTP answer.
# Judge: lib/companion_auth.py.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="companion_listener_refuses_unauthenticated"
PROBE_QUESTION="from the LAN, does the companion listener on :8443 refuse a request with no (or a made-up) bearer with 401, with pairing and a pair rate limit stated in the shipped config?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${OSTLER_COMPANION_PORT:-8443}"

self_test() {
    if python3 "${_HERE}/lib/companion_auth.py" --self-test; then
        probe_examined 11 "canned captures"
        probe_fail "negative control behaved: an unauthenticated 200, an accepted made-up bearer and a missing require_pairing all went red"
    fi
    probe_examined 11 "canned captures"
    probe_pass "SELF-TEST BROKEN: the judge let an open listener through"
}

run_probe() {
    [ -n "${OSTLER_BOX_HOST:-}" ] || probe_cannot_run "OSTLER_BOX_HOST is unset: a request from the box itself is loopback and proves nothing about the LAN"
    box_reachable || probe_cannot_run "cannot reach the box"
    local host cap code cfg
    host="${OSTLER_PAIR_PROBE_HOST:-${OSTLER_BOX_HOST##*@}}"
    code() { curl -sk --noproxy '*' -m 15 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }
    cfg="$(box_run "awk '/^\\[/{g=(\$0==\"[gateway]\")} g' \$HOME/.ostler/assistant-config/config.toml 2>/dev/null; echo __END__")"
    cap="$(mktemp)"
    CU_H="$(code "https://${host}:${PORT}/health")" \
    CU_U="$(code "https://${host}:${PORT}/api/sessions")" \
    CU_B="$(code -H 'Authorization: Bearer walk-probe-not-a-token' "https://${host}:${PORT}/api/sessions")" \
    CU_CFG="$cfg" python3 - > "$cap" <<'PY'
import json, os, re
cfg = os.environ.get("CU_CFG", "")
body = cfg.replace("__END__", "")
def val(k):
    m = re.search(r"(?m)^\s*%s\s*=\s*(\S+)" % k, body)
    return m.group(1).strip('"') if m else None
print(json.dumps({"source": "lan",
                  "health": int(os.environ.get("CU_H") or 0), "unauth": int(os.environ.get("CU_U") or 0),
                  "bogus": int(os.environ.get("CU_B") or 0),
                  "config_readable": "__END__" in cfg and "[gateway]" in body,
                  "require_pairing": val("require_pairing"),
                  "pair_rate_limit_per_minute": val("pair_rate_limit_per_minute")}))
PY
    local out rc n
    out="$(python3 "${_HERE}/lib/companion_auth.py" judge "$cap")"; rc=$?
    rm -f "$cap"
    printf '%s\n' "$out"
    n="$(printf '%s\n' "$out" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "$n" "assertions"
    [ "$n" -gt 0 ] || probe_fail "the judge printed nothing; a silent probe is not a pass"
    case "$rc" in
        0)  probe_pass "the companion listener refuses unauthenticated requests and the shipped config states pairing and its rate limit" ;;
        78) probe_cannot_run "see the CANNOT line above" ;;
        *)  probe_fail "see the FAIL lines above" ;;
    esac
}

probe_main "$@"
