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
#
# ---------------------------------------------------------------------------
# WHY THE FAKE BOX BINDS THE WAY IT DOES  (task #348, measured 2026-08-16)
# ---------------------------------------------------------------------------
# This harness failed 56 of 81 completed CI runs, always with "fake box never
# bound a port", always with the process ALIVE and stderr EMPTY. It was carried
# as a load-sensitive flake and bypassed on two cuts.
#
# It was not load. Stage-timed on a macos-latest runner, 12 spawns out of 12:
#
#   T+0.108  http.server imported
#   T+0.108  raw socket bind + close        0.000s
#   T+35.118 socket.getfqdn('127.0.0.1')   35.010s   <-- flat, every time
#   T+35.119 HTTPServer() constructed       0.000s
#
# http.server.HTTPServer.server_bind() finishes with getfqdn(host), a REVERSE
# DNS lookup, inside the constructor and therefore before the portfile can be
# written. The runner's /etc/hosts does carry `127.0.0.1 localhost` and the
# call does return 'localhost' -- after mDNSResponder has spent a full resolver
# timeout on nameserver 192.168.64.1 first. 35.0s, not variable.
#
# The old wait was 200 turns of `sleep 0.1`, which is ~30s of wall clock, drifts
# upward as the job loads the runner, and described itself as "20s". So the
# scenario outcome was a race between a ~30-37s loop and a fixed 35s lookup:
# early scenarios lost, late ones won. That is the whole "flake".
#
# Two consequences for anyone editing this file:
#   1. The fake box must never perform name resolution. LoopbackHTTPServer
#      below exists solely to drop the getfqdn call.
#   2. Do not "fix" a readiness timeout by enlarging it. Raising the budget
#      past 35s would have gone green while paying 35s of dead DNS per
#      scenario -- 7 minutes a run, on the cut path.
# ============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
PROBE="${REPO}/scripts/box_walk_probes/probes/people_seed_and_retrieval.sh"

if [ ! -f "$PROBE" ]; then
    echo "FAIL: probe not found at ${PROBE}"
    exit 1
fi

# The probe joined probes/ so run_box_walk.sh would collect it -- it had never
# executed in a box walk while it sat one level up. Joining probes/ obliged it
# to carry a --self-test, and the runner DISCARDS the result of any probe whose
# negative control does not go red. The 12 scenarios below drive the real
# measurement path; the self-test check after them drives the control, so a
# regression in either is caught here rather than by the cut host quietly
# marking the probe BROKEN and reporting one fewer measurement.

# PORTABILITY, DORMANT NOT ABSENT: `mktemp -t NAME` with no X's in the
# template is BSD-ONLY. GNU mktemp rejects it with "too few X's in
# template", the variable comes back EMPTY, and whatever consumes it
# fails somewhere else wearing a cause that is not the real one. This is
# safe TODAY only because cut-manifest.yml runs people-probe-fires on macos-latest. Move it to ubuntu and it fires.
# Fix if you move it: mktemp "${TMPDIR:-/tmp}/NAME.XXXXXX" plus an
# emptiness guard -- the guard matters as much as the template.
WORK="$(mktemp -d -t peopleprobetest)"
FAKE="${WORK}/fake_box.py"

