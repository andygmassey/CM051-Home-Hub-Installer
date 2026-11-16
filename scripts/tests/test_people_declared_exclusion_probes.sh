#!/usr/bin/env bash
# test_people_declared_exclusion_probes.sh
# ============================================================================
# Proves the probes' independent re-check of the product's DECLARED people
# exclusion (133). Runs the REAL embedded payloads of people_stores_reconcile.sh
# and people_count_agreement.sh against a fake Oxigraph + Qdrant that serve a
# planted world, then asserts on the line the payload prints.
#
#   control   declared URIs are all shipped-rule service senders  -> status ok
#   RED       a declared URI is a real person (the rule does NOT confirm it)
#             -> status fail, and the fail reaches the probe's gate
#   absent    no state file, or a state file from the 132 build with no
#             declaration fields -> cannot_run (never fail, never pass)
#   MUTANT    the payload TRUSTS the declaration (re-check skipped) -> the RED
#             arm must go red. The test is only worth having if it does.
#
# Also exercises the bash gate (_excl_gate / _excl_gate_vis) by extracting the
# function text and running it with stubbed probe_* verdict functions.
# No real store, no launchctl, no keychain. python3 stdlib only.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PROBES="$REPO/scripts/box_walk_probes/probes"
LIB="$REPO/scripts/box_walk_probes/lib/people_declared_exclusion.py"
RULE="$REPO/vendor/ostler_fda/pwg_ingest.py"
RULES_DIR="$REPO/vendor/cm041/assistant_api"
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t pde)"
PORT=17893
FAKE_PID=""
trap '[ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
FAILURES=""
note() { printf '  %s\n' "$1"; }
fail() { FAILURES="${FAILURES} $1"; printf '  FAIL [%s]: %s\n' "$1" "$2"; }
ok()   { printf '  ok   [%s]: %s\n' "$1" "$2"; }

# ── fake stores: one planted world, dispatched on the query text ────────────
cat > "$WORK/fake_stores.py" <<'PY'
import http.server, json, os, re, sys
WORLD = json.load(open(os.environ["PDE_WORLD"], encoding="utf-8"))
P = "https://schema.ostler.ai/ontology#"
def uri_in(q):
    m = re.search(r"<(urn:[^>]+)>", q)
    return m.group(1) if m else None
def binds(rows):
    return {"head": {}, "results": {"bindings": rows}}
def sparql(q):
    persons = WORLD["persons"]
    if "COUNT(*) AS ?n) WHERE { ?s ?p ?o }" in q:
        return binds([{"n": {"value": str(WORLD["triples"])}}])
    if "COUNT(DISTINCT ?o)" in q:
        return binds([{"n": {"value": "0"}}])
    if re.search(r"SELECT \(COUNT\(\*\)", q):
        return binds([{"n": {"value": "0"}}])
    if "SELECT ?p ?m ?dn" in q:
        rows = []
        for u, v in persons.items():
            rows.append({"p": {"value": u}, "dn": {"value": v["displayName"]}})
            for t, x in v.get("identifiers", []):
                rows.append({"p": {"value": u}, "dn": {"value": v["displayName"]},
                             "t": {"value": t}, "v": {"value": x}})
        return binds(rows)
    if "SELECT ?p WHERE { ?p a <" in q:
        return binds([{"p": {"value": u}} for u in persons])
    u = uri_in(q)
    if u is None or u not in persons:
        return binds([])
    v = persons[u]
    if "identifierType" in q:
        return binds([{"t": {"value": t}, "v": {"value": x}} for t, x in v.get("identifiers", [])])
    if "displayName> ?d" in q or "displayName> ?d }" in q:
        return binds([{"d": {"value": v["displayName"]}}] if v.get("displayName") else [])
    return binds([])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace")
        if self.path.startswith("/collections/"):
            pts = [{"id": i, "payload": {"person_uri": u, "display_name": v["displayName"],
                                         "source": "fixture"}}
                   for i, (u, v) in enumerate(sorted(WORLD["vectored"].items()))]
            return self._send({"result": {"points": pts, "next_page_offset": None}})
        q = body
        if self.headers.get("Content-Type", "").startswith("application/x-www-form-urlencoded"):
            from urllib.parse import parse_qs
            q = (parse_qs(body).get("query") or [""])[0]
        if not q and self.headers.get("Content-Type", "").startswith("application/json"):
            return self._send({"result": {"points": [], "next_page_offset": None}})
        return self._send(sparql(q))
