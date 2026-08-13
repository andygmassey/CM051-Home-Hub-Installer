#!/usr/bin/env bash
# scripts/box_walk_probes/people_seed_and_retrieval.sh
# ============================================================================
# Seed-and-retrieval round-trip against a real box.
#
# Proves the thing a customer notices first and no static gate can see: that a
# person actually lands in the graph on a fresh install, and that the assistant
# can get that person back by the route it really uses.
#
# THE ROUTE UNDER TEST (read out of the source, not assumed)
# ---------------------------------------------------------
# The daemon's `pwg_people` tool calls the loopback Assistant API in this
# order (crates/zeroclaw-tools/src/pwg_people.rs):
#
#   1. GET /api/v1/people/context?name=<NAME>   -> Oxigraph SPARQL   [PRIMARY]
#   2. only when that returns found:false:
#      GET /api/v1/people/search?q=<NAME>       -> Qdrant + Ollama   [FALLBACK]
#
# So the primary leg is `context`, backed by Oxigraph, and this probe tests it
# through the product's own API end to end: seed with POST /api/v1/memory/assert
# (which mints a pwg:Person), retrieve with GET /api/v1/people/context, remove
# with POST /api/v1/people/{slug}/forget. No raw store writes on that leg.
#
# The fallback leg is tested separately, and it has to be seeded differently:
# memory/assert writes Oxigraph ONLY and deliberately does not touch Qdrant
# (see the "LAST CHANCE BEFORE MINTING" comment in ical-server.py). A person
# minted through the API is therefore invisible to /people/search until the
# next contact sync, so asserting the seeded name on /search would be a
# guaranteed false RED. Leg B seeds Qdrant directly instead.
#
# WHY THE WORK HAPPENS ON THE BOX
# -------------------------------
# The Assistant API binds 127.0.0.1 (OSTLER_API_BIND) and rejects any Host
# header that is not loopback, as DNS-rebind defence. It is unreachable from
# the operator's machine BY DESIGN. Every HTTP call below runs ON the box (over
# ssh unless the box is this machine); only parsing happens locally.
#
# THE TRAP THIS PROBE MUST NOT FALL INTO
# --------------------------------------
# Both people routes return HTTP 200 with `"degraded": true` when the backing
# store is unreachable (ical-server.py, the try/except around people_search and
# person_context). A 200 is NOT proof of a working store, and a degraded
# response is NOT evidence that a person is absent. Every judgement below
# treats degraded as INCONCLUSIVE and fails loudly, and treats 401/403 as a
# token/Host fault rather than as absence.
#
# SYNTHETIC DATA ONLY
# -------------------
# Every identity here is constructed and provably fictional: reserved .example
# / .test domains (RFC 2606) and Ofcom drama-range numbers (+44 7700 900xxx).
# The address book is never touched. Both legs sweep before seeding, so a
# previous crashed run cannot fake a pass, and both clean up and then VERIFY
# the cleanup rather than assuming it.
#
# PII DISCIPLINE
# --------------
# A failing retrieval returns REAL people from the operator's graph. Every
# retrieved name is masked BEFORE printing unless it is one of this probe's own
# synthetic names, so a cut log can never carry a real name out of here.
#
# CONTRACT (scripts/box_walk_probes/README.md)
# --------------------------------------------
# exit 0 = PASS, non-zero = FAIL, 180s budget, and the verifier surfaces the
# LAST stdout line -- so the last line is always a one-line verdict.
# ============================================================================

set -uo pipefail

PROBE_NAME="people_seed_and_retrieval"

# ---------------------------------------------------------------------------
# Configuration. Defaults are the real customer values. The overrides exist so
# the gate can be exercised against a controlled fake in CI (see
# scripts/tests/test_people_seed_and_retrieval_probe.sh). Every resolved value
# is printed, so a misconfigured run is visible rather than silently testing
# nothing.
# ---------------------------------------------------------------------------
API_BASE="${OSTLER_PROBE_API_BASE:-http://127.0.0.1:8090}"
QDRANT_BASE="${OSTLER_PROBE_QDRANT_BASE:-http://127.0.0.1:6333}"
EMBED_BASE="${OSTLER_PROBE_EMBED_BASE:-http://127.0.0.1:11434}"
EMBED_MODEL="${OSTLER_PROBE_EMBED_MODEL:-nomic-embed-text}"
TOKEN_PATH="${OSTLER_PROBE_TOKEN_PATH:-\$HOME/.ostler/secrets/service_token}"
COLLECTION="${OSTLER_PROBE_COLLECTION:-people}"
HTTP_TIMEOUT="${OSTLER_PROBE_HTTP_TIMEOUT:-15}"
EMBED_TIMEOUT="${OSTLER_PROBE_EMBED_TIMEOUT:-30}"

