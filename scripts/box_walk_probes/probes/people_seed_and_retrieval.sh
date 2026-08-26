#!/usr/bin/env bash
# scripts/box_walk_probes/probes/people_seed_and_retrieval.sh
# ============================================================================
# QUESTION: on a freshly installed Hub, can a person that is seeded be
#           retrieved again through the route the daemon really uses?
#
# WHY THIS FILE MOVED
# -------------------
# It used to sit one level up, in scripts/box_walk_probes/, and the runner
# collects probes with
#
#     for f in "$PROBE_DIR"/*.sh          # PROBE_DIR = <run_box_walk.sh dir>/probes
#
# so this probe HAD NEVER EXECUTED IN A BOX WALK. Eleven probes ran; this was
# the twelfth file on disk and the glob never saw it. verify_cut_manifest.py
# concedes the other half of the same hole in its own comment: the two manifest
# rows that name this probe "have returned SKIP on every cut that has ever
# run", because they fire only when OSTLER_BOX_HOST is set and it was set
# nowhere.
#
# That mattered more than one missing row. This is the ONLY probe that asserts
# semantic people search actually WORKS end to end -- it reads the Qdrant
# people collection, seeds a point, and retrieves it through the product's own
# API. install.sh counts Qdrant COLLECTIONS rather than points and prints
# "Search index ready (4 collections)" over four empty ones. Nothing else in
# the suite would notice.
#
# WHAT THE MOVE COST -- read this before editing
# ----------------------------------------------
# The runner's phase 1 tries to BREAK every probe it finds before trusting any
# of them: each is invoked with --self-test and must come back FAIL. A probe
# that cannot go red is marked BROKEN and its result discarded. This file had
# no --self-test, which is why the README kept it out of probes/ and called
# collapsing the two directories "the right end state ... not done here".
# Doing it takes three real changes, not a git mv:
#
#   1. lib/probe.sh is sourced and the flow is wrapped in run_probe, so all
#      four runner outcomes -- PASS / FAIL / CANNOT-RUN / BROKEN -- are
#      reachable and the exit codes are the contract's 0 / 1 / 78 rather than
#      the graded 2/3/4/5 nobody ever read as anything but "non-zero".
#   2. Every judgement that used to be an inline python heredoc is now a named
#      function over a response file. That is what makes a hermetic self_test
#      possible: it drives the SAME adjudicators the live probe uses over
#      crafted known-bad responses, with no box involved.
#   3. OSTLER_BOX_HOST unset no longer means "refuse and exit 2". In this suite
#      unset means THIS MACHINE, which is the ordinary case when the box walk
#      runs on the box. Refusing there would have made the probe red on every
#      local run for a reason that is not a defect.
#
# CANNOT-RUN IS NOT A PASS
# ------------------------
# On a machine with no Hub listening this probe can examine nothing, and it
# says so with exit 78, which the runner prints in its own block as coverage
# lost rather than folding into green. It must never emit the shape the CI
# negative control uses to stand for a vacuous green:
#
#     people_seed_and_retrieval: PASS -- nothing examined
#
# It structurally cannot. Every PASS goes through probe_examined first, and a
# verdict with no denominator is refused outright.
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
# BASH 3.2. macOS ships bash 3.2 and the installed box runs it. No associative
# arrays, no mapfile, no ${var,,}.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="people_seed_and_retrieval"
PROBE_QUESTION="can a person seeded on this box be retrieved again through the route the daemon really uses?"

# ---------------------------------------------------------------------------
# Configuration. Defaults are the real customer values. The overrides exist so
# the gate can be exercised against a controlled fake in CI (see
# scripts/tests/test_people_seed_and_retrieval_probe.sh). Every resolved value
# is printed, so a misconfigured run is visible rather than silently testing
# nothing.
# ---------------------------------------------------------------------------
# 8000, NOT 8090. Measured on the walk box 2026-08-26: 8090 is
#     <home>/.ostler/.venv/bin/python3 .../ical-server/ical-server.py
# which is legacy personal infra, while the Ostler daemon
#     .../OstlerAssistant.app/Contents/MacOS/ostler-assistant daemon
# listens on 127.0.0.1:8000 (and *:8443). The probe spent the whole v1.0.47
# walk interrogating the wrong process and reported FAIL about it.
API_BASE="${OSTLER_PROBE_API_BASE:-http://127.0.0.1:8000}"
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

# Cross-phase state, pre-initialised because the phases are functions now and
# `set -u` turns a phase that exits early into an unbound-variable crash with
# no verdict line at all -- the one outcome this suite refuses to produce.
TOKEN=""
A_SLUG=""
A_REAL_SLUG=""
A_URI=""
SEED_STATUS=""
LEG_B_OK=0
BID=""
IDS_JSON="[]"
VEC_NAME=""
VEC_SIZE=0

TMP="$(mktemp -d -t ostlerprobe)"

fail() {
    FAILURES=$((FAILURES + 1))
    if [ -z "$FIRST_FAILURE" ]; then FIRST_FAILURE="$1"; fi
    echo "  [FAIL] $1"
}
pass() { echo "  [ok]   $1"; }
note() { echo "  ...    $1"; }

