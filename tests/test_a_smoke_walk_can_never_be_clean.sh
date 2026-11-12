#!/usr/bin/env bash
# tests/test_a_smoke_walk_can_never_be_clean.sh
#
# `ttywalk.sh --tier smoke` must (1) run only the selected scope, (2) say `tier smoke` in its record, (3) never write
# `verdict CLEAN`, even when every probe passes, (4) write to <v>.smoke.tsv so it cannot replace the full record, and
# (5) be refused by scripts/verify_walk_record.sh. The whole of post_walk_qa.sh runs here, against a stub ssh and a
# stub run_box_walk.sh that prints a RESULT block with 0 FAIL / 0 CANNOT-RUN, i.e. the input that makes a FULL walk say CLEAN.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
arm() { if [ "$2" -eq 0 ]; then echo "  [PASS] $1"; PASS=$((PASS+1)); else echo "  [FAIL] $1"; printf '%s\n' "${3:-}" | tail -15 | sed 's/^/         /'; FAIL=$((FAIL+1)); fi; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAKE="$WORK/repo"; mkdir -p "$FAKE" "$WORK/bin" "$WORK/home"
cp -R "$REPO/scripts" "$FAKE/scripts"; cp -R "$REPO/cut-manifests" "$FAKE/cut-manifests" 2>/dev/null; mkdir -p "$FAKE/walks"
# stub run_box_walk.sh: record argv, print the summary block post_walk_qa.sh parses
cat > "$FAKE/scripts/box_walk_probes/run_box_walk.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_ARGV"
n=0; for a in "$@"; do :; done
want="${STUB_PROBE_TOTAL:-79}"
printf 'RESULT\n  PASS        %s\n  FAIL        %s\n  CANNOT-RUN  0\n  BROKEN      0\n  ----------------\n  of          %s probes\n' "$want" "${STUB_FAIL:-0}" "$want"
[ "${STUB_FAIL:-0}" -eq 0 ]
STUB
chmod +x "$FAKE/scripts/box_walk_probes/run_box_walk.sh"
cat > "$WORK/bin/ssh" <<'STUB'
#!/usr/bin/env bash
cmd="${*: -1}"
case "$cmd" in *walk-artefact-version*) printf 'v1.0.9\n' ;; esac
exit 0
STUB
chmod +x "$WORK/bin/ssh"
export STUB_ARGV="$WORK/argv"
run_qa() { # $1 = tier ; rest env
    local tier="$1"; shift
    env HOME="$WORK/home" PATH="$WORK/bin:$PATH" OSTLER_WALK_TIER="$tier" OSTLER_WALK_STORE="$WORK/store" \
        OSTLER_WALK_RECORD_DIR="$FAKE/walks" OSTLER_OS003_DIR="$WORK/none" "$@" \
        bash "$FAKE/scripts/post_walk_qa.sh" stub@example.invalid v1.0.9 2>&1 </dev/null
}
mkdir -p "$WORK/store"

printf 'SMOKE tier, every probe passes:\n'
out="$(run_qa smoke STUB_PROBE_TOTAL=79)"
REC="$FAKE/walks/v1.0.9.smoke.tsv"
[ -f "$REC" ]; arm "smoke writes walks/v1.0.9.smoke.tsv" $? "$out"
[ ! -f "$FAKE/walks/v1.0.9.tsv" ]; arm "and does NOT write walks/v1.0.9.tsv (cannot replace the full record)" $? "$(ls "$FAKE/walks")"
awk -F'\t' '$1=="tier"{print $2}' "$REC" | grep -qx smoke; arm "the record says tier smoke" $? "$(grep -n tier "$REC")"
v="$(awk -F'\t' '$1=="verdict"{print $2}' "$REC")"
[ "$v" = "SMOKE-PASS" ]; arm "all-green smoke verdict is SMOKE-PASS (got '$v')" $? "$out"
! grep -qP '^verdict\tCLEAN' "$REC" 2>/dev/null && ! awk -F'\t' '$1=="verdict" && $2=="CLEAN"{f=1} END{exit !f}' "$REC"
arm "and never CLEAN" $? "$(grep verdict "$REC")"
grep -q $'^smoke_note\tOS003 origin/main read' "$REC"; arm "the record carries the OS003 read line (smoke_note)" $? "$(grep smoke_note "$REC")"
grep -q -- '--only' "$WORK/argv" && grep -q -- '--allow-writes' "$WORK/argv"; arm "run_box_walk.sh was invoked with --only <scope> --allow-writes" $? "$(cat "$WORK/argv")"
for p in no_store_port_is_tcp_reachable assistant_answers_grounded no_person_holds_two_contact_cards people_stores_reconcile; do
    grep -q "$p" "$WORK/argv"; arm "BLOCKING probe $p is in the executed scope" $? "$(cat "$WORK/argv")"
