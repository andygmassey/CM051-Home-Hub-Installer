#!/usr/bin/env bash
# probes/people_stores_reconcile.sh
# ============================================================================
# QUESTION: do the graph and the vector store hold the SAME set of people --
#           not merely the same NUMBER of them?
#
# WHY A SECOND PROBE. people_count_agreement compares two totals. Two totals
# that are both wrong can agree, and on the box measured 2026-08-26 they were
# both wrong in ways a total cannot show:
#
#     qdrant distinct person_uri   7284
#     graph  distinct Person       7111
#     in QDRANT not in GRAPH        203
#     in GRAPH not in QDRANT         30      203 - 30 = 173
#
# The headline "gap of 173" is a NET figure hiding two defects of opposite sign
# that partially cancel. Anyone fixing "173 orphans" deletes 173 of the 203 and
# never learns about the 30. Set arithmetic answers what subtraction cannot.
#
# THE THREE RESIDUALS, each a different defect with a different owner:
#
#   A  terminal untyped merge survivors
#      A merge DELETES the discard's rdf:type and never ASSERTS the survivor's,
#      while copying displayName/givenName/organization onto it. Merging into a
#      URI that was not already a live Person therefore yields a node that
#      acquires every person property and never acquires the type: person-
#      shaped, untyped, invisible to every "?p a pwg:Person" count. 106 of these
#      on the box measured. CM041 fix: "a merge must leave the SURVIVOR typed".
#      A CHAINED merge (A->B, B->C) strips B's type legitimately, so chained
#      survivors are excluded -- 35 of them, and counting those as defects would
#      have been a false red.
#
#   B  orphan vectors
#      A person_uri with a vector and NO presence in the graph at all. 97 on the
#      box. merge_persons is graph-only, so an absorbed node keeps its vector.
#      These inflate every people count the customer sees.
#
#   C  named persons with no vector
#      A graph Person carrying a human name but no vector is a contact the
#      customer cannot find by searching. That is the customer-visible half.
#      DELIBERATELY NARROWED TO *NAMED*: all 30 unvectored persons on the box
#      measured carry prefLabel identical to their email address and no name at
#      all -- 9 are provably role/robot addresses and the other 21 are an
#      address someone was written to once. Embedding those would push raw email
#      addresses into the People tab as if they were contacts. So an unnamed
#      stub is REPORTED and does not fail the probe; whether it should be a
#      Person node at all is a product question, not a defect this gate can
#      settle.
#
#   D  the number the CUSTOMER is shown
#      Task #273 measured THREE surfaces and got three answers: Oxigraph 6376,
#      Doctor hydration 6755, UI 6547. The UI matched NEITHER store -- it had
#      arrived at a third number of its own. Two of those surfaces are stores
#      and are covered above; the third is the only one anybody actually reads.
#
#      The wiki's headline tile is compiled markdown, not an API:
#          <span class="pw-tile-n">7,111</span>
#          <span class="pw-tile-l">People</span>
#      Measured 2026-08-26 it reads 7,111 -- exactly the graph count, so the
#      customer is being shown a figure 76 short of the reconciled 7,187.
#
#      D FAILS ONLY WHEN IT MATCHES NEITHER the graph count NOR the reconciled
#      count. That is deliberate and it is the #273 predicate:
#        - matching the graph count means the tile faithfully renders a store
#          this probe already fails on via A and B. Failing it again would
#          report one defect twice and hide whether the UI itself is sound.
#        - matching the reconciled count is correct.
#        - matching NEITHER means the UI computed its own third number, which
#          is the actual #273 defect and is invisible to any store-vs-store
#          check.
#      It also means a wiki compiled one cycle behind does not flap the gate.
#
# WHY THIS IS NOT A TOLERANCE CHECK. A residual is not drift. Each of A, B and C
# names a specific broken write path, and the correct value for each is zero.
# There is no ingest race that produces a merge survivor with no rdf:type.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="people_stores_reconcile"
PROBE_QUESTION="do the graph and the vector store hold the same SET of people?"

