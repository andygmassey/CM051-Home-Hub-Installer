#!/usr/bin/env bash
# scripts/push_cut_tag.sh must refuse a tag when the OS003 model-pin gate (arms 6
# and 7 of gates/verify_model_weights_pinned.sh) is red, cannot run, or does not
# even report arms 6 and 7. Before this nothing ran those arms anywhere.
# OS003 is private, so the gate here is a STUB in a fixture repo whose origin/main
# holds it; what is proved is the WIRING: fetch-from-origin/main, the CM051 SHA
# handed over as OSTLER_CM051_REF, and the refusal on every non-green outcome.
# The real gate's own red/green is in OS003 (gates/verify_model_weights_pinned.sh
# --self-test, mutants 4-6) and in the PR body.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
S=scripts/push_cut_tag.sh
H=$(git rev-parse HEAD)
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }; no(){ echo "  FAIL $1"; fail=$((fail+1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkos(){ # $1 = name, $2 = stub gate body
  local d="$T/$1"; mkdir -p "$d/gates"; git -C "$d" init -q
  printf '%s\n' '#!/usr/bin/env bash' "$2" > "$d/gates/verify_model_weights_pinned.sh"
  echo '[models]' > "$d/release.toml"
  git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@example.com commit -q -m stub
  git -C "$d" update-ref refs/remotes/origin/main HEAD; }
run(){ # $1 = os003 dir, $2 = script
  OSTLER_OS003_DIR="$1" OSTLER_PRETAG_NOFETCH=1 OSTLER_PRETAG_PRAGE=true OSTLER_PRETAG_DRY_RUN=1 \
  OSTLER_PRETAG_CANDIDATE="echo success $H https://example.invalid/cand" OSTLER_PRETAG_REHEARSE="echo success $H https://example.invalid/run" \
  bash "$2" v1.0.99999 "$H" 2>&1; }
GREEN='echo "  [PASS] arm 6: stub ref=${OSTLER_CM051_REF}"; echo "  [PASS] arm 7: stub"; exit 0'
mkos green "$GREEN"
mkos red6 'echo "  [FAIL] arm 6: stub mismatch"; echo "  [PASS] arm 7: stub"; exit 1'
mkos red7 'echo "  [PASS] arm 6: stub"; echo "  [FAIL] arm 7: stub moved"; exit 1'
mkos cannot 'echo "  [CANNOT-RUN] arm 6: stub no checkout"; echo "  [PASS] arm 7: stub"; exit 2'
mkos noarms 'echo "  [PASS] arm 1: stub"; exit 0'
mkos exit0_fail6 'echo "  [FAIL] arm 6: stub"; echo "  [PASS] arm 7: stub"; exit 0'

out=$(run "$T/green" "$S"); rc=$?
[ $rc -eq 0 ] && grep -q "model pins (arms 6 and 7): GREEN" <<<"$out" && grep -q "DRY-RUN: git tag v1.0.99999 $H" <<<"$out" && ok "a green gate reaches the push" || { no "green gate did not reach the push"; echo "$out" | tail -6; }
grep -q "ref=$H" <<<"$out" && ok "the gate was handed the SHA being tagged as OSTLER_CM051_REF" || no "gate not told the tag SHA"
for n in red6 red7 cannot noarms exit0_fail6; do
  out=$(run "$T/$n" "$S"); rc=$?
  [ $rc -ne 0 ] && grep -q "REFUSED. The model-pin gate" <<<"$out" && ! grep -q DRY-RUN <<<"$out" && ok "$n refuses and pushes nothing" || { no "$n did not refuse"; echo "$out" | tail -4; }
done
out=$(HOME="$T/emptyhome" run "$T/does-not-exist" "$S"); rc=$?
[ $rc -ne 0 ] && grep -q "no OS003 checkout found" <<<"$out" && grep -q "REFUSED" <<<"$out" && ok "no OS003 checkout refuses (CANNOT-RUN is not a pass)" || { no "missing OS003 did not refuse"; echo "$out" | tail -4; }
m=$(mktemp); sed 's/if \[ "\$mprc" -ne 0 \] || /if false \&\& /' "$S" > "$m"
if cmp -s "$S" "$m"; then no "mutant did not apply"; else
  out=$(run "$T/red6" "$m"); [ $? -eq 0 ] && grep -q DRY-RUN <<<"$out" && ok "mutant ignoring the gate verdict is caught (it would have pushed)" || no "mutant survived"; fi
rm -f "$m"; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