done
grep -q 'RUNTIME PROOFS: NOT RUN (tier smoke)' <<<"$out"; arm "cut-manifest runtime proofs are announced as NOT RUN" $? "$out"

printf '\nSMOKE tier with a FAIL:\n'
rm -f "$REC"
out="$(run_qa smoke STUB_PROBE_TOTAL=79 STUB_FAIL=1)"
v="$(awk -F'\t' '$1=="verdict"{print $2}' "$REC")"
[ "$v" = "SMOKE-FAILED" ]; arm "a failing smoke walk is SMOKE-FAILED (got '$v'), not FAILED and not CLEAN" $? "$out"

printf '\nFULL tier is unchanged:\n'
out="$(run_qa full STUB_PROBE_TOTAL=79)"
[ -f "$FAKE/walks/v1.0.9.tsv" ] && awk -F'\t' '$1=="tier"{print $2}' "$FAKE/walks/v1.0.9.tsv" | grep -qx full
arm "full writes walks/v1.0.9.tsv with tier full" $? "$out"
! grep -q -- '--only' "$WORK/argv"; arm "and passes no --only (every probe runs)" $? "$(cat "$WORK/argv")"

printf '\nA smoke verdict is refused by the release gate:\n'
GATE="$REPO/scripts/verify_walk_record.sh"
SHA="$(printf 'a%.0s' $(seq 1 64))"
mkdir -p "$WORK/gate"; cp "$REC" "$WORK/gate/v1.0.9.tsv"   # worst case: smoke content under the full name
env OSTLER_WALK_RECORD_DIR="$WORK/gate" bash "$GATE" v1.0.9 "$SHA" >"$WORK/gate.out" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q "unknown verdict 'SMOKE-" "$WORK/gate.out"; arm "verify_walk_record.sh refuses a SMOKE-* verdict even under the full filename, as an unknown verdict (rc=$rc)" $? "$(cat "$WORK/gate.out")"
rm -f "$WORK/gate/v1.0.9.tsv"; cp "$REC" "$WORK/gate/v1.0.9.smoke.tsv"
env OSTLER_WALK_RECORD_DIR="$WORK/gate" bash "$GATE" v1.0.9 "$SHA" >"$WORK/gate.out" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'NO WALK RECORD' "$WORK/gate.out"; arm "and a lone .smoke.tsv is 'no walk record' to the gate (rc=$rc)" $? "$(cat "$WORK/gate.out")"

printf '\nMUTATION: with the smoke verdict rewrite removed, the CLEAN arm must fail:\n'
sed -e '/^if \[\[ "\$TIER" == "smoke" \]\]; then$/,/^fi$/{/SMOKE-PASS/d;}' "$FAKE/scripts/post_walk_qa.sh" > "$WORK/mut.sh"
cmp -s "$WORK/mut.sh" "$FAKE/scripts/post_walk_qa.sh"; same=$?
[ "$same" -ne 0 ]; arm "the mutant differs from the real script (injection landed)" $? "sed matched nothing"
cp "$WORK/mut.sh" "$FAKE/scripts/post_walk_qa.sh"; rm -f "$REC"
run_qa smoke STUB_PROBE_TOTAL=79 >/dev/null
v="$(awk -F'\t' '$1=="verdict"{print $2}' "$REC")"
[ "$v" = "CLEAN" ]; arm "MUST-FAIL: the mutant records '$v' (CLEAN) for an all-green smoke, so the SMOKE-PASS arm is a real assertion" $? "mutant still recorded: $v"

printf '\n== %s pass / %s fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