# The fake box is a python3 process. If python3 is missing or broken, every
# scenario fails identically with "never bound a port", which names the SHAPE
# of the failure and not its cause. State the interpreter up front.
echo "harness: python3 = $(command -v python3 || echo '<NOT FOUND>')"
echo "harness: $(python3 --version 2>&1 || echo 'python3 --version FAILED')"
PASSES=0
FAILS=0
# Kept apart from FAILS on purpose. FAILS means "the probe did not behave as
# this scenario demands". HARNESS_FAILS means "the fixture never stood up, so
# the probe was never asked". Both are RED; conflating them is how a broken
# harness got read for four days as a broken probe.
HARNESS_FAILS=0
CASES=0
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
import socketserver
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
DECOY_URI = "https://schema.ostler.ai/ontology#person_decoy00"


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
        uri = "https://schema.ostler.ai/ontology#person_ffffffff"
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

        # The identity check the probe makes before trusting anything else:
        # is the thing on this port actually the assistant API, or is it some
        # other service that happens to answer /health?
        #
        # THIS MOCK DID NOT SERVE THIS ROUTE AT ALL, so the green scenario
        # could not satisfy an identity check and the whole suite went red the
        # moment the probe started making one. A fixture that omits a route the
        # real service has does not test a smaller thing -- it makes the
        # correct behaviour unreachable.
        #
        # Public by design: /api/v1/hydration/status answers unauthenticated on
        # a real box, which is precisely why the probe uses it -- it keeps
        # measuring through an auth outage.
        if path == "/api/api/v1/hydration/status":
            if MODE == "json_body_html_ctype":
                # The CONTROL for the judge's content-type arm, which was
                # otherwise unguarded: removing that arm left all 13 scenarios
                # green, because wrong_service is caught by the SHAPE arm (HTML
                # is not valid JSON) and nothing exercised content-type alone.
                #
                # This is a real shape, not a contrivance: an intercepting proxy
                # or a catch-all that echoes an upstream body serves the right
                # BYTES under the wrong content-type. Trusting a body because it
                # parses, without asking what the server said it was, is how the
                # SPA catch-all got believed in the first place.
                self._send(200, json.dumps(
                    {"overall_state": "running", "phases": []}), raw=True)
                return
            if MODE == "wrong_service":
                # The SPA catch-all: 200, HTML, for any /api/v1 path. Measured
                # on the real daemon at :8000, which answers 200 text/html for
                # /api/v1/definitely-not-a-real-route-zzz.
                self._send(200, "<!DOCTYPE html><html><title>Ostler</title>", raw=True)
                return
            self._send(200, {"overall_state": "running",
                             "phases": [{"key": "contacts", "state": "done", "count": 3}]})
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
            # #574. Store auth has been ENFORCED since #550/#1222, so a keyless
            # Qdrant GET returns 401 on every real install. 404 (absent) and
            # 401 (present but not shown a key) are DIFFERENT FACTS and the
            # probe must not collapse them: 404 is a product defect, 401
            # without a credential is the probe's own blindness.
            #
            # Both modes answer 401. They differ only in whether the probe was
            # given a curl config to present, which is set by the harness.
            if MODE in ("qdrant_401", "qdrant_401_credentialled"):
                self._send(401, {"status": {"error": "Unauthorized"}})
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
                uri = "https://schema.ostler.ai/ontology#person_%08x" % (abs(hash(slug)) & 0xffffffff)
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


class LoopbackHTTPServer(HTTPServer):
    """HTTPServer that binds without a reverse-DNS lookup.

    http.server.HTTPServer.server_bind() ends with
    ``self.server_name = socket.getfqdn(host)``. getfqdn() is a REVERSE DNS
    lookup, it runs INSIDE the constructor, and on a GitHub macOS runner it
    can block for tens of seconds while mDNSResponder waits on a resolver
    that is not answering yet. The portfile is written AFTER the constructor
    returns, so a slow lookup presents as "the box never bound a port" with
    the process alive and stderr empty -- which is exactly the flake this
    harness suffered on 56 of 81 completed CI runs.

    Nothing in this fake reads ``server_name``. Bind with a literal instead:
    a field we never read must not be able to hang the harness.
    """

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


srv = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
# The constructor has already called listen(), so the port accepts connections
# from here on. Announce first, then publish: if the harness ever has to print
# this stderr, the reader can see how far the box got.
sys.stderr.write("fake box mode=%s listening on 127.0.0.1:%d\n"
                 % (MODE, srv.server_port))
sys.stderr.flush()
with open(sys.argv[1], "w") as fh:
    fh.write(str(srv.server_port))
