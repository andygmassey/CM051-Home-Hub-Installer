#!/usr/bin/env bash
# test_ingest_coverage_probe.sh
# ============================================================================
# Proves the store-credential + transport-guard + three-part-401 adjudication
# added to ingest_coverage.sh. count_store used to query Qdrant BARE; on an
# enforce-ON box that 401s, and the probe read the 401 as UNAVAILABLE ->
# "not one of the stores answered", conflating a missing credential with a down
# store. Now count_store presents the install's -K config and returns AUTH /
# TRANSPORT sentinels that the aggregate verdict adjudicates:
#
#   401 WITH a credential presented   -> FAIL        (a key the store refuses is real)
#   401 with NO usable credential     -> CANNOT-RUN  (keyless, coverage not measured)
#   000 (no HTTP status at all)       -> CANNOT-RUN  (transport failure)
#
# Every arm asserts the VERDICT REASON, never the exit code alone. A #1284
# mutation arm proves the literal-$HOME -K path is caught. python3 fake Qdrant
# on loopback + a controlled -K config; no real store, no ssh; bash 3.2.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${HERE}/../box_walk_probes/probes/ingest_coverage.sh"
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t ingcov)"
MUT="$(dirname "$PROBE")/.mutant_ingest_$$.sh"
trap 'kill "${FAKE_PID:-}" 2>/dev/null; rm -rf "$WORK"; rm -f "$MUT"' EXIT

FAILURES=""
note() { printf '  %s\n' "$1"; }
fail() { FAILURES="${FAILURES} $1"; printf '  FAIL [%s]: %s\n' "$1" "$2"; }

FAKE_PY="${WORK}/fake_qdrant.py"
cat > "$FAKE_PY" <<'PY'
import http.server, os, sys
CODE = int(os.environ.get("FAKE_CODE", "401"))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(CODE)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":{"error":"Unauthorized"}}' if CODE == 401 else b'{"status":"ok","result":{"points_count":1}}')
srv = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
srv.serve_forever()
PY

start_fake() { FAKE_CODE="$2" python3 "$FAKE_PY" "$1" >/dev/null 2>&1 & FAKE_PID=$!
    local i=0; while [ $i -lt 50 ]; do curl -s -o /dev/null -m 1 "http://127.0.0.1:$1/" 2>/dev/null && return 0; i=$((i+1)); sleep 0.05 2>/dev/null || true; done; }
stop_fake() { kill "${FAKE_PID:-}" 2>/dev/null; FAKE_PID=""; }

OK_PORT=16333
CLOSED_PORT=16399

run_probe_capture() { # $1 qdrant url  $2 conf path  $3 auth|noauth  $4 probe
    local url="$1" confpath="$2" mode="$3" probe="${4:-$PROBE}" realconf
    realconf="$(HOME="$WORK" bash -lc "printf '%s' \"$confpath\"")"
    mkdir -p "$(dirname "$realconf")"
    case "$mode" in
        auth)       printf 'header = "Authorization: Bearer t"\n' > "$realconf" ;;
        unreadable) printf 'header = "Authorization: Bearer t"\n' > "$realconf"; chmod 000 "$realconf" ;;
        absent)     rm -f "$realconf" ;;
        *)          : > "$realconf" ;;
    esac
    HOME="$WORK" OSTLER_QDRANT_URL="$url" OSTLER_PROBE_STORE_CURL_CONF="$confpath" \
        OSTLER_INGEST_BASELINE="${WORK}/baseline.tsv" OSTLER_BOX_HOST="" bash "$probe" 2>&1
}
verdict_of() { printf '%s' "$1" | grep -oE 'VERDICT: (PASS|FAIL|CANNOT-RUN|BROKEN)' | head -1; }

printf 'test_ingest_coverage_probe\n'

start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}" "${WORK}/conf_auth" auth)"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: FAIL" ]; then fail arm1 "401+cred got '${V}', expected FAIL"
elif [ "$(printf '%s' "$OUT" | grep -cF 'store credential presented')" -eq 0 ]; then fail arm1-reason "FAIL but reason does not name the presented key"
else note "arm1 401+cred -> FAIL, reason names presented key ✅"; fi

start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}" "${WORK}/conf_noauth" noauth)"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm2 "401+nocred got '${V}', expected CANNOT-RUN"
elif [ "$(printf '%s' "$OUT" | grep -cF 'NO store credential')" -eq 0 ]; then fail arm2-reason "CANNOT-RUN but reason does not say credential absent"
else note "arm2 401+nocred -> CANNOT-RUN, keyless ✅"; fi

OUT="$(run_probe_capture "http://127.0.0.1:${CLOSED_PORT}" "${WORK}/conf_auth" auth)"
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm3 "000 got '${V}', expected CANNOT-RUN"
elif [ "$(printf '%s' "$OUT" | grep -cF 'no HTTP response')" -eq 0 ]; then fail arm3-reason "CANNOT-RUN but reason not a transport failure"
else note "arm3 000 transport -> CANNOT-RUN ✅"; fi

# #1284: literal-$HOME conf. Fixed probe expands it (STORE_CONF_PATH) -> presents key -> 401 -> FAIL.
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}" '$HOME/conf_home' auth)"; stop_fake
V="$(verdict_of "$OUT")"
[ "$V" = "VERDICT: FAIL" ] && note "arm4a fixed expands \$HOME conf -> FAIL ✅" || fail arm4a "fixed literal-\$HOME got '${V}', expected FAIL"
# mutant: -K on literal STORE_CURL_CONF -> curl rc=26 -> TRANSPORT -> CANNOT-RUN, never FAIL
sed "s/-K '\${STORE_CONF_PATH}'/-K '\${STORE_CURL_CONF}'/" "$PROBE" > "$MUT"
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}" '$HOME/conf_home' auth "$MUT")"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" = "VERDICT: FAIL" ]; then fail arm4b-mutant-FAIL "#1284 mutant produced FAIL -- literal-\$HOME -K not caught"
elif [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm4b "#1284 mutant got '${V}', expected CANNOT-RUN"
else note "arm4b #1284 mutant -> CANNOT-RUN (transport), not a false FAIL ✅"; fi


# ARM 5: ABSENT conf -> keyless -> CANNOT-RUN that NAMES absence, not "empty".
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}" "${WORK}/conf_absent" absent)"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm5-absent "got '${V}', expected CANNOT-RUN"
elif [ "$(printf '%s' "$OUT" | grep -cF 'does not exist')" -eq 0 ]; then fail arm5-absent-reason "absent conf reported as something other than absence -- residual-a collapse"
else note "arm5 absent conf -> CANNOT-RUN, reason names absence ✅"; fi

# ARM 6: POPULATED-but-UNREADABLE conf (0600 owner-only, wrong account) -> must
# read as a PERMISSION problem, never as "empty". This is the #549/#550 misread
# TNM named: a probe running as a second account gets denied on a file full of
# headers, and the walk record must not tell a tired human the credential is empty.
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}" "${WORK}/conf_noread" unreadable)"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm6-unreadable "got '${V}', expected CANNOT-RUN"
elif [ "$(printf '%s' "$OUT" | grep -cF 'not readable')" -eq 0 ]; then fail arm6-unreadable-reason "populated unreadable conf reported as empty, not as denied -- the exact residual-a defect"
else note "arm6 unreadable populated conf -> CANNOT-RUN, reason names permission not emptiness ✅"; fi

echo
[ -n "$FAILURES" ] && { printf 'RESULT: FAILURES ->%s\n' "$FAILURES"; exit 1; }
printf 'RESULT: all arms passed\n'
