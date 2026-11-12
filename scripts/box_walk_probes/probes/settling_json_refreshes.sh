#!/usr/bin/env bash
# probes/settling_json_refreshes.sh
# ============================================================================
# QUESTION: does settling.json, which feeds the setup status screen, get
#           refreshed on the 15-minute settling-refresh cadence, and does the
#           gateway serve it?
#
# WHY. The full wiki compile runs once a day and takes hours, so before the
# settling-refresh LaunchAgent the setup screen could freeze for 24 h. The
# agent (com.creativemachines.ostler.settling-refresh, StartInterval 900) runs
# the CM044 `--settling-only` mode. This probe reads the file the CUSTOMER'S
# screen reads: GET /wiki/settling.json through the gateway with the service
# bearer (not the file on disk), twice, more than one interval apart.
#
# ASSERTS (contract: ~/walkdriver/ui/setup-status/design/SETTLING_ONLY_CONTRACT.md)
#   1. HTTP 200 on both reads.
#   2. The body is a JSON object carrying percent, history_filling,
#      eta_seconds, eta_display, computed_at, basis.
#   3. computed_at ADVANCES between the two reads (waited
#      OSTLER_SETTLING_REFRESH_WAIT_S, default 1000 s = 15 min + slack).
#   4. The second reading is fresh: computed_at within 30 min of now
#      (SETTLING_FRESH_SECONDS, the constant the wiki panel and Hub card share).
#
# WHAT BROKEN LOOKS LIKE: an agent not loaded, a docker failure, or a route not
# served gives 404/401, or the same computed_at twice. Each is a FAIL here.
# NO TOKEN or no reply = CANNOT-RUN, never PASS.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="settling_json_refreshes"
PROBE_QUESTION="does the gateway serve settling.json with a computed_at that advances on the 15-minute refresh?"

SETTLING_URL="${OSTLER_SETTLING_URL:-http://127.0.0.1:8000/wiki/settling.json}"
TOKEN_PATH="${OSTLER_PROBE_TOKEN_PATH:-\$HOME/.ostler/secrets/service_token}"
WAIT_S="${OSTLER_SETTLING_REFRESH_WAIT_S:-1000}"
case "$WAIT_S" in ''|*[!0-9]*) WAIT_S=1000 ;; esac

# _judge <code1> <body1-file> <code2> <body2-file> <now-epoch>
# Prints PASS|<why> or FAIL|<why>, one line. Stdlib only, isolated mode.
_judge() {
    python3 -I - "$@" <<'PY'
import json, sys
from datetime import datetime, timezone

code1, f1, code2, f2, now = sys.argv[1:6]
REQUIRED = ("percent", "history_filling", "eta_seconds", "eta_display", "computed_at", "basis")
FRESH = 30 * 60

def fail(why):
    print("FAIL|" + why); sys.exit(0)

def load(code, path, label):
    if code != "200":
        fail("%s read returned HTTP %s, not 200" % (label, code))
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError) as exc:
        fail("%s body is not JSON (%s)" % (label, type(exc).__name__))
    if not isinstance(d, dict):
        fail("%s body is not a JSON object" % label)
    missing = [k for k in REQUIRED if k not in d]
    if missing:
        fail("%s body lacks %s" % (label, ",".join(missing)))
    return d

def ts(v, label):
    try:
        t = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        fail("%s computed_at %r is not an ISO timestamp" % (label, v))
    if t.tzinfo is None:
        t = t.replace(tzinfo=timezone.utc)
    return t.timestamp()

a = load(code1, f1, "first")
b = load(code2, f2, "second")
t1, t2 = ts(a["computed_at"], "first"), ts(b["computed_at"], "second")
if not t2 > t1:
    fail("computed_at did not advance (%s then %s): the refresh agent is not running or not writing" % (a["computed_at"], b["computed_at"]))
age = float(now) - t2
if age > FRESH:
    fail("second computed_at is %d s old, over the %d s freshness limit" % (age, FRESH))
print("PASS|computed_at advanced %d s (%s -> %s); second reading %d s old" % (t2 - t1, a["computed_at"], b["computed_at"], max(age, 0)))
PY
}