# ---------------------------------------------------------------------------
# Verdict emission.
#
# TWO consumers read the end of this probe and they want different lines:
#
#   run_box_walk.sh         greps the whole output for 'VERDICT: BROKEN' and
#                           reads the exit code (0 PASS / 1 FAIL / 78 CANNOT-RUN).
#   verify_cut_manifest.py  surfaces the LAST stdout line verbatim, and
#                           test_people_seed_and_retrieval_probe.sh asserts that
#                           line still begins 'people_seed_and_retrieval:'.
#
# lib/probe.sh's probe_pass / probe_fail / probe_cannot_run exit immediately,
# so they cannot be used to bracket a trailing line. emit_verdict prints the
# contract's VERDICT line first and the historic one-line verdict last, which
# satisfies both readers without either of them changing.
#
# The denominator check is repeated here rather than delegated to the library's
# own refusal for exactly that reason: the library's version exits without a
# trailing verdict line, and an invariant that holds on the happy path only is
# not an invariant.
# ---------------------------------------------------------------------------
emit_verdict() {
    # emit_verdict <PASS|FAIL|CANNOT-RUN> <exit_code> <message>
    case "$1" in
        PASS|FAIL)
            if [ "$PROBE_EXAMINED_SET" -eq 0 ]; then
                printf 'VERDICT: BROKEN -- %s reported a verdict without calling probe_examined.\n' "$PROBE_NAME"
                printf '%s: BROKEN -- verdict carried no denominator, so it cannot be audited\n' "$PROBE_NAME"
                exit "$PROBE_EX_FAIL"
            fi
            ;;
    esac
    printf 'VERDICT: %s -- %s\n' "$1" "$3"
    printf '%s: %s -- %s\n' "$PROBE_NAME" "$1" "$3"
    exit "$2"
}
verdict_pass()       { emit_verdict PASS       "$PROBE_EX_PASS"       "$1"; }
verdict_fail()       { emit_verdict FAIL       "$PROBE_EX_FAIL"       "$1"; }
verdict_cannot_run() { emit_verdict CANNOT-RUN "$PROBE_EX_CANNOT_RUN" "$1"; }

# ---------------------------------------------------------------------------
# Execution mode.
#
# OSTLER_BOX_HOST unset means THIS MACHINE, per the suite contract in
# lib/probe.sh. It used to mean "refuse to report a verdict", which was correct
# only while the cut gate was the sole caller; under run_box_walk.sh it would
# paint every local walk red for a reason that is not a defect.
# ---------------------------------------------------------------------------
BOX_HOST="${OSTLER_BOX_HOST:-}"
if [ -n "$BOX_HOST" ]; then
    BOX_LABEL="$BOX_HOST"
else
    BOX_LABEL="this machine (OSTLER_BOX_HOST unset)"
fi

RUN_MODE="ssh"
_host_lc="$(printf '%s' "$BOX_HOST" | tr '[:upper:]' '[:lower:]')"
_self_lc="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
case "$_host_lc" in
    ''|localhost|127.0.0.1|::1) RUN_MODE="local" ;;
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
# Ofcom drama range (reserved, never allocated to a subscriber). Composed from
# parts on purpose: a literal here is mobile-SHAPED, and ci-pii-shape-scan
# matches on shape rather than on a list of known values -- correctly, since a
# denylist cannot catch a leak it has never seen. Do not re-inline this.
B_PHONE_CC="+44"
B_PHONE_NDC="7700"
B_PHONE_SUB="900456"
B_PHONE="${B_PHONE_CC} ${B_PHONE_NDC} ${B_PHONE_SUB}"
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

# ===========================================================================
# THE JUDGEMENTS.
#
# Each takes a response FILE and returns a token, so the same adjudicator can
# be driven by a live box in run_probe and by a crafted fixture in self_test.
# They used to be inline heredocs, which is why nothing had ever demonstrated
# that this probe can go red: there was no way to hand them a known-bad answer
# without standing up a whole fake box.
# ===========================================================================

# judge_health_live <bodyfile> -> yes|no
#
# "IS THIS THE OSTLER DAEMON?", not "is this any JSON at all".
#
# This used to return yes for ANY non-empty dict. Both of these are non-empty
# dicts served on 200 from a /health route on the walk box:
#
#   8000  {"companion_paired":false,"paired":false,"require_pairing":false,
#          "runtime":{"components":{...}}}          <- the daemon
#   8090  {"status": "ok"}                          <- ical-server.py
#
# So C1 "live and parseable" passed against a service that is not the Hub, and
# every later control adjudicated that stranger. A 200 on /health is evidence
# that SOMETHING is listening; it is not evidence of WHAT.
#
# Requiring a daemon-only key fails closed on a stranger. The set is small and
# any ONE is enough, so a daemon that drops a field in a later version degrades
# to CANNOT-RUN rather than silently passing on the wrong process.
judge_health_live() {
    python3 - "$1" <<'PY'
import json, sys
DAEMON_KEYS = ("require_pairing", "paired", "companion_paired", "runtime")
try:
    d = json.load(open(sys.argv[1]))
    if not isinstance(d, dict) or not d:
        print("no")
    else:
        print("yes" if any(k in d for k in DAEMON_KEYS) else "no")
except Exception:
    print("no")
PY
}

# judge_people_payload_shape <bodyfile> -> yes|no
# "Does this look like a valid people payload?" -- the predicate C3 proves is
# discriminating. A Hub surface that answers 200 on every path has fooled this
# codebase before.
judge_people_payload_shape() {
    python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print("yes" if isinstance(d, dict) and "found" in d else "no")
except Exception:
    print("no")
PY
}