OXIGRAPH_URL="${OSTLER_OXIGRAPH_URL:-http://127.0.0.1:7878/query}"
QDRANT_URL="${OSTLER_QDRANT_URL:-http://127.0.0.1:6333}"
QDRANT_COLLECTION="${OSTLER_QDRANT_PEOPLE_COLLECTION:-people}"

# STORE CREDENTIAL. Both stores 401 to a keyless request on every enforce-ON
# install (#550/#1222). This probe reads them via python urllib, not curl, so
# the credential is parsed from the install's own curl config and injected as
# request headers -- and a 401 is split three ways INSIDE the payload:
# AUTHFAIL (credential presented and refused -> FAIL) vs KEYLESS (no credential
# presented -> CANNOT-RUN). STORE_CONF_PATH is $HOME expanded on the box (never
# the literal STORE_CURL_CONF, whose unexpanded $HOME the box python could not
# open -- the urllib analogue of the #1284 curl bug).
STORE_CURL_CONF="${OSTLER_PROBE_STORE_CURL_CONF:-\$HOME/.ostler/secrets/store-curl.conf}"
STORE_CONF_PATH=""

_store_resolve() {
    STORE_CONF_PATH="$(box_run "printf '%s' \"${STORE_CURL_CONF}\"" | tr -d '\r\n')"
}

# The reconciliation is set arithmetic over ~7k URIs from two stores. bash 3.2
# has no associative arrays -- and /bin/bash is 3.2.57 here AND on the cut host
# -- so the join runs in python3 on the box. Single-quoted below and free of
# "$" and backticks so nothing expands on the way through box_run.
read -r -d '' RECONCILE_PY <<'PYPAYLOAD'
import json, os, sys
try:
    import urllib.request, urllib.error
except Exception as exc:
    print("CANNOTRUN urllib " + str(exc)); sys.exit(0)

OXI = sys.argv[1]; QD = sys.argv[2]; COLL = sys.argv[3]
CONF = sys.argv[4] if len(sys.argv) > 4 else ""
P   = "https://schema.ostler.ai/ontology#"
SKOS= "http://www.w3.org/2004/02/skos/core#prefLabel"

# The install store credential, parsed from its curl config header lines and
# presented on every store request so an enforce-ON store answers. Its presence
# also decides whether a 401 is a refused key (AUTHFAIL) or a keyless probe
# (KEYLESS). No shell metacharacters here -- this payload must stay literal.
STORE_HEADERS = {}
CRED_REASON = ""
if not CONF:
    CRED_REASON = "no store curl config path was provided to the probe"
elif not os.path.exists(CONF):
    CRED_REASON = "the store curl config " + CONF + " does not exist on the box"
elif not os.access(CONF, os.R_OK):
    CRED_REASON = ("the store curl config " + CONF + " exists but is not readable by "
                   "this probe's account -- it is written 0600 owner-only, so a probe "
                   "running as a different user cannot read a config that may be full of "
                   "headers; this is NOT evidence the credential is absent")
else:
    try:
        for line in open(CONF, encoding="utf-8"):
            line = line.strip()
            if line.startswith("header") and "=" in line:
                val = line.split("=", 1)[1].strip().strip('"')
                if ":" in val:
                    k, v = val.split(":", 1)
                    STORE_HEADERS[k.strip()] = v.strip()
    except Exception as exc:
        CRED_REASON = ("the store curl config " + CONF
                       + " could not be read: " + type(exc).__name__)
    if not STORE_HEADERS and not CRED_REASON:
        CRED_REASON = ("the store curl config " + CONF
                       + " is readable but carries no 'header = ' lines")
HAVE_CRED = bool(STORE_HEADERS)

# Bypass any operator proxy (HTTP_PROXY / http_proxy) -- the python analogue of
# curl --noproxy '*'. Without it a local proxy answers for 127.0.0.1 with its own
# 5xx, masking the store's real 401 and reading as the store being down.
urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))

def sparql(q):
    h = {"Content-Type": "application/sparql-query",
         "Accept": "application/sparql-results+json"}
    h.update(STORE_HEADERS)
    req = urllib.request.Request(OXI, data=q.encode(), headers=h)
    try:
        return json.load(urllib.request.urlopen(req, timeout=120))["results"]["bindings"]
    except urllib.error.HTTPError as exc:
        exc._store = "Oxigraph (SPARQL) at " + OXI
        raise

