#!/usr/bin/env bash
# test_walk_probes_l3_and_maps.sh -- drives the two thin-walk probes added for #2435 and #2528 end to end:
#   l3_not_prefetched                       against a loopback fake Hub/Qdrant/embedder (leak, clean, blind modes)
#   wiki_maps_links_carry_no_join_secret    against fixture wiki trees through the REAL run_probe (no docker started)
# plus the wiring checks (scope row, walk glob) and one mutant per probe. Synthetic data only. HOME is a temp dir.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
P="${ROOT}/scripts/box_walk_probes"
T="$(mktemp -d)"
FAKE_PID=""
cleanup() { [ -n "${FAKE_PID}" ] && kill "${FAKE_PID}" 2>/dev/null; rm -rf "${T}"; }
trap cleanup EXIT
export HOME="${T}/home"; mkdir -p "${HOME}"
export NO_PROXY=127.0.0.1,localhost; unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY
unset OSTLER_BOX_HOST
FAILS=0; N=0
ok() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "  ok   $1 (rc=$3)"; else echo "  FAIL $1: want rc=$2 got rc=$3"; FAILS=$((FAILS+1)); fi; }
has() { N=$((N+1)); if printf '%s' "$2" | /usr/bin/grep -q -- "$3"; then echo "  ok   $1"; else echo "  FAIL $1: output lacks '$3'"; FAILS=$((FAILS+1)); fi; }

cat > "${T}/fake.py" <<'PY'
import json, os, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
MODE = sys.argv[1]
PTS = {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj, code=200):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/collections/people":
            return self._send({"result": {"config": {"params": {"vectors": {"size": 4}}}}})
        if u.path == "/api/v1/people/search":
            q = urllib.parse.parse_qs(u.query)["q"][0].lower()
            res = []
            for p in PTS.values():
                pl = p["payload"]
                hay = " ".join([pl["display_name"], pl["organization"]] + pl["emails"]).lower()
                if MODE == "blind" or q not in hay: continue
                if pl["privacy_level"] == "L3" and MODE != "leak": continue   # ical-server.py:2251
                res.append({"name": pl["display_name"], "person_uri": pl["person_uri"]})
            return self._send({"results": res})
        self._send({}, 404)
    def do_PUT(self):
        for p in self._body()["points"]: PTS[p["id"]] = p
        self._send({"result": {}})
    def do_POST(self):
        u = urllib.parse.urlparse(self.path); b = self._body()
        if u.path == "/api/embed": return self._send({"embeddings": [[0.1, 0.2, 0.3, 0.4]]})
        if u.path.endswith("/points/delete"):
            for i in b["points"]: PTS.pop(i, None)
            return self._send({"result": {}})
        if u.path.endswith("/points"):
            return self._send({"result": [{"id": i} for i in b["ids"] if i in PTS]})
        self._send({}, 404)
s = HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY

run_l3() {  # $1 mode, $2 lib dir override (optional)
    python3 "${T}/fake.py" "$1" > "${T}/port" & FAKE_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "${T}/port" ] && break; sleep 0.3; done
    local port; port="$(cat "${T}/port")"; : > "${T}/store.conf"
    local base="http://127.0.0.1:${port}"
    OUT="$(env OSTLER_PROBE_API_BASE="${base}" OSTLER_PROBE_QDRANT_BASE="${base}" OSTLER_PROBE_EMBED_BASE="${base}" \
        OSTLER_SERVICE_TOKEN=synthetic OSTLER_PROBE_STORE_CURL_CONF="${T}/store.conf" \
        bash "${2:-${P}}/probes/l3_not_prefetched.sh" 2>&1)"; RC=$?
    kill "${FAKE_PID}" 2>/dev/null; FAKE_PID=""; : > "${T}/port"
}

echo "== 2435 l3_not_prefetched"
run_l3 clean;  ok "clean hub: L3 withheld, control seen -> PASS" 0 "${RC}"; has "PASS names the denominator" "${OUT}" "l3_leaks=0"
run_l3 leak;   ok "RED: hub returns the L3 person -> FAIL" 1 "${RC}";        has "FAIL line names the shapes" "${OUT}" "FAIL the L3 person was returned"
run_l3 blind;  ok "blind: hub finds nobody -> CANNOT-RUN, never PASS" 78 "${RC}"
bash "${P}/probes/l3_not_prefetched.sh" --self-test >/dev/null 2>&1; ok "--self-test is red (runner demands 1)" 1 $?