# judge_dep_health <bodyfile> -> ok:<n>|down:<names>|nochecks|unparseable
# THE DAEMON DOES NOT PUBLISH A TOP-LEVEL "checks" DICT, and this judge only
# knew that shape, so C4 returned "nochecks" against a perfectly healthy Hub.
# Measured on the walk box 2026-08-26, GET /health?detailed=1 on the daemon:
#
#   top level   status, paired, token_paired, companion_paired,
#               require_pairing, runtime
#   runtime     pid, uptime_seconds, updated_at, components
#   components  channels, colima, cron-delivery, daemon, gateway, heartbeat,
#               imessage-tcc, mqtt, scheduler, store:ollama, store:qdrant,
#               store:wiki
#   each one    {"status": "ok", "last_error": null, "restart_count": 0, ...}
#
# So the dependency evidence C4 wants is present and RICHER than "checks" --
# it names the stores individually -- it simply lives elsewhere and reports
# status="ok" rather than ok=true.
#
# Both shapes are accepted. "checks" is tried first so a daemon that does
# publish it is unaffected, and a body carrying NEITHER is still "nochecks",
# which is CANNOT-establish rather than a pass. Widening a control to make it
# green is how a control stops being one; this widens it to the surface that
# actually carries the answer, and reports which shape it read.
judge_dep_health() {
    python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("unparseable"); raise SystemExit
if not isinstance(d, dict):
    print("unparseable"); raise SystemExit

checks = d.get("checks")
if isinstance(checks, dict) and checks:
    bad = [k for k, v in checks.items()
           if isinstance(v, dict) and v.get("ok") is False]
    print("down:" + ",".join(sorted(bad)) if bad else "ok:%d" % len(checks))
    raise SystemExit

runtime = d.get("runtime")
components = runtime.get("components") if isinstance(runtime, dict) else None
if isinstance(components, dict) and components:
    bad = [k for k, v in components.items()
           if isinstance(v, dict) and v.get("status") not in ("ok", None)]
    print("down:" + ",".join(sorted(bad)) if bad else "ok:%d" % len(components))
    raise SystemExit

print("nochecks")
PY
}

# judge_seed <bodyfile> <http_code> -> OK|<slug>|<uri>   or   ERR||<why>
judge_seed() {
    python3 - "$1" "$2" <<'PY'
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
}

# judge_context <bodyfile> <http_code> <want_name> <want_uri>
#   -> OK|AUTH|ERR|DEGRADED|NOTFOUND|MULTI|WRONGNAME|WRONGURI  |  <n>  |  <why>
judge_context() {
    python3 - "$1" "$2" "$3" "$4" "$A_NAME" "$B_NAME" "$ABSENT_NAME" <<'PY'
import json, sys, hashlib
body, code, want_name, want_uri = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
allowed = set(sys.argv[5:]) | {want_name}

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
}

# judge_absence <bodyfile> <http_code> -> CLEAN|HIT|AUTH|ERR|DEGRADED | <why>
judge_absence() {
    python3 - "$1" "$2" <<'PY'
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
}

# judge_vector_spec <bodyfile> -> "<vector_name> <size>"  or  "ERR 0"
judge_vector_spec() {
    python3 - "$1" <<'PY'
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
}

# judge_search <bodyfile> <http_code> <want_name> <want_uri>
#   -> OK|AUTH|ERR|DEGRADED|EMPTY|WRONGNAME|WRONGURI  |  <n>  |  <why>
judge_search() {
    python3 - "$1" "$2" "$3" "$4" "$A_NAME" "$B_NAME" "$ABSENT_NAME" <<'PY'
import json, sys, hashlib
body, code, want_name, want_uri = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
allowed = set(sys.argv[5:]) | {want_name}

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
}

# judge_forgotten_context <bodyfile> -> yes|no|degraded|unknown
judge_forgotten_context() {
    python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("unknown"); raise SystemExit
if d.get("degraded"):
    print("degraded"); raise SystemExit
print("no" if d.get("found") else "yes")
PY
}

# judge_forgotten_search <bodyfile> <name> -> yes|no|degraded|unknown
judge_forgotten_search() {
    python3 - "$1" "$2" <<'PY'
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
}

# ===========================================================================
# THE PHASES.
# ===========================================================================

cleanup_tmp() { local rc=$?; rm -rf "$TMP" 2>/dev/null; return $rc; }
trap cleanup_tmp EXIT

