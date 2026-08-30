#!/usr/bin/env bash
# test_no_person_holds_two_contact_cards_probe.sh
# ============================================================================
# Proves the store-credential + transport-guard + three-part-401 adjudication
# added to no_person_holds_two_contact_cards.sh. The probe used to query
# Oxigraph BARE; on an enforce-ON box that 401s, and the probe read the empty
# body as "UNAVAILABLE" -> CANNOT-RUN blaming the store's reachability. Now it
# presents the install's own -K config and separates:
#
#   401 WITH a credential presented   -> FAIL        (a key the store refuses is real)
#   401 with NO usable credential     -> CANNOT-RUN  (keyless, nothing measured)
#   000 (no HTTP status at all)       -> CANNOT-RUN  (transport failure)
#
# Every arm asserts on the VERDICT REASON, never on the exit code alone: FAIL
# and the two CANNOT-RUNs are distinguishable only by their reason string, which
# is exactly the trap (#574/#1284/#1285) that shipped a false FAIL on the first
# real walk. A #1284 mutation arm proves the literal-$HOME path is caught.
#
# No real store, no box, no ssh: a python3 fake Oxigraph on loopback and a
# controlled fake -K config. Runs under bash 3.2.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${HERE}/../box_walk_probes/probes/no_person_holds_two_contact_cards.sh"
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t nptcc)"
trap 'kill "${FAKE_PID:-}" 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=""
note() { printf '  %s\n' "$1"; }
fail() { FAILURES="${FAILURES} $1"; printf '  FAIL [%s]: %s\n' "$1" "$2"; }

# --- fake Oxigraph -----------------------------------------------------------
# Answers with a fixed HTTP status from $FAKE_MODE. 401 for the auth arms; for a
# 000 arm we do NOT start it and point the probe at a closed port instead.
FAKE_PY="${WORK}/fake_oxigraph.py"
cat > "$FAKE_PY" <<'PY'
import http.server, os, sys
CODE = int(os.environ.get("FAKE_CODE", "401"))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(CODE)
        self.send_header("Content-Type", "application/sparql-results+json")
        self.end_headers()
        self.wfile.write(b'{"error":"unauthorized"}' if CODE == 401 else b'{}')
    do_POST = do_GET
srv = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
srv.serve_forever()
PY

start_fake() { # $1 = port, $2 = code
    FAKE_CODE="$2" python3 "$FAKE_PY" "$1" >/dev/null 2>&1 &
    FAKE_PID=$!
    # wait for the port
    local i=0
    while [ $i -lt 50 ]; do
        if curl -s -o /dev/null -m 1 "http://127.0.0.1:$1/" 2>/dev/null; then return 0; fi
        i=$((i+1)); sleep 0.05 2>/dev/null || python3 -c 'import time;time.sleep(0.05)'
    done
    return 0
}
stop_fake() { kill "${FAKE_PID:-}" 2>/dev/null; FAKE_PID=""; }

# free-ish loopback ports
OK_PORT=17878
CLOSED_PORT=17999   # nothing listens here -> connection refused -> curl 000

# --- run the probe in a controlled environment, capture VERDICT --------------
# $1 = oxigraph url, $2 = store-curl.conf path (may contain a literal $HOME),
# $3 = "auth" to plant a header line in the conf / "noauth" to leave it empty,
# $4 = probe path (so a mutated copy can be passed)
run_probe_capture() {
    local url="$1" confpath="$2" mode="$3" probe="${4:-$PROBE}"
    # HOME is the WORK dir so a literal '$HOME/...' conf path resolves here.
    local realconf; realconf="$(HOME="$WORK" bash -lc "printf '%s' \"$confpath\"")"
    mkdir -p "$(dirname "$realconf")"
    if [ "$mode" = "auth" ]; then
        printf 'header = "Authorization: Bearer testtoken"\n' > "$realconf"
    else
        : > "$realconf"   # exists but zero header lines -> STORE_AUTH stays ""
    fi
    HOME="$WORK" \
    OSTLER_OXIGRAPH_URL="$url" \
    OSTLER_PROBE_STORE_CURL_CONF="$confpath" \
    OSTLER_BOX_HOST="" \
    bash "$probe" 2>&1
}

verdict_of() { printf '%s' "$1" | grep -oE 'VERDICT: (PASS|FAIL|CANNOT-RUN|BROKEN)' | head -1; }

