#!/usr/bin/env bash
# scripts/tests/test_people_seed_and_retrieval_probe.sh
# ============================================================================
# Proves the people_seed_and_retrieval box-walk probe FIRES.
#
# The probe it guards shipped as `exit 0` from v1.0.12 onward. A gate with no
# demonstrated RED is indistinguishable from that stub, so this test drives the
# real probe against a controllable fake box and asserts it goes RED on every
# way the round-trip can be wrong, and GREEN only when it genuinely works.
#
# The fake implements the surfaces the probe touches -- the loopback Assistant
# API (health, people/context, people/search, memory/assert, people/forget),
# Qdrant, and the Ollama embedder -- behind one port. Each mode is a
# deliberate, single-axis break.
#
# NO REAL DATA: every identity here is constructed. The decoy used to prove the
# wrong-person path is itself synthetic and deliberately NOT on the probe's
# allowlist, so it exercises the masking without carrying the thing the masking
# exists to hunt.
# ============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
PROBE="${REPO}/scripts/box_walk_probes/people_seed_and_retrieval.sh"

if [ ! -f "$PROBE" ]; then
    echo "FAIL: probe not found at ${PROBE}"
    exit 1
fi

WORK="$(mktemp -d -t peopleprobetest)"
FAKE="${WORK}/fake_box.py"

# The fake box is a python3 process. If python3 is missing or broken, every
# scenario fails identically with "never bound a port", which names the SHAPE
# of the failure and not its cause. State the interpreter up front.
echo "harness: python3 = $(command -v python3 || echo '<NOT FOUND>')"
echo "harness: $(python3 --version 2>&1 || echo 'python3 --version FAILED')"
PASSES=0
FAILS=0
SERVER_PID=""

