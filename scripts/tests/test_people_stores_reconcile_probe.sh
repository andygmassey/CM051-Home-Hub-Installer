#!/usr/bin/env bash
# test_people_stores_reconcile_probe.sh
# ============================================================================
# Proves the store-credential + three-part-401 adjudication added to
# people_stores_reconcile.sh. This probe reads both stores via python urllib in
# a box_run heredoc, so the credential is parsed from the install curl config and
# injected as request headers, and a 401 is split INSIDE the payload:
#   AUTHFAIL (credential presented + refused) -> FAIL
#   KEYLESS  (no credential presented)        -> CANNOT-RUN
# A closed port is a urllib URLError -> the existing CANNOTRUN path. The #1284
# analogue: passing the literal STORE_CURL_CONF (unexpanded $HOME) means the box
# python cannot open the config -> HAVE_CRED false -> KEYLESS -> CANNOT-RUN, never
# a false product FAIL. Asserts on the REASON. python3 fake Oxigraph; bash 3.2.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${HERE}/../box_walk_probes/probes/people_stores_reconcile.sh"
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t psr)"
MUT="$(dirname "$PROBE")/.mutant_psr_$$.sh"
trap 'kill "${FAKE_PID:-}" 2>/dev/null; rm -rf "$WORK"; rm -f "$MUT"' EXIT
FAILURES=""
note() { printf '  %s\n' "$1"; }
fail() { FAILURES="${FAILURES} $1"; printf '  FAIL [%s]: %s\n' "$1" "$2"; }

FAKE_PY="${WORK}/fake_oxigraph.py"
cat > "$FAKE_PY" <<'PY'
import http.server, os, sys
CODE = int(os.environ.get("FAKE_CODE", "401"))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(CODE); self.send_header("Content-Type","application/sparql-results+json"); self.end_headers()
        self.wfile.write(b'{"error":"unauthorized"}' if CODE==401 else b'{}')
    do_POST = do_GET
srv = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H); srv.serve_forever()
PY
start_fake() { FAKE_CODE="$2" python3 "$FAKE_PY" "$1" >/dev/null 2>&1 & FAKE_PID=$!
    local i=0; while [ $i -lt 50 ]; do curl -s -o /dev/null -m 1 "http://127.0.0.1:$1/" 2>/dev/null && return 0; i=$((i+1)); sleep 0.05 2>/dev/null || true; done; }
stop_fake() { kill "${FAKE_PID:-}" 2>/dev/null; FAKE_PID=""; }
OK_PORT=17878; CLOSED_PORT=17999
run_probe_capture() { # url conf mode probe
    local url="$1" confpath="$2" mode="$3" probe="${4:-$PROBE}" realconf
    realconf="$(HOME="$WORK" bash -lc "printf '%s' \"$confpath\"")"; mkdir -p "$(dirname "$realconf")"
    if [ "$mode" = "auth" ]; then printf 'header = "Authorization: Bearer testtoken"\n' > "$realconf"; else : > "$realconf"; fi
    HOME="$WORK" OSTLER_OXIGRAPH_URL="$url" OSTLER_QDRANT_URL="http://127.0.0.1:${CLOSED_PORT}" \
        OSTLER_PROBE_STORE_CURL_CONF="$confpath" OSTLER_BOX_HOST="" bash "$probe" 2>&1
}
verdict_of() { printf '%s' "$1" | grep -oE 'VERDICT: (PASS|FAIL|CANNOT-RUN|BROKEN)' | head -1; }

printf 'test_people_stores_reconcile_probe\n'

start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}/query" "${WORK}/conf_auth" auth)"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: FAIL" ]; then fail arm1 "401+cred got '${V}', expected FAIL. tail: $(printf '%s' "$OUT"|tail -1)"
elif [ "$(printf '%s' "$OUT" | grep -cF 'store credential presented')" -eq 0 ]; then fail arm1-reason "FAIL but reason does not name presented key"
else note "arm1 401+cred -> AUTHFAIL -> FAIL ✅"; fi

start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}/query" "${WORK}/conf_noauth" noauth)"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm2 "401+nocred got '${V}', expected CANNOT-RUN"
elif [ "$(printf '%s' "$OUT" | grep -cF 'NO store credential')" -eq 0 ]; then fail arm2-reason "reason does not say credential absent"
else note "arm2 401+nocred -> KEYLESS -> CANNOT-RUN ✅"; fi

OUT="$(run_probe_capture "http://127.0.0.1:${CLOSED_PORT}/query" "${WORK}/conf_auth" auth)"
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm3 "transport got '${V}', expected CANNOT-RUN"
else note "arm3 transport (closed port) -> URLError -> CANNOT-RUN ✅"; fi

start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}/query" '$HOME/conf_home' auth)"; stop_fake
V="$(verdict_of "$OUT")"
[ "$V" = "VERDICT: FAIL" ] && note "arm4a fixed expands \$HOME conf -> FAIL ✅" || fail arm4a "fixed literal-\$HOME got '${V}', expected FAIL"
sed "s/'\${STORE_CONF_PATH}'/'\${STORE_CURL_CONF}'/" "$PROBE" > "$MUT"
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}/query" '$HOME/conf_home' auth "$MUT")"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" = "VERDICT: FAIL" ]; then fail arm4b-mutant-FAIL "#1284 analogue mutant produced FAIL -- literal-\$HOME conf not caught"
elif [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm4b "#1284 mutant got '${V}', expected CANNOT-RUN"
else note "arm4b #1284 analogue mutant -> KEYLESS -> CANNOT-RUN, not a false FAIL ✅"; fi

echo
[ -n "$FAILURES" ] && { printf 'RESULT: FAILURES ->%s\n' "$FAILURES"; exit 1; }
printf 'RESULT: all arms passed\n'
