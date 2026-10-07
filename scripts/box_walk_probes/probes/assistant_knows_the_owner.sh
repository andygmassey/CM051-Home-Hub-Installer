#!/usr/bin/env bash
# probes/assistant_knows_the_owner.sh
# ============================================================================
# QUESTION: across identity, work, family, friends, habits, money and more,
#           how much of what the graph holds about the OWNER actually reaches
#           a plain question about themselves?
#
# WHY THIS EXISTS. Andy, asking his own Hub "Where have I worked?", was told
# there was no record -- on a box holding real history. assistant_answers_grounded
# already measures whether a THIRD PARTY's facts reach an answer (Jane Doe,
# cable engineer). It does not ask about the OWNER at all. This probe is that
# other half: a synthetic owner persona, seeded through the SAME write surfaces
# the shipped product uses, then asked the questions a person actually asks
# about themselves.
#
# ADVISORY, NOT BLOCKING (scripts/walk_promote_scope.tsv). This is a new,
# unproven instrument on its first PR. It reports a score; it does not refuse
# a promote. Promote to blocking is a later, separate decision once it has run
# clean on a real box -- the same path assistant_grounds_the_opening_turn took.
#
# THE QUESTION BANK: lib/owner_knowledge_questions.tsv, ~70 questions across 15
# domains (identity, work, education, family/partner, friends, places, food,
# media, hobbies, routines, health, money, recent events, upcoming, drifting
# relationships). Most rows carry NO seeded fact -- they are the catalogue of
# what a full persona would need, left honestly unseeded rather than padded
# with facts cheap to plant and pointless to ask. Exactly ONE live-asked row
# per underlying seeded fact (17 rows), so NOT_INGESTED is never claimed about
# a fact this run never tried to plant, and the LLM-turn budget stays bounded
# (17 turns x the suite's own measured 2-5 min/turn, same order as the grounded
# probe's three-question battery, not an order of magnitude more).
#
# SEEDING, THROUGH THE PRODUCT'S OWN SURFACES, NEVER A FIXTURE BEHIND ITS BACK:
#   employer    -- the REAL customer path: a synthetic Positions.csv (LinkedIn
#                  GDPR export shape) run through ${OSTLER_DIR}/bin/ostler-import,
#                  the same CLI install.sh wires up and a customer runs by hand
#                  to re-import a folder Ostler missed. Company: "ExampleCo"
#                  (Andy, 2026-10-07: match the employer name the other
#                  owner-identity probe in flight uses).
#   4 relationships (partner, sister, 2 friends) -- POST /api/v1/memory/assert,
#                  the exact route and payload shape OS003 gates/seed/load_seed.py
#                  already proved works, read back via /people/context. These
#                  are real third parties (not the owner), so this is the
#                  identical mechanism assistant_answers_grounded's seed uses,
#                  just four more synthetic people with their own names.
#   10 self-attribute facts (education, places, food, media, hobbies, routines,
#                  health, money, recent events, upcoming) -- a direct SPARQL
#                  INSERT of a pwg:PersonFact onto the OWNER's own node
#                  (https://schema.ostler.ai/ontology#user_<USER_ID>, the exact
#                  URI contact_syncer.linkedin_career and owner_node.py write
#                  to). HONESTLY NAMED: this is the same triple SHAPE the
#                  shipped importers write, not a file parsed by one of them,
#                  because no per-domain importer exists for diet, hobbies or
#                  a dentist appointment. It is a real write to the real store
#                  through the real predicate the daemon reads, not a fixture
#                  in a vault nothing consumes.
#
# SYNTHETIC CAST ONLY, every name on .pii-name-registry.tsv's cast: Alison Coe,
# Elizabeth Ross, Alexander Patel, Mary Stewart. Riverside/Riverside college/
# Riverside bay (cast placename), Globex streaming (cast fictional company), ExampleCo
# (per Andy's instruction, matching example.com already used by the sibling
# fixture).
#
# SCORING, never on answer text alone -- same discipline as the sibling probe:
#   PASS              the final reply carries the expected fact
#   FAIL:NOT_INGESTED  the fact never reached the graph after seeding (or was
#                      never seeded at all -- a catalogue row)
#   FAIL:NOT_RETRIEVED the fact is in the graph; no tool result the model saw
#                      carried it
#   FAIL:MODEL_IGNORED a tool result DID carry it; the final reply did not
# classify_question() below is the one function that decides this, and it is
# exactly the function self_test() drives with planted fixtures -- never a
# re-implementation of the judgement, the real one.
#
# PRIVACY: the reply's prose never leaves the box. The embedded client computes
# containment ON the box and emits only FRAME reply_fact YES|NO and
# FRAME tool_fact YES|NO, the same discipline assistant_answers_grounded uses.
#
# RUNTIME: see the budget note above. OSTLER_PROBE_CHAT_TIMEOUT tunes the
# per-turn ceiling; OSTLER_OWNER_KNOWLEDGE_ONLY restricts to a substring match
# on domain, for a fast manual check of one domain.
#
# BASH 3.2 (macOS system bash). No associative arrays, no mapfile.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="assistant_knows_the_owner"
PROBE_QUESTION="across identity, work, family, friends and habits, how much of what the graph holds about the OWNER reaches a plain question about themselves?"

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
QUESTIONS_TSV="${OSTLER_OWNER_QUESTIONS_TSV:-${_LIB_DIR}/owner_knowledge_questions.tsv}"