srv.serve_forever()
FAKEPY

# Poll until the fake box is genuinely SERVING, on a wall-clock deadline.
#
# Two things were wrong with the loop this replaces. It counted 200 turns of
# `sleep 0.1` and called that "20s", but each turn also forks, so it really
# waited ~30s and then reported the wrong number in its own failure message. And
# it treated "the portfile is non-empty" as ready, which is a file-existence
# check, not a readiness check.
#
# READY here means: the port is published AND a request to /api/health comes
# back 200. /api/health answers 200 in every one of the 12 modes -- including
# no_auth and blanket_200 -- so this readiness gate cannot mask the break the
# scenario is meant to exercise.
#
# Sets FAKE_BOX_PORT / FAKE_BOX_WAITED. Returns 0 ready, 1 not.
FAKE_BOX_READY_TIMEOUT="${FAKE_BOX_READY_TIMEOUT:-25}"
FAKE_BOX_PORT=""
FAKE_BOX_WAITED=0

wait_for_fake_box() {
    local pid="$1" portfile="$2"
    local started deadline now port
    started="$(date +%s)"
    deadline=$((started + FAKE_BOX_READY_TIMEOUT))
    FAKE_BOX_PORT=""
    while :; do
        if [ -s "$portfile" ]; then
            # tr, not cat: a truncated or partially-flushed write must not
            # become a garbage port that then fails as a connection error.
            port="$(tr -cd '0-9' < "$portfile")"
            # --fail, so a non-2xx is NOT ready. Without it curl exits 0 on any
            # answer at all and the failure message below would be claiming a
            # 200 it never checked for. /api/health returns 200 in all 12 modes.
            if [ -n "$port" ] && /usr/bin/curl -sS --fail --noproxy '*' \
                    --max-time 3 -o /dev/null \
                    "http://127.0.0.1:${port}/api/health"; then
                FAKE_BOX_PORT="$port"
                FAKE_BOX_WAITED=$(( $(date +%s) - started ))
                return 0
            fi
        fi
        # A dead box is answered now rather than at the deadline: waiting out
        # 25s on a process that has already exited is 25s of nothing.
        if ! kill -0 "$pid" 2>/dev/null; then
            FAKE_BOX_WAITED=$(( $(date +%s) - started ))
            return 1
        fi
        now="$(date +%s)"
        if [ "$now" -ge "$deadline" ]; then
            FAKE_BOX_WAITED=$((now - started))
            return 1
        fi
        sleep 0.2
    done
}