# Counters. A gate that does not say what it EXAMINED cannot be told apart from
# a gate that examined nothing.
CONTROLS_RUN=0
SEEDED=0
RETRIEVED=0
QUERIES=0
ASSERTIONS=0
RESULTS_EXAMINED=0
CLEANED=0
FAILURES=0
FIRST_FAILURE=""

TMP="$(mktemp -d -t ostlerprobe)"

fail() {
    FAILURES=$((FAILURES + 1))
    if [ -z "$FIRST_FAILURE" ]; then FIRST_FAILURE="$1"; fi
    echo "  [FAIL] $1"
}
pass() { echo "  [ok]   $1"; }
note() { echo "  ...    $1"; }

# ---------------------------------------------------------------------------
# Execution mode.
# ---------------------------------------------------------------------------
BOX_HOST="${OSTLER_BOX_HOST:-}"
if [ -z "$BOX_HOST" ]; then
    echo "${PROBE_NAME}: OSTLER_BOX_HOST is not set. The verifier is contracted to"
    echo "SKIP in that case and never invoke this probe, so reaching here means the"
    echo "primitive changed. Refusing to report a verdict on an unnamed box."
    echo "${PROBE_NAME}: FAIL -- OSTLER_BOX_HOST unset; no target box to examine"
    exit 2
fi

RUN_MODE="ssh"
_host_lc="$(printf '%s' "$BOX_HOST" | tr '[:upper:]' '[:lower:]')"
_self_lc="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
case "$_host_lc" in
    localhost|127.0.0.1|::1) RUN_MODE="local" ;;
    *) if [ -n "$_self_lc" ] && [ "$_host_lc" = "$_self_lc" ]; then RUN_MODE="local"; fi ;;
esac
if [ "${OSTLER_PROBE_FORCE_LOCAL:-0}" = "1" ]; then RUN_MODE="local"; fi

# One command string drives both modes, so local and remote cannot drift apart.
box_exec() {
    if [ "$RUN_MODE" = "local" ]; then
        eval "$1"
    else
        /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new "$BOX_HOST" "$1"
    fi
}

# HTTP on the box. Body on stdout, HTTP code on the final line.
# --noproxy '*' is mandatory: the operator shell routinely carries HTTP_PROXY,
# and a proxy will intercept even a 127.0.0.1 request and answer with its own
# error, which reads exactly like the service being down.
# args: <method> <url> <auth|noauth> <outfile> [bodyfile] [timeout]
box_http() {
    local method="$1" url="$2" want_auth="$3" outfile="$4"
    local bodyfile="${5:-}" tmo="${6:-$HTTP_TIMEOUT}"
    local hdr="" datapart=""
    # The token is inlined single-quoted rather than passed as a command PREFIX
    # assignment. A prefix assignment is not visible to expansions in its own
    # command, so `TOK=x curl -H "...${TOK}"` expands TOK while still unset --
    # which under `set -u` kills the shell mid-probe with no verdict line.
    # Phase 0 rejects a token containing a single quote, so this cannot break
    # the quoting.
    if [ "$want_auth" = "auth" ]; then
        hdr="-H 'Authorization: Bearer ${TOKEN}'"
    fi
    if [ -n "$bodyfile" ]; then
        datapart="-H \"Content-Type: application/json\" --data-binary @-"
    fi
    local cmd="/usr/bin/curl -sS --noproxy '*' --max-time ${tmo} -w '\n%{http_code}' -X ${method} ${hdr} ${datapart} \"${url}\""
    if [ -n "$bodyfile" ]; then
        box_exec "$cmd" < "$bodyfile" > "$outfile" 2>"${outfile}.err"
    else
        box_exec "$cmd" < /dev/null > "$outfile" 2>"${outfile}.err"
    fi
    # Always split out <outfile>.body here. Leaving it to the caller meant a
    # judgement could read a .body that was never written and score the empty
    # string as "unknown" -- a cleanup check that silently could not see.
    http_code_of "$outfile" >/dev/null
}