srv = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
srv.serve_forever()
PY

# ── the world: real service senders, one planted wrongly-declared person ────
cat > "$WORK/world.json" <<'JSON'
{
  "triples": 100,
  "persons": {
    "urn:pde:alex":    {"displayName": "Alex Brown",  "identifiers": [["email", "alex@example.com"]]},
    "urn:pde:sam":     {"displayName": "Sam Jones",     "identifiers": [["phone", "+447700900111"]]},
    "urn:pde:shop":    {"displayName": "Initech Corp", "identifiers": [["email", "noreply@example.com"]]},
    "urn:pde:alerts":  {"displayName": "Globex Corp", "identifiers": [["email", "notifications@example.com"]]},
    "urn:pde:jordan":  {"displayName": "Ben Ross",   "identifiers": [["email", "jordan@example.com"]]}
  },
  "vectored": {
    "urn:pde:alex": {"displayName": "Alex Brown"},
    "urn:pde:sam":  {"displayName": "Sam Jones"},
    "urn:pde:jordan": {"displayName": "Ben Ross"}
  }
}
JSON

start_fake() {
    PDE_WORLD="$WORK/world.json" python3 "$WORK/fake_stores.py" "$PORT" >/dev/null 2>&1 &
    FAKE_PID=$!
    local i=0
    while [ $i -lt 100 ]; do
        curl -s -o /dev/null -m 1 --noproxy '*' "http://127.0.0.1:$PORT/" 2>/dev/null && return 0
        i=$((i+1)); sleep 0.05 2>/dev/null || true
    done
    return 1
}
stop_fake() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; FAKE_PID=""; }

# ── the probes' own embedded payloads, extracted verbatim from the probe file
extract_payload() { # probe-file  start-marker  end-marker
    awk -v s="$2" -v e="$3" 'index($0, s)==1 {on=1; next} on && $0==e {exit} on {print}' "$1"
}
RECON_PAYLOAD="$WORK/recon_payload.py"; VIS_PAYLOAD="$WORK/vis_payload.py"
extract_payload "$PROBES/people_stores_reconcile.sh" "read -r -d '' RECONCILE_PY <<'PYPAYLOAD'" "PYPAYLOAD" > "$RECON_PAYLOAD"
extract_payload "$PROBES/people_count_agreement.sh" "read -r -d '' VISIBLE_PY <<'PYVISIBLE'" "PYVISIBLE" > "$VIS_PAYLOAD"
if [ ! -s "$RECON_PAYLOAD" ] || [ ! -s "$VIS_PAYLOAD" ]; then
    fail extract "could not extract an embedded payload from a probe file"
fi

# A mutant payload: the declaration is TRUSTED, the shipped rule never runs.
mutate_recon() { python3 - "$1" "$2" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '        _excl = verify(_excl_decl, _lookup_person, _rule, 1000)'
assert src.count(old) == 1, src.count(old)
new = ('        _excl = {"status": "ok", "detail": "mutant", "verified": set(_excl_decl["excluded_uris"]), '
       '"checked": 0, "excluded": _excl_decl["excluded"], "mismatches": [], "share": None, "sampled": False}')
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
}
mutate_vis() { python3 - "$1" "$2" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '        _excl = verify(_decl, _row, _rule, 1000)'
assert src.count(old) == 1, src.count(old)
new = ('        _excl = {"status": "ok", "detail": "mutant", "verified": set(_decl["excluded_uris"]), '
       '"checked": 0, "excluded": _decl["excluded"], "mismatches": [], "share": None, "sampled": False}')
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
}

