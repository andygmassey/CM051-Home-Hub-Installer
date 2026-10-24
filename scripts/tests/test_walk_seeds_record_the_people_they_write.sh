#!/usr/bin/env bash
# scripts/tests/test_walk_seeds_record_the_people_they_write.sh
# The walk's seeds that write Person nodes record `<seed> <count>` in
# ~/.walk-seeded-people (from their own write result) and remove it when they forget;
# data_conservation reads it so people/all STORED = owner + seeded is EXPLAINED, not INFLATED.
# Arms:
#   A. record/forget snippets: replace-not-double, other seeds' lines kept, forget leaves
#      the file EMPTY (readable 0), under /bin/bash AND /bin/sh; a bad seed name is refused
#   B. grounding: the count is the loader's own `statuses` line (created_person -> 1,
#      stored-only -> 0, no statuses line -> nothing recorded); forget removes the line;
#      a failed forget keeps it
#   C. neighbour (scale_fixture.py): seed_neighbour records 1 on a 2xx write, nothing on a
#      failed write; the forget path removes the line only when both halves forgot
#   D. the collector reads what the seeds wrote, end to end (sum 10, the row EXPLAINED)
#   E. wiring: run_box_walk.sh exports OSTLER_WALK_SEEDS_RAN=1 before its first seed, and the
#      probe withholds --no-seed-run when it is 1; the seed_persona.py non-wiring is pinned
# EXIT: 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBD="${REPO}/scripts/box_walk_probes/lib"
PROBES="${REPO}/scripts/box_walk_probes/probes"
RUNNER="${REPO}/scripts/box_walk_probes/run_box_walk.sh"
EXP="${REPO}/scripts/box_walk_probes/fixtures/data_conservation/expected.json"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
for f in "$LIBD/seeded_people.sh" "$LIBD/grounding_seed.sh" "$LIBD/scale_fixture.py" "$LIBD/data_conservation.py" "$RUNNER" "$EXP"; do
    [ -r "$f" ] || { echo "CANNOT-RUN: $f unreadable" >&2; exit 2; }
done
command -v python3 >/dev/null || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
file() { cat "$W/h/.walk-seeded-people" 2>/dev/null; }
fresh() { rm -rf "$W/h"; mkdir -p "$W/h"; }

# ---- A. the snippets
for sh in /bin/bash /bin/sh; do
    fresh
    . "$LIBD/seeded_people.sh"
    HOME="$W/h" "$sh" -c "$(seeded_people_record_cmd contact_cards 8)"
    HOME="$W/h" "$sh" -c "$(seeded_people_record_cmd neighbour 1)"
    HOME="$W/h" "$sh" -c "$(seeded_people_record_cmd contact_cards 8)"
    [ "$(file | sort | tr '\n' ,)" = "contact_cards 8,neighbour 1," ] \
        && ok "A1 ($sh): record replaces its own line, keeps the other seed's" || bad "A1 ($sh): $(file | tr '\n' ,)"
    HOME="$W/h" "$sh" -c "$(seeded_people_forget_cmd contact_cards)"
    [ "$(file)" = "neighbour 1" ] && ok "A2 ($sh): forget removes only its line" || bad "A2 ($sh): $(file)"
    HOME="$W/h" "$sh" -c "$(seeded_people_forget_cmd neighbour)"
    { [ -f "$W/h/.walk-seeded-people" ] && [ ! -s "$W/h/.walk-seeded-people" ]; } \
        && ok "A3 ($sh): the last forget leaves the file EMPTY, not absent" || bad "A3 ($sh): file state wrong"
    HOME="$W/h" "$sh" -c "$(seeded_people_record_cmd contact_cards unreadable)"
    [ "$(file)" = "contact_cards unreadable" ] && ok "A4 ($sh): an uncountable seed records a word, not a number" || bad "A4 ($sh): $(file)"
done
seeded_people_record_cmd 'a b; rm -rf /' 1 >/dev/null 2>&1 && bad "A5: a hostile seed name was accepted" || ok "A5: a bad seed name is refused"