# Split a box_http output file into <file>.body and echo the HTTP code.
http_code_of() {
    python3 - "$1" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
body, _, code = raw.rpartition("\n")
open(sys.argv[1] + ".body", "w").write(body)
print(code.strip() or "000")
PY
}

# ---------------------------------------------------------------------------
# Synthetic identities. Constructed names, reserved domains, drama-range
# numbers. LEG_A goes through the product API; LEG_B goes into Qdrant.
# ---------------------------------------------------------------------------
A_NAME="Wilhelmina Quibblesworth-Example"
A_FACT="Fixture person created by the Ostler box-walk probe."
B_NAME="Bartholomew Fenwicke-Testcase"
B_ORG="Testcase Instruments"
B_EMAIL="bartholomew@probe.example"
B_PHONE="+44 7700 900456"
B_URI="https://ostler.test/box-walk-probe/person/b0"
# Never seeded anywhere. Used only for the absence assertion, and only after
# the positive controls have proved the route returns people that ARE there.
ABSENT_NAME="Peregrine Thistlewaite-Absent"

slugify() {
    python3 - "$1" <<'PY'
import sys, re, unicodedata
n = unicodedata.normalize("NFKD", sys.argv[1])
n = "".join(c for c in n if not unicodedata.combining(c))
s = re.sub(r"[^a-z0-9]+", "-", n.lower()).strip("-")
print(s or "unknown")
PY
}

urlencode() {
    python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

b_point_id() {
    python3 - <<'PY'
import uuid
print(uuid.uuid5(uuid.NAMESPACE_URL,
                 "https://ostler.test/box-walk-probe/people/b0"))
PY
}

# ---------------------------------------------------------------------------
cleanup_tmp() { local rc=$?; rm -rf "$TMP" 2>/dev/null; return $rc; }
trap cleanup_tmp EXIT

echo "${PROBE_NAME}: seed-and-retrieval round-trip"
echo "  box           = ${BOX_HOST}   (run mode: ${RUN_MODE})"
echo "  assistant api = ${API_BASE}"
echo "  primary leg   = GET /api/v1/people/context   (Oxigraph; what pwg_people calls first)"
echo "  fallback leg  = GET /api/v1/people/search    (Qdrant '${COLLECTION}' + Ollama)"
echo "  seed / unseed = POST /api/v1/memory/assert, POST /api/v1/people/{slug}/forget"
echo "  identities    = synthetic only, reserved .example/.test + drama-range numbers"
echo ""

# ---------------------------------------------------------------------------
echo "PHASE 0 -- reach the box, resolve the service token"
if ! box_exec "true" >/dev/null 2>&1; then
    echo "  [FAIL] cannot execute on box '${BOX_HOST}' (mode=${RUN_MODE})"
    echo "${PROBE_NAME}: FAIL -- box ${BOX_HOST} unreachable in ${RUN_MODE} mode; nothing examined"
    exit 3
fi
pass "box reachable (${RUN_MODE})"

TOKEN="${OSTLER_SERVICE_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    TOKEN="$(box_exec "cat ${TOKEN_PATH} 2>/dev/null" | tr -d '\r\n' | head -c 512)"
fi
if [ -z "$TOKEN" ]; then
    echo "  [FAIL] no service token at ${TOKEN_PATH} on the box, and OSTLER_SERVICE_TOKEN unset"
    echo "${PROBE_NAME}: FAIL -- service token absent; API fails closed with 401 so retrieval is untestable"
    exit 4
fi
case "$TOKEN" in
    *"'"*)
        echo "  [FAIL] service token contains a single quote; refusing to inline it into a shell command"
        echo "${PROBE_NAME}: FAIL -- service token has an unquotable character; cannot authenticate safely"
        exit 4 ;;
esac
pass "service token resolved (${#TOKEN} chars; value never printed)"
echo ""

# ---------------------------------------------------------------------------
# POSITIVE CONTROLS. Each proves the probe can SEE something that is genuinely
# there. Until they pass, no absence claim this probe makes is worth anything.
# ---------------------------------------------------------------------------
echo "PHASE 1 -- positive controls (all before any absence claim)"

# C1 -- the service is alive and speaks JSON we can actually parse.
OUT="${TMP}/health.out"; box_http GET "${API_BASE}/health" noauth "$OUT"
CODE="$(http_code_of "$OUT")"; CONTROLS_RUN=$((CONTROLS_RUN + 1))
OK="$(python3 - "${OUT}.body" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print("yes" if isinstance(d, dict) and d else "no")
except Exception:
    print("no")
