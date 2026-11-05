#!/usr/bin/env bash
# test_walk_probe_core_memory_prefetch.sh -- drives core_memory_holds_no_prefetch_block (#2436) end to end through the
# REAL run_probe against a loopback stand-in for the daemon's GET /api/memory (clean, leak, empty, 401, ignored-filter
# modes), plus one mutant (the marker predicate blinded) and the wiring checks. Synthetic data only; HOME is a temp dir.
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
lacks() { N=$((N+1)); if printf '%s' "$2" | /usr/bin/grep -q -- "$3"; then echo "  FAIL $1: output carries '$3'"; FAILS=$((FAILS+1)); else echo "  ok   $1"; fi; }

cat > "${T}/fake.py" <<'PY'
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
MODE = sys.argv[1]
BLOCK = "\n\n[Looked up in the user's own data before answering (pwg_people {}):\nPerson: ZZ-CANARY-2436\n"
CORE = [{"key": "core_a1", "category": "core", "content": "User moved to a new flat."},
        {"key": "core_b2", "category": "core", "content": "User prefers tea."}]
if MODE == "leak":
    CORE.append({"key": "core_c3", "category": "core", "content": "User asked about a friend." + BLOCK})
DAILY = [{"key": "daily_x", "category": "daily", "content": "Talked about the flat."}]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj, code=200):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if self.headers.get("Authorization") != "Bearer synthetic-admin":
            return self._send({"error": "unauthorized"}, 401)
        if MODE == "unauth":
            return self._send({"error": "unauthorized"}, 401)
        if u.path != "/api/memory":
            return self._send({}, 404)
        cat = urllib.parse.parse_qs(u.query).get("category", [""])[0]
        if MODE == "empty":
            return self._send({"entries": []})
        if MODE == "nofilter":
            return self._send({"entries": CORE + DAILY})
        return self._send({"entries": CORE if cat == "core" else DAILY if cat == "daily" else CORE + DAILY})
s = HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY
mkdir -p "${T}/secrets"; printf 'synthetic-admin\n' > "${T}/secrets/admin_token"

run_mem() {  # $1 mode, $2 probes dir override (optional)
    python3 "${T}/fake.py" "$1" > "${T}/port" & FAKE_PID=$!
    for _ in $(seq 1 150); do [ -s "${T}/port" ] && break; sleep 0.2; done
    local port; port="$(cat "${T}/port")"
    if [ -z "${port}" ]; then N=$((N+1)); echo "  FAIL stand-in ($1) never reported a port in 30s: harness fault, not a probe verdict"; FAILS=$((FAILS+1)); fi
    OUT="$(env OSTLER_PROBE_GATEWAY="http://127.0.0.1:${port}" OSTLER_PROBE_TOKEN_PATH="${T}/secrets/admin_token" \
        OSTLER_PROMOTE_SCOPE_FILE="${T}/scope.tsv" \
        bash "${2:-${P}}/probes/core_memory_holds_no_prefetch_block.sh" 2>&1)"; RC=$?
    kill "${FAKE_PID}" 2>/dev/null; wait "${FAKE_PID}" 2>/dev/null; FAKE_PID=""; : > "${T}/port"
}
# Graded as BLOCKING here (empty scope file = fail-closed), so the RED arm must exit 1.
: > "${T}/scope.tsv"

echo "== 2436 core_memory_holds_no_prefetch_block"
run_mem clean;    ok "clean core memories -> PASS" 0 "${RC}"; has "PASS names the denominator" "${OUT}" "EXAMINED: 2 core_"
run_mem leak;     ok "RED: a core entry carries the prefetch block -> FAIL" 1 "${RC}"; has "FAIL names the key" "${OUT}" "core_c3"
lacks "FAIL never prints the memory content" "${OUT}" "ZZ-CANARY-2436"
run_mem empty;    ok "zero core entries -> CANNOT-RUN, never PASS" 78 "${RC}"
run_mem unauth;   ok "gateway refuses the token -> CANNOT-RUN" 78 "${RC}"; has "CANNOT names the HTTP status" "${OUT}" "HTTP 401"
run_mem nofilter; ok "category filter ignored -> CANNOT-RUN" 78 "${RC}"
env OSTLER_PROBE_TOKEN_PATH="${T}/secrets/missing" bash "${P}/probes/core_memory_holds_no_prefetch_block.sh" >/dev/null 2>&1
ok "token file missing -> CANNOT-RUN" 78 $?
bash "${P}/probes/core_memory_holds_no_prefetch_block.sh" --self-test >/dev/null 2>&1; ok "--self-test is red (runner demands 1)" 1 $?

echo "== 2436 mutant: the marker predicate is blinded"
MP="${T}/mut"; mkdir -p "${MP}"; cp -R "${P}/probes" "${P}/lib" "${MP}/"
sed -i.bak 's/return any(m in t for m in MARKERS)/return False/' "${MP}/lib/core_memory_prefetch.py"
cmp -s "${MP}/lib/core_memory_prefetch.py" "${P}/lib/core_memory_prefetch.py" && { N=$((N+1)); echo "  FAIL mutation did not apply"; FAILS=$((FAILS+1)); }
run_mem leak "${MP}"; N=$((N+1)); if [ "${RC}" -ne 1 ]; then echo "  ok   mutant is caught: the leak is no longer FAIL (rc=${RC})"; else echo "  FAIL mutant survived: still FAIL"; FAILS=$((FAILS+1)); fi
python3 "${MP}/lib/core_memory_prefetch.py" --self-test >/dev/null 2>&1; ok "mutant also turns the judge self-test red" 1 $?

echo "== wiring"
n=core_memory_holds_no_prefetch_block
N=$((N+1)); if /usr/bin/grep -q "^${n}	" "${ROOT}/scripts/walk_promote_scope.tsv"; then echo "  ok   ${n} has a promote-scope row"; else echo "  FAIL ${n} has no scope row"; FAILS=$((FAILS+1)); fi
N=$((N+1)); if /usr/bin/grep -q "probe: \"${n}\"" "${ROOT}/cut-manifests/permanent.yaml"; then echo "  ok   ${n} has a permanent.yaml row"; else echo "  FAIL ${n} has no permanent.yaml row"; FAILS=$((FAILS+1)); fi
N=$((N+1)); if [ -x "${P}/probes/${n}.sh" ] && /usr/bin/grep -q 'for f in "\$PROBE_DIR"/\*.sh' "${P}/run_box_walk.sh"; then echo "  ok   ${n}.sh is executable and inside the walk glob"; else echo "  FAIL ${n} is outside the walk glob"; FAILS=$((FAILS+1)); fi

echo "RESULT: ${N} checks, ${FAILS} failed"
[ "${FAILS}" -eq 0 ]
