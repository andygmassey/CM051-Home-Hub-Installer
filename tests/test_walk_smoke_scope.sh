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

# fake OS003 with origin/main. BOMs are CUMULATIVE, as on real data (v1.0.128: 180 rows, v1.0.129: 190, each with ~50
# capability_id=none rows and all three components): v1.0.6 = every v1.0.5 row + whatever is new.
OS3="$WORK/os003"; mkdir -p "$OS3/manifest" "$OS3/cuts/v1.0.5" "$OS3/cuts/v1.0.6" && cd "$OS3" && git init -q .
printf 'id\tname\trepo\tmethod\tpath\tpattern\texpect\trequired\tticket\ncap_wiki\tw\tcm044\tsource\t.\tx\tpresent\tyes\tt\ncap_wiki2\tw\tcm044\tsource\t.\tx\tpresent\tyes\tt\ncap_daemon\td\tassistant\tsource\t.\tx\tpresent\tyes\tt\ncap_inst\ti\tcm051\tsource\t.\tx\tpresent\tyes\tt\n' > manifest/capability_manifest.tsv
bomfile() { # $1 = version, rest = "what|repo|ref|capability" rows
    local v="$1"; shift; printf 'what\trepo\tref\tlanded\tcapability_id\tverify\tticket\n' > "$OS3/cuts/$v/MUST_CONTAIN.tsv"
    for r in "$@"; do IFS='|' read -r w rp rf c <<<"$r"; printf '%s\t%s\t%s\tno\t%s\tv\tt\n' "$w" "$rp" "$rf" "$c" >> "$OS3/cuts/$v/MUST_CONTAIN.tsv"; done; }
commit_os3() { git -C "$OS3" add -A; git -C "$OS3" -c user.name=t -c user.email=t@example.invalid commit -q -m b --allow-empty; git -C "$OS3" update-ref refs/remotes/origin/main HEAD; }
BASE=("old daemon fix|ostler-assistant|a1|cap_daemon" "old wiki fix|CM044|b2|cap_wiki" "old installer fix|CM051|c3|cap_inst" "old unguarded 1|CM051|d4|none" "old unguarded 2|CM051|e5|none")
cd "$REPO"
mkdir -p "$WORK/store1"
printf 'version\tv1.0.5\nverdict\tCLEAN\n' > "$WORK/store1/v1.0.5-20261101T000000Z.tsv"          # legacy record, no tier row = full
sel1() { sel --walk-store "$WORK/store1" --os003-dir "$OS3" --target-version v1.0.6; }
inout() { echo "$out" | names | grep -qx "$1"; }

bomfile v1.0.5 "${BASE[@]}"
bomfile v1.0.6 "${BASE[@]}" "new wiki fix|CM044|f6|cap_wiki2"; commit_os3
out="$(sel1)"
inout usage_journal_producers && ! inout todos_reach_reminders && ! inout fda_tick_can_import
arm "CUMULATIVE BOMs, one new cm044 row (old none rows present in both): cm044 only, no widening" $? "$(cat "$WORK/err")"
grep -q 'smoke delta: 6 rows in v1.0.6, 5 in v1.0.5, 1 new' "$WORK/err"; arm "the delta is printed (6 vs 5 rows, 1 new)" $? "$(cat "$WORK/err")"
grep -qE 'OS003 origin/main read: [0-9a-f]+ 20[0-9]{2}-' "$WORK/err"; arm "the OS003 origin/main commit and date that were read are printed" $? "$(cat "$WORK/err")"
for p in no_store_port_is_tcp_reachable assistant_answers_grounded no_person_holds_two_contact_cards people_stores_reconcile app_signature_survives_first_run; do
    inout "$p"; arm "always selected: $p" $? "$out"
done
bomfile v1.0.6 "${BASE[@]}" "new daemon fix|ostler-assistant|f6|cap_daemon"; commit_os3
out="$(sel1)"
inout todos_reach_reminders && ! inout usage_journal_producers; arm "one new assistant row: assistant probes yes, cm044 probes no" $? "$(cat "$WORK/err")"
bomfile v1.0.6 "${BASE[@]}" "new unguarded|CM051|f6|none"; commit_os3
out="$(sel1)"
[ "$(wc -l <<<"$out" | tr -d ' ')" = "$(wc -l <<<"$ondisk" | tr -d ' ')" ] && grep -q "NEW v1.0.6 BOM row has capability 'none'" "$WORK/err"; arm "a NEW none row widens to ALL" $? "$(cat "$WORK/err")"
bomfile v1.0.6 "${BASE[@]}" "new unmapped|CM051|f6|cap_not_in_manifest"; commit_os3
out="$(sel1)"
[ "$(wc -l <<<"$out" | tr -d ' ')" = "$(wc -l <<<"$ondisk" | tr -d ' ')" ] && grep -q 'maps to no component' "$WORK/err"; arm "a NEW row whose capability is not in the manifest widens to ALL" $? "$(cat "$WORK/err")"
bomfile v1.0.6 "${BASE[@]}" "new wiki fix|CM044|f6|cap_wiki2"; rm "$OS3/cuts/v1.0.5/MUST_CONTAIN.tsv"; commit_os3
out="$(sel1)"
[ "$(wc -l <<<"$out" | tr -d ' ')" = "$(wc -l <<<"$ondisk" | tr -d ' ')" ] && grep -q 'last FULL walk v1.0.5 unreadable' "$WORK/err"; arm "an unreadable last-FULL BOM widens to ALL (no delta possible)" $? "$(cat "$WORK/err")"
bomfile v1.0.5 "${BASE[@]}"; bomfile v1.0.6 "${BASE[@]}" "new wiki fix|CM044|f6|cap_wiki2"; commit_os3
out="$(sel --walk-store "$WORK/store1" --os003-dir "$OS3" --target-version v1.0.7)"
[ "$(wc -l <<<"$out" | tr -d ' ')" = "$(wc -l <<<"$ondisk" | tr -d ' ')" ] && grep -q 'unreadable' "$WORK/err"; arm "a target cut whose BOM cannot be read widens to ALL" $? "$(cat "$WORK/err")"

# 5. a newer SMOKE record must not count as the last FULL walk
bomfile v1.0.6 "${BASE[@]}" "new wiki fix|CM044|f6|cap_wiki2"; commit_os3
printf 'version\tv1.0.6\ntier\tsmoke\nverdict\tSMOKE-PASS\n' > "$WORK/store1/v1.0.6-20261110T000000Z.tsv"
out="$(sel1)"
grep -q 'last FULL record v1.0.5' "$WORK/err"; arm "a newer smoke record in the store is ignored; last FULL stays v1.0.5" $? "$(cat "$WORK/err")"

# MUTATION: if smoke records counted as FULL the previous arm must fail
sed 's/rows.get("tier", "full") != "full"/False/' "$SEL" > "$WORK/mut.py"; cmp -s "$WORK/mut.py" "$SEL" && { arm "mutant injection landed" 1 "sed matched nothing"; }
python3 "$WORK/mut.py" --repo-root "$REPO" --walk-store "$WORK/store1" --os003-dir "$OS3" --target-version v1.0.6 >/dev/null 2>"$WORK/err"
grep -q 'last FULL record v1.0.5' "$WORK/err"; [ $? -ne 0 ]; arm "MUST-FAIL: the mutant treats the smoke record as FULL, so the arm above is a real assertion" $? "$(cat "$WORK/err")"

printf '\n== %s pass / %s fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