PY
)"
if [ "$CODE" = "200" ] && [ "$OK" = "yes" ]; then
    pass "C1 /health live and parseable (HTTP 200)"
else
    fail "C1 /health unusable (HTTP ${CODE}, parseable=${OK}) -- the service under test is not running"
fi

# C2 -- auth is genuinely enforced on the route under test. If context answers
# without a token then a later authenticated 200 proves nothing about the
# authed path, and the install has a real security regression besides.
OUT="${TMP}/noauth.out"
box_http GET "${API_BASE}/api/v1/people/context?name=control" noauth "$OUT"
CODE="$(http_code_of "$OUT")"; CONTROLS_RUN=$((CONTROLS_RUN + 1))
if [ "$CODE" = "401" ]; then
    pass "C2 unauthenticated /people/context refused (HTTP 401) -- the token is load-bearing"
else
    fail "C2 unauthenticated /people/context returned HTTP ${CODE}, expected 401 -- auth not enforced, so no later result proves the authed path"
fi

# C3 -- our success predicate discriminates. A Hub surface that answers 200 on
# every path has fooled this codebase before, so prove a nonsense route does
# NOT satisfy "valid people payload".
OUT="${TMP}/nonsense.out"
box_http GET "${API_BASE}/api/v1/people/context-no-such-route-probe" auth "$OUT"
CODE="$(http_code_of "$OUT")"; CONTROLS_RUN=$((CONTROLS_RUN + 1))
LOOKS_VALID="$(python3 - "${OUT}.body" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print("yes" if isinstance(d, dict) and "found" in d else "no")
except Exception:
    print("no")
PY
)"
if [ "$LOOKS_VALID" = "no" ]; then
    pass "C3 nonsense route does not satisfy the predicate (HTTP ${CODE}) -- a blanket 200 cannot fake a pass"
else
    fail "C3 nonsense route returned a valid-looking people payload -- the predicate cannot discriminate and every assertion below would be void"
fi

# C4 -- the stores the two legs depend on are actually up. This is the control
# that stops a dead Oxigraph or Qdrant being reported later as "person absent".
OUT="${TMP}/deep.out"
box_http GET "${API_BASE}/health?detailed=1" auth "$OUT"
CODE="$(http_code_of "$OUT")"; CONTROLS_RUN=$((CONTROLS_RUN + 1))
DEPS="$(python3 - "${OUT}.body" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("unparseable"); raise SystemExit
checks = d.get("checks") or {}
if not isinstance(checks, dict) or not checks:
    print("nochecks"); raise SystemExit
bad = [k for k, v in checks.items()
       if isinstance(v, dict) and v.get("ok") is False]
print("down:" + ",".join(sorted(bad)) if bad else "ok:%d" % len(checks))
PY
)"
case "$DEPS" in
    ok:*) pass "C4 dependency health reports every store up (${DEPS#ok:} checks, HTTP ${CODE})" ;;
    down:*) fail "C4 dependency health reports stores DOWN (${DEPS#down:}) -- absence below would be a store fault, not a missing person" ;;
    *) fail "C4 dependency health unreadable (HTTP ${CODE}, ${DEPS}) -- cannot establish the stores are up" ;;
esac

if [ "$FAILURES" -gt 0 ]; then
    echo ""
    echo "EXAMINED: controls=${CONTROLS_RUN} seeded=0 retrieved=0 queries=0 assertions=0"
    echo "${PROBE_NAME}: FAIL -- control failed before seeding: ${FIRST_FAILURE}"
    exit 5
fi
echo ""

# ---------------------------------------------------------------------------
# LEG A -- the primary route, entirely through the product's own API.
# ---------------------------------------------------------------------------
echo "PHASE 2 -- LEG A primary route: seed via memory/assert, retrieve via people/context"

A_SLUG="$(slugify "$A_NAME")"

# Sweep first. A person left behind by a crashed run would make memory/assert
# ATTACH instead of MINT, and the created_person assertion below is what turns
# that into a visible failure rather than a false pass.
OUT="${TMP}/presweep.out"
box_http POST "${API_BASE}/api/v1/people/${A_SLUG}/forget" auth "$OUT"
note "pre-seed sweep of slug '${A_SLUG}' returned HTTP $(http_code_of "$OUT") (idempotent; stale fixtures cannot fake a pass)"

