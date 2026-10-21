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
pinof(){ git -C "$T/$1" rev-parse HEAD; }
run(){ # $1 = os003 dir, $2 = script
  OSTLER_PRETAG_OS003_PIN="$(git -C "$1" rev-parse HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)" \
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
# The wrapper's own CANNOT-RUN paths (push_cut_tag.sh modelpins): each must refuse.
runraw(){ # env passed by caller; no OSTLER_OS003_DIR default
  OSTLER_PRETAG_PRAGE=true OSTLER_PRETAG_DRY_RUN=1 \
  OSTLER_PRETAG_CANDIDATE="echo success $H https://example.invalid/cand" OSTLER_PRETAG_REHEARSE="echo success $H https://example.invalid/run" \
  bash "$S" v1.0.99999 "$H" 2>&1; }
mkdir -p "$T/emptyhome2"
out=$(env -u OSTLER_OS003_DIR -u OSTLER_PRETAG_MODELPINS HOME="$T/emptyhome2" OSTLER_PRETAG_NOFETCH=1 bash -c "$(declare -f runraw); H=$H S=$S; runraw"); rc=$?
[ $rc -ne 0 ] && grep -q "no OS003 checkout found" <<<"$out" && grep -q "REFUSED" <<<"$out" && ! grep -q DRY-RUN <<<"$out" && ok "OSTLER_OS003_DIR unset and no default checkout refuses" || { no "unset OSTLER_OS003_DIR did not refuse"; echo "$out" | tail -4; }
mkdir -p "$T/noorigin"; git -C "$T/noorigin" init -q
out=$(env -u OSTLER_PRETAG_MODELPINS HOME="$T/emptyhome2" OSTLER_OS003_DIR="$T/noorigin" OSTLER_PRETAG_NOFETCH=0 bash -c "$(declare -f runraw); H=$H S=$S; runraw"); rc=$?
[ $rc -ne 0 ] && grep -q "could not fetch OS003 origin/main" <<<"$out" && grep -q "REFUSED" <<<"$out" && ! grep -q DRY-RUN <<<"$out" && ok "an OS003 fetch failure refuses" || { no "fetch failure did not refuse"; echo "$out" | tail -4; }
d="$T/nogate"; mkdir -p "$d"; git -C "$d" init -q; echo x > "$d/README"; git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@example.com commit -q -m nogate; git -C "$d" update-ref refs/remotes/origin/main HEAD
out=$(env -u OSTLER_PRETAG_MODELPINS HOME="$T/emptyhome2" OSTLER_OS003_DIR="$d" OSTLER_PRETAG_NOFETCH=1 OSTLER_PRETAG_OS003_PIN="$(git -C "$d" rev-parse HEAD)" bash -c "$(declare -f runraw); H=$H S=$S; runraw"); rc=$?
[ $rc -ne 0 ] && grep -q "OS003 origin/main has no gate" <<<"$out" && grep -q "REFUSED" <<<"$out" && ! grep -q DRY-RUN <<<"$out" && ok "an OS003 origin/main without the gate refuses" || { no "missing gate did not refuse"; echo "$out" | tail -4; }
# Frozen cut: OS003 main has moved its pins, the cut's recorded commit has not.
# The stub gate passes only if it was handed the RECORDED release.toml.
d="$T/frozen"; mkdir -p "$d/gates"; git -C "$d" init -q
printf '%s\n' '#!/usr/bin/env bash' 'if grep -q pins-recorded "$(dirname "$0")/../release.toml"; then echo "  [PASS] arm 6: recorded"; echo "  [PASS] arm 7: stub"; exit 0; else echo "  [FAIL] arm 6: read main pins"; echo "  [PASS] arm 7: stub"; exit 1; fi' > "$d/gates/verify_model_weights_pinned.sh"
echo 'pins-recorded' > "$d/release.toml"; git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@example.com commit -q -m recorded
rec=$(git -C "$d" rev-parse HEAD)
echo 'pins-moved-on-main' > "$d/release.toml"; git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@example.com commit -q -m moved
git -C "$d" update-ref refs/remotes/origin/main HEAD
out=$(env -u OSTLER_PRETAG_MODELPINS HOME="$T/emptyhome2" OSTLER_OS003_DIR="$d" OSTLER_PRETAG_NOFETCH=1 OSTLER_PRETAG_OS003_PIN="$rec" bash -c "$(declare -f runraw); H=$H S=$S; runraw"); rc=$?
[ $rc -eq 0 ] && grep -q DRY-RUN <<<"$out" && ok "a frozen cut verifies against ITS recorded OS003 release.toml, not main's moved pins" || { no "frozen cut read main's pins"; echo "$out" | tail -4; }
out=$(env -u OSTLER_PRETAG_MODELPINS -u OSTLER_PRETAG_OS003_PIN HOME="$T/emptyhome2" OSTLER_OS003_DIR="$d" OSTLER_PRETAG_NOFETCH=1 bash -c "$(declare -f runraw); H=$H S=$S; runraw"); rc=$?
[ $rc -ne 0 ] && grep -q "lacks the recorded commit\|records no os003_sha" <<<"$out" && grep -q REFUSED <<<"$out" && ! grep -q DRY-RUN <<<"$out" && ok "the real cuts/REGISTRY_PIN lookup refuses when OS003 lacks that commit" || { no "REGISTRY_PIN lookup did not refuse"; echo "$out" | tail -4; }
m=$(mktemp); sed 's/if \[ "\$mprc" -ne 0 \] || /if false \&\& /' "$S" > "$m"
if cmp -s "$S" "$m"; then no "mutant did not apply"; else
  out=$(run "$T/red6" "$m"); [ $? -eq 0 ] && grep -q DRY-RUN <<<"$out" && ok "mutant ignoring the gate verdict is caught (it would have pushed)" || no "mutant survived"; fi
rm -f "$m"; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