printf 'test_no_person_holds_two_contact_cards_probe\n'

# ── ARM 1: 401 + credential presented -> FAIL, reason names the presented key ─
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}/query" "${WORK}/conf_auth" auth)"
stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: FAIL" ]; then
    fail arm1-401-cred-not-FAIL "got '${V}', expected FAIL. output: $(printf '%s' "$OUT" | tail -1)"
elif [ "$(printf '%s' "$OUT" | grep -cF 'store credential presented')" -eq 0 ]; then
    fail arm1-reason "FAIL but reason does not name the presented credential -- an exit-code-only pass"
else
    note "arm1 401+cred -> FAIL, reason names the presented key ✅"
fi

# ── ARM 2: 401 + NO credential -> CANNOT-RUN, reason = keyless/nothing measured ─
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}/query" "${WORK}/conf_noauth" noauth)"
stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: CANNOT-RUN" ]; then
    fail arm2-401-nocred-not-CANNOTRUN "got '${V}', expected CANNOT-RUN"
elif [ "$(printf '%s' "$OUT" | grep -cF 'NO store credential')" -eq 0 ]; then
    fail arm2-reason "CANNOT-RUN but reason does not say the credential was absent"
else
    note "arm2 401+nocred -> CANNOT-RUN, reason = keyless nothing measured ✅"
fi

# ── ARM 3: transport 000 (closed port) -> CANNOT-RUN, reason = no HTTP response ─
OUT="$(run_probe_capture "http://127.0.0.1:${CLOSED_PORT}/query" "${WORK}/conf_auth" auth)"
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: CANNOT-RUN" ]; then
    fail arm3-000-not-CANNOTRUN "got '${V}', expected CANNOT-RUN"
elif [ "$(printf '%s' "$OUT" | grep -cF 'no HTTP response')" -eq 0 ]; then
    fail arm3-reason "CANNOT-RUN but reason does not name a transport failure"
else
    note "arm3 000 transport -> CANNOT-RUN, reason = no HTTP response ✅"
fi

# ── ARM 4: #1284 MUTATION. Conf path carries a literal $HOME. The FIXED probe
#    resolves it (STORE_CONF_PATH) so the key is presented and the 401 -> FAIL.
#    The MUTANT (-K on the literal STORE_CURL_CONF) hands curl an unopenable
#    path -> rc=26 -> 000 -> and MUST read as CANNOT-RUN, never a product FAIL.
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}/query" '$HOME/conf_home' auth)"
stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: FAIL" ]; then
    fail arm4-fixed-literalHOME-not-FAIL "fixed probe with a literal-\$HOME conf got '${V}', expected FAIL (STORE_CONF_PATH must expand it)"
else
    note "arm4a fixed probe expands \$HOME conf, presents key, 401 -> FAIL ✅"
fi
# the mutant: -K reads STORE_CURL_CONF (literal) instead of STORE_CONF_PATH.
# It MUST live in the probes/ dir so the probe's `../lib/probe.sh` source
# resolves; dot-prefixed so run_box_walk's *.sh glob never picks it up.
MUT="$(dirname "$PROBE")/.mutant_no_person_$$.sh"
sed "s/-K '\${STORE_CONF_PATH}'/-K '\${STORE_CURL_CONF}'/" "$PROBE" > "$MUT"
trap 'kill "${FAKE_PID:-}" 2>/dev/null; rm -rf "$WORK"; rm -f "$MUT"' EXIT
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}/query" '$HOME/conf_home' auth "$MUT")"
stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" = "VERDICT: FAIL" ]; then
    fail arm4-mutant-still-FAIL "the #1284 mutant produced FAIL -- the literal-\$HOME -K bug is NOT caught (this is the shipped-false-FAIL class)"
elif [ "$V" != "VERDICT: CANNOT-RUN" ]; then
    fail arm4-mutant-not-CANNOTRUN "the #1284 mutant produced '${V}', expected CANNOT-RUN (curl rc=26 -> 000)"
else
    note "arm4b #1284 mutant -> CANNOT-RUN (000), not a false product FAIL ✅ -- the fix is load-bearing"
fi

echo
if [ -n "$FAILURES" ]; then
    printf 'RESULT: FAILURES ->%s\n' "$FAILURES"; exit 1
fi
printf 'RESULT: all arms passed (401+cred FAIL / 401+nocred CANNOT-RUN / 000 CANNOT-RUN / #1284 mutant caught)\n'
