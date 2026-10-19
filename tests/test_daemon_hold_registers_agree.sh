#!/usr/bin/env bash
# scripts/verify_daemon_hold_registers_agree.py must refuse a daemon hold that is
# written in scripts/daemon_hold_ack.tsv but not in cut-manifests/permanent.yaml
# (v1.0.110, cut run 39197687650: check-manifest killed the build after the tag).
# Arms (synthetic fixtures): both registers agree -> 0; one SHA only in the .tsv
# -> 1 naming it; nothing held for the pin -> 0; a missing register -> 2
# (CANNOT-RUN, never a pass); a mutant that skips the comparison is caught.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
S=scripts/verify_daemon_hold_registers_agree.py
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }; no(){ echo "  FAIL $1"; fail=$((fail+1)); }
python3 -c 'import yaml' 2>/dev/null || { echo "CANNOT-RUN: PyYAML unavailable"; exit 2; }
mk(){ # dir, tsv_shas, perm_shas, pin
  mkdir -p "$1/cuts/v1.0.99999" "$1/scripts" "$1/cut-manifests"
  printf 'CUT_VERSION=1.0.99999\nDAEMON_COMMIT=%s\nCM051=0000000000000000000000000000000000000000\n' "$4" > "$1/cuts/v1.0.99999/cut.env"
  printf '# pinned_sha_prefix\thold_ack_shas\tshipping_bugfixes_grafted\treason\n' > "$1/scripts/daemon_hold_ack.tsv"
  [ -n "$2" ] && printf 'abcdef12\t%s\ttrue\tfixture hold\n' "$2" >> "$1/scripts/daemon_hold_ack.tsv"
  { echo "entries:"; echo "  - id: permanent-daemon-freshness"; echo "    proof:"; echo "      kind: pinned_artefact_freshness"; echo "      hold_ack:"; echo "        reason: \"fixture\""; echo "        shas:"; for x in $3; do echo "          - $x  # fixture"; done; } > "$1/cut-manifests/permanent.yaml"
}
T=$(mktemp -d)
mk "$T/agree" "1111111aa 2222222bb" "1111111aa 2222222bb 9999999zz" abcdef1234
out=$(python3 "$S" v1.0.99999 --root "$T/agree" 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q "PASS all 2" <<<"$out" && ok "both registers hold the set -> 0" || no "agreeing registers did not pass (rc=$rc)"
mk "$T/split" "1111111aa 2222222bb" "1111111aa" abcdef1234
out=$(python3 "$S" v1.0.99999 --root "$T/split" 2>&1); rc=$?
[ $rc -eq 1 ] && grep -q "2222222bb" <<<"$out" && ok "a SHA held only in the .tsv -> 1, named" || no "split registers not refused (rc=$rc)"
mk "$T/none" "" "1111111aa" abcdef1234
out=$(python3 "$S" v1.0.99999 --root "$T/none" 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q "nothing is held" <<<"$out" && ok "nothing held for the pin -> 0, said so" || no "empty hold mis-graded (rc=$rc)"
mk "$T/other" "1111111aa" "" 7777777777
out=$(python3 "$S" v1.0.99999 --root "$T/other" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "a .tsv row for ANOTHER pin is not this cut's hold -> 0" || no "another pin's row was counted (rc=$rc)"
rm -f "$T/split/cut-manifests/permanent.yaml"
out=$(python3 "$S" v1.0.99999 --root "$T/split" 2>&1); rc=$?
[ $rc -eq 2 ] && grep -q CANNOT-RUN <<<"$out" && ok "a missing register -> 2 CANNOT-RUN, not a pass" || no "missing register mis-graded (rc=$rc)"
mk "$T/split" "1111111aa 2222222bb" "1111111aa" abcdef1234
m=$(mktemp); sed 's/^missing = \[s for s in held_tsv if not any(same(s, p) for p in held_perm)\]$/missing = []/' "$S" > "$m"
if cmp -s "$S" "$m"; then no "mutant did not apply"; else
  python3 "$m" v1.0.99999 --root "$T/split" >/dev/null 2>&1; [ $? -eq 0 ] && ok "mutant that skips the comparison is caught" || no "mutant survived"; fi
rm -rf "$T" "$m"; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
