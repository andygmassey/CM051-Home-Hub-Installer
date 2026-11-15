#!/usr/bin/env bash
# test_two_cards_probe_refuses_a_vacuous_pass.sh
# ============================================================================
# no_person_holds_two_contact_cards used to print PASS on a graph with ONE
# icloud_contact_uid and ZERO merge chances (nothing could have been
# over-merged). Walks of v1.0.111 and v1.0.112 recorded that as a pass, and the
# regression triage then used it as a baseline.
#
# Arms (a fake Oxigraph on loopback answers each query with planted counts):
#   1  one distinct uid, no candidate pairs        -> CANNOT-RUN, denominator printed
#   2  two distinct uids, no candidate pairs       -> CANNOT-RUN, denominator printed
#   3  NEGATIVE: three uids, candidate pairs, 0 violations -> still PASS
# Synthetic only. No store, no box, no ssh. Runs under bash 3.2.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${HERE}/../box_walk_probes/probes/no_person_holds_two_contact_cards.sh"
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t tcvp)"
trap 'kill "${FAKE_PID:-}" 2>/dev/null; rm -rf "$WORK"' EXIT

FAILURES=0
bad()  { FAILURES=$((FAILURES+1)); printf '  FAIL [%s]: %s\n' "$1" "$2"; }
ok()   { printf '  ok   [%s]\n' "$1"; }

cat > "${WORK}/fake.py" <<'PY'
import http.server, json, os, sys, urllib.parse
CONTROL = os.environ["F_CONTROL"]
UIDS = os.environ["F_UIDS"]
OPP = os.environ["F_OPP"]
def body(var, val):
    return {"head": {"vars": [var]}, "results": {"bindings": [{var: {"type": "literal", "value": val}}]}}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("query", [""])[0]
        if "HAVING (COUNT(DISTINCT ?h) > 1)" in q:
            out = body("n", OPP)
        elif "HAVING" in q:
            out = {"head": {"vars": ["person", "uids"]}, "results": {"bindings": []}}
        elif "AS ?uidn" in q:
            out = body("uidn", UIDS)
        elif "COUNT(DISTINCT ?i)" in q:
            out = body("n", CONTROL)
        else:
            out = body("n", "0")
        b = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/sparql-results+json")
        self.end_headers()
        self.wfile.write(b)
srv = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
srv.serve_forever()
PY

PORT=17881
run() { # $1 control  $2 distinct uids  $3 opportunity
    F_CONTROL="$1" F_UIDS="$2" F_OPP="$3" python3 "${WORK}/fake.py" "$PORT" >/dev/null 2>&1 &
    FAKE_PID=$!
    local i=0
    while [ $i -lt 60 ]; do
        curl -s -o /dev/null -m 1 "http://127.0.0.1:${PORT}/" 2>/dev/null && break
        i=$((i+1)); python3 -c 'import time;time.sleep(0.05)'
    done
    printf 'header = "Authorization: Bearer testtoken"\n' > "${WORK}/conf"
    HOME="$WORK" OSTLER_OXIGRAPH_URL="http://127.0.0.1:${PORT}/query" \
        OSTLER_PROBE_STORE_CURL_CONF="${WORK}/conf" OSTLER_BOX_HOST="" \
        bash "$PROBE" 2>&1
    kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; FAKE_PID=""
}
verdict_of() { printf '%s' "$1" | grep -oE 'VERDICT: (PASS|FAIL|CANNOT-RUN|BROKEN)' | head -1; }

printf 'test_two_cards_probe_refuses_a_vacuous_pass\n'

OUT="$(run 1 1 0)"; V="$(verdict_of "$OUT")"
[ "$V" = "VERDICT: CANNOT-RUN" ] && ok arm1-verdict || bad arm1-one-uid-zero-pairs "got '${V}', expected CANNOT-RUN. $(printf '%s' "$OUT" | tail -1 | cut -c1-160)"
printf '%s' "$OUT" | grep -qF 'EXAMINED: 1 ' && ok arm1-denominator-uids || bad arm1-denominator "no 'EXAMINED: 1 ' line (distinct uid count) in output"
printf '%s' "$OUT" | grep -qF 'candidate' && ok arm1-denominator-pairs || bad arm1-pairs "output does not state the candidate pair count"

OUT="$(run 2 2 0)"; V="$(verdict_of "$OUT")"
[ "$V" = "VERDICT: CANNOT-RUN" ] && ok arm2-verdict || bad arm2-two-uids-zero-pairs "got '${V}', expected CANNOT-RUN. $(printf '%s' "$OUT" | tail -1 | cut -c1-160)"

OUT="$(run 3 3 4)"; V="$(verdict_of "$OUT")"
[ "$V" = "VERDICT: PASS" ] && ok arm3-negative-real-fixture-passes || bad arm3-negative "3 uids + 4 candidate nodes + 0 violations got '${V}', expected PASS. $(printf '%s' "$OUT" | tail -1 | cut -c1-160)"

if [ "$FAILURES" -eq 0 ]; then printf 'PASS: 0 failures\n'; exit 0; fi
printf 'FAIL: %d failure(s)\n' "$FAILURES"; exit 1