run_probe() {
    local tmp; tmp="$(mktemp -d)" || probe_cannot_run "no scratch dir"
    local fetch="tok=\$(tr -d '\\r\\n' < \"${TOKEN_PATH}\"); [ -n \"\$tok\" ] || { echo NOTOKEN; exit 0; }; curl -sS --noproxy '*' -m 20 -w '\\n%{http_code}' -H \"Authorization: Bearer \$tok\" '${SETTLING_URL}'"
    local r1 r2 c1 c2
    r1="$(box_run "$fetch")"
    case "$r1" in NOTOKEN*) rm -rf "$tmp"; probe_cannot_run "no service token at ${TOKEN_PATH}; the gateway fails closed, so nothing was measured" ;; esac
    [ -n "$r1" ] || { rm -rf "$tmp"; probe_cannot_run "no reply from the box for $SETTLING_URL (curl failed or the box is unreachable); not a pass"; }
    c1="${r1##*$'\n'}"; printf '%s\n' "${r1%$'\n'*}" > "$tmp/b1"
    probe_note "first reading: HTTP $c1; waiting ${WAIT_S}s for a second (agent interval is 900 s)"
    sleep "$WAIT_S"
    r2="$(box_run "$fetch")"
    [ -n "$r2" ] || { rm -rf "$tmp"; probe_cannot_run "no reply from the box for the second reading; not a pass"; }
    c2="${r2##*$'\n'}"; printf '%s\n' "${r2%$'\n'*}" > "$tmp/b2"
    probe_examined 2 "readings of $SETTLING_URL via the gateway bearer, ${WAIT_S}s apart"
    local v; v="$(_judge "$c1" "$tmp/b1" "$c2" "$tmp/b2" "$(date -u +%s)")"
    rm -rf "$tmp"
    case "$v" in
        PASS\|*) probe_pass "${v#PASS|}" ;;
        *) probe_fail_or_advisory "${v#FAIL|}" ;;
    esac
}

self_test() {
    SELF_TEST_LOCAL=1
    probe_examined 4 "synthetic settling.json pairs: advancing (positive control), stalled, 404, schema-missing (negative controls)"
    local tmp; tmp="$(mktemp -d)"
    local now t1 t2
    now="$(date -u +%s)"
    # python, not `date -r`: BSD and GNU date disagree on -r.
    t1="$(python3 -I -c 'import sys,datetime as D;print(D.datetime.fromtimestamp(int(sys.argv[1]),D.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' $((now - 600)))"
    t2="$(python3 -I -c 'import sys,datetime as D;print(D.datetime.fromtimestamp(int(sys.argv[1]),D.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' $((now - 60)))"
    mk() { printf '{"percent":40,"history_filling":true,"eta_seconds":null,"eta_display":null,"computed_at":"%s","basis":"synthetic"}\n' "$1" > "$2"; }
    mk "$t1" "$tmp/old"; mk "$t2" "$tmp/new"
    printf '{"percent":40}\n' > "$tmp/thin"; printf 'not found\n' > "$tmp/nf"
    local adv stall nf thin
    adv="$(_judge 200 "$tmp/old" 200 "$tmp/new" "$now")"
    stall="$(_judge 200 "$tmp/old" 200 "$tmp/old" "$now")"
    nf="$(_judge 200 "$tmp/old" 404 "$tmp/nf" "$now")"
    thin="$(_judge 200 "$tmp/thin" 200 "$tmp/new" "$now")"
    rm -rf "$tmp"
    case "$adv" in PASS\|*) ;; *) probe_pass "POSITIVE CONTROL DID NOT PASS ($adv): this probe cannot see a healthy refresh" ;; esac
    case "$stall" in FAIL\|*) ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: a stalled computed_at gave: $stall" ;; esac
    case "$nf" in FAIL\|*) ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: a 404 gave: $nf" ;; esac
    case "$thin" in FAIL\|*) ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: a schema-less body gave: $thin" ;; esac
    probe_fail "self-test: healthy pair gave PASS, and stalled, 404 and schema-less pairs each gave FAIL, so this probe returns FAIL on them as it must"
}

probe_main "$@"