def qpost(path, body):
    h = {"Content-Type": "application/json"}
    h.update(STORE_HEADERS)
    req = urllib.request.Request(QD + path, data=json.dumps(body).encode(), headers=h)
    try:
        return json.load(urllib.request.urlopen(req, timeout=60))
    except urllib.error.HTTPError as exc:
        exc._store = "Qdrant (vector store) at " + QD
        raise

try:
    # Control FIRST: a store that answers 0 triples is a store we cannot read,
    # and every residual below would then read as a clean zero.
    triples = int(sparql("SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }")[0]["n"]["value"])
    if triples == 0:
        print("CANNOTRUN graph-empty"); sys.exit(0)

    graph = set()
    for b in sparql("SELECT ?p WHERE { ?p a <" + P + "Person> }"):
        graph.add(b["p"]["value"])

    vec, fixture, nxt, npoints = set(), set(), None, 0
    while True:
        # ASK FOR THE FIXTURE FLAG TOO. people_seed_and_retrieval seeds a point
        # carrying "box_walk_probe": True and removes it in its phase 5. It is
        # the ONLY file in the tree that knows that flag exists -- measured --
        # so if its cleanup ever fails, the leaked point lands in residual B
        # below and THIS probe blames the product for the suite's own fixture.
        # Reading the flag is what lets the two be told apart.
        body = {"limit": 1000, "with_payload": ["person_uri", "box_walk_probe"], "with_vector": False}
        if nxt is not None:
            body["offset"] = nxt
        r = qpost("/collections/" + COLL + "/points/scroll", body)["result"]
        for pt in r["points"]:
            npoints += 1
            pl = pt.get("payload") or {}
            u = pl.get("person_uri")
            if u:
                vec.add(u)
                if pl.get("box_walk_probe"):
                    fixture.add(u)
        nxt = r.get("next_page_offset")
        if nxt is None:
            break
    if npoints == 0:
        print("CANNOTRUN qdrant-empty"); sys.exit(0)

    # A: merge survivors that are terminal (did NOT merge onward) and untyped.
    a = int(sparql(
        "SELECT (COUNT(DISTINCT ?o) AS ?n) WHERE { "
        "  ?s <" + P + "mergedInto> ?o . "
        "  FILTER NOT EXISTS { ?o a <" + P + "Person> } "
        "  FILTER NOT EXISTS { ?o <" + P + "mergedInto> ?z } }")[0]["n"]["value"])

    # B: a vector whose URI has no presence in the graph in ANY position.
    # SPLIT BY WHO MADE IT. A vector this suite seeded and failed to remove is a
    # defect of the WALK, and people_seed_and_retrieval already fails loudly on
    # exactly that ("probe leaked a fixture into the graph"). Failing here as
    # well would report one defect twice and, worse, would report it against the
    # DMG -- this probe is artefact-owned, so its red refuses the promote. Same
    # reasoning the header already applies to chained merge survivors and to
    # residual D.
    b_orphan = 0
    b_fixture = 0
    for u in sorted(vec - graph):
        n_s = int(sparql("SELECT (COUNT(*) AS ?n) WHERE { <" + u + "> ?p ?o }")[0]["n"]["value"])
        n_o = int(sparql("SELECT (COUNT(*) AS ?n) WHERE { ?s ?p <" + u + "> }")[0]["n"]["value"])
        if n_s == 0 and n_o == 0:
            if u in fixture:
                b_fixture += 1
            else:
                b_orphan += 1

    # C: graph Person with no vector, split by whether a HUMAN NAME is known.
    c_named = 0; c_unnamed = 0
    for u in sorted(graph - vec):
        label = ""; email = ""
        rows = sparql("SELECT ?l WHERE { <" + u + "> <" + SKOS + "> ?l }")
        if rows: label = rows[0]["l"]["value"].strip()
        rows = sparql("SELECT ?e WHERE { <" + u + "> <" + P + "email> ?e }")
        if rows: email = rows[0]["e"]["value"].strip()
        dn = sparql("SELECT ?d WHERE { <" + u + "> <" + P + "displayName> ?d }")
        named = bool(dn) or (label != "" and label.lower() != email.lower())
        if named: c_named += 1
        else: c_unnamed += 1

    # b_fixture is APPENDED, ninth. The reader below takes $2..$8 exactly as
    # before, so a self-test fixture written against the eight-field line still
    # drives the same arithmetic and reports the attribution as NOT MEASURED
    # rather than as zero.
    print("OK %d %d %d %d %d %d %d %d" % (
        len(graph), len(vec), a, b_orphan, c_named, c_unnamed, len(vec & graph),
        b_fixture))