# ---- B. grounding
fresh
(
    . "$LIBD/grounding_seed.sh"
    _gs_box_exec() { HOME="$W/h" /bin/sh -c "$1"; }
    _gs_record_people "seed: asserted 3 fact(s) for 'Jane Doe' via POST /api/v1/memory/assert; statuses = ['created_person', 'stored', 'stored']
SEED-LOAD OK: 'Jane Doe' is in the graph"
    echo "after-created=$(file)" > "$W/b1"
    _gs_record_people "seed: asserted 3 fact(s) for 'Jane Doe' via POST /api/v1/memory/assert; statuses = ['stored', 'stored', 'stored']"
    echo "after-existing=$(file)" > "$W/b2"
    fresh
    _gs_record_people "SEED-LOAD CANNOT-RUN: no token"
    { [ ! -e "$W/h/.walk-seeded-people" ] && echo none || echo "wrote=$(file)"; } > "$W/b3"
    _gs_record_people "seed: asserted 3 fact(s) for 'Jane Doe' via POST /api/v1/memory/assert; statuses = ['created_person', 'stored', 'stored']"
    # forget path through the real function, loader stubbed
    GROUNDING_SEED_STATE=seeded; GROUNDING_SEED_DIR=/x; OSTLER_SEED_KEEP=0
    _gs_run_loader() { echo "SEED-FORGET OK"; return "${FAKE_FORGET_RC:-0}"; }
    FAKE_FORGET_RC=1 grounding_seed_forget >/dev/null
    echo "after-failed-forget=$(file)" > "$W/b4"
    FAKE_FORGET_RC=0 grounding_seed_forget >/dev/null
    { [ -f "$W/h/.walk-seeded-people" ] && [ ! -s "$W/h/.walk-seeded-people" ] && echo empty || echo "left=$(file)"; } > "$W/b5"
)
[ "$(cat "$W/b1")" = "after-created=grounding 1" ] && ok "B1: created_person in the loader's statuses -> grounding 1" || bad "B1: $(cat "$W/b1")"
[ "$(cat "$W/b2")" = "after-existing=grounding 0" ] && ok "B2: a person that already existed (stored only) -> grounding 0" || bad "B2: $(cat "$W/b2")"
[ "$(cat "$W/b3")" = "none" ] && ok "B3: no statuses line (loader never wrote) -> nothing recorded" || bad "B3: $(cat "$W/b3")"
[ "$(cat "$W/b4")" = "after-failed-forget=grounding 1" ] && ok "B4: a failed forget KEEPS the line (the person is still there)" || bad "B4: $(cat "$W/b4")"
[ "$(cat "$W/b5")" = "empty" ] && ok "B5: a clean forget removes the line, file left empty" || bad "B5: $(cat "$W/b5")"

# B6: the REAL grounding_seed_apply and grounding_seed_forget, loader and box stubbed
fresh
mkdir -p "$W/seed"; echo "api/v1/memory/assert" > "$W/seed/load_seed.py"
echo '{"gate":{"known_person":"Jane Doe","expect_fact":"cable engineer at example.com"}}' > "$W/seed/seed_fixture.json"
(
    . "$LIBD/grounding_seed.sh"
    OSTLER_SEED_DIR="$W/seed"; unset OSTLER_GATE_EXPECT_FACT OSTLER_GATE_KNOWN_PERSON OSTLER_SEED_SKIP
    _gs_box_exec() { HOME="$W/h" /bin/sh -c "$1"; }
    _gs_purge_daemon_memory() { :; }
    _gs_run_loader() {
        case "$*" in
            *--forget*) echo "SEED-FORGET OK: 'Jane Doe'"; return 0 ;;
            *) echo "seed: asserted 3 fact(s) for 'Jane Doe' via POST /api/v1/memory/assert; statuses = ['created_person', 'stored', 'stored']"
               echo "SEED-LOAD OK: 'Jane Doe' is in the graph"; return 0 ;;
        esac
    }
    grounding_seed_apply >/dev/null
    echo "state=${GROUNDING_SEED_STATE} file=$(file)" > "$W/b6a"
    grounding_seed_forget >/dev/null
    { [ -f "$W/h/.walk-seeded-people" ] && [ ! -s "$W/h/.walk-seeded-people" ] && echo empty || echo "left=$(file)"; } > "$W/b6b"
)
[ "$(cat "$W/b6a")" = "state=seeded file=grounding 1" ] && ok "B6a: grounding_seed_apply records grounding 1 from the loader's output" || bad "B6a: $(cat "$W/b6a")"
[ "$(cat "$W/b6b")" = "empty" ] && ok "B6b: grounding_seed_forget removes it" || bad "B6b: $(cat "$W/b6b")"