GATEWAY="${OSTLER_PROBE_GATEWAY:-http://127.0.0.1:8000}"
CHAT_TIMEOUT="${OSTLER_PROBE_CHAT_TIMEOUT:-300}"
ADMIN_TOKEN_PATH="${OSTLER_PROBE_TOKEN_PATH:-~/.ostler/secrets/zeroclaw_admin_token}"
SERVICE_TOKEN_PATH="${OSTLER_SERVICE_TOKEN_PATH:-~/.ostler/secrets/service_token}"
PEOPLE_PORT="${OSTLER_PEOPLE_PORT:-8090}"
OSTLER_DIR_REMOTE="${OSTLER_DIR:-\$HOME/.ostler}"
DOMAIN_ONLY="${OSTLER_OWNER_KNOWLEDGE_ONLY:-}"

# ── THE SEEDER, embedded. Ships to the box exactly as grounding_seed.sh ships
# load_seed.py: base64'd, decoded on the far side, run, discarded. ──────────
_seeder_py() {
    cat <<'PYEOF'
import csv, hashlib, json, os, subprocess, sys, tempfile, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone

_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # no proxy, ever: loopback only

def _esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

def read_dotenv(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                k, v = k.strip(), v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                    v = v[1:-1]
                out[k] = v
    except OSError:
        pass
    return out

def sparql_update(oxigraph_url, sparql):
    req = urllib.request.Request(oxigraph_url.rstrip("/") + "/update", data=sparql.encode("utf-8"),
                                  method="POST", headers={"Content-Type": "application/sparql-update"})
    with _OPENER.open(req, timeout=15) as r:
        r.read()

def sparql_ask(oxigraph_url, query):
    req = urllib.request.Request(oxigraph_url.rstrip("/") + "/query", data=query.encode("utf-8"),
                                  method="POST", headers={"Content-Type": "application/sparql-query",
                                                           "Accept": "application/sparql-results+json"})
    with _OPENER.open(req, timeout=15) as r:
        js = json.loads(r.read().decode("utf-8"))
    return bool(js.get("boolean"))

def owner_uri(user_id):
    return "https://schema.ostler.ai/ontology#user_%s" % user_id

def write_owner_fact(oxigraph_url, user_id, text, fact_type):
    uri = owner_uri(user_id)
    fid = hashlib.sha256(("owner_knowledge_probe:" + text).encode("utf-8")).hexdigest()[:16]
    furi = "https://schema.ostler.ai/ontology#fact_%s" % fid
    now = datetime.now(timezone.utc).isoformat()
    sparql = (
        "PREFIX pwg: <https://schema.ostler.ai/ontology#>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        "INSERT DATA { <%s> a pwg:PersonFact ; "
        'pwg:factType "%s" ; pwg:factText "%s" ; '
        "pwg:aboutPerson <%s> ; "
        'pwg:createdAt "%s"^^xsd:dateTime ; '
        'pwg:source "owner_knowledge_probe_seed" . }'
        % (furi, _esc(fact_type), _esc(text), uri, now)
    )
    sparql_update(oxigraph_url, sparql)

def owner_fact_contains(oxigraph_url, user_id, substring):
    uri = owner_uri(user_id)
    q = ('PREFIX pwg: <https://schema.ostler.ai/ontology#>\n'
         'ASK { ?f a pwg:PersonFact ; pwg:aboutPerson <%s> ; pwg:factText ?t . '
         'FILTER(CONTAINS(?t, "%s")) }' % (uri, _esc(substring)))
    return sparql_ask(oxigraph_url, q)

def seed_employer_linkedin(ostler_dir):
    d = tempfile.mkdtemp(prefix="ownerprobe-")
    with open(os.path.join(d, "Positions.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["Company Name", "Title", "Description", "Location", "Started On", "Finished On"])
        w.writerow(["ExampleCo", "senior field engineer", "", "Riverside", "Jan 2019", ""])
    importer = os.path.join(ostler_dir, "bin", "ostler-import")
    if not (os.path.isfile(importer) and os.access(importer, os.X_OK)):
        return False, "no ostler-import at %s" % importer
    try:
        r = subprocess.run([importer, d], capture_output=True, text=True, timeout=120)
    except Exception as exc:
        return False, "ostler-import failed to run: %s" % exc
    if r.returncode != 0:
        return False, "ostler-import exit %d: %s" % (r.returncode, (r.stderr or r.stdout)[-300:])
    return True, "ostler-import exit 0"

def people_api(port, token, method, path, body=None, timeout=15.0):
    data = None
    headers = {"Authorization": "Bearer %s" % token, "Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request("http://127.0.0.1:%s%s" % (port, path), data=data, method=method, headers=headers)
    try:
        with _OPENER.open(req, timeout=timeout) as r:
            return r.status, _parse(r.read())
    except urllib.error.HTTPError as e:
        return e.code, _parse(e.read())
    except (urllib.error.URLError, OSError) as exc:
        return None, str(exc)

def _parse(raw):
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return None

def _facts_of(js):
    if isinstance(js, dict) and "facts" in js:
        return js["facts"]
    if isinstance(js, list):
        for item in js:
            if isinstance(item, dict) and "facts" in item:
                return item["facts"]
    return None

def assert_person_fact(port, token, name, sentence):
    status, js = people_api(port, token, "POST", "/api/v1/memory/assert",
                             {"subject": name, "fact_text": sentence, "asserted_via": "owner-knowledge-probe-seed"})
    return status == 200 and isinstance(js, dict)

def person_fact_contains(port, token, name, substring):
    status, js = people_api(port, token, "GET", "/api/v1/people/context?name=%s" % urllib.parse.quote(name))
    if status != 200:
        return False
    facts = _facts_of(js)
    return facts is not None and any(substring.lower() in str(f).lower() for f in facts)

def forget_person(port, token, name):
    status, js = people_api(port, token, "GET", "/api/v1/people/context?name=%s" % urllib.parse.quote(name))
    slug = None
    if isinstance(js, dict):
        slug = js.get("slug")
    elif isinstance(js, list) and js and isinstance(js[0], dict):
        slug = js[0].get("slug")
    if slug:
        people_api(port, token, "POST", "/api/v1/people/%s/forget" % slug)

OWNER_FACTS = [
    ("education", "The user studied mechanical engineering at Riverside college.", "Riverside college"),
    ("places", "The user went on holiday to Riverside bay last year.", "Riverside bay"),
    ("food", "The user's favourite cuisine is Thai food, especially green curry.", "Thai food"),
    ("media", "The user has recently been watching a detective drama called Saltmarsh.", "Saltmarsh"),
    ("hobbies", "The user's hobby is woodworking, building small furniture at weekends.", "woodworking"),
    ("routines", "The user wakes at 6am and goes for a run most mornings.", "6am"),
    ("health", "The user's imported step count averages around 9000 steps a day.", "9000 steps"),
    ("money", "The user has a subscription to a streaming service called Globex streaming, billed monthly.", "Globex streaming"),
    ("recent_events", "The user recently moved house in Riverside.", "moved house"),
    ("upcoming", "The user has a dentist appointment next Tuesday.", "dentist appointment"),
]
REL_FACTS = [
    ("partner", "Alison Coe", "Alison Coe is the user's partner.", "Alison Coe"),
    ("sister", "Elizabeth Ross",
     "Elizabeth Ross is the user's sister. They last saw each other in March 2026 in Riverside.", "March 2026"),
    ("friend1", "Alexander Patel", "Alexander Patel is one of the user's closest friends.", "Alexander Patel"),
    ("friend2", "Mary Stewart",
     "Mary Stewart is one of the user's closest friends, but the user has not spoken to her in over four months.",
     "Mary Stewart"),
]

def main():
    cmd = sys.argv[1]
    ostler_dir = os.path.expanduser(sys.argv[2])
    people_port = sys.argv[3]
    token_path = os.path.expanduser(sys.argv[4])
    try:
        token = open(token_path, encoding="utf-8").read().strip()
    except OSError:
        token = ""

    if cmd == "forget":
        for _, name, _, _ in REL_FACTS:
            try:
                if token:
                    forget_person(people_port, token, name)
            except Exception:
                pass
        print("FORGET done")
        return 0

    env = read_dotenv(os.path.join(ostler_dir, "config", ".env"))
    oxigraph_url, user_id = env.get("OXIGRAPH_URL", ""), env.get("USER_ID", "")
    if not oxigraph_url or not user_id:
        print("SEED ALL CANNOT_RUN OXIGRAPH_URL=%r USER_ID=%r unreadable from %s/config/.env"
              % (oxigraph_url, user_id, ostler_dir))
        return 0

    for key, text, check in OWNER_FACTS:
        try:
            write_owner_fact(oxigraph_url, user_id, text, "owner_knowledge_probe")
            ok = owner_fact_contains(oxigraph_url, user_id, check)
            print("SEED %s %s" % (key, "INGESTED" if ok else "ABSENT"))
        except Exception as exc:
            print("SEED %s CANNOT_RUN %s" % (key, exc))

    ok, detail = seed_employer_linkedin(ostler_dir)
    if not ok:
        print("SEED employer CANNOT_RUN %s" % detail)
    else:
        try:
            ok2 = owner_fact_contains(oxigraph_url, user_id, "ExampleCo")
            print("SEED employer %s" % ("INGESTED" if ok2 else "ABSENT"))
        except Exception as exc:
            print("SEED employer CANNOT_RUN %s" % exc)

    if not token:
        for key, _, _, _ in REL_FACTS:
            print("SEED %s CANNOT_RUN no service token at %s" % (key, token_path))
    else:
        for key, name, sentence, check in REL_FACTS:
            try:
                asserted = assert_person_fact(people_port, token, name, sentence)
                ok = person_fact_contains(people_port, token, name, check) if asserted else False
                print("SEED %s %s" % (key, "INGESTED" if ok else "ABSENT"))
            except Exception as exc:
                print("SEED %s CANNOT_RUN %s" % (key, exc))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
PYEOF
}

# ── THE CHAT CLIENT, embedded. Same transport and the same privacy discipline
# as assistant_answers_grounded.sh's: /ws/chat, admin bearer token, containment
# computed on the box, only FRAME lines cross the wire. ─────────────────────
_ws_client_py() {
    cat <<'PYEOF'
import base64, json, os, re, socket, struct, sys, time

_FUNCTION_WORDS = {"a", "an", "and", "as", "at", "by", "for", "from", "in", "is",
                   "of", "on", "or", "the", "to", "with"}

def components(fact):
    return [w for w in re.split(r"[^a-z0-9.@'-]+", fact.lower()) if w and w not in _FUNCTION_WORDS]

def carries(text, fact):
    if not fact:
        return False
    cs = components(fact)
    t = text.lower()
    return bool(cs) and all(re.search(r"(?<![a-z0-9])" + re.escape(c) + r"(?![a-z0-9])", t) for c in cs)

def carries_any(text, fact, alt):
    return carries(text, fact) or (bool(alt) and carries(text, alt))

if len(sys.argv) > 1 and sys.argv[1] == "--self-check":
    print("YES" if carries_any(sys.stdin.read(), sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "") else "NO")
    sys.exit(0)

host, port = "127.0.0.1", int(sys.argv[1])
token_path, question, deadline_s = sys.argv[2], sys.argv[3], float(sys.argv[4])
expect_fact = sys.argv[5] if len(sys.argv) > 5 else ""
alt_fact = sys.argv[6] if len(sys.argv) > 6 else ""
try:
    token = open(os.path.expanduser(token_path)).read().strip()
except Exception as e:
    print("PROBE_FATAL no_token %s" % e); sys.exit(3)

deadline = time.time() + deadline_s
try:
    s = socket.create_connection((host, port), timeout=20)
except Exception as e:
    print("PROBE_FATAL no_connect %s" % e); sys.exit(3)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(("GET /ws/chat HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
           "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: zeroclaw.v1\r\n"
           "Authorization: Bearer %s\r\n\r\n" % (host, port, key, token)).encode())
buf = b""
while b"\r\n\r\n" not in buf:
    c = s.recv(4096)
    if not c:
        print("PROBE_FATAL handshake_eof"); sys.exit(3)
    buf += c
head, rest = buf.split(b"\r\n\r\n", 1)
status = head.split(b"\r\n")[0].decode(errors="replace")
if "101" not in status:
    print("PROBE_FATAL handshake %s" % status); sys.exit(3)

def send(p):
    d = p.encode(); m = os.urandom(4)
    mk = bytes(b ^ m[i % 4] for i, b in enumerate(d)); n = len(d)
    if n < 126:      h = struct.pack("!BB", 0x81, 0x80 | n)
    elif n < 65536:  h = struct.pack("!BBH", 0x81, 0x80 | 126, n)
    else:            h = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
    s.sendall(h + m + mk)

def rd(n):
    global rest
    o = b""
    while len(o) < n:
        if rest:
            t = rest[: n - len(o)]; o += t; rest = rest[len(t):]
        else:
            s.settimeout(max(1, deadline - time.time()))
            c = s.recv(65536)
            if not c: raise EOFError
            rest = c
    return o

def frame():
    b0, b1 = rd(2); op = b0 & 0x0F; n = b1 & 0x7F
    if n == 126:   n = struct.unpack("!H", rd(2))[0]
    elif n == 127: n = struct.unpack("!Q", rd(8))[0]
    return op, rd(n)

send(json.dumps({"type": "message", "content": question}))

text = ""
saw_tool_call = False
tool_fact_yes = False
while time.time() < deadline:
    try:
        op, pay = frame()
    except Exception:
        print("FRAME timeout"); break
    if op == 8:
        print("FRAME close"); break
    if op != 1:
        continue
    try:
        ev = json.loads(pay)
    except Exception:
        print("FRAME unparseable"); continue
    t = ev.get("type", "?")
    if t == "tool_call":
        saw_tool_call = True
        print("FRAME tool_call %s" % ev.get("name", "?"))
    elif t == "tool_result":
        out = str(ev.get("output", ""))
        if expect_fact and carries_any(out, expect_fact, alt_fact):
            tool_fact_yes = True
        print("FRAME tool_result %s" % ev.get("name", "?"))
    elif t == "chunk":
        c = ev.get("content") or ""
        text += c
    elif t == "chunk_reset":
        text = ""
        print("FRAME chunk_reset")
    elif t in ("done", "session_start", "error"):
        if t == "done":
            graded = ev.get("full_response", text) or text
            print("FRAME tool_fact %s" % ("YES" if tool_fact_yes else "NO"))
            print("FRAME reply_fact %s" % ("YES" if carries_any(graded, expect_fact, alt_fact) else "NO"))
            print("FRAME saw_tool_call %s" % ("YES" if saw_tool_call else "NO"))
        print("FRAME %s" % t)
        if t in ("done", "error"):
            break
PYEOF
}

# ── THE SCORER. This is the function self_test() drives, unchanged. ────────
# classify_question <seed_status: INGESTED|ABSENT|CANNOT_RUN> <transcript|->
# -> PASS | FAIL:NOT_INGESTED | FAIL:NOT_RETRIEVED | FAIL:MODEL_IGNORED | CANNOT_RUN
classify_question() {
    local seed_status="$1" transcript="$2"
    case "$seed_status" in
        ABSENT)     printf 'FAIL:NOT_INGESTED'; return ;;
        CANNOT_RUN) printf 'CANNOT_RUN'; return ;;
    esac
    # seed_status = INGESTED from here on.
    if [ "$transcript" = "-" ] || [ ! -s "$transcript" ]; then
        printf 'CANNOT_RUN'; return
    fi
    if ! grep -q '^FRAME done$' "$transcript"; then
        printf 'CANNOT_RUN'; return
    fi
    if grep -q '^FRAME reply_fact YES$' "$transcript"; then
        printf 'PASS'; return
    fi
    if grep -q '^FRAME tool_fact YES$' "$transcript"; then
        printf 'FAIL:MODEL_IGNORED'; return
    fi
    printf 'FAIL:NOT_RETRIEVED'
}

# ── Shipping files to the box. Same base64-JSON-over-stdin technique as
# lib/grounding_seed.sh's _gs_run_loader, written fresh here because this
# probe must not source or edit that file. ──────────────────────────────────
_ship_and_run() {
    # _ship_and_run <remote_filename> <local_content_fn> <plain_remote_arg_string>
    #
    # Same transport assistant_answers_grounded.sh's run_probe already uses:
    # base64 the file, embed it (base64's alphabet has no shell metacharacter,
    # so single-quoting it is safe), `base64 -d` it back to a file on the box,
    # run it there, discard it. box_run is lib/probe.sh's own primitive; this
    # adds no new one.
    #
    # The arg string is interpolated UNQUOTED into the remote script on
    # purpose, the same convention lib/grounding_seed.sh's helpers use: every
    # value this file passes here is either a fixed keyword ("seed", "forget")
    # or a path default spelled with $HOME / ~ that must still be a live
    # reference when the REMOTE shell parses the line. Neither carries
    # customer-controlled text; the one value that does (the question text,
    # in ask_question below) is kept out of this helper and quoted there.
    local fname="$1" fn="$2" argstr="$3"
    local payload
    payload="$("$fn" | base64 | tr -d '\n')"
    box_run "
d=\$(mktemp -d) || exit 2
printf %s '${payload}' | base64 -d > \"\$d/${fname}\"
python3 \"\$d/${fname}\" ${argstr}
rc=\$?
rm -rf \"\$d\"
exit \$rc
"
}

run_seed() {
    _ship_and_run "owner_probe_seed.py" _seeder_py "seed ${OSTLER_DIR_REMOTE} ${PEOPLE_PORT} ${SERVICE_TOKEN_PATH}"
}

run_forget() {
    _ship_and_run "owner_probe_seed.py" _seeder_py "forget ${OSTLER_DIR_REMOTE} ${PEOPLE_PORT} ${SERVICE_TOKEN_PATH}"
}

seed_status_for() {
    # seed_status_for <key> <seed_output_file>
    local line
    line="$(grep "^SEED $1 " "$2" 2>/dev/null | tail -1)"
    case "$line" in
        *INGESTED*)   printf 'INGESTED' ;;
        *ABSENT*)     printf 'ABSENT' ;;
        *CANNOT_RUN*) printf 'CANNOT_RUN' ;;
        *)            printf 'CANNOT_RUN' ;;
    esac
}