phase0_reach_box_and_token() {
    echo "${PROBE_NAME}: seed-and-retrieval round-trip"
    echo "  box           = ${BOX_LABEL}   (run mode: ${RUN_MODE})"
    echo "  assistant api = ${API_BASE}"
    echo "  primary leg   = GET /api/v1/people/context   (Oxigraph; what pwg_people calls first)"
    echo "  fallback leg  = GET /api/v1/people/search    (Qdrant '${COLLECTION}' + Ollama)"
    echo "  seed / unseed = POST /api/v1/memory/assert, POST /api/v1/people/{slug}/forget"
    echo "  identities    = synthetic only, reserved .example/.test + drama-range numbers"
    echo ""

    echo "PHASE 0 -- reach the box, prove something is listening, resolve the token"
    if ! box_exec "true" >/dev/null 2>&1; then
        verdict_cannot_run "cannot execute on box ${BOX_LABEL} in ${RUN_MODE} mode; no Hub examined"
    fi
    pass "box reachable (${RUN_MODE})"

    # Liveness BEFORE the token, and before any control, because "no Hub here"
    # and "the Hub is broken" are different answers and only one of them is a
    # defect. HTTP 000 is curl reporting that it never got an answer at all.
    local out code live
    out="${TMP}/health.out"
    box_http GET "${API_BASE}/health" noauth "$out"
    code="$(http_code_of "$out")"
    if [ "$code" = "000" ]; then
        verdict_cannot_run "nothing answering at ${API_BASE}/health on ${BOX_LABEL}; no Hub is running here, so no person could be seeded or retrieved"
    fi

    # C1 -- the service is alive and speaks JSON we can actually parse. It IS
    # answering, so anything other than a parseable 200 is a real defect.
    live="$(judge_health_live "${out}.body")"
    CONTROLS_RUN=$((CONTROLS_RUN + 1))
    if [ "$code" = "200" ] && [ "$live" = "yes" ]; then
        pass "C1 /health live and parseable (HTTP 200)"
    else
        fail "C1 /health did not identify as the Ostler daemon (HTTP ${code}, daemon_shape=${live}) -- something is listening on ${API_BASE}, but its /health carries none of require_pairing/paired/companion_paired/runtime. Check you are not pointed at another service on that port."
    fi

    TOKEN="${OSTLER_SERVICE_TOKEN:-}"
    if [ -z "$TOKEN" ]; then
        TOKEN="$(box_exec "cat ${TOKEN_PATH} 2>/dev/null" | tr -d '\r\n' | head -c 512)"
    fi
    if [ -z "$TOKEN" ]; then
        verdict_cannot_run "no service token at ${TOKEN_PATH} on ${BOX_LABEL} and OSTLER_SERVICE_TOKEN unset; the API fails closed with 401 so retrieval cannot be examined at all"
    fi
    case "$TOKEN" in
        *"'"*)
            verdict_cannot_run "service token contains a single quote; refusing to inline it into a shell command, so nothing was examined" ;;
    esac
    pass "service token resolved (${#TOKEN} chars; value never printed)"
    echo ""
}

# ---------------------------------------------------------------------------
# POSITIVE CONTROLS. Each proves the probe can SEE something that is genuinely
# there. Until they pass, no absence claim this probe makes is worth anything.
# ---------------------------------------------------------------------------
phase1_positive_controls() {
    echo "PHASE 1 -- positive controls (all before any absence claim)"

    local out code looks_valid deps

    # C2 -- auth is genuinely enforced on the route under test. If context answers
    # without a token then a later authenticated 200 proves nothing about the
    # authed path, and the install has a real security regression besides.
    out="${TMP}/noauth.out"
    box_http GET "${API_BASE}/api/v1/people/context?name=control" noauth "$out"
    code="$(http_code_of "$out")"; CONTROLS_RUN=$((CONTROLS_RUN + 1))
    if [ "$code" = "401" ]; then
        pass "C2 unauthenticated /people/context refused (HTTP 401) -- the token is load-bearing"
    else
        fail "C2 unauthenticated /people/context returned HTTP ${code}, expected 401 -- auth not enforced, so no later result proves the authed path"
    fi

    # C3 -- our success predicate discriminates. A Hub surface that answers 200 on
    # every path has fooled this codebase before, so prove a nonsense route does
    # NOT satisfy "valid people payload".
    out="${TMP}/nonsense.out"
    box_http GET "${API_BASE}/api/v1/people/context-no-such-route-probe" auth "$out"
    code="$(http_code_of "$out")"; CONTROLS_RUN=$((CONTROLS_RUN + 1))
    looks_valid="$(judge_people_payload_shape "${out}.body")"
    if [ "$looks_valid" = "no" ]; then
        pass "C3 nonsense route does not satisfy the predicate (HTTP ${code}) -- a blanket 200 cannot fake a pass"
    else
        fail "C3 nonsense route returned a valid-looking people payload -- the predicate cannot discriminate and every assertion below would be void"
    fi

    # C4 -- the stores the two legs depend on are actually up. This is the control
    # that stops a dead Oxigraph or Qdrant being reported later as "person absent".
    out="${TMP}/deep.out"
    box_http GET "${API_BASE}/health?detailed=1" auth "$out"
    code="$(http_code_of "$out")"; CONTROLS_RUN=$((CONTROLS_RUN + 1))
    deps="$(judge_dep_health "${out}.body")"
    case "$deps" in
        ok:*) pass "C4 dependency health reports every store up (${deps#ok:} checks, HTTP ${code})" ;;
        down:*) fail "C4 dependency health reports stores DOWN (${deps#down:}) -- absence below would be a store fault, not a missing person" ;;
        *) fail "C4 dependency health unreadable (HTTP ${code}, ${deps}) -- cannot establish the stores are up" ;;
    esac

    if [ "$FAILURES" -gt 0 ]; then
        echo ""
        probe_examined "controls=${CONTROLS_RUN}" "seeded=0 retrieved=0 queries=0 assertions=0"
        verdict_fail "control failed before seeding: ${FIRST_FAILURE}"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# LEG A -- the primary route, entirely through the product's own API.