# ---- C. neighbour
fresh
python3 -I - "$LIBD" "$W/h" <<'PY' && ok "C: neighbour records 1 on a 2xx write, nothing on a failed write, forget removes only on a full forget" || bad "C: see above"
import os, sys, tempfile, threading, http.server
sys.path.insert(0, sys.argv[1])
home = sys.argv[2]
import scale_fixture as sf
os.makedirs(os.path.join(home, ".ostler", "config"), exist_ok=True)
open(os.path.join(home, ".ostler", "config", ".env"), "w").write("USER_ID=walkowner\n")
code = {"v": 200}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0)); self.send_response(code["v"]); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
store = "http://127.0.0.1:%d" % srv.server_port
path = os.path.join(home, ".walk-seeded-people")
os.environ["NO_PROXY"] = "127.0.0.1"
code["v"] = 500
st = sf.seed_neighbour(home, store=store, wait_s=0)
assert st.startswith("failed-write"), st
assert not os.path.exists(path), "a failed write must record nothing"
code["v"] = 200
st = sf.seed_neighbour(home, store=store, wait_s=0)
assert st == "failed-digest-not-rewritten", st          # the write landed; the digest wait is not under test
assert open(path).read() == "neighbour 1\n", open(path).read()
sf.record_seeded_people(home, "contact_cards", 8)
sf.forget_seeded_people(home, "neighbour")
assert open(path).read() == "contact_cards 8\n"
sf.forget_seeded_people(home, "contact_cards")
assert os.path.exists(path) and open(path).read() == ""
# the CLI forget, the stores stubbed: a full forget removes the line, a half-failed one keeps it
import io, contextlib
sf.record_seeded_people(home, "neighbour", 1)
sf.forget = lambda q, h, post=None: {}
sf.forget_neighbour = lambda h, store=None: "forgotten"
sf.forget_neighbour_vector = lambda q, h, post=None: "failed-URLError"
with contextlib.redirect_stdout(io.StringIO()):
    sf.main(["forget", "--qdrant", "http://127.0.0.1:9", "--home", home])
assert open(path).read() == "neighbour 1\n", "a half-failed forget must keep the line: " + open(path).read()
sf.forget_neighbour_vector = lambda q, h, post=None: "forgotten"
with contextlib.redirect_stdout(io.StringIO()):
    sf.main(["forget", "--qdrant", "http://127.0.0.1:9", "--home", home])
assert open(path).read() == "", "a full forget must remove the line: " + open(path).read()
PY