ask_question() {
    # ask_question <question> <expect> <alt> <transcript_out_path>
    #
    # Question/expect/alt text is embedded LOCAL-single-quoted (grounding_seed's
    # own convention) rather than shipped on stdin, so it must never carry an
    # apostrophe -- lib/owner_knowledge_questions.tsv's self-test-adjacent rule
    # is that every LIVE-ASKED question, expect_fact and alt_fact is checked by
    # hand for one. (Catalogue-only rows are never passed to a shell at all.)
    local q="$1" expect="$2" alt="$3" out="$4"
    local b64 port
    b64="$(_ws_client_py | base64 | tr -d '\n')"
    port="${GATEWAY##*:}"
    box_run "
d=\$(mktemp -d) || exit 2
printf %s '${b64}' | base64 -d > \"\$d/c.py\"
python3 \"\$d/c.py\" ${port} '${ADMIN_TOKEN_PATH}' \"\$(printf %s '${q}')\" ${CHAT_TIMEOUT} \"\$(printf %s '${expect}')\" \"\$(printf %s '${alt}')\"
rc=\$?
rm -rf \"\$d\"
exit \$rc
" > "$out" 2>&1
}

# ── REPORTING STATE. Flat files, not associative arrays (bash 3.2). ────────
_TALLY=""   # lines: "domain<TAB>verdict"