REQ="${TMP}/assert.json"
python3 - "$A_NAME" "$A_FACT" > "$REQ" <<'PY'
import json, sys
print(json.dumps({"subject": sys.argv[1], "fact_text": sys.argv[2],
                  "asserted_via": "box-walk-probe"}))
PY
OUT="${TMP}/assert.out"
box_http POST "${API_BASE}/api/v1/memory/assert" auth "$OUT" "$REQ"
CODE="$(http_code_of "$OUT")"
ASSERTIONS=$((ASSERTIONS + 1))
SEED_INFO="$(python3 - "${OUT}.body" "$CODE" <<'PY'
import json, sys
body, code = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(body))
except Exception:
    print("ERR||unparseable seed response (HTTP %s)" % code); raise SystemExit
if code != "200":
    reason = d.get("reason") or d.get("error") or d.get("status") or "unknown"
    print("ERR||seed refused HTTP %s (%s)" % (code, reason)); raise SystemExit
if d.get("status") != "created_person":
    print("ERR||seed returned status=%r, expected created_person" % d.get("status"))
    raise SystemExit
print("OK|%s|%s" % (d.get("person_slug") or "", d.get("person_uri") or ""))
PY
)"
SEED_STATUS="$(printf '%s' "$SEED_INFO" | cut -d'|' -f1)"
A_REAL_SLUG="$(printf '%s' "$SEED_INFO" | cut -d'|' -f2)"
A_URI="$(printf '%s' "$SEED_INFO" | cut -d'|' -f3)"
if [ "$SEED_STATUS" = "OK" ] && [ -n "$A_URI" ]; then
    SEEDED=$((SEEDED + 1))
    pass "seeded ${A_NAME} -> minted person_uri (slug '${A_REAL_SLUG}')"
else
    fail "LEG A seed failed: $(printf '%s' "$SEED_INFO" | cut -d'|' -f3-)"
fi

if [ "$SEEDED" -eq 1 ]; then
    q="$(urlencode "$A_NAME")"
    OUT="${TMP}/ctx.out"
    box_http GET "${API_BASE}/api/v1/people/context?name=${q}" auth "$OUT"
    CODE="$(http_code_of "$OUT")"
    QUERIES=$((QUERIES + 1)); ASSERTIONS=$((ASSERTIONS + 1))
    VERDICT="$(python3 - "${OUT}.body" "$CODE" "$A_NAME" "$A_URI" "$B_NAME" "$ABSENT_NAME" <<'PY'
import json, sys, hashlib
body, code, want_name, want_uri = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
allowed = {want_name, sys.argv[5], sys.argv[6]}

def mask(n):
    if n in allowed:
        return n
    return "<redacted len=%d sha=%s>" % (len(n), hashlib.sha256(n.encode()).hexdigest()[:8])

if code in ("401", "403"):
    print("AUTH|0|HTTP %s is a token/Host fault, never evidence of absence" % code)
    raise SystemExit
try:
    d = json.load(open(body))
except Exception:
    print("ERR|0|unparseable context response (HTTP %s)" % code); raise SystemExit
# Degraded is INCONCLUSIVE. It arrives as HTTP 200 and must never be read as
# "the person is not there".
if d.get("degraded"):
    print("DEGRADED|0|store unreachable (%s); inconclusive, not absence"
          % (d.get("reason") or "no reason given"))
    raise SystemExit
if not d.get("found"):
    print("NOTFOUND|0|found:false for a person minted moments ago")
    raise SystemExit
person = d.get("person")
if not isinstance(person, dict):
    matches = d.get("matches") or []
    print("MULTI|%d|context returned %d matches, expected one exact person"
          % (len(matches), len(matches)))
    raise SystemExit
got_name, got_uri = person.get("name", ""), person.get("person_uri", "")
if got_name != want_name:
    print("WRONGNAME|1|top person was %s, not the seeded fixture" % mask(got_name))
    raise SystemExit
if got_uri != want_uri:
    print("WRONGURI|1|name matched but person_uri was %r, expected the minted %r"
          % (got_uri, want_uri))
    raise SystemExit
print("OK|1|found the seeded person by name AND minted person_uri")
PY
)"
    ST="$(printf '%s' "$VERDICT" | cut -d'|' -f1)"
    N="$(printf '%s' "$VERDICT" | cut -d'|' -f2)"
    MSG="$(printf '%s' "$VERDICT" | cut -d'|' -f3-)"
    RESULTS_EXAMINED=$((RESULTS_EXAMINED + N))
    if [ "$ST" = "OK" ]; then
        RETRIEVED=$((RETRIEVED + 1))
        pass "retrieved ${A_NAME} via /people/context -- ${MSG}"
    else
        fail "LEG A retrieval (${ST}): ${MSG}"
    fi
    if grep -qi "I don't have any information" "${OUT}.body" 2>/dev/null; then
        fail "context response carries the confabulation tell \"I don't have any information\""
    fi
    ASSERTIONS=$((ASSERTIONS + 1))