cleanup() {
    if [ -n "${SERVER_PID}" ]; then kill "$SERVER_PID" 2>/dev/null; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$FAKE" <<'FAKEPY'
"""Controllable stand-in for the services the probe touches.

  /api/health[?detailed=1]              Assistant API liveness / dep health
  /api/api/v1/people/context?name=      PRIMARY retrieval route (Oxigraph)
  /api/api/v1/people/search?q=          FALLBACK retrieval route (Qdrant)
  /api/api/v1/memory/assert             seed (mints a Person)
  /api/api/v1/people/<slug>/forget      unseed
  /qdrant/collections/people[...]       collection info / upsert / delete
  /ollama/api/embed                     embeddings

MODE selects one deliberate break. "green" is the honest box.
"""
import json
import os
import re
import sys
import threading
import unicodedata
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

MODE = os.environ.get("MODE", "green")
TOKEN = os.environ.get("FAKE_TOKEN", "")
VECTOR_SIZE = 768

OXI = {}       # slug -> {"name":..., "uri":...}
QDRANT = {}    # id -> point
LOCK = threading.Lock()

# Synthetic decoy. Constructed, and intentionally NOT on the probe's allowlist,
# so the wrong-person path must mask it when printing.
DECOY_NAME = "Gwendolyn Ashcombe-Decoy"
DECOY_URI = "https://pwg.dev/ontology#person_decoy00"


def slugify(name):
    n = unicodedata.normalize("NFKD", name)
    n = "".join(c for c in n if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", "-", n.lower()).strip("-") or "unknown"


def context_payload(name):
    if MODE == "degraded":
        return {"query": name, "found": False, "degraded": True,
                "reason": "HTTPConnectionPool(host='localhost', port=7878)"}
    if MODE == "context_notfound":
        return {"query": name, "found": False,
                "message": "No person found matching '%s'." % name}
    if MODE == "wrong_person":
        return {"query": name, "found": True,
                "person": {"name": DECOY_NAME, "slug": "decoy",
                           "person_uri": DECOY_URI}}
    with LOCK:
        rec = OXI.get(slugify(name))
    if not rec:
        return {"query": name, "found": False,
                "message": "No person found matching '%s'." % name}
    uri = rec["uri"]
    if MODE == "wrong_uri":
        uri = "https://pwg.dev/ontology#person_ffffffff"
    return {"query": name, "found": True,
            "person": {"name": rec["name"], "slug": slugify(rec["name"]),
                       "person_uri": uri}}


def search_payload(q):
    if MODE == "search_empty":
        return {"query": q, "results": [], "count": 0}
    with LOCK:
        pts = list(QDRANT.values())
    out = []
    for p in pts:
        pay = p.get("payload", {})
        if pay.get("contact_type") != "person":
            continue
        nm = pay.get("display_name", "")
        if nm == q:
            score = 1.0
        elif q.lower() in nm.lower() or nm.lower() in q.lower():
            score = 0.7
        else:
            continue
        out.append({"name": nm, "slug": slugify(nm), "score": score,
                    "person_uri": pay.get("person_uri", "")})
    out.sort(key=lambda r: -r["score"])
    return {"query": q, "results": out, "count": len(out)}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj, raw=False):
        body = obj if raw else json.dumps(obj)
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type",
                         "text/html" if raw else "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        if MODE == "no_auth":
            return True
        got = (self.headers.get("Authorization") or "").strip()
        return bool(TOKEN) and got == "Bearer " + TOKEN

    def do_GET(self):
        u = urlparse(self.path)
        path, qs = u.path, parse_qs(u.query)

        # A box that answers every AUTHENTICATED path with a valid-looking
        # people payload. Auth stays enforced so this isolates control C3.
        if MODE == "blanket_200":
            if path.startswith("/api/") and not self._authed() \
                    and path != "/api/health":
                self._send(401, {"error": "unauthorised"})
                return
            if path.startswith("/api/"):
                self._send(200, {"query": "x", "found": False})
                return

        if path == "/api/health":
            if qs.get("detailed"):
                if not self._authed():
                    self._send(401, {"error": "unauthorised"})
                    return
                ok = MODE != "deps_down"
                self._send(200, {"status": "ok" if ok else "error", "checks": {
                    "qdrant": {"ok": ok}, "oxigraph": {"ok": ok},
                    "ollama": {"ok": True}}})
                return
            self._send(200, {"status": "ok"})
            return

        if path == "/api/api/v1/people/context":
            if not self._authed():
                self._send(401, {"error": "unauthorised"})
                return
            self._send(200, context_payload((qs.get("name") or [""])[0]))
            return

        if path == "/api/api/v1/people/search":
            if not self._authed():
                self._send(401, {"error": "unauthorised"})
                return
            self._send(200, search_payload((qs.get("q") or [""])[0]))
            return

        if path == "/qdrant/collections/people":
            if MODE == "no_collection":
                self._send(404, {"status": {"error": "Not found"}})
                return
            self._send(200, {"result": {"config": {"params": {"vectors": {
                "size": VECTOR_SIZE, "distance": "Cosine"}}}}})
            return

        self._send(404, "not found", raw=True)

    def do_PUT(self):
        u = urlparse(self.path)
        if u.path == "/qdrant/collections/people/points":
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(n) or b"{}")
            with LOCK:
                for pt in body.get("points", []):
                    QDRANT[str(pt["id"])] = pt
            self._send(200, {"result": {"status": "completed"}, "status": "ok"})
            return
        self._send(404, "not found", raw=True)

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n) if n else b"{}"

        if u.path == "/api/api/v1/memory/assert":
            if not self._authed():
                self._send(401, {"error": "unauthorised"})
                return
            if MODE == "seed_503":
                self._send(503, {"status": "error", "degraded": True,
                                 "reason": "user_id_not_configured"})
                return
            req = json.loads(raw or b"{}")
            subject = req.get("subject", "")
            slug = slugify(subject)
            with LOCK:
                created = slug not in OXI
                uri = "https://pwg.dev/ontology#person_%08x" % (abs(hash(slug)) & 0xffffffff)
                if created:
                    OXI[slug] = {"name": subject, "uri": uri}
                else:
                    uri = OXI[slug]["uri"]
            self._send(200, {"status": "created_person" if created else "stored",
                             "person_uri": uri, "person_slug": slug,
                             "fact_id": "fact_probe", "wiki_recompile_queued": True})
            return

        if u.path.startswith("/api/api/v1/people/") and u.path.endswith("/forget"):
            if not self._authed():
                self._send(401, {"error": "unauthorised"})
                return
            slug = u.path[len("/api/api/v1/people/"):-len("/forget")]
            if MODE != "leak":
                with LOCK:
                    OXI.pop(slug, None)
            self._send(200, {"forgotten": True, "slug": slug})
            return

        if u.path == "/ollama/api/embed":
            req = json.loads(raw or b"{}")
            text = (req.get("input") or [""])[0]
            # Deterministic, correctly-sized vector. Content is irrelevant:
            # the fake matches on name; the probe only checks the width.
            vec = [0.0] * VECTOR_SIZE
            vec[abs(hash(text)) % VECTOR_SIZE] = 1.0
            self._send(200, {"embeddings": [vec]})
            return

        if u.path == "/qdrant/collections/people/points/delete":
            body = json.loads(raw or b"{}")
            if MODE != "leak":
                with LOCK:
                    for pid in body.get("points", []):
                        QDRANT.pop(str(pid), None)
            self._send(200, {"result": {"status": "completed"}, "status": "ok"})
            return

        self._send(404, "not found", raw=True)


