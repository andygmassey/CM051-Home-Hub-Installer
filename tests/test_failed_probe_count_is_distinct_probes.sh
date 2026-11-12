#!/bin/bash
# "names N of M" must count DISTINCT probes, and every refusal must print cold.
#
# v1.0.129: the record said "7 of 11" and the gate refused it (rc 2, CANNOT-RUN)
# although nothing was unnamed: the 11 were FAIL ROWS (5 main pass + 6 manifest),
# 4 of them a probe already named (reported by both phases, or by two manifest
# rows). The counter counted rows. The writer now counts distinct probes and
# keeps one failed_row per raw row; the gate re-derives the count from those rows.
#
# Exit: 0 pass, 1 fail, 2 cannot-run.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO/scripts/verify_walk_record.sh"
QA="$REPO/scripts/post_walk_qa.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
for f in "$GATE" "$QA"; do [ -f "$f" ] || { echo "CANNOT-RUN: missing $f" >&2; exit 2; }; done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export OSTLER_WALK_RECORD_DIR="$TMP"
printf 'fixture artefact\n' > "$TMP/a.bin"
SHA="$(shasum -a 256 "$TMP/a.bin" | awk '{print $1}')"
NAMES="hub_screens_customer_read db_key_reaches_every_service morning_brief_catches_me_up setup_progress_advancing todos_reach_reminders acceptance_gate_v1013 followup_keys_match_chat_threads"
: > "$TMP/scope.tsv"
for n in $NAMES; do printf '%s\tblocking\tfixture\tfixture row\n' "$n" >> "$TMP/scope.tsv"; done
export OSTLER_PROMOTE_SCOPE="$TMP/scope.tsv"

# rec <version> <names-recorded-line> <cold-row|omit> [skip-name] ; 11 raw rows, 7 distinct
ROWS="hub_screens_customer_read db_key_reaches_every_service morning_brief_catches_me_up setup_progress_advancing todos_reach_reminders box-walk-setup-progress-advancing box-walk-todos-reach-reminders acceptance_gate_v1013 followup_keys_match_chat_threads box-walk-morning-brief-catches-me-up probe-todos-reach-reminders"
rec() {
    local v="$1" cnt="$2" cold="$3" skip="${4:-}" n
    {
      printf 'version\t%s\nversion_source\tmeasured(CFBundleShortVersionString, matches argument)\n' "$v"
      printf 'artefact_sha256\t%s\nartefact_sha256_source\tmeasured(shasum -a 256 of the fixture)\n' "$SHA"
      printf 'walked_at\t2026-11-12T13:02:47Z\nbox_fp\t3f8a1c9d2e4b6071\nwalk_kind\tthin\nwalk_kind_source\tdefault\n'
      printf 'pass\t57\nfail\t5\ncannot_run\t0\nbroken\t0\nverdict\tFAILED\nqa_exit\t1\n'
      printf 'failed_probe_names_recorded\t%s\n' "$cnt"
      for n in $NAMES; do [ "$n" = "$skip" ] || printf 'failed_probe\t%s\n' "$n"; done
      for n in $ROWS; do printf 'failed_row\t%s\n' "$n"; done
      [ "$cold" = omit ] || printf 'cold\t%s\n' "$cold"
    } > "$TMP/$v.tsv"
}
gate() { "$GATE" "$1" "$SHA" > "$TMP/out" 2> "$TMP/err"; echo $?; }

printf 'the failed-probe count is of distinct probes\n'
COLD='NOT_COLD(synthetic: 123775 pre-reset files)'
rec v9.1.0 "7 of 11" "$COLD"
rc="$(gate v9.1.0)"
[ "$rc" = 1 ] && ok "11 rows covering 7 distinct probes, all 7 named: accepted past the count check (rc 1, FAILED)" || bad "11 rows / 7 distinct returned rc=$rc: $(head -3 "$TMP/err")"
grep -q 'cold: NOT_COLD' "$TMP/err" && ok "the FAILED refusal also prints the cold row as recorded" || bad "no cold line on the FAILED refusal"
rec v9.1.1 "7 of 11" "$COLD" todos_reach_reminders
rc="$(gate v9.1.1)"
[ "$rc" = 2 ] && grep -q 'names 7 of 11' "$TMP/err" && ok "CONTROL: 11 rows but one distinct probe NOT named: still refused (rc 2)" || bad "an unnamed distinct probe was accepted (rc=$rc)"
rec v9.1.2 "7 of 12" "$COLD"
rc="$(gate v9.1.2)"
[ "$rc" = 2 ] && ok "CONTROL: rows that do not account for the whole denominator (11 rows vs 12): refused (rc 2)" || bad "denominator mismatch accepted (rc=$rc)"
rec v9.1.3 "7 of 7" "$COLD"
rc="$(gate v9.1.3)"
[ "$rc" = 1 ] && ok "the writer's new form '7 of 7' passes the count check (rc 1)" || bad "7 of 7 returned rc=$rc"
rec v9.1.4 "7 of 11" omit
rc="$(gate v9.1.4)"
grep -q 'cold: ABSENT' "$TMP/err" && ok "a record with no cold row says so on the refusal path" || bad "no ABSENT cold line (rc=$rc)"
printf 'version\tv9.1.5\n' > "$TMP/v9.1.5.tsv"
"$GATE" v9.1.5 "$SHA" >/dev/null 2> "$TMP/err"; rc=$?
[ "$rc" != 0 ] && grep -q 'cold:' "$TMP/err" && ok "an early malformed-record refusal prints the cold line too" || bad "early refusal missing cold line (rc=$rc)"
rec v9.1.6 "7 of 7" "PROVEN(synthetic)"
"$GATE" v9.1.6 "$SHA" >/dev/null 2> "$TMP/err"; grep -q 'cold:' "$TMP/err" && ok "the cold row is printed as recorded (PROVEN too)" || bad "PROVEN row not printed"

# WRITER: the pipeline that builds FAILED_ROWS / FAILED_NAMES from the two phases.
l1="$(grep -n '^    FAILED_ROWS=' "$QA" | head -1 | cut -d: -f1)"
if [ -z "$l1" ]; then bad "WRITER: FAILED_ROWS is not built in post_walk_qa.sh"; else
  { sed -n "${l1}p" "$QA"; sed -n "$((l1+1))p" "$QA"; } > "$TMP/w.sh"
  P1="hub_screens_customer_read
db_key_reaches_every_service
morning_brief_catches_me_up
setup_progress_advancing
todos_reach_reminders"
  P2="setup_progress_advancing
todos_reach_reminders
acceptance_gate_v1013
followup_keys_match_chat_threads
morning_brief_catches_me_up
box-walk-todos-reach-reminders"
  out="$(FAILED_NAMES_P1="$P1" PHASE2_FAILED_NAMES="$P2" bash -c 'source "$1"; printf "rows=%s distinct=%s\n" "$(printf "%s\n" "$FAILED_ROWS" | grep -c .)" "$(printf "%s\n" "$FAILED_NAMES" | grep -c .)"' _ "$TMP/w.sh" 2>&1)"
  [ "$out" = "rows=11 distinct=7" ] && ok "WRITER: 11 rows (one with a box-walk- prefix) normalise to 7 distinct names" || bad "WRITER: got '$out'"
fi
grep -q "printf 'failed_row" "$QA" && ok "WRITER: failed_row rows are emitted" || bad "WRITER: no failed_row emission"
bash -n "$QA" && bash -n "$GATE" && ok "both scripts parse" || bad "parse error"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