fi
echo ""

# ---------------------------------------------------------------------------
# Absence assertion. Safe only because LEG A just proved this exact route
# returns a person that IS there.
# ---------------------------------------------------------------------------
echo "PHASE 3 -- absence assertion on the same route (valid only now the positive control has passed)"
q="$(urlencode "$ABSENT_NAME")"
OUT="${TMP}/absent.out"
box_http GET "${API_BASE}/api/v1/people/context?name=${q}" auth "$OUT"
CODE="$(http_code_of "$OUT")"
QUERIES=$((QUERIES + 1)); ASSERTIONS=$((ASSERTIONS + 1))
ABS="$(python3 - "${OUT}.body" "$CODE" <<'PY'
import json, sys
body, code = sys.argv[1], sys.argv[2]
if code in ("401", "403"):
    print("AUTH|token/Host fault, not absence"); raise SystemExit
try:
    d = json.load(open(body))
except Exception:
    print("ERR|unparseable"); raise SystemExit
if d.get("degraded"):
    print("DEGRADED|%s" % (d.get("reason") or "store unreachable")); raise SystemExit
print("CLEAN|not found, as expected" if not d.get("found")
      else "HIT|a name that was never seeded came back as found")
PY
)"
ABS_ST="$(printf '%s' "$ABS" | cut -d'|' -f1)"
ABS_MSG="$(printf '%s' "$ABS" | cut -d'|' -f2-)"
if [ "$ABS_ST" = "CLEAN" ]; then
    pass "never-seeded control '${ABSENT_NAME}' is correctly absent (${ABS_MSG})"
else
    fail "absence control (${ABS_ST}): ${ABS_MSG}"
fi
echo ""

# ---------------------------------------------------------------------------
# LEG B -- the fallback route. Seeded directly into Qdrant, because
# memory/assert deliberately does not write Qdrant.
# ---------------------------------------------------------------------------
echo "PHASE 4 -- LEG B fallback route: seed Qdrant directly, retrieve via people/search"

BID="$(b_point_id)"
IDS_JSON="[\"${BID}\"]"
qdrant_delete() {
    # Separate `local` statements on purpose: bash expands every word of a
    # single `local a=.. b=${a}..` BEFORE any of the assignments take effect,
    # so referring to `label` in the same statement reads it while unset and
    # `set -u` kills the probe.
    local label="$1"
    local body="${TMP}/del_${label}.json"
    local out="${TMP}/del_${label}.out"
    printf '{"points": %s}' "$IDS_JSON" > "$body"
    box_http POST "${QDRANT_BASE}/collections/${COLLECTION}/points/delete?wait=true" \
        noauth "$out" "$body"
    http_code_of "$out"
}

OUT="${TMP}/coll.out"
box_http GET "${QDRANT_BASE}/collections/${COLLECTION}" noauth "$OUT"
CODE="$(http_code_of "$OUT")"
VEC_SPEC="$(python3 - "${OUT}.body" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1]))["result"]["config"]["params"]["vectors"]
except Exception:
    print("ERR 0"); raise SystemExit
if isinstance(v, dict) and "size" in v:
    print("- %d" % int(v["size"]))
elif isinstance(v, dict) and v:
    k = sorted(v.keys())[0]
    print("%s %d" % (k, int(v[k]["size"])))
else:
    print("ERR 0")
PY
)"
VEC_NAME="$(printf '%s' "$VEC_SPEC" | awk '{print $1}')"
VEC_SIZE="$(printf '%s' "$VEC_SPEC" | awk '{print $2}')"
LEG_B_OK=0
if [ "$CODE" = "200" ] && [ "$VEC_NAME" != "ERR" ] && [ "${VEC_SIZE:-0}" -gt 0 ] 2>/dev/null; then
    pass "qdrant collection '${COLLECTION}' present (vector=${VEC_NAME}, size=${VEC_SIZE})"
    LEG_B_OK=1
else
    fail "qdrant collection '${COLLECTION}' missing or unreadable (HTTP ${CODE}, spec='${VEC_SPEC}') -- semantic people search cannot work on this install"
