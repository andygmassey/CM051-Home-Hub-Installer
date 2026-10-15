#!/usr/bin/env bash
# scripts/tests/test_data_conservation_probe.sh
# Drives the REAL probe and the REAL adjudicator. Arms:
#   A. the probe's --self-test goes FAIL (its negative control fired)
#   B. adjudicate on a clean synthetic fact set -> exit 0
#   C. the same set with ONE store emptied -> exit 1 and the row is named LOST
#   D. the same set with a fact removed -> exit 78 (not a pass, not a fail)
#   E. every profile in the shipped expected.json parses and has rows
#   F. the probe is registered: walk_promote_scope.tsv has its row
# EXIT: 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="${REPO}/scripts/box_walk_probes/probes/data_conservation.sh"
LIB="${REPO}/scripts/box_walk_probes/lib/data_conservation.py"
EXP="${REPO}/scripts/box_walk_probes/fixtures/data_conservation/expected.json"
SCOPE="${REPO}/scripts/walk_promote_scope.tsv"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
for f in "$PROBE" "$LIB" "$EXP" "$SCOPE"; do [ -r "$f" ] || { echo "CANNOT-RUN: $f unreadable" >&2; exit 2; }; done
command -v python3 >/dev/null || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

out="$(bash "$PROBE" --self-test 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'VERDICT: FAIL -- negative control behaved correctly'; } \
    && ok "A: --self-test came back FAIL (negative control fired)" || bad "A: --self-test rc=$rc: $(printf '%s' "$out" | tail -2)"

cat > "$W/exp.json" <<'J'
{"profiles":{"t":{"rows":[
 {"id":"a/x","source":"a","category":"x","expected":{"in":10,"stored":10,"shown":10},"facts":{"in":"i","stored":"s","shown":"w"}},
 {"id":"b/y","source":"b","category":"y","expected":{"in":5,"stored":5,"shown":4},"exclusions":[{"stage":"shown","count":1,"reason":"set-aside calendar"}],"facts":{"in":"i2","stored":"s2","shown":"w2"}}]}}}
J
echo '{"facts":{"i":10,"s":10,"w":10,"i2":5,"s2":5,"w2":4}}' > "$W/f_ok.json"
echo '{"facts":{"i":10,"s":0,"w":0,"i2":5,"s2":5,"w2":4}}' > "$W/f_lost.json"
echo '{"facts":{"i":10,"w":10,"i2":5,"s2":5,"w2":4}}' > "$W/f_nm.json"
python3 "$LIB" adjudicate --expected "$W/exp.json" --facts "$W/f_ok.json" --profile t >"$W/o1" 2>&1; r1=$?
python3 "$LIB" adjudicate --expected "$W/exp.json" --facts "$W/f_lost.json" --profile t >"$W/o2" 2>&1; r2=$?
python3 "$LIB" adjudicate --expected "$W/exp.json" --facts "$W/f_nm.json" --profile t >"$W/o3" 2>&1; r3=$?
[ "$r1" -eq 0 ] && grep -q 'EXPLAINED' "$W/o1" && ok "B: clean set exits 0 and the declared exclusion reads EXPLAINED" || bad "B: rc=$r1 $(cat "$W/o1")"
{ [ "$r2" -eq 1 ] && grep -q '| LOST |' "$W/o2"; } && ok "C: emptied store exits 1 with a LOST row" || bad "C: rc=$r2 $(cat "$W/o2")"
[ "$r3" -eq 78 ] && ok "D: an unreadable fact exits 78, not 0 and not 1" || bad "D: rc=$r3"
python3 - "$EXP" <<'PY' && ok "E: every shipped profile parses and has rows" || bad "E: expected.json profile empty or unparseable"
import json,sys
d=json.load(open(sys.argv[1])); assert d["profiles"]
for k,v in d["profiles"].items():
    assert v["rows"], k
    for r in v["rows"]:
        assert r.get("template") or (r["id"] and r["facts"]), r
PY
awk -F'\t' '$1=="data_conservation"{f=1} END{exit !f}' "$SCOPE" && ok "F: walk_promote_scope.tsv has a data_conservation row" || bad "F: no scope row"
echo; echo "== ${PASS} pass / ${FAIL} fail =="; [ "$FAIL" -eq 0 ]