run_probe() {
    box_reachable || probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)}; no owner-knowledge question was asked"
    [ -f "${QUESTIONS_TSV}" ] || probe_cannot_run "no question bank at ${QUESTIONS_TSV}"

    local seed_out
    seed_out="$(mktemp)"
    run_seed > "${seed_out}" 2>&1
    probe_note "seed step output:"
    while IFS= read -r l; do probe_note "  ${l}"; done < "${seed_out}"

    local total=0 asked=0 ingested=0 pass=0 fail_ni=0 fail_nr=0 fail_mi=0 cannot=0
    local tally_file _raw_line _pipe_line
    tally_file="$(mktemp)"

    # 🔴 TAB IS AN "IFS WHITESPACE" CHARACTER TO `read`, EVEN WHEN IT IS THE
    # ONLY CHARACTER IN IFS: bash collapses RUNS of it and strips a leading or
    # trailing one, exactly as it would for space. Measured: a row with two
    # consecutive empty fields ("...met me?\t\t\tANY\t\t") read back with
    # "ANY" landed in the THIRD field (expect_fact), not the fifth
    # (accept_tools) -- every catalogue-only row then carried a non-empty
    # expect_fact and was asked live against a seed_key that was never seeded,
    # scoring CANNOT_RUN for all 71 rows instead of skipping 54 of them as
    # NOT_INGESTED. `|` never appears in this TSV's content (checked below),
    # so translating tabs to it first gives `read` a delimiter it will not
    # coalesce, and empty fields survive.
    while IFS= read -r _raw_line; do
        case "$_raw_line" in \#*|"") continue ;; esac
        case "$_raw_line" in *'|'*)
            probe_fail "lib/owner_knowledge_questions.tsv contains a literal '|', which the field-split workaround below assumes never happens; fix the workaround before trusting any row" ;;
        esac
        _pipe_line="$(printf '%s' "$_raw_line" | tr '\t' '|')"
        IFS='|' read -r domain question expect alt _accept _seed_method seed_key <<< "$_pipe_line"
        case "$domain" in \#*|"") continue ;; esac
        [ -n "${DOMAIN_ONLY}" ] && case "$domain" in *"${DOMAIN_ONLY}"*) ;; *) continue ;; esac
        total=$(( total + 1 ))

        if [ -z "$expect" ]; then
            # Catalogue-only row: never seeded, never asked. True NOT_INGESTED,
            # not a re-worded duplicate of something this run DID seed.
            printf '%s\tFAIL:NOT_INGESTED\n' "$domain" >> "${tally_file}"
            fail_ni=$(( fail_ni + 1 ))
            continue
        fi

        asked=$(( asked + 1 ))
        local status
        status="$(seed_status_for "${seed_key}" "${seed_out}")"
        local verdict transcript
        if [ "$status" = "INGESTED" ]; then
            ingested=$(( ingested + 1 ))
            transcript="$(mktemp)"
            ask_question "$question" "$expect" "$alt" "$transcript"
            verdict="$(classify_question "$status" "$transcript")"
            rm -f "$transcript"
        else
            verdict="$(classify_question "$status" "-")"
        fi
        printf '%s\t%s\n' "$domain" "$verdict" >> "${tally_file}"
        case "$verdict" in
            PASS)                pass=$(( pass + 1 )) ;;
            FAIL:NOT_INGESTED)    fail_ni=$(( fail_ni + 1 )) ;;
            FAIL:NOT_RETRIEVED)   fail_nr=$(( fail_nr + 1 )) ;;
            FAIL:MODEL_IGNORED)   fail_mi=$(( fail_mi + 1 )) ;;
            CANNOT_RUN)           cannot=$(( cannot + 1 )) ;;
        esac
        probe_note "$(printf '%-28s %-55s -> %s' "$domain" "$question" "$verdict")"
    done < "${QUESTIONS_TSV}"

    run_forget >/dev/null 2>&1 || true

    probe_note ""
    probe_note "PER-DOMAIN SCORE (pass/asked, NOT_INGESTED excluded from the denominator):"
    local d
    for d in $(awk -F'\t' '!/^#/{print $1}' "${QUESTIONS_TSV}" | sort -u); do
        local dp dasked
        dp="$(awk -F'\t' -v dd="$d" '$1==dd && $2=="PASS"' "${tally_file}" | wc -l | tr -d ' ')"
        dasked="$(awk -F'\t' -v dd="$d" '$1==dd && $2!="FAIL:NOT_INGESTED"' "${tally_file}" | wc -l | tr -d ' ')"
        [ "$dasked" -gt 0 ] && probe_note "  ${d}: ${dp}/${dasked}"
    done

    probe_examined "$total" "owner-knowledge questions in the catalogue (${asked} rows had a seeded fact to try; ${ingested} were confirmed ingested before being asked)"
    probe_note "TOTALS: pass=${pass} not_ingested=${fail_ni} not_retrieved=${fail_nr} model_ignored=${fail_mi} cannot_run=${cannot} of ${total}"
    rm -f "${seed_out}" "${tally_file}"

    # ingested, never asked: the seed step itself could not run (no box config,
    # no token, transport down). That is lost coverage, not a product fact --
    # the EXACT zero-denominator shape this whole suite exists to refuse, and
    # a PASS printed over it would be the false "16 confirmed ingested" this
    # file's own first local run produced before this check existed.
    if [ "$ingested" -eq 0 ]; then
        probe_cannot_run "no seeded fact could be confirmed ingested (seed step CANNOT_RUN or every fact came back ABSENT); nothing was asked of the assistant"
    fi
    if [ $(( fail_nr + fail_mi )) -gt 0 ]; then
        probe_fail "owner knowledge gaps on a seeded box: ${fail_nr} not_retrieved, ${fail_mi} model_ignored, out of ${ingested} confirmed-ingested questions asked (${fail_ni} catalogue rows never seeded, excluded). ADVISORY: see scripts/walk_promote_scope.tsv."
    fi
    probe_pass "every seeded owner fact confirmed ingested (${ingested} of them) reached the final reply"
}