except urllib.error.HTTPError as exc:
    store = getattr(exc, "_store", "an unidentified store")
    if exc.code in (401, 403):
        if HAVE_CRED:
            print("AUTHFAIL %d %s" % (exc.code, store))
        else:
            print("KEYLESS %d %s" % (exc.code, CRED_REASON))
    else:
        print("CANNOTRUN HTTPError %d from %s" % (exc.code, store))
except Exception as exc:
    print("CANNOTRUN " + type(exc).__name__ + " " + str(exc)[:120])
PYPAYLOAD

# The tile is COMPILED MARKDOWN, so this is keyed to a CSS class and a class is
# a NAME, and gates keyed to names rot. Mitigated two ways: the pairing must
# match (a number span IMMEDIATELY followed by a label span saying People), and
# a marker that cannot be found returns UNREADABLE rather than 0. A missing tile
# must never read as "the customer is shown zero people".
read_wiki_people_tile() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_TILE:-UNREADABLE}"; return; fi
    box_run "python3 - <<'OSTLERTILE'
import os, re
p = os.path.expanduser(\"~/Documents/Ostler/Wiki/index.md\")
try:
    src = open(p, encoding=\"utf-8\").read()
except Exception:
    print(\"UNREADABLE\"); raise SystemExit
m = re.search(r'pw-tile-n\">([0-9,]+)<[^>]*>\\s*<span class=\"pw-tile-l\">People<', src)
if not m:
    print(\"UNREADABLE\"); raise SystemExit
print(m.group(1).replace(\",\", \"\"))
OSTLERTILE"
}

read_result() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_RECONCILE:-CANNOTRUN self-test-unset}"; return; fi
    box_run "python3 - '${OXIGRAPH_URL}' '${QDRANT_URL}' '${QDRANT_COLLECTION}' '${STORE_CONF_PATH}' <<'PYPAYLOAD'
${RECONCILE_PY}
PYPAYLOAD"
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "box ${OSTLER_BOX_HOST:-localhost} is not reachable over ssh; nothing was measured"
    fi

    _store_resolve

    local out _af _kl
    out="$(read_result)"

    case "$out" in
        OK\ *) : ;;
        AUTHFAIL\ *)
            _af="${out#AUTHFAIL }"
            probe_examined 0 "person records across two stores"
            probe_fail "${_af#* } returned HTTP ${_af%% *} WITH the install's store credential presented (from ${STORE_CONF_PATH}); a key the store refuses is a real fault, not a missing probe credential." ;;
        KEYLESS\ *)
            _kl="${out#KEYLESS }"
            probe_examined 0 "person records across two stores"
            probe_cannot_run "a store returned HTTP ${_kl%% *} and this run presented NO store credential -- ${_kl#* }. Store auth is ENFORCED since #550/#1222, so a keyless probe cannot read the two sets -- nothing was measured." ;;
        CANNOTRUN\ *)
            probe_cannot_run "reconciliation could not run: ${out#CANNOTRUN }" ;;
        "")
            probe_cannot_run "the reconciliation returned NOTHING -- python3 missing on the box, or ssh dropped the payload. An empty answer is not a clean answer." ;;
        *)
            probe_cannot_run "unrecognised reconciliation output (first 120 chars): $(printf '%s' "$out" | head -c 120)" ;;
    esac

    local graph vec a b c_named c_unnamed both b_fixture
    graph=$(printf '%s' "$out" | awk '{print $2}')
    vec=$(printf '%s'   "$out" | awk '{print $3}')
    a=$(printf '%s'     "$out" | awk '{print $4}')
    b=$(printf '%s'     "$out" | awk '{print $5}')
    c_named=$(printf '%s'   "$out" | awk '{print $6}')
    c_unnamed=$(printf '%s' "$out" | awk '{print $7}')
    both=$(printf '%s'  "$out" | awk '{print $8}')
    b_fixture=$(printf '%s' "$out" | awk '{print $9}')

    probe_examined "$((graph + vec))" "person records across two stores (graph ${graph}, vectors ${vec}, in both ${both})"

    probe_note "residual A  untyped terminal merge survivors : ${a}"
    probe_note "residual B  orphan vectors, no graph presence: ${b}"
    # PRINT IT EVEN WHEN IT IS ZERO. A zero that is never printed and a
    # measurement that never ran look identical from the log, and this suite
    # exists because they used to.
    case "$b_fixture" in
        ''|*[!0-9]*)
            probe_note "            of which are OUR OWN fixtures     : NOT MEASURED -- the reconciliation did not report the box_walk_probe flag, so a leaked seed would be counted against the product below" ;;
        *)
            probe_note "            of which are OUR OWN fixtures     : ${b_fixture}  (excluded from B: people_seed_and_retrieval owns that failure)" ;;
    esac
    probe_note "residual C  NAMED persons with no vector     : ${c_named}"
    probe_note "            unnamed stubs with no vector     : ${c_unnamed}  (reported, not failed -- see header)"

    local tile reconciled d_state
    tile="$(read_wiki_people_tile)"
    reconciled=$((graph + a - c_unnamed))
    case "$tile" in
        ''|UNREADABLE|*[!0-9]*)
            d_state="unreadable"
            probe_note "residual D  wiki People tile           : UNREADABLE (marker absent or page missing) -- NOT counted as zero" ;;
        *)
            if [ "$tile" -eq "$reconciled" ]; then
                d_state="ok"
            elif [ "$tile" -eq "$graph" ]; then
                d_state="tracks-graph"
            else
                d_state="third-number"
            fi
            probe_note "residual D  wiki People tile           : ${tile}  (graph ${graph}, reconciled ${reconciled}) -> ${d_state}" ;;
    esac

    local failures=""
    [ "$a" -gt 0 ] && failures="${failures}A=${a} untyped merge survivors; "
    [ "$b" -gt 0 ] && failures="${failures}B=${b} orphan vectors; "
    # A leaked fixture does NOT go in $failures. It is reported above and it is
    # the red of people_seed_and_retrieval, because that probe seeds it, verifies
    # its own removal, and says "probe leaked a fixture into the graph" when the
    # removal did not take. This probe refusing the promote for it would blame
    # the DMG for the harness.
    [ "$c_named" -gt 0 ] && failures="${failures}C=${c_named} named persons unsearchable; "
    # D only when the stores agree. If A or B is non-zero the tile tracking the
    # graph is a CONSEQUENCE, and reporting it as a second failure would say one
    # defect twice while hiding whether the UI itself is sound.
    if [ "$a" -eq 0 ] && [ "$b" -eq 0 ] && [ "$d_state" = "third-number" ]; then
        failures="${failures}D=wiki tile ${tile} matches neither store (graph ${graph}, reconciled ${reconciled}); "
    fi

    if [ -n "$failures" ]; then
        probe_fail "the two stores hold different SETS of people -- ${failures%; }"
    fi
    probe_pass "graph and vector store hold the same set of people; all three residuals are zero"
}


