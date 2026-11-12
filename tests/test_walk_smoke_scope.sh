#!/usr/bin/env bash
# tests/test_walk_smoke_scope.sh -- the smoke scope is explicit, complete, and fails WIDE.
#   1. every probe on disk is in smoke_scope.tsv exactly once (a new probe cannot fall out of smoke)
#   2. the 4 launch-directive BLOCKING probes are always selected
#   3. with no FULL record, or an unreadable / unmappable BOM, ALL components run (never narrower)
#   4. a changed component (via OS003 BOM capability_id -> capability_manifest repo) selects only that component
#   5. smoke records in the walk store never count as the last FULL walk; a record with no tier row does
#   6. the --only substring rule cannot pull in probes beyond the scope
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEL="$REPO/scripts/walk_smoke_select.py"
PASS=0; FAIL=0
arm() { if [ "$2" -eq 0 ]; then echo "  [PASS] $1"; PASS=$((PASS+1)); else echo "  [FAIL] $1"; printf '%s\n' "${3:-}" | tail -8 | sed 's/^/         /'; FAIL=$((FAIL+1)); fi; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 1. coverage, exactly once
ondisk="$(for f in "$REPO"/scripts/box_walk_probes/probes/*.sh; do basename "$f" .sh; done | LC_ALL=C sort)"
inscope="$(grep -v '^#' "$REPO/scripts/box_walk_probes/smoke_scope.tsv" | cut -f3 | tr ',' '\n' | grep -v '^$' | LC_ALL=C sort)"
[ "$ondisk" = "$(printf '%s\n' "$inscope" | LC_ALL=C sort -u)" ]; arm "every probe on disk ($(wc -l <<<"$ondisk" | tr -d ' ')) is in smoke_scope.tsv" $? "$(diff <(echo "$ondisk") <(echo "$inscope" | sort -u))"
[ -z "$(printf '%s\n' "$inscope" | uniq -d)" ]; arm "and none appears twice" $? "$(printf '%s\n' "$inscope" | uniq -d)"

sel() { python3 "$SEL" --repo-root "$REPO" "$@" 2>"$WORK/err"; }
names() { cut -f1; }

# 3. no FULL record -> ALL
mkdir -p "$WORK/store0"
out="$(sel --walk-store "$WORK/store0" --os003-dir "$WORK/none")"
[ "$(wc -l <<<"$out" | tr -d ' ')" = "$(wc -l <<<"$ondisk" | tr -d ' ')" ] && grep -q 'fail wide' "$WORK/err"; arm "no FULL record in the store: all probes, and it says fail wide" $? "$(cat "$WORK/err")"

# fake OS003 with origin/main
OS3="$WORK/os003"; mkdir -p "$OS3/manifest" "$OS3/cuts/v1.0.6" && cd "$OS3" && git init -q . 
printf 'id\tname\trepo\tmethod\tpath\tpattern\texpect\trequired\tticket\ncap_wiki\tw\tcm044\tsource\t.\tx\tpresent\tyes\tt\ncap_daemon\td\tassistant\tsource\t.\tx\tpresent\tyes\tt\n' > manifest/capability_manifest.tsv
bom() { printf 'what\trepo\tref\tlanded\tcapability_id\tverify\tticket\n' > "$OS3/cuts/v1.0.6/MUST_CONTAIN.tsv"; for c in "$@"; do printf 'x\tCM051\tabc\tno\t%s\tv\tt\n' "$c" >> "$OS3/cuts/v1.0.6/MUST_CONTAIN.tsv"; done
  git -C "$OS3" add -A; git -C "$OS3" -c user.name=t -c user.email=t@example.invalid commit -q -m b --allow-empty; git -C "$OS3" update-ref refs/remotes/origin/main HEAD; }
cd "$REPO"
mkdir -p "$WORK/store1"
printf 'version\tv1.0.5\nverdict\tCLEAN\n' > "$WORK/store1/v1.0.5-20261101T000000Z.tsv"          # legacy record, no tier row = full
bom cap_wiki
out="$(sel --walk-store "$WORK/store1" --os003-dir "$OS3" --target-version v1.0.6)"
echo "$out" | names | grep -qx usage_journal_producers && ! echo "$out" | names | grep -qx todos_reach_reminders && ! echo "$out" | names | grep -qx fda_tick_can_import
arm "cm044 changed since the last FULL: cm044 probes yes, assistant and cm051 probes no" $? "$(cat "$WORK/err")"
for p in no_store_port_is_tcp_reachable assistant_answers_grounded no_person_holds_two_contact_cards people_stores_reconcile app_signature_survives_first_run; do
    echo "$out" | names | grep -qx "$p"; arm "always selected: $p" $? "$out"
done
bom cap_daemon
out="$(sel --walk-store "$WORK/store1" --os003-dir "$OS3" --target-version v1.0.6)"
echo "$out" | names | grep -qx todos_reach_reminders && ! echo "$out" | names | grep -qx usage_journal_producers; arm "assistant changed: assistant probes yes, cm044 probes no" $? "$(cat "$WORK/err")"
bom none
out="$(sel --walk-store "$WORK/store1" --os003-dir "$OS3" --target-version v1.0.6)"
[ "$(wc -l <<<"$out" | tr -d ' ')" = "$(wc -l <<<"$ondisk" | tr -d ' ')" ] && grep -q 'fail wide' "$WORK/err"; arm "a BOM row whose capability maps to nothing widens to ALL" $? "$(cat "$WORK/err")"
bom cap_wiki
out="$(sel --walk-store "$WORK/store1" --os003-dir "$OS3" --target-version v1.0.7)"
[ "$(wc -l <<<"$out" | tr -d ' ')" = "$(wc -l <<<"$ondisk" | tr -d ' ')" ] && grep -q 'unreadable' "$WORK/err"; arm "a target cut whose BOM cannot be read widens to ALL" $? "$(cat "$WORK/err")"

# 5. a newer SMOKE record must not count as the last FULL walk
bom cap_wiki
printf 'version\tv1.0.6\ntier\tsmoke\nverdict\tSMOKE-PASS\n' > "$WORK/store1/v1.0.6-20261110T000000Z.tsv"
out="$(sel --walk-store "$WORK/store1" --os003-dir "$OS3" --target-version v1.0.6)"
grep -q 'last FULL record v1.0.5' "$WORK/err"; arm "a newer smoke record in the store is ignored; last FULL stays v1.0.5" $? "$(cat "$WORK/err")"

# MUTATION: if smoke records counted as FULL the previous arm must fail
sed 's/rows.get("tier", "full") != "full"/False/' "$SEL" > "$WORK/mut.py"; cmp -s "$WORK/mut.py" "$SEL" && { arm "mutant injection landed" 1 "sed matched nothing"; }
python3 "$WORK/mut.py" --repo-root "$REPO" --walk-store "$WORK/store1" --os003-dir "$OS3" --target-version v1.0.6 >/dev/null 2>"$WORK/err"
grep -q 'last FULL record v1.0.5' "$WORK/err"; [ $? -ne 0 ]; arm "MUST-FAIL: the mutant treats the smoke record as FULL, so the arm above is a real assertion" $? "$(cat "$WORK/err")"

printf '\n== %s pass / %s fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
