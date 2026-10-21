#!/usr/bin/env bash
# scripts/push_cut_tag.sh must refuse to push a cut tag while any PR will
# cross 48h within the lookahead (default 3h). v1.0.114 spent its tag on
# exactly this: #2993 crossed 48h between the green candidate and the tag run.
# The REAL verify_pr_age.sh runs here; only `gh` is faked (a PR whose age we
# set). Arms: 46h-old PR (crosses within 3h) refuses and pushes nothing;
# 44h-old PR (does not) reaches the push; 49h-old PR refuses; a 46h-old PR
# with a valid exemption reaches the push; a mutant that ignores the
# lookahead verdict is caught.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
S=scripts/push_cut_tag.sh
H=$(git rev-parse HEAD)
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }; no(){ echo "  FAIL $1"; fail=$((fail+1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkfake(){ # $1 = age in hours of the one open PR
  local created; created=$(python3 -c "import datetime as d,sys;print((d.datetime.now(d.timezone.utc)-d.timedelta(hours=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1")
  mkdir -p "$T/bin"; cat > "$T/bin/gh" <<GH
#!/bin/sh
case "\$*" in
  *"auth token"*) echo fake-token ;;
  *"pr list"*) echo '[{"number":424242,"title":"fixture PR","createdAt":"$created","isDraft":false}]' ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$T/bin/gh"; }
run(){ OSTLER_PRETAG_MODELPINS='echo "[PASS] arm 6: held green"; echo "[PASS] arm 7: held green"' OSTLER_PRETAG_DRY_RUN=1 OSTLER_PRETAG_PRAGE_GH_PATH="$T/bin" OSTLER_PRETAG_PRAGE_REPOS="fixture/FixtureRepo" \
  OSTLER_PRETAG_CANDIDATE="echo success $H https://example.invalid/cand" OSTLER_PRETAG_REHEARSE="echo success $H https://example.invalid/run" \
  OSTLER_CUT_DEFERRALS="${DEFER:-$PWD/cut-deferrals.yaml}" bash "$1" v1.0.99999 "$H" 2>&1; }
mkfake 46; out=$(run "$S"); rc=$?
[ $rc -ne 0 ] && grep -q "REFUSED. A PR crosses 48h within 3h" <<<"$out" && grep -q "FixtureRepo#424242" <<<"$out" && ! grep -q DRY-RUN <<<"$out" && ok "a PR crossing 48h within 3h refuses, pushes nothing" || { no "46h PR did not refuse"; echo "$out" | tail -5; }
mkfake 44; out=$(run "$S"); rc=$?
[ $rc -eq 0 ] && grep -q "lookahead: GREEN" <<<"$out" && grep -q "DRY-RUN: git tag v1.0.99999 $H" <<<"$out" && ok "a PR 4h from 48h reaches the push" || { no "44h PR did not reach the push"; echo "$out" | tail -5; }
mkfake 49; out=$(run "$S"); rc=$?
[ $rc -ne 0 ] && ! grep -q DRY-RUN <<<"$out" && ok "a PR already over 48h refuses" || no "49h PR accepted"
mkfake 46; printf 'pr_exemptions:\n  - ref: "FixtureRepo#424242"\n    reason: "fixture exemption for the test"\n    review_by: 2099-01-01\n' > "$T/defer.yaml"
out=$(DEFER="$T/defer.yaml" run "$S"); rc=$?
[ $rc -eq 0 ] && grep -q "DRY-RUN" <<<"$out" && ok "an exempted PR inside the lookahead reaches the push" || { no "exemption not honoured"; echo "$out" | tail -5; }
m=$(mktemp); sed 's/if \[ "\$prc" -ne 0 \]; then/if false; then/' "$S" > "$m"
if cmp -s "$S" "$m"; then no "mutant did not apply"; else
  mkfake 46; out=$(run "$m"); [ $? -eq 0 ] && ok "mutant ignoring the lookahead verdict is caught (it would have pushed)" || no "mutant survived"; fi
rm -f "$m"; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
