#!/usr/bin/env bash
# Cut paperwork must never carry the owner's name (Archie 2026-11-17).
# Fake HOME + synthetic term only. Drives the REAL carry_cut_manifest.sh and
# the REAL new_cut.sh cut.env copy step.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
fail=0; ok(){ echo "PASS $1"; }; bad(){ echo "FAIL $1"; fail=1; }
term="Zorbwick"
mkdir -p "$t/fakehomedir"
printf '[family_names]\nnames = ["%s"]\n' "$term" > "$t/fakehomedir/.ostler-operator-pii.toml"
mkdir -p "$t/r/cut-manifests" "$t/r/scripts"
cp "$repo/scripts/carry_cut_manifest.sh" "$repo/scripts/owner_scrub.py" "$t/r/scripts/"
cat > "$t/r/cut-manifests/v9.9.1.yaml" <<Y
# awaiting ${term}'s walk on ${term}'s box
gate: "blocked until ${term} walks"
verdict_91: "ZORBWICK saw it"
Y
run(){ HOME="$t/fakehomedir" bash "$t/r/scripts/carry_cut_manifest.sh" v9.9.1 v9.9.2; }
run >"$t/o" 2>&1 && ok "carry runs" || bad "carry rc ($(cat "$t/o"))"
n=$(grep -oi -- "$term" "$t/r/cut-manifests/v9.9.2.yaml" | wc -l | tr -d " "); [ "$n" = 0 ] && ok "0 occurrences in carried manifest" || bad "$n occurrences"
grep -q "awaiting the owner's walk on the owner's box" "$t/r/cut-manifests/v9.9.2.yaml" && ok "wording is the owner" || bad "wording"
# control: the source really had the term (the count is not a vacuous zero)
[ "$(grep -oi -- "$term" "$t/r/cut-manifests/v9.9.1.yaml" | wc -l | tr -d " ")" = 4 ] && ok "control: source had 4" || bad "control"
# cannot-run: no inventory is rc 2, not a clean carry
rm "$t/r/cut-manifests/v9.9.2.yaml"; mkdir -p "$t/empty"
HOME="$t/empty" bash "$t/r/scripts/carry_cut_manifest.sh" v9.9.1 v9.9.2 >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -e "$t/r/cut-manifests/v9.9.2.yaml" ] && ok "no inventory is CANNOT-RUN rc 2, no file" || bad "rc=$rc"
# new_cut.sh must route cut.env through the scrubber
grep -q 'owner_scrub.py" < "cuts/\$PREV/cut.env" > "\$NEW/cut.env"' "$repo/scripts/new_cut.sh" && ok "new_cut.sh scrubs cut.env copy" || bad "new_cut.sh does not scrub cut.env"
HOME="$t/fakehomedir" python3 -I "$repo/scripts/owner_scrub.py" <<<"# note: ${term} said" | grep -qi -- "$term" && bad "cut.env filter leaves term" || ok "cut.env filter removes term"
exit $fail