# ---------------------------------------------------------------------------
# self_test -- the probe must be able to DEMONSTRATE a fail, not merely compile.
#
# Each case drives the real verdict logic through FAKE_RECONCILE, so the parser,
# the residual arithmetic and the three-state branching are all exercised. A
# probe whose self-test only checks the happy path cannot tell PASS from
# "measured nothing".
# ---------------------------------------------------------------------------
self_test() {
    # NOTE THE INVERTED CONVENTION, which is deliberate and documented in
    # run_box_walk.sh PHASE 1: a self-test that BEHAVED CORRECTLY exits 1 via
    # probe_fail, because phase 1 reads exit 1 as "this probe can go red on
    # known-bad input". Exiting 0 here means a negative control DID NOT FIRE,
    # and phase 1 treats that as BROKEN. So probe_pass below is the failure
    # path, not the success path.
    SELF_TEST_LOCAL=1
    probe_examined 18 "synthetic reconciliation results (negative control)"
    local rc out fails=0 firstbad=""

    _case() {
        # _case <label> <FAKE value> <expected exit code>
        local label="$1" fake="$2" want="$3"
        out="$(SELF_TEST_LOCAL=1 FAKE_RECONCILE="$fake" run_probe 2>&1)"; rc=$?
        if [ "$rc" -ne "$want" ]; then
            printf '  SELF-TEST FAIL [%s]: expected exit %s, got %s\n' "$label" "$want" "$rc"
            printf '    output: %s\n' "$(printf '%s' "$out" | tail -1)"
            fails=$((fails + 1))
            [ -z "$firstbad" ] && firstbad="$label"
        else
            printf '  ok [%s] exit %s\n' "$label" "$rc"
        fi
    }

    # graph vec A B C_named C_unnamed both
    _tcase() {
        # _tcase <label> <FAKE_RECONCILE> <FAKE_TILE> <expected exit>
        local label="$1" fake="$2" tile="$3" want="$4"
        out="$(SELF_TEST_LOCAL=1 FAKE_RECONCILE="$fake" FAKE_TILE="$tile" run_probe 2>&1)"; rc=$?
        if [ "$rc" -ne "$want" ]; then
            printf '  SELF-TEST FAIL [%s]: expected exit %s, got %s\n' "$label" "$want" "$rc"
            printf '    output: %s\n' "$(printf '%s' "$out" | tail -1)"
            fails=$((fails + 1))
            [ -z "$firstbad" ] && firstbad="$label"
        else
            printf '  ok [%s] exit %s\n' "$label" "$rc"
        fi
    }

    # ---- residual D. graph vec A B Cn Cu both ; reconciled = graph + A - Cu
    # stores agree (A=B=0), tile matches reconciled -> PASS
    _tcase "D tile correct -> PASS"           "OK 7187 7187 0 0 0 0 7187" "7187" "$PROBE_EX_PASS"
    # stores agree, tile matches NEITHER -> the #273 defect -> FAIL
    _tcase "D tile is a THIRD number -> FAIL" "OK 7187 7187 0 0 0 0 7187" "6547" "$PROBE_EX_FAIL"
    # stores agree, tile tracks the graph, which here EQUALS reconciled -> PASS
    _tcase "D tile tracks graph -> PASS"      "OK 7187 7187 0 0 0 0 7187" "7187" "$PROBE_EX_PASS"
    # THE ONE THAT MATTERS: A is non-zero, so a graph-tracking tile is a
    # CONSEQUENCE and must not be reported as a separate D failure.
    # Exit code ALONE cannot test this: suppressed and not-suppressed both exit
    # 1, because A already failed. The claim is about the MESSAGE, so the
    # message is what gets asserted.
    out="$(SELF_TEST_LOCAL=1 FAKE_RECONCILE="OK 7111 7284 106 0 0 30 7081" \
           FAKE_TILE="7111" run_probe 2>&1)"; rc=$?
    if [ "$rc" -ne "$PROBE_EX_FAIL" ]; then
        printf '  SELF-TEST FAIL [D suppressed]: expected exit %s, got %s\n' "$PROBE_EX_FAIL" "$rc"
        fails=$((fails + 1)); [ -z "$firstbad" ] && firstbad="D suppressed exit"
    else
        case "$out" in
            *"D=wiki tile"*)
                printf '  SELF-TEST FAIL [D suppressed]: the verdict names D even though A=106 explains it.\n'
                fails=$((fails + 1)); [ -z "$firstbad" ] && firstbad="D suppressed message" ;;
            *) printf '  ok [D suppressed while A non-zero -- verdict names A, not D]\n' ;;
        esac
    fi
    # an unreadable tile must never read as "the customer is shown zero people"
    _tcase "D unreadable -> not a zero"       "OK 7187 7187 0 0 0 0 7187" "UNREADABLE" "$PROBE_EX_PASS"
    _tcase "D empty -> not a zero"            "OK 7187 7187 0 0 0 0 7187" "" "$PROBE_EX_PASS"

    _case "all residuals zero -> PASS"        "OK 7187 7187 0 0 0 0 7187"   "$PROBE_EX_PASS"
    _case "A untyped survivors -> FAIL"       "OK 7111 7284 106 0 0 30 7081" "$PROBE_EX_FAIL"
    _case "B orphan vectors -> FAIL"          "OK 7187 7284 0 97 0 0 7187"  "$PROBE_EX_FAIL"
    _case "C named unsearchable -> FAIL"      "OK 7200 7187 0 0 13 0 7187"  "$PROBE_EX_FAIL"
    # THE ONE THAT MATTERS MOST: unnamed stubs alone must NOT fail, or the probe
    # goes permanently red on a box where nothing is actually broken.
    _case "unnamed stubs only -> PASS"        "OK 7217 7187 0 0 0 30 7187"  "$PROBE_EX_PASS"
    # CANNOT-RUN is a third outcome and must not collapse into either.
    # ---- B, split by who made the orphan. Ninth field = this suite's fixtures.
    # THE FALSE RED: every orphan vector is a seed people_seed_and_retrieval
    # failed to remove. That is the walk's defect and that probe's red. This one
    # is artefact-owned, so failing here would refuse the promote over the
    # harness.
    _case "B is entirely our own leaked fixtures -> PASS" \
          "OK 7187 7188 0 0 0 0 7187 1"  "$PROBE_EX_PASS"
    # THE FALSE GREEN THE SPLIT COULD BUY: a genuine orphan standing beside one
    # of ours must still fail. Excluding ours must never excuse theirs.
    _case "a real orphan beside a leaked fixture -> FAIL" \
          "OK 7187 7189 0 1 0 0 7187 1"  "$PROBE_EX_FAIL"
    # An eight-field line is a reconciliation that did not measure the flag. It
    # must say NOT MEASURED, never print a zero it did not observe. Exit code
    # alone cannot test this -- both branches pass -- so assert the MESSAGE.
    out="$(SELF_TEST_LOCAL=1 FAKE_RECONCILE="OK 7187 7187 0 0 0 0 7187" run_probe 2>&1)"; rc=$?
    case "$out" in
        *"NOT MEASURED"*) printf '  ok [eight-field line says NOT MEASURED, not zero]\n' ;;
        *) printf '  SELF-TEST FAIL [fixture attribution]: an unmeasured attribution did not say so.\n'
           fails=$((fails + 1)); [ -z "$firstbad" ] && firstbad="fixture attribution unmeasured" ;;
    esac

    _case "graph unreadable -> CANNOT-RUN"    "CANNOTRUN graph-empty"       "$PROBE_EX_CANNOT_RUN"
    _case "qdrant empty -> CANNOT-RUN"        "CANNOTRUN qdrant-empty"      "$PROBE_EX_CANNOT_RUN"
    _case "empty output -> CANNOT-RUN"        ""                            "$PROBE_EX_CANNOT_RUN"
    _case "garbage output -> CANNOT-RUN"      "totally unexpected"          "$PROBE_EX_CANNOT_RUN"

    if [ "$fails" -ne 0 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT BEHAVE: ${fails} of 18 self-test cases returned the wrong outcome (first: ${firstbad}). This probe cannot be trusted to distinguish PASS from FAIL from CANNOT-RUN, so its verdicts mean nothing."
    fi
    probe_fail "negative control behaved correctly on all 18 cases: three residuals each drive FAIL independently, unnamed stubs alone do NOT fail, a leaked walk fixture is reported but does not refuse the promote while a real orphan beside it still does, an unmeasured fixture attribution says NOT MEASURED rather than zero, and unreadable/empty/garbage input all return CANNOT-RUN rather than collapsing into a pass"
}

probe_main "$@"