# ---- D. the collector, end to end through the shipped expected.json row
fresh
printf 'contact_cards 8\nneighbour 1\ngrounding 1\n' > "$W/h/.walk-seeded-people"
python3 -I - "$LIBD" "$EXP" "$W/h/.walk-seeded-people" <<'PY' && ok "D: seed file -> collector -> shipped chain+full people/all row: EXPLAINED at 11/11, INFLATED at 12, LOST at 12 declared" || bad "D: see above"
import json, sys
sys.path.insert(0, sys.argv[1])
import data_conservation as dc
dc.SEEDED_PEOPLE = sys.argv[3]
facts, meta = {}, {}
dc.collect_seeded_people(facts, meta, False)
assert facts["walk.seeded.people"] == 10, (facts, meta)
exp = json.load(open(sys.argv[2]))["profiles"]
for prof in ("chain", "full"):
    rows = {"rows": [r for r in exp[prof]["rows"] if r.get("id") == "people/all"]}
    base = {"hyd.people.item_count": 1, "q.people.total": 11, "x.class.Person": 11, "x.class.total": 11,
            "w.shown.people.source=fda_people_index": 11}
    def v(**over):
        f = dict(base, **facts); f.update(over)
        r, c = dc.adjudicate(rows, f); return r[0]["verdict"]
    assert v() == "EXPLAINED", (prof, v())
    assert v(**{"q.people.total": 12, "x.class.Person": 12, "w.shown.people.source=fda_people_index": 12}) == "INFLATED", prof
    assert v(**{"walk.seeded.people": 12}) == "LOST", prof
PY

# ---- E. wiring
n_export="$(/usr/bin/grep -m1 -n '^export OSTLER_WALK_SEEDS_RAN' "$RUNNER" | cut -d: -f1)"
n_first="$(/usr/bin/grep -m1 -n '^grounding_seed_apply' "$RUNNER" | cut -d: -f1)"
{ [ -n "$n_export" ] && [ -n "$n_first" ] && [ "$n_export" -lt "$n_first" ]; } \
    && ok "E1: the runner exports OSTLER_WALK_SEEDS_RAN (line $n_export) before its first seed (line $n_first)" || bad "E1: export ${n_export:-none} first seed ${n_first:-none}"
# the probe with its last line (the call to probe_main) removed, beside symlinks to the real lib
mkdir -p "$W/bw/probes"; ln -s "$LIBD" "$W/bw/lib"; ln -s "${REPO}/scripts/box_walk_probes/fixtures" "$W/bw/fixtures"
sed '$d' "$PROBES/data_conservation.sh" > "$W/bw/probes/data_conservation.sh"
nosd() { env $1 bash -c '. "$0"; box_run() { IFS= read -r l <<<"$1"; printf "%s\n" "$l"; }; dc_collect' "$W/bw/probes/data_conservation.sh" 2>&1; }
a="$(nosd OSTLER_WALK_SEEDS_RAN=1)"; b="$(nosd OSTLER_WALK_SEEDS_RAN=0)"; c="$(nosd X=1)"
{ [ "$a" = "python3 - collect  <<'PYPAYLOAD'" ] && [ "$b" = "python3 - collect --no-seed-run <<'PYPAYLOAD'" ] && [ "$c" = "$b" ]; } \
    && ok "E2: probe withholds --no-seed-run once seeds ran (1), passes it when none ran (0 or unset)" || bad "E2: [$a] [$b] [$c]"
# owner_score/seed_persona.py DOES write Person nodes, but graph only (no Qdrant vector), inside
# owner_knowledge_score, which the runner pins LAST and which purges before it returns. Recording it
# in the file would feed a STORED addition for people that never reach Qdrant, so it is not recorded.
OKS="$PROBES/owner_knowledge_score.sh"; SP="${REPO}/scripts/owner_score/seed_persona.py"
{ /usr/bin/grep -q '^PROBES="$(pin_last owner_knowledge_score)"' "$RUNNER" && /usr/bin/grep -q 'seed_persona.py purge' "$OKS"; } \
    && ok "E3a: seed_persona runs only inside owner_knowledge_score, pinned last and purged before it returns" || bad "E3a: ordering/purge pin missing"
! /usr/bin/grep -qi 'qdrant\|6333' "$SP" \
    && ok "E3b: seed_persona.py never writes a Qdrant vector (graph-only Person nodes), so a STORED addition would be wrong" || bad "E3b: seed_persona.py now touches Qdrant; it needs a recorder"
echo; echo "== ${PASS} pass / ${FAIL} fail =="; [ "$FAIL" -eq 0 ]