run_case() {
    local mode="$1" expect="$2" label="$3"
    local portfile="${WORK}/port.${mode}" outfile="${WORK}/out.${mode}"
    rm -f "$portfile"
    CASES=$((CASES + 1))

    local errfile="${WORK}/err.${mode}"
    MODE="$mode" FAKE_TOKEN="probe-test-token" \
        python3 "$FAKE" "$portfile" >/dev/null 2>"$errfile" &
    SERVER_PID=$!

    local port=""
    if wait_for_fake_box "$SERVER_PID" "$portfile"; then
        port="$FAKE_BOX_PORT"
    fi
    if [ -z "$port" ]; then
        # A gate that times out must say what it was waiting for and for how
        # long. This is a HARNESS failure, not a missed expectation: the probe
        # under test never ran. It is still fail-closed -- the run exits 2 --
        # because a harness that cannot stand up its own fixture proves nothing
        # about the probe, and silence there is indistinguishable from a pass.
        echo "FAIL [${mode}] HARNESS: fake box never became ready"
        echo "       waited for: fake box (MODE=${mode}) to publish a port in"
        echo "                   ${portfile} and answer GET /api/health with 200"
        echo "       budget:     ${FAKE_BOX_READY_TIMEOUT}s    measured: ${FAKE_BOX_WAITED}s"
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            if [ -s "$portfile" ]; then
                echo "       state:      pid ${SERVER_PID} ALIVE, port published (${portfile}), but /api/health never answered"
            else
                echo "       state:      pid ${SERVER_PID} ALIVE, no port published -- blocked before listen()"
            fi
        else
            echo "       state:      pid ${SERVER_PID} is DEAD"
        fi
        if [ -s "$errfile" ]; then
            echo "       --- fake box stderr ---"
            sed 's/^/       /' "$errfile" | head -20
        else
            echo "       fake box wrote NOTHING to stderr"
        fi
        HARNESS_FAILS=$((HARNESS_FAILS + 1))
        kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
        return
    fi

    # STORE CURL CONFIG, ALWAYS SET EXPLICITLY (#574).
    # Never allowed to default to $HOME: the operator running this suite may
    # have a real Ostler install, and then the probe would present a real
    # credential here while CI presents none. The suite would pass on one
    # machine and fail on the other for a reason nothing printed. Modes that
    # want a credential set STORE_CONF before calling; everyone else gets a
    # path that provably does not exist.
    local store_conf="${STORE_CONF:-${WORK}/no-such-store-curl.conf}"

    OSTLER_BOX_HOST="127.0.0.1" \
    OSTLER_PROBE_FORCE_LOCAL=1 \
    OSTLER_SERVICE_TOKEN="probe-test-token" \
    OSTLER_PROBE_API_BASE="http://127.0.0.1:${port}/api" \
    OSTLER_PROBE_QDRANT_BASE="http://127.0.0.1:${port}/qdrant" \
    OSTLER_PROBE_EMBED_BASE="http://127.0.0.1:${port}/ollama" \
    OSTLER_PROBE_STORE_CURL_CONF="${store_conf}" \
        /bin/bash "$PROBE" > "$outfile" 2>&1
    local rc=$?

    kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""

    local ok=0
    if [ "$expect" = "pass" ] && [ "$rc" -eq 0 ]; then ok=1; fi
    if [ "$expect" = "fail" ] && [ "$rc" -ne 0 ]; then ok=1; fi
    # EXACT-CODE EXPECTATIONS (#574). `fail` above means "any non-zero", which
    # cannot tell 1 (the product is broken) from 78 (the probe could not look).
    # That is the same two-state reading of a three-state contract that put a
    # false product FAIL in the v1.0.50 walk record. A numeric expectation
    # pins the exact outcome, and the cases below use it wherever the
    # difference between 1 and 78 is the whole point of the scenario.
    case "$expect" in
        ''|*[!0-9]*) ;;
        *) if [ "$rc" -eq "$expect" ]; then ok=1; else ok=0; fi ;;
    esac

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
run_case no_collection    1    "RED: qdrant people collection absent on a fresh install (404 -- a REAL product defect, exit 1)"

# ---- #574: 401 is not 404, and CANNOT-RUN is not FAIL ---------------------
# The v1.0.50 walk recorded people_seed_and_retrieval as a product FAIL. It was
# not. Store auth became mandatory in #550/#1222, this probe called Qdrant
# bare, and the resulting 401 was read as "collection missing or unreadable".
# The collection was there the whole time and returns 200 with the key.
#
# These two cases are the discrimination, and BOTH are needed. The first alone
# could be satisfied by a probe that simply never fails on 401 -- which would
# bury a genuinely wrong credential. The second proves the CANNOT-RUN arm is
# earned by the ABSENCE of a credential, not by the status code.
#
# The credentialled fixture carries a marker header, not a secret: the point
# is that SOMETHING was presented and refused. Nothing here is a token, so
# nothing here can leak one.
_present_conf="${WORK}/store-curl-present.conf"
printf 'header = "X-Ostler-Probe-Fixture: present"\n' > "$_present_conf"
# The credentialled case is scoped with a PREFIX assignment and STORE_CONF is
# then explicitly unset. A plain `STORE_CONF=...` here would stay set for the
# rest of the file, hand a credential to the case below, and turn its 78 into
# a 1 -- a green suite proving the opposite of what it claims.
STORE_CONF="$_present_conf" \
    run_case qdrant_401_credentialled 1 \
    "RED: qdrant 401s WITH a credential presented -- a wrong key is a real defect (exit 1, NOT 78)"