# run one payload against a world + state. Prints the payload's last line.
#   $1 payload  $2 state-json-or-ABSENT  $3 world-json  $4 which(recon|vis)
run_payload() {
    local payload="$1" state="$2" world="$3" which="$4" home="$WORK/home.$RANDOM$RANDOM"
    mkdir -p "$home/.ostler/state"
    if [ "$state" != "ABSENT" ]; then printf '%s' "$state" > "$home/.ostler/state/people-index.json"; fi
    [ "$world" = "$WORK/world.json" ] || cp "$world" "$WORK/world.json"
    stop_fake; start_fake || { echo "FAKE_NOT_UP"; return; }
    local body="$(cat "$LIB")
$(cat "$payload")"
    if [ "$which" = "recon" ]; then
        HOME="$home" OSTLER_FDA_PWG_INGEST="$RULE" \
            python3 -I - "http://127.0.0.1:$PORT/query" "http://127.0.0.1:$PORT" people "$WORK/none.conf" <<< "$body" 2>&1 | tail -1
    else
        HOME="$home" OSTLER_FDA_PWG_INGEST="$RULE" \
            python3 -I - "http://127.0.0.1:$PORT/query" "http://127.0.0.1:$PORT" people "$WORK/none.conf" "$RULES_DIR" <<< "$body" 2>&1 | tail -1
    fi
    stop_fake
}
field() { printf '%s' "$1" | awk -v n="$2" '{print $n}'; }

CONTROL_STATE='{"excluded": 2, "by_reason": {"service mailbox": 2}, "excluded_uris": ["urn:pde:alerts", "urn:pde:shop"]}'
PLANT_STATE='{"excluded": 3, "by_reason": {"service mailbox": 3}, "excluded_uris": ["urn:pde:alerts", "urn:pde:jordan", "urn:pde:shop"]}'
NO_FIELDS_STATE='{"backlog": 0, "phase": "done"}'
# A world with the planted person left OUT of the declaration: nothing to re-check.
printf 'control: %s\n' "declared senders confirmed by the shipped rule"
: > "$WORK/empty.conf"

R_CTRL="$(run_payload "$RECON_PAYLOAD" "$CONTROL_STATE" "$WORK/world.json" recon)"
printf '%s\n' "$R_CTRL" | sed 's/^/    recon control: /' | cut -c1-240
[ "$(field "$R_CTRL" 16)" = "ok" ] && ok recon-control "status ok" || fail recon-control "status '$(field "$R_CTRL" 16)' line: ${R_CTRL:0:200}"
[ "$(field "$R_CTRL" 6)" = "0" ] && ok recon-control-residual "named residual C = 0 after the confirmed exclusion" || fail recon-control-residual "C residual '$(field "$R_CTRL" 6)' expected 0"

V_CTRL="$(run_payload "$VIS_PAYLOAD" "$CONTROL_STATE" "$WORK/world.json" vis)"
printf '%s\n' "$V_CTRL" | sed 's/^/    vis control: /' | cut -c1-240
[ "$(field "$V_CTRL" 14)" = "ok" ] && ok vis-control "status ok" || fail vis-control "status '$(field "$V_CTRL" 14)' line: ${V_CTRL:0:200}"

printf 'RED: a declared URI the shipped rule does not confirm%s\n' "${PDE_MUTANT:+ (MUTANT payloads: declaration trusted)}"
RED_R="$RECON_PAYLOAD"; RED_V="$VIS_PAYLOAD"
if [ "${PDE_MUTANT:-0}" = 1 ]; then
    mutate_recon "$RECON_PAYLOAD" "$WORK/recon_mutant.py" && RED_R="$WORK/recon_mutant.py" || fail mutant-build "recon mutant not built"
    mutate_vis "$VIS_PAYLOAD" "$WORK/vis_mutant.py" && RED_V="$WORK/vis_mutant.py" || fail mutant-build "vis mutant not built"
fi
R_RED="$(run_payload "$RED_R" "$PLANT_STATE" "$WORK/world.json" recon)"
printf '%s\n' "$R_RED" | sed 's/^/    recon red: /' | cut -c1-240
[ "$(field "$R_RED" 16)" = "fail" ] && ok recon-red "planted person FAILS the re-check" || fail recon-red "status '$(field "$R_RED" 16)' expected fail"
V_RED="$(run_payload "$RED_V" "$PLANT_STATE" "$WORK/world.json" vis)"
printf '%s\n' "$V_RED" | sed 's/^/    vis red: /' | cut -c1-240
[ "$(field "$V_RED" 14)" = "fail" ] && ok vis-red "planted person FAILS the re-check" || fail vis-red "status '$(field "$V_RED" 14)' expected fail"