fi

if [ "$LEG_B_OK" = "1" ]; then
    note "pre-seed sweep of the probe point returned HTTP $(qdrant_delete presweep)"
    REQ="${TMP}/emb.json"
    python3 - "$EMBED_MODEL" "$B_NAME" "$B_ORG" > "$REQ" <<'PY'
import json, sys
print(json.dumps({"model": sys.argv[1],
                  "input": ["%s %s" % (sys.argv[2], sys.argv[3])]}))
PY
    OUT="${TMP}/emb.out"
    box_http POST "${EMBED_BASE}/api/embed" noauth "$OUT" "$REQ" "$EMBED_TIMEOUT"
    CODE="$(http_code_of "$OUT")"
    if [ "$CODE" != "200" ]; then
        fail "embedding call returned HTTP ${CODE} -- retrieval is semantic, so a dead embedder means the customer cannot find anyone"
        LEG_B_OK=0
    fi
fi

if [ "$LEG_B_OK" = "1" ]; then
    UP="${TMP}/up.json"
    python3 - "${TMP}/emb.out.body" "$BID" "$B_NAME" "$B_ORG" "$B_EMAIL" "$B_PHONE" \
             "$B_URI" "$VEC_NAME" "$VEC_SIZE" > "$UP" <<'PY'
import json, sys
emb, pid, name, org, email, phone, uri, vecname, vecsize = sys.argv[1:10]
vec = json.load(open(emb))["embeddings"][0]
if len(vec) != int(vecsize):
    sys.stderr.write("DIM_MISMATCH got=%d want=%s\n" % (len(vec), vecsize))
    raise SystemExit(9)
point = {"id": pid, "payload": {
    "display_name": name, "organization": org, "job_title": "Probe Fixture",
    "relationship": "test fixture", "emails": [email], "phones": [phone],
    "contact_type": "person", "person_uri": uri,
    "privacy_level": "L1", "box_walk_probe": True}}
point["vector"] = vec if vecname == "-" else {vecname: vec}
print(json.dumps({"points": [point]}))
PY
    if [ $? -ne 0 ]; then
        fail "embedding width does not match collection '${COLLECTION}' (want ${VEC_SIZE}) -- writer and reader disagree on vector size"
        LEG_B_OK=0
    fi
fi

if [ "$LEG_B_OK" = "1" ]; then
    OUT="${TMP}/up.out"
    box_http PUT "${QDRANT_BASE}/collections/${COLLECTION}/points?wait=true" noauth "$OUT" "${TMP}/up.json"
    CODE="$(http_code_of "$OUT")"
    if [ "$CODE" = "200" ]; then
        SEEDED=$((SEEDED + 1))
        pass "seeded ${B_NAME} into qdrant '${COLLECTION}'"
    else
        fail "qdrant seed returned HTTP ${CODE} -- the people collection rejects writes"
        LEG_B_OK=0
    fi
fi

if [ "$LEG_B_OK" = "1" ]; then
    q="$(urlencode "$B_NAME")"
    OUT="${TMP}/search.out"
    box_http GET "${API_BASE}/api/v1/people/search?q=${q}" auth "$OUT"
    CODE="$(http_code_of "$OUT")"
    QUERIES=$((QUERIES + 1)); ASSERTIONS=$((ASSERTIONS + 1))
    V="$(python3 - "${OUT}.body" "$CODE" "$B_NAME" "$B_URI" "$A_NAME" "$ABSENT_NAME" <<'PY'
import json, sys, hashlib
body, code, want_name, want_uri = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
allowed = {want_name, sys.argv[5], sys.argv[6]}

def mask(n):
    if n in allowed:
        return n
    return "<redacted len=%d sha=%s>" % (len(n), hashlib.sha256(n.encode()).hexdigest()[:8])

if code in ("401", "403"):
    print("AUTH|0|HTTP %s is a token/Host fault, never absence" % code); raise SystemExit
try:
    d = json.load(open(body))
except Exception:
    print("ERR|0|unparseable search response (HTTP %s)" % code); raise SystemExit
if d.get("degraded"):
    print("DEGRADED|0|store unreachable (%s); inconclusive, not absence"
          % (d.get("reason") or "no reason given")); raise SystemExit
res = d.get("results")
if not isinstance(res, list):
    print("ERR|0|response carries no results list"); raise SystemExit