unset STORE_CONF
run_case qdrant_401       78   "CANNOT-RUN: qdrant 401s and the probe had no credential -- nothing measured, so the product is NOT accused (exit 78)"
run_case search_empty     fail "RED: fallback route returns nothing for a seeded person"
run_case leak             fail "RED: cleanup accepted but the fixture is still retrievable"
# The control for the identity check itself. Without it, the probe could stop
# checking WHICH service answers and this suite would stay green -- which is
# how the probe came to be measuring the wrong port in the first place.
run_case wrong_service    fail "RED: port answers /health but serves HTML for /api/v1/hydration/status (not the assistant API)"
run_case json_body_html_ctype fail "RED: right JSON body under text/html -- content-type arm of the identity judge"

echo ""
# ---------------------------------------------------------------------------
# The probe's own negative control, checked here for the same reason the runner
# checks it: a probe that cannot come back FAIL on known-bad input is discarded
# as BROKEN, and a BROKEN probe measures exactly as much as an absent one.
#
# Deliberately NOT a run_case: it needs no fake box, and folding it into the
# scenario count would make `scenarios=15/14` the normal reading of a clean run.
# It contributes to FAILS, so the stubbed-probe control in cut-manifest.yml
# still sees this as one more missed expectation rather than as a crash.
# ---------------------------------------------------------------------------
SELFTEST_OUT="${WORK}/selftest.out"
SELFTEST="red"
/bin/bash "$PROBE" --self-test > "$SELFTEST_OUT" 2>&1
selftest_rc=$?
# Exit code alone is not enough, and reading it alone is how a broken probe
# passes: the contract's own refusals also exit 1 while printing BROKEN.
if [ "$selftest_rc" -eq 1 ] && ! grep -q 'VERDICT: BROKEN' "$SELFTEST_OUT"; then
    echo "PASS [--self-test] probe's own negative control goes red on known-bad input (exit 1)"
    SELFTEST="ok"
else
    echo "FAIL [--self-test] expected exit 1 with no BROKEN verdict, got exit ${selftest_rc}"
    echo "----- self-test output -----"; cat "$SELFTEST_OUT"; echo "----------------------------"
    FAILS=$((FAILS + 1))
fi

echo ""
# scenarios counts CASES ATTEMPTED, not PASSES+FAILS. Those diverge: the
# verdict-line check can add a second FAILS for one case, which used to print
# scenarios=13 out of 12, and a harness failure adds neither. Print the
# denominator that was actually driven, plus every bucket, so a run that
# examined less than it should cannot read as a clean one.
echo "EXAMINED: scenarios=${CASES}/16 passed=${PASSES} failed=${FAILS} harness_failures=${HARNESS_FAILS} selftest=${SELFTEST}"
if [ "$HARNESS_FAILS" -gt 0 ]; then
    echo "test_people_seed_and_retrieval_probe: FAIL (${HARNESS_FAILS} harness failures --"
    echo "  the fake box never became ready, so the probe was never exercised on those"
    echo "  scenarios; this is NOT evidence about the probe either way)"
    exit 2
fi
if [ "$CASES" -ne 16 ]; then
    echo "test_people_seed_and_retrieval_probe: FAIL (drove ${CASES} scenarios, expected 16)"
    exit 2
fi
if [ "$FAILS" -gt 0 ]; then
    echo "test_people_seed_and_retrieval_probe: FAIL (${FAILS} expectations missed)"
    exit 1
fi
echo "test_people_seed_and_retrieval_probe: PASS (gate proven to fire on 15 distinct scenarios (13 breaks + 2 auth-state discriminations), and its own --self-test proven to go red)"
exit 0