printf 'absent: nothing declared, nothing confirmed\n'
R_NONE="$(run_payload "$RECON_PAYLOAD" ABSENT "$WORK/world.json" recon)"
[ "$(field "$R_NONE" 16)" = "cannot_run" ] && ok recon-absent "no state file -> cannot_run" || fail recon-absent "status '$(field "$R_NONE" 16)'"
V_NONE="$(run_payload "$VIS_PAYLOAD" ABSENT "$WORK/world.json" vis)"
[ "$(field "$V_NONE" 14)" = "cannot_run" ] && ok vis-absent "no state file -> cannot_run" || fail vis-absent "status '$(field "$V_NONE" 14)'"
R_OLD="$(run_payload "$RECON_PAYLOAD" "$NO_FIELDS_STATE" "$WORK/world.json" recon)"
[ "$(field "$R_OLD" 16)" = "cannot_run" ] && ok recon-132-shape "declaration fields absent -> cannot_run, not fail" || fail recon-132-shape "status '$(field "$R_OLD" 16)'"

# CLI: the lib on its own, with rows built by hand (no store).
CLI_OUT="$(python3 -I "$LIB" cli "$WORK/state_plant.json" "$RULE" "$WORK/rows.json" 2>&1)" || true
printf '%s' "$PLANT_STATE" > "$WORK/state_plant.json"
cat > "$WORK/rows.json" <<'JSON'
{"urn:pde:alerts": {"name": "Globex Corp", "phones": [], "emails": ["notifications@example.com"]},
 "urn:pde:jordan": {"name": "Ben Ross", "phones": [], "emails": ["jordan@example.com"]},
 "urn:pde:shop":   {"name": "Initech Corp", "phones": [], "emails": ["noreply@example.com"]}}
JSON
CLI_OUT="$(python3 -I "$LIB" cli "$WORK/state_plant.json" "$RULE" "$WORK/rows.json" 2>&1)"
printf '%s' "$CLI_OUT" | grep -q '"status": "fail"' && ok cli-red "lib CLI: planted URI -> fail" || fail cli-red "CLI said: ${CLI_OUT:0:200}"
printf '%s' "$CLI_OUT" | grep -q 'urn:pde' && fail cli-no-uri "CLI printed a URI" || ok cli-no-uri "CLI prints fingerprints, never a URI"

# The bash gate: extract the function text and run it with stubbed verdicts.
gate_run() { # function-name  file  stdin-line  -> prints verdict word
    local fn="$1" file="$2"
    (
        probe_examined() { :; }
        probe_fail() { printf 'VERDICT: FAIL\n'; exit 0; }
        probe_cannot_run() { printf 'VERDICT: CANNOT-RUN\n'; exit 0; }
        eval "$(awk -v f="$fn" 'index($0, f"() {")==1 {on=1} on {print} on && /^}/ {exit}' "$file")"
        "$fn" "$3" "${4:-}"
        printf 'VERDICT: PASS\n'
    )
}
G_OK="$(gate_run _excl_gate_vis "$PROBES/people_count_agreement.sh" ok "excluded=2;checked=2")"
G_FAIL="$(gate_run _excl_gate_vis "$PROBES/people_count_agreement.sh" fail "detail_here")"
G_NONE="$(gate_run _excl_gate_vis "$PROBES/people_count_agreement.sh" cannot_run "state absent")"
[ "$G_OK" = "VERDICT: PASS" ] && ok gate-vis-ok "ok passes on" || fail gate-vis-ok "$G_OK"
[ "$G_FAIL" = "VERDICT: FAIL" ] && ok gate-vis-fail "fail is FAIL" || fail gate-vis-fail "$G_FAIL"
[ "$G_NONE" = "VERDICT: CANNOT-RUN" ] && ok gate-vis-cr "cannot_run is CANNOT-RUN" || fail gate-vis-cr "$G_NONE"
G_REC_ABS="$(gate_run _excl_gate "$PROBES/people_stores_reconcile.sh" "OK 1 1 0 0 0 0 0 0 - - - - - - " )"
[ "$G_REC_ABS" = "VERDICT: CANNOT-RUN" ] && ok gate-recon-absent "a line with no exclusion fields is CANNOT-RUN" || fail gate-recon-absent "$G_REC_ABS"

echo
if [ -z "$FAILURES" ]; then
    echo "test_people_declared_exclusion_probes: PASS"
else
    echo "test_people_declared_exclusion_probes: FAIL [${FAILURES# }]"
    exit 1
fi