srv = HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as fh:
    fh.write(str(srv.server_port))
srv.serve_forever()
FAKEPY

run_case() {
    local mode="$1" expect="$2" label="$3"
    local portfile="${WORK}/port.${mode}" outfile="${WORK}/out.${mode}"
    rm -f "$portfile"

    local errfile="${WORK}/err.${mode}"
    MODE="$mode" FAKE_TOKEN="probe-test-token" \
        python3 "$FAKE" "$portfile" >/dev/null 2>"$errfile" &
    SERVER_PID=$!

    # Bounded wait WITH a real delay: a poll loop with no sleep is not a wait.
    local tries=0 port=""
    while [ "$tries" -lt 200 ]; do
        if [ -s "$portfile" ]; then port="$(cat "$portfile")"; break; fi
        sleep 0.1
        tries=$((tries + 1))
    done
    if [ -z "$port" ]; then
        echo "FAIL [${mode}] fake box never bound a port after 20s"
        # Say WHY. A harness that cannot name its own cause sends the reader
        # guessing, and the guess is usually wrong.
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "       server pid ${SERVER_PID} is ALIVE but wrote no portfile"
        else
            echo "       server pid ${SERVER_PID} is DEAD"
        fi
        if [ -s "$errfile" ]; then
            echo "       --- fake box stderr ---"
            sed 's/^/       /' "$errfile" | head -20
        else
            echo "       fake box wrote NOTHING to stderr"
        fi
        FAILS=$((FAILS + 1)); kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""
        return
    fi

    OSTLER_BOX_HOST="127.0.0.1" \
    OSTLER_PROBE_FORCE_LOCAL=1 \
    OSTLER_SERVICE_TOKEN="probe-test-token" \
    OSTLER_PROBE_API_BASE="http://127.0.0.1:${port}/api" \
    OSTLER_PROBE_QDRANT_BASE="http://127.0.0.1:${port}/qdrant" \
    OSTLER_PROBE_EMBED_BASE="http://127.0.0.1:${port}/ollama" \
        /bin/bash "$PROBE" > "$outfile" 2>&1
    local rc=$?

    kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""

    local ok=0
    if [ "$expect" = "pass" ] && [ "$rc" -eq 0 ]; then ok=1; fi
    if [ "$expect" = "fail" ] && [ "$rc" -ne 0 ]; then ok=1; fi

    if [ "$ok" = "1" ]; then
        echo "PASS [${mode}] ${label} (exit ${rc})"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL [${mode}] ${label} -- expected ${expect}, got exit ${rc}"
        echo "----- probe output -----"; cat "$outfile"; echo "------------------------"
        FAILS=$((FAILS + 1))
    fi

    # The verdict must always be the LAST stdout line: it is the only line the
    # cut verifier surfaces.
    local last; last="$(tail -n 1 "$outfile")"
    case "$last" in
        people_seed_and_retrieval:*) ;;
        *) echo "FAIL [${mode}] last stdout line is not the verdict: ${last}"
           FAILS=$((FAILS + 1)) ;;
    esac
}

echo "=== people_seed_and_retrieval: does the gate actually fire? ==="
echo ""

run_case green            pass "honest box: both legs seed and retrieve"
run_case context_notfound fail "RED: primary route reports found:false for a person minted moments ago"
run_case wrong_person     fail "RED: a different person comes back as the match"
run_case wrong_uri        fail "RED: right name, wrong person_uri (identity mismatch)"
run_case degraded         fail "RED: store unreachable arrives as HTTP 200 + degraded, must not read as absence"
run_case seed_503         fail "RED: memory/assert refuses to mint (user_id not configured)"
run_case no_auth          fail "RED: API answers without a token, so no result proves the authed path"
run_case blanket_200      fail "RED: box answers every authenticated path with a valid-looking payload"
run_case deps_down        fail "RED: dependency health reports the stores down"
run_case no_collection    fail "RED: qdrant people collection absent on a fresh install"
run_case search_empty     fail "RED: fallback route returns nothing for a seeded person"
run_case leak             fail "RED: cleanup accepted but the fixture is still retrievable"

echo ""
echo "EXAMINED: scenarios=$((PASSES + FAILS)) passed=${PASSES} failed=${FAILS}"
if [ "$FAILS" -gt 0 ]; then
    echo "test_people_seed_and_retrieval_probe: FAIL (${FAILS} expectations missed)"
    exit 1
fi
echo "test_people_seed_and_retrieval_probe: PASS (gate proven to fire on 11 distinct breaks)"
exit 0