# ---------------------------------------------------------------------------
# NEGATIVE CONTROLS. classify_question is exercised directly, with planted
# transcripts, so the self-test drives the same function run_probe calls --
# never a re-implementation of the judgement.
# ---------------------------------------------------------------------------
self_test() {
    local fail=0 r tmp

    # 1. ABSENT must FAIL:NOT_INGESTED. "one seeded question whose expected
    #    fact is deliberately absent must FAIL" -- the task's own requirement.
    r="$(classify_question ABSENT -)"
    [ "$r" = "FAIL:NOT_INGESTED" ] || { fail=1; probe_note "control: ABSENT adjudicated as '${r}', not FAIL:NOT_INGESTED"; }

    # 2. CANNOT_RUN seed status must stay CANNOT_RUN, never a pass.
    r="$(classify_question CANNOT_RUN -)"
    [ "$r" = "CANNOT_RUN" ] || { fail=1; probe_note "control: CANNOT_RUN seed status adjudicated as '${r}'"; }

    # 3. INGESTED + a transcript whose reply carried the fact must PASS.
    #    "one present fact must PASS" -- the task's other requirement.
    tmp="$(mktemp)"
    printf 'FRAME tool_call pwg_people\nFRAME tool_result pwg_people\nFRAME tool_fact YES\nFRAME reply_fact YES\nFRAME done\n' > "$tmp"
    r="$(classify_question INGESTED "$tmp")"
    [ "$r" = "PASS" ] || { fail=1; probe_note "control: a reply carrying the fact adjudicated as '${r}', not PASS"; }

    # 4. INGESTED + tool carried it, reply did not -> MODEL_IGNORED.
    printf 'FRAME tool_call pwg_people\nFRAME tool_result pwg_people\nFRAME tool_fact YES\nFRAME reply_fact NO\nFRAME done\n' > "$tmp"
    r="$(classify_question INGESTED "$tmp")"
    [ "$r" = "FAIL:MODEL_IGNORED" ] || { fail=1; probe_note "control: tool-had-it/reply-dropped-it adjudicated as '${r}', not FAIL:MODEL_IGNORED"; }

    # 5. INGESTED + no tool ever carried it, reply did not -> NOT_RETRIEVED.
    printf 'FRAME tool_call pwg_overview\nFRAME tool_result pwg_overview\nFRAME tool_fact NO\nFRAME reply_fact NO\nFRAME done\n' > "$tmp"
    r="$(classify_question INGESTED "$tmp")"
    [ "$r" = "FAIL:NOT_RETRIEVED" ] || { fail=1; probe_note "control: nothing-ever-carried-it adjudicated as '${r}', not FAIL:NOT_RETRIEVED"; }

    # 6. INGESTED + a turn that never finished (no FRAME done) -> CANNOT_RUN,
    #    never a silent PASS or a FAIL that blames the product for a transport
    #    failure.
    printf 'FRAME tool_call pwg_people\nFRAME timeout\n' > "$tmp"
    r="$(classify_question INGESTED "$tmp")"
    [ "$r" = "CANNOT_RUN" ] || { fail=1; probe_note "control: an incomplete turn adjudicated as '${r}', not CANNOT_RUN"; }

    rm -f "$tmp"

    # 7. The containment predicate itself: word-boundary, case-insensitive,
    #    two-component fact, plus the alt-fact OR arm. The client script and
    #    the self-check's INPUT TEXT both want stdin, so the script goes to a
    #    file first -- piping _ws_client_py straight into `python3 -` and
    #    THEN redirecting a heredoc at the same command makes the heredoc win
    #    and the script vanish, which is exactly the shape that silently
    #    turned this control into three Python syntax errors on its first run.
    local client_py
    client_py="$(mktemp)"
    _ws_client_py > "$client_py"
    r="$(python3 "$client_py" --self-check 'cable engineer at example.com' '' <<< "works as a submarine CABLE ENGINEER at example.com")"
    [ "$r" = "YES" ] || { fail=1; probe_note "control: carries() missed a correct paraphrase (got ${r})"; }
    r="$(python3 "$client_py" --self-check 'cable engineer at example.com' '' <<< "no information about the persons job")"
    [ "$r" = "NO" ] || { fail=1; probe_note "control: carries() matched text with none of the fact's components (got ${r})"; }
    r="$(python3 "$client_py" --self-check 'Alexander Patel' 'Mary Stewart' <<< "your closest friend is Mary Stewart")"
    [ "$r" = "YES" ] || { fail=1; probe_note "control: carries_any() missed the alt-fact arm (got ${r})"; }
    rm -f "$client_py"

    probe_examined 9 "adjudication controls (5 seed/verdict states, 1 incomplete-turn, 3 containment predicates)"

    if [ "$fail" -ne 0 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: classify_question or carries_any misclassified a planted fixture, so a green from this probe would prove nothing"
    fi
    probe_fail "control fired: ABSENT, CANNOT_RUN, PASS, MODEL_IGNORED, NOT_RETRIEVED, an incomplete turn, and the containment predicate's paraphrase/absence/alt-fact arms are each classified correctly"
}

probe_main "$@"