echo "== 2435 mutant: judge ignores a leak"
MP="${T}/mut_l3"; mkdir -p "${MP}"; cp -R "${P}/probes" "${P}/lib" "${MP}/"
sed -i.bak 's/if q\["subject"\] == "l3" and l3_uri in q\["returned_uris"\]/if False/' "${MP}/lib/l3_prefetch.py"
cmp -s "${MP}/lib/l3_prefetch.py" "${P}/lib/l3_prefetch.py" && { echo "  FAIL mutation did not apply"; FAILS=$((FAILS+1)); }
run_l3 leak "${MP}"; N=$((N+1)); if [ "${RC}" -ne 1 ]; then echo "  ok   mutant is caught: leak no longer FAIL (rc=${RC})"; else echo "  FAIL mutant survived: still FAIL"; FAILS=$((FAILS+1)); fi
python3 "${MP}/lib/l3_prefetch.py" --self-test >/dev/null 2>&1; ok "mutant also turns the judge self-test red" 1 $?

echo "== 2528 wiki_maps_links_carry_no_join_secret"
run_maps() { OUT="$(env OSTLER_WIKI_EXEC= OSTLER_WIKI_DOCS_ROOT="$1" bash "${2:-${P}}/probes/wiki_maps_links_carry_no_join_secret.sh" 2>&1)"; RC=$?; }
run_maps "${P}/fixtures/maps_href/bad";  ok "RED: seeded passcode maps links -> FAIL" 1 "${RC}"; has "caught both seeded links" "${OUT}" "maps_urls_with_pwd_or_passcode=2"
run_maps "${P}/fixtures/maps_href/good"; ok "clean pages -> PASS" 0 "${RC}"
mkdir -p "${T}/empty"; run_maps "${T}/empty"; ok "no pages scanned -> CANNOT-RUN, never PASS" 78 "${RC}"
bash "${P}/probes/wiki_maps_links_carry_no_join_secret.sh" --self-test >/dev/null 2>&1; ok "--self-test is red (runner demands 1)" 1 $?

echo "== 2528 mutant: judge only knows pwd="
MM="${T}/mut_maps"; mkdir -p "${MM}"; cp -R "${P}/probes" "${P}/lib" "${P}/fixtures" "${MM}/"
sed -i.bak 's/(?:pwd|passcode)/(?:pwd)/' "${MM}/lib/maps_href_secrets.py"
cmp -s "${MM}/lib/maps_href_secrets.py" "${P}/lib/maps_href_secrets.py" && { echo "  FAIL mutation did not apply"; FAILS=$((FAILS+1)); }
run_maps "${P}/fixtures/maps_href/bad" "${MM}"; N=$((N+1)); if [ "${RC}" -eq 1 ]; then echo "  ok   mutant is caught: the instrument's own control fails (rc=1, ${OUT##*VERDICT: })"; else echo "  FAIL mutant survived (rc=${RC})"; FAILS=$((FAILS+1)); fi
has "mutant fails on the control, not on the subject" "${OUT}" "positive control was not caught"

echo "== wiring"
for n in l3_not_prefetched wiki_maps_links_carry_no_join_secret; do
    N=$((N+1)); if /usr/bin/grep -q "^${n}	" "${ROOT}/scripts/walk_promote_scope.tsv"; then echo "  ok   ${n} has a promote-scope row"; else echo "  FAIL ${n} has no scope row (fail-closed blocking, but undeclared)"; FAILS=$((FAILS+1)); fi
    N=$((N+1)); if [ -x "${P}/probes/${n}.sh" ] && /usr/bin/grep -q 'for f in "\$PROBE_DIR"/\*.sh' "${P}/run_box_walk.sh"; then echo "  ok   ${n}.sh is executable and inside the walk glob"; else echo "  FAIL ${n} is outside the walk glob"; FAILS=$((FAILS+1)); fi
done

echo "RESULT: ${N} checks, ${FAILS} failed"
[ "${FAILS}" -eq 0 ]