if not res:
    print("EMPTY|0|zero results for a person seeded moments ago"); raise SystemExit
top = res[0]
if top.get("name") != want_name:
    print("WRONGNAME|%d|top hit was %s, not the seeded fixture"
          % (len(res), mask(top.get("name", "")))); raise SystemExit
if top.get("person_uri") != want_uri:
    print("WRONGURI|%d|name matched but person_uri was %r, expected %r"
          % (len(res), top.get("person_uri"), want_uri)); raise SystemExit
print("OK|%d|top hit is the seeded person by name AND person_uri" % len(res))
PY
)"
    ST="$(printf '%s' "$V" | cut -d'|' -f1)"
    N="$(printf '%s' "$V" | cut -d'|' -f2)"
    MSG="$(printf '%s' "$V" | cut -d'|' -f3-)"
    RESULTS_EXAMINED=$((RESULTS_EXAMINED + N))
    if [ "$ST" = "OK" ]; then
        RETRIEVED=$((RETRIEVED + 1))
        pass "retrieved ${B_NAME} via /people/search -- ${MSG} (${N} results examined)"
    else
        fail "LEG B retrieval (${ST}): ${MSG}"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
echo "PHASE 5 -- remove both fixtures and verify they are actually gone"

if [ "$SEED_STATUS" = "OK" ]; then
    OUT="${TMP}/forget.out"
    TARGET_SLUG="${A_REAL_SLUG:-$A_SLUG}"
    box_http POST "${API_BASE}/api/v1/people/${TARGET_SLUG}/forget" auth "$OUT"
    CODE="$(http_code_of "$OUT")"
    q="$(urlencode "$A_NAME")"
    OUT="${TMP}/ctx_after.out"
    box_http GET "${API_BASE}/api/v1/people/context?name=${q}" auth "$OUT"
    QUERIES=$((QUERIES + 1)); ASSERTIONS=$((ASSERTIONS + 1))
    GONE="$(python3 - "${OUT}.body" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("unknown"); raise SystemExit
if d.get("degraded"):
    print("degraded"); raise SystemExit
print("no" if d.get("found") else "yes")
PY
)"
    if [ "$GONE" = "yes" ]; then
        CLEANED=$((CLEANED + 1))
        pass "LEG A fixture forgotten (HTTP ${CODE}) and confirmed gone from /people/context"
    else
        fail "LEG A fixture still present after forget (state=${GONE}) -- probe leaked a fixture into the graph"
    fi
fi

if [ "$LEG_B_OK" = "1" ]; then
    DEL="$(qdrant_delete final)"
    q="$(urlencode "$B_NAME")"
    OUT="${TMP}/search_after.out"
    box_http GET "${API_BASE}/api/v1/people/search?q=${q}" auth "$OUT"
    QUERIES=$((QUERIES + 1)); ASSERTIONS=$((ASSERTIONS + 1))
    GONE="$(python3 - "${OUT}.body" "$B_NAME" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("unknown"); raise SystemExit
if d.get("degraded"):
    print("degraded"); raise SystemExit
print("no" if any(r.get("name") == sys.argv[2]
                  for r in (d.get("results") or [])) else "yes")
PY
)"
    if [ "$GONE" = "yes" ]; then
        CLEANED=$((CLEANED + 1))
        pass "LEG B fixture deleted (HTTP ${DEL}) and confirmed gone from /people/search"
    else
        fail "LEG B fixture still retrievable after delete (state=${GONE}) -- probe leaked a fixture into the graph"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
echo "EXAMINED: controls=${CONTROLS_RUN} seeded=${SEEDED}/2 retrieved=${RETRIEVED}/2 queries=${QUERIES} assertions=${ASSERTIONS} results_inspected=${RESULTS_EXAMINED} cleaned=${CLEANED}/2 failures=${FAILURES}"

if [ "$FAILURES" -gt 0 ]; then
    echo "${PROBE_NAME}: FAIL -- ${FIRST_FAILURE} [controls=${CONTROLS_RUN} seeded=${SEEDED}/2 retrieved=${RETRIEVED}/2 cleaned=${CLEANED}/2 failures=${FAILURES}]"
    exit 1
fi

echo "${PROBE_NAME}: PASS -- ${RETRIEVED}/2 synthetic people seeded and retrieved on ${BOX_HOST} via people/context + people/search [controls=${CONTROLS_RUN} queries=${QUERIES} results=${RESULTS_EXAMINED} cleaned=${CLEANED}/2]"
exit 0
