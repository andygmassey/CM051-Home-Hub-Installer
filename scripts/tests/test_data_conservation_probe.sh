#!/usr/bin/env bash
# scripts/tests/test_data_conservation_probe.sh
# Drives the REAL probe and the REAL adjudicator. Arms:
#   A. the probe's --self-test goes FAIL (its negative control fired)
#   B. adjudicate on a clean synthetic fact set -> exit 0
#   C. the same set with ONE store emptied -> exit 1 and the row is named LOST
#   D. the same set with a fact removed -> exit 78 (not a pass, not a fail)
#   E. every profile in the shipped expected.json parses and has rows
#   F. the probe is registered: walk_promote_scope.tsv has its row
#   G. an all-zero box exits 78 (CANNOT-RUN), never 0
#   H. a known_gap row that was not read exits 78, never 0 (NOT-MEASURED is not KNOWN-GAP)
#   I. an absent graph class reads 0 only when the graph answered, and is still judged
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
cat > "$W/exp_gz.json" <<'J'
{"profiles":{"t":{"rows":[
 {"id":"a/x","source":"a","category":"x","expected":{"in":0,"stored":0,"shown":0},"facts":{"in":"i","stored":"s","shown":"w"}}]}}}
J
echo '{"facts":{"i":0,"s":0,"w":0}}' > "$W/f_zero.json"
python3 "$LIB" adjudicate --expected "$W/exp_gz.json" --facts "$W/f_zero.json" --profile t >"$W/o4" 2>&1; r4=$?
[ "$r4" -eq 78 ] && ok "G: an all-zero box exits 78, not 0" || bad "G: rc=$r4"
cat > "$W/exp_kg.json" <<'J'
{"profiles":{"t":{"rows":[
 {"id":"p/a","source":"p","category":"a","known_gap":"declared gap","expected":{"stored":4,"shown":4},"facts":{"stored":"s","shown":"w"}}]}}}
J
echo '{"facts":{"s":4}}' > "$W/f_kg.json"
python3 "$LIB" adjudicate --expected "$W/exp_kg.json" --facts "$W/f_kg.json" --profile t >"$W/o5" 2>&1; r5=$?
{ [ "$r5" -eq 78 ] && ! grep -q 'KNOWN-GAP |' "$W/o5"; } && ok "H: an unread known_gap row exits 78 and is not KNOWN-GAP" || bad "H: rc=$r5"
# I. An absent graph class reads 0 only when the graph answered (x.class.total),
#    and a 0 read that way is still judged: Person absent under 2 stored is LOST.
cat > "$W/exp_cls.json" <<'J'
{"profiles":{"t":{"rows":[
 {"id":"pl/a","source":"pl","category":"a","expected":{"stored":0},"facts":{"stored":{"key":"x.class.Place","zero_if":"x.class.total"}}},
 {"id":"pe/a","source":"pe","category":"a","facts":{"in":"i","stored":"s","graph":{"key":"x.class.Person","zero_if":"x.class.total"}}}]}}}
J
echo '{"facts":{"i":2,"s":2,"x.class.Person":2,"x.class.total":2}}' > "$W/f_cls_ok.json"
echo '{"facts":{"i":2,"s":2,"x.class.total":0}}' > "$W/f_cls_lost.json"
echo '{"facts":{"i":2,"s":2,"x.class.Person":2}}' > "$W/f_cls_nm.json"
python3 "$LIB" adjudicate --expected "$W/exp_cls.json" --facts "$W/f_cls_ok.json" --profile t >"$W/o6" 2>&1; r6=$?
python3 "$LIB" adjudicate --expected "$W/exp_cls.json" --facts "$W/f_cls_lost.json" --profile t >"$W/o7" 2>&1; r7=$?
python3 "$LIB" adjudicate --expected "$W/exp_cls.json" --facts "$W/f_cls_nm.json" --profile t >"$W/o8" 2>&1; r8=$?
{ [ "$r6" -eq 0 ] && ! grep -q 'unreadable' "$W/o6"; } && ok "I1: an absent Place class reads 0 when the graph answered" || bad "I1: rc=$r6 $(cat "$W/o6")"
{ [ "$r7" -eq 1 ] && grep -q '| pe | a |.*| LOST |' "$W/o7"; } && ok "I2: Person absent under 2 stored is still LOST" || bad "I2: rc=$r7 $(cat "$W/o7")"
{ [ "$r8" -eq 78 ] && grep -q 'x.class.Place unreadable' "$W/o8"; } && ok "I3: without x.class.total an absent class stays unreadable (78)" || bad "I3: rc=$r8 $(cat "$W/o8")"
echo; echo "== ${PASS} pass / ${FAIL} fail =="; [ "$FAIL" -eq 0 ]