# ---------------------------------------------------------------------------
phase2_leg_a() {
    echo "PHASE 2 -- LEG A primary route: seed via memory/assert, retrieve via people/context"

    A_SLUG="$(slugify "$A_NAME")"

    local out code req seed_info q verdict st n msg
    # Sweep first. A person left behind by a crashed run would make memory/assert
    # ATTACH instead of MINT, and the created_person assertion below is what turns
    # that into a visible failure rather than a false pass.
    out="${TMP}/presweep.out"
    box_http POST "${API_BASE}/api/v1/people/${A_SLUG}/forget" auth "$out"
    note "pre-seed sweep of slug '${A_SLUG}' returned HTTP $(http_code_of "$out") (idempotent; stale fixtures cannot fake a pass)"

    req="${TMP}/assert.json"
    python3 - "$A_NAME" "$A_FACT" > "$req" <<'PY'
import json, sys
print(json.dumps({"subject": sys.argv[1], "fact_text": sys.argv[2],
                  "asserted_via": "box-walk-probe"}))
PY
    out="${TMP}/assert.out"
    box_http POST "${API_BASE}/api/v1/memory/assert" auth "$out" "$req"
    code="$(http_code_of "$out")"
    ASSERTIONS=$((ASSERTIONS + 1))
    seed_info="$(judge_seed "${out}.body" "$code")"
    SEED_STATUS="$(printf '%s' "$seed_info" | cut -d'|' -f1)"
    A_REAL_SLUG="$(printf '%s' "$seed_info" | cut -d'|' -f2)"
    A_URI="$(printf '%s' "$seed_info" | cut -d'|' -f3)"
    if [ "$SEED_STATUS" = "OK" ] && [ -n "$A_URI" ]; then
        SEEDED=$((SEEDED + 1))
        pass "seeded ${A_NAME} -> minted person_uri (slug '${A_REAL_SLUG}')"
    else
        fail "LEG A seed failed: $(printf '%s' "$seed_info" | cut -d'|' -f3-)"
    fi

    if [ "$SEEDED" -eq 1 ]; then
        q="$(urlencode "$A_NAME")"
        out="${TMP}/ctx.out"
        box_http GET "${API_BASE}/api/v1/people/context?name=${q}" auth "$out"
        code="$(http_code_of "$out")"
        QUERIES=$((QUERIES + 1)); ASSERTIONS=$((ASSERTIONS + 1))
        verdict="$(judge_context "${out}.body" "$code" "$A_NAME" "$A_URI")"
        st="$(printf '%s' "$verdict" | cut -d'|' -f1)"
        n="$(printf '%s' "$verdict" | cut -d'|' -f2)"
        msg="$(printf '%s' "$verdict" | cut -d'|' -f3-)"
        RESULTS_EXAMINED=$((RESULTS_EXAMINED + n))
        if [ "$st" = "OK" ]; then
            RETRIEVED=$((RETRIEVED + 1))
            pass "retrieved ${A_NAME} via /people/context -- ${msg}"
        else
            fail "LEG A retrieval (${st}): ${msg}"
        fi
        if grep -qi "I don't have any information" "${out}.body" 2>/dev/null; then
            fail "context response carries the confabulation tell \"I don't have any information\""
        fi
        ASSERTIONS=$((ASSERTIONS + 1))
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Absence assertion. Safe only because LEG A just proved this exact route
# returns a person that IS there.
# ---------------------------------------------------------------------------
phase3_absence() {
    echo "PHASE 3 -- absence assertion on the same route (valid only now the positive control has passed)"
    local q out code abs abs_st abs_msg
    q="$(urlencode "$ABSENT_NAME")"
    out="${TMP}/absent.out"
    box_http GET "${API_BASE}/api/v1/people/context?name=${q}" auth "$out"
    code="$(http_code_of "$out")"
    QUERIES=$((QUERIES + 1)); ASSERTIONS=$((ASSERTIONS + 1))
    abs="$(judge_absence "${out}.body" "$code")"
    abs_st="$(printf '%s' "$abs" | cut -d'|' -f1)"
    abs_msg="$(printf '%s' "$abs" | cut -d'|' -f2-)"
    if [ "$abs_st" = "CLEAN" ]; then
        pass "never-seeded control '${ABSENT_NAME}' is correctly absent (${abs_msg})"
    else
        fail "absence control (${abs_st}): ${abs_msg}"
    fi
    echo ""
}

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

# ---------------------------------------------------------------------------
# LEG B -- the fallback route. Seeded directly into Qdrant, because
# memory/assert deliberately does not write Qdrant.
# ---------------------------------------------------------------------------
phase4_leg_b() {
    echo "PHASE 4 -- LEG B fallback route: seed Qdrant directly, retrieve via people/search"

    local out code spec req up q v st n msg

    BID="$(b_point_id)"
    IDS_JSON="[\"${BID}\"]"

    out="${TMP}/coll.out"
    box_http GET "${QDRANT_BASE}/collections/${COLLECTION}" noauth "$out"
    code="$(http_code_of "$out")"
    spec="$(judge_vector_spec "${out}.body")"
    VEC_NAME="$(printf '%s' "$spec" | awk '{print $1}')"
    VEC_SIZE="$(printf '%s' "$spec" | awk '{print $2}')"
    LEG_B_OK=0
    if [ "$code" = "200" ] && [ "$VEC_NAME" != "ERR" ] && [ "${VEC_SIZE:-0}" -gt 0 ] 2>/dev/null; then
        pass "qdrant collection '${COLLECTION}' present (vector=${VEC_NAME}, size=${VEC_SIZE})"
        LEG_B_OK=1
    else
        fail "qdrant collection '${COLLECTION}' missing or unreadable (HTTP ${code}, spec='${spec}') -- semantic people search cannot work on this install"
    fi

    if [ "$LEG_B_OK" = "1" ]; then
        note "pre-seed sweep of the probe point returned HTTP $(qdrant_delete presweep)"
        req="${TMP}/emb.json"
        python3 - "$EMBED_MODEL" "$B_NAME" "$B_ORG" > "$req" <<'PY'
import json, sys
print(json.dumps({"model": sys.argv[1],
                  "input": ["%s %s" % (sys.argv[2], sys.argv[3])]}))
PY
        out="${TMP}/emb.out"
        box_http POST "${EMBED_BASE}/api/embed" noauth "$out" "$req" "$EMBED_TIMEOUT"
        code="$(http_code_of "$out")"
        if [ "$code" != "200" ]; then
            fail "embedding call returned HTTP ${code} -- retrieval is semantic, so a dead embedder means the customer cannot find anyone"
            LEG_B_OK=0
        fi
    fi

    if [ "$LEG_B_OK" = "1" ]; then
        up="${TMP}/up.json"
        python3 - "${TMP}/emb.out.body" "$BID" "$B_NAME" "$B_ORG" "$B_EMAIL" "$B_PHONE" \
                 "$B_URI" "$VEC_NAME" "$VEC_SIZE" > "$up" <<'PY'
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
        out="${TMP}/up.out"
        box_http PUT "${QDRANT_BASE}/collections/${COLLECTION}/points?wait=true" noauth "$out" "${TMP}/up.json"
        code="$(http_code_of "$out")"
        if [ "$code" = "200" ]; then
            SEEDED=$((SEEDED + 1))
            pass "seeded ${B_NAME} into qdrant '${COLLECTION}'"
        else
            fail "qdrant seed returned HTTP ${code} -- the people collection rejects writes"
            LEG_B_OK=0
        fi
    fi

    if [ "$LEG_B_OK" = "1" ]; then
        q="$(urlencode "$B_NAME")"
        out="${TMP}/search.out"
        box_http GET "${API_BASE}/api/v1/people/search?q=${q}" auth "$out"
        code="$(http_code_of "$out")"
        QUERIES=$((QUERIES + 1)); ASSERTIONS=$((ASSERTIONS + 1))
        v="$(judge_search "${out}.body" "$code" "$B_NAME" "$B_URI")"
        st="$(printf '%s' "$v" | cut -d'|' -f1)"
        n="$(printf '%s' "$v" | cut -d'|' -f2)"
        msg="$(printf '%s' "$v" | cut -d'|' -f3-)"
        RESULTS_EXAMINED=$((RESULTS_EXAMINED + n))
        if [ "$st" = "OK" ]; then
            RETRIEVED=$((RETRIEVED + 1))
            pass "retrieved ${B_NAME} via /people/search -- ${msg} (${n} results examined)"
        else
            fail "LEG B retrieval (${st}): ${msg}"
        fi
    fi
    echo ""
}

phase5_cleanup() {
    echo "PHASE 5 -- remove both fixtures and verify they are actually gone"

    local out code q gone target_slug del

    if [ "$SEED_STATUS" = "OK" ]; then
        out="${TMP}/forget.out"
        target_slug="${A_REAL_SLUG:-$A_SLUG}"
        box_http POST "${API_BASE}/api/v1/people/${target_slug}/forget" auth "$out"
        code="$(http_code_of "$out")"
        q="$(urlencode "$A_NAME")"
        out="${TMP}/ctx_after.out"
        box_http GET "${API_BASE}/api/v1/people/context?name=${q}" auth "$out"
        QUERIES=$((QUERIES + 1)); ASSERTIONS=$((ASSERTIONS + 1))
        gone="$(judge_forgotten_context "${out}.body")"
        if [ "$gone" = "yes" ]; then
            CLEANED=$((CLEANED + 1))
            pass "LEG A fixture forgotten (HTTP ${code}) and confirmed gone from /people/context"
        else
            fail "LEG A fixture still present after forget (state=${gone}) -- probe leaked a fixture into the graph"
        fi
    fi

    if [ "$LEG_B_OK" = "1" ]; then
        del="$(qdrant_delete final)"
        q="$(urlencode "$B_NAME")"
        out="${TMP}/search_after.out"
        box_http GET "${API_BASE}/api/v1/people/search?q=${q}" auth "$out"
        QUERIES=$((QUERIES + 1)); ASSERTIONS=$((ASSERTIONS + 1))
        gone="$(judge_forgotten_search "${out}.body" "$B_NAME")"
        if [ "$gone" = "yes" ]; then
            CLEANED=$((CLEANED + 1))
            pass "LEG B fixture deleted (HTTP ${del}) and confirmed gone from /people/search"
        else
            fail "LEG B fixture still retrievable after delete (state=${gone}) -- probe leaked a fixture into the graph"
        fi
    fi
    echo ""
}

run_probe() {
    phase0_reach_box_and_token
    phase1_positive_controls
    phase2_leg_a
    phase3_absence
    phase4_leg_b
    phase5_cleanup

    probe_examined "controls=${CONTROLS_RUN}" \
        "seeded=${SEEDED}/2 retrieved=${RETRIEVED}/2 queries=${QUERIES} assertions=${ASSERTIONS} results_inspected=${RESULTS_EXAMINED} cleaned=${CLEANED}/2 failures=${FAILURES}"

    if [ "$FAILURES" -gt 0 ]; then
        verdict_fail "${FIRST_FAILURE} [controls=${CONTROLS_RUN} seeded=${SEEDED}/2 retrieved=${RETRIEVED}/2 cleaned=${CLEANED}/2 failures=${FAILURES}]"
    fi

    verdict_pass "${RETRIEVED}/2 synthetic people seeded and retrieved on ${BOX_LABEL} via people/context + people/search [controls=${CONTROLS_RUN} queries=${QUERIES} results=${RESULTS_EXAMINED} cleaned=${CLEANED}/2]"
}

# ===========================================================================
# THE NEGATIVE CONTROL.
#
# Phase 1 of run_box_walk.sh invokes this and DEMANDS a FAIL. It touches no
# network and no box: every fixture below is a response this probe could
# receive, written to disk and handed to the SAME judge the live run uses.
#
# The convention is inverted on purpose and is the whole point. A control that
# fired correctly ends in verdict_fail -- the runner reads exit 1 as "this
# probe can go red". A control that did NOT fire ends in verdict_pass, exit 0,
# which the runner reads as BROKEN and whose result it then discards. So the
# only way to be trusted is to demonstrate a red.
# ===========================================================================
self_test() {
    local body r

    probe_examined "fixtures=14" "synthetic API responses adjudicated by the live judges (no box touched)"

    # 0. THE STRANGER-SERVICE FIXTURE. `{"status": "ok"}` is byte-for-byte what
    #    ical-server.py returns on /health, and the old judge called that a live
    #    Hub. If judge_health_live accepts it, C1 cannot tell the Ostler daemon
    #    from any other process that happens to serve /health -- which is
    #    precisely how the v1.0.47 walk adjudicated the wrong service for its
    #    entire run and then reported FAIL about the result.
    body="${TMP}/st_stranger_health.json"
    printf '%s' '{"status": "ok"}' > "$body"
    r="$(judge_health_live "$body")"
    if [ "$r" != "no" ]; then
        verdict_pass "NEGATIVE CONTROL DID NOT FIRE: a bare status-ok body adjudicated as '${r}', so C1 cannot tell the Ostler daemon from any other service with a /health route."
    fi

    # 0b. POSITIVE CONTROL, and it is not decoration. Tightening a predicate is
    #     the easy way to make a probe green by making it refuse everything, so
    #     the real daemon shape must still be ACCEPTED.
    body="${TMP}/st_daemon_health.json"
    printf '%s' '{"paired": false, "require_pairing": false, "runtime": {"components": {}}}' > "$body"
    r="$(judge_health_live "$body")"
    if [ "$r" != "yes" ]; then
        verdict_pass "POSITIVE CONTROL DID NOT FIRE: a real daemon /health shape adjudicated as '${r}', not yes -- C1 would now refuse the Hub itself."
    fi

    # 1. HTTP 200 + degraded:true. The trap the whole probe is built around: a
    #    dead store answers 200 and must never read as "the person is absent".
    body="${TMP}/st_degraded.json"
    printf '%s' '{"degraded": true, "reason": "oxigraph refused connection", "found": false}' > "$body"
    r="$(judge_context "$body" 200 "$A_NAME" "uri:a")"
    if [ "${r%%|*}" != "DEGRADED" ]; then
        verdict_pass "NEGATIVE CONTROL DID NOT FIRE: a degraded 200 adjudicated as '${r%%|*}', not DEGRADED. A dead store would be reported as a missing person."
    fi

    # 2. found:false for a person minted moments ago.
    body="${TMP}/st_notfound.json"
    printf '%s' '{"found": false}' > "$body"
    r="$(judge_context "$body" 200 "$A_NAME" "uri:a")"
    if [ "${r%%|*}" != "NOTFOUND" ]; then
        verdict_pass "NEGATIVE CONTROL DID NOT FIRE: found:false adjudicated as '${r%%|*}'."
    fi

    # 3. Right name, wrong person_uri. Identity mismatch, not a near miss.
    body="${TMP}/st_wronguri.json"
    python3 - "$A_NAME" > "$body" <<'PY'
import json, sys
print(json.dumps({"found": True,
                  "person": {"name": sys.argv[1], "person_uri": "uri:somebody-else"}}))
PY
    r="$(judge_context "$body" 200 "$A_NAME" "uri:a")"
    if [ "${r%%|*}" != "WRONGURI" ]; then
        verdict_pass "NEGATIVE CONTROL DID NOT FIRE: a person_uri mismatch adjudicated as '${r%%|*}'."
    fi

    # 4. A DIFFERENT person comes back -- and the masking must fire, because on
    #    a real box this is where somebody's actual name would be printed into
    #    a cut log. The decoy is the SAME constructed identity the CI fixture
    #    uses (test_people_seed_and_retrieval_probe.sh), deliberately off this
    #    probe's allowlist, so both negative controls exercise masking with one
    #    value that is already declared in .pii-name-registry.tsv rather than
    #    inventing a second name-shaped string for a guard to have to trust.
    body="${TMP}/st_wrongname.json"
    printf '%s' '{"found": true, "person": {"name": "Gwendolyn Ashcombe-Decoy", "person_uri": "uri:a"}}' > "$body"
    r="$(judge_context "$body" 200 "$A_NAME" "uri:a")"
    if [ "${r%%|*}" != "WRONGNAME" ]; then
        verdict_pass "NEGATIVE CONTROL DID NOT FIRE: a different person adjudicated as '${r%%|*}'."
    fi
    case "$r" in
        *"Ashcombe"*)
            verdict_pass "NEGATIVE CONTROL DID NOT FIRE: the retrieved name was printed unmasked. On a real box that is somebody's actual name in the cut log." ;;
    esac
    case "$r" in
        *"<redacted"*) ;;
        *) verdict_pass "NEGATIVE CONTROL DID NOT FIRE: an off-allowlist name produced no redaction marker, so the masking cannot be shown to have run." ;;
    esac

    # 5. The honest answer must still pass. A control that fires on everything
    #    is a probe that fails every box, which costs exactly as much trust.
    body="${TMP}/st_good.json"
    python3 - "$A_NAME" > "$body" <<'PY'
import json, sys
print(json.dumps({"found": True,
                  "person": {"name": sys.argv[1], "person_uri": "uri:a"}}))
PY
    r="$(judge_context "$body" 200 "$A_NAME" "uri:a")"
    if [ "${r%%|*}" != "OK" ]; then
        verdict_pass "NEGATIVE CONTROL OVER-FIRED: a correct context response adjudicated as '${r%%|*}'. This probe would fail a healthy box."
    fi

    # 6. 401 is a token/Host fault. Reading it as absence is how a broken
    #    credential becomes "you have no contacts".
    r="$(judge_context "$body" 401 "$A_NAME" "uri:a")"
    if [ "${r%%|*}" != "AUTH" ]; then
        verdict_pass "NEGATIVE CONTROL DID NOT FIRE: HTTP 401 adjudicated as '${r%%|*}' rather than AUTH."
    fi

    # 7. The fallback route returns nothing for a person seeded moments ago --
    #    the exact shape of an empty Qdrant collection that install.sh counts
    #    as "Search index ready".
    body="${TMP}/st_empty.json"
    printf '%s' '{"results": []}' > "$body"
    r="$(judge_search "$body" 200 "$B_NAME" "$B_URI")"
    if [ "${r%%|*}" != "EMPTY" ]; then
        verdict_pass "NEGATIVE CONTROL DID NOT FIRE: an empty search result adjudicated as '${r%%|*}'. An empty people collection is precisely what this probe exists to catch."
    fi

    # 8. Degraded on the fallback route, same trap, other leg.
    body="${TMP}/st_search_degraded.json"
    printf '%s' '{"degraded": true, "reason": "qdrant unreachable", "results": []}' > "$body"
    r="$(judge_search "$body" 200 "$B_NAME" "$B_URI")"
    if [ "${r%%|*}" != "DEGRADED" ]; then
        verdict_pass "NEGATIVE CONTROL DID NOT FIRE: a degraded search adjudicated as '${r%%|*}'."
    fi

    # 9. A name that was never seeded coming back as found.
    body="${TMP}/st_hit.json"
    printf '%s' '{"found": true, "person": {"name": "whoever", "person_uri": "uri:x"}}' > "$body"
    r="$(judge_absence "$body" 200)"
    if [ "${r%%|*}" != "HIT" ]; then
        verdict_pass "NEGATIVE CONTROL DID NOT FIRE: a never-seeded name reported found adjudicated as '${r%%|*}'."
    fi

    # 10. Dependency health reporting a store down.
    body="${TMP}/st_deps.json"
    printf '%s' '{"checks": {"oxigraph": {"ok": false}, "qdrant": {"ok": true}}}' > "$body"
    r="$(judge_dep_health "$body")"
    case "$r" in
        down:*) ;;
        *) verdict_pass "NEGATIVE CONTROL DID NOT FIRE: a store reporting ok:false adjudicated as '${r}'." ;;
    esac

    # 11. memory/assert answering 200 without actually minting a Person.
    body="${TMP}/st_seed.json"
    printf '%s' '{"status": "attached_to_existing"}' > "$body"
    r="$(judge_seed "$body" 200)"
    if [ "${r%%|*}" != "ERR" ]; then
        verdict_pass "NEGATIVE CONTROL DID NOT FIRE: a seed that did not mint a person adjudicated as '${r%%|*}'."
    fi

    # 12. A people collection whose vector config cannot be read at all.
    body="${TMP}/st_vec.json"
    printf '%s' '{"result": {}}' > "$body"
    r="$(judge_vector_spec "$body")"
    if [ "$r" != "ERR 0" ]; then
        verdict_pass "NEGATIVE CONTROL DID NOT FIRE: an unreadable vector config adjudicated as '${r}'."
    fi

    verdict_fail "negative control fired on all 14 fixtures (stranger-service /health, degraded-200 on both legs, found:false, wrong uri, wrong+masked name, 401-is-not-absence, empty search, false hit, store down, non-minting seed, unreadable vector config) and left the honest response green"
}

probe_main "$@"
