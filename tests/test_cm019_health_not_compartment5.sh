#!/usr/bin/env bash
# test_cm019_health_not_compartment5.sh -- self-test for
# scripts/verify_cm019_health_compartment.py and its call in
# scripts/verify_vendor_fresh.sh (Archie ruling, 133: no vendor/cm019 re-pin
# while upstream apple.py writes Apple Health as compartment_level=5).
#
# HERMETIC and SYNTHETIC: every scenario builds throwaway git repos in a temp
# dir. No real CM019 checkout, no real health data. Success line to require:
#   "test_cm019_health_not_compartment5: N passed, 0 failed"
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HELPER="$ROOT/scripts/verify_cm019_health_compartment.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $*" >&2; }
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

REL=services/ingest/src/parsers/apple.py

# mkapple <dir> <health_level> : synthetic parser. Notes always write 5.
mkapple() {
    mkdir -p "$1/services/ingest/src/parsers"
    cat > "$1/$REL" <<PY
def Call(**kw): return kw

class AppleParser:
    def _parse_icloud_notes(self):
        # notes are a different decision: compartment_level=5 here must NOT trip the gate
        yield Call(kind="note", compartment_level=5)

    def _yield_workout_patterns(self):
        yield Call(kind="HKWorkoutActivityType", compartment_level=$2)

    def _yield_sleep_patterns(self):
        yield Call(kind="sleep", compartment_level=$2)

    def _yield_activity_patterns(self):
        # comment only, not a write: compartment_level=5 (highest privacy)
        yield Call(kind="HKQuantityTypeIdentifierStepCount", compartment_level=$2)
PY
}
mkrepo() { git init -q "$1" && git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }

echo "== helper, direct"
mkapple "$T/up_red" 5;   mkrepo "$T/up_red" red
mkapple "$T/up_green" 3; mkrepo "$T/up_green" green

out="$(python3 -I "$HELPER" --rev HEAD --source-repo "$T/up_red" 2>&1)"; rc=$?
n=$(printf '%s\n' "$out" | grep -c '^REFUSED: services/ingest/src/parsers/apple.py@HEAD:[0-9]* compartment_level=5 in health path')
[ "$rc" = 1 ] && [ "$n" = 3 ] && ok "RED: health at 5 refused, 3 sites named (rc=1)" || bad "RED rc=$rc sites=$n: $out"
printf '%s\n' "$out" | grep -q '_parse_icloud_notes' && bad "notes site was refused (should be the negative control)" || ok "NEGATIVE CONTROL: notes at 5 outside a health path is not refused"
printf '%s\n' "$out" | grep -q 'examined 4 compartment_level=5 site' && ok "denominator printed: 4 sites examined, 3 refused" || bad "denominator missing: $out"

out="$(python3 -I "$HELPER" --rev HEAD --source-repo "$T/up_green" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "GREEN: health not at 5 passes (rc=0; the notes 5 and the comment 5 do not trip it)" || bad "GREEN rc=$rc: $out"

python3 -I "$HELPER" --rev no-such-rev --source-repo "$T/up_green" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "CANNOT-RUN (rc=2): unreadable upstream rev is not a pass" || bad "unreadable rev rc=$rc"
printf 'def broken(:\n' > "$T/bad.py"
python3 -I "$HELPER" --scan-file "$T/bad.py" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "CANNOT-RUN (rc=2): unparseable file is not a pass" || bad "unparseable rc=$rc"

echo "== gate mode through verify_vendor_fresh.sh (synthetic CM051 root)"
mkroot() { # <dir> <vendored_level> <pin>
    local d="$1"
    mkdir -p "$d/scripts" "$d/vendor/cm019_preferences"
    cp "$ROOT/scripts/_vendor_lib.sh" "$ROOT/scripts/verify_vendor_fresh.sh" "$HELPER" "$d/scripts/"
    mkapple "$d/vendor/cm019_preferences" "$2"
    cat > "$d/vendor/VENDOR_MANIFEST.toml" <<M
[[tree]]
name             = "cm019_preferences"
vendor_path      = "vendor/cm019_preferences"
source_repo      = "\$CM019"
source_path      = "."
pinned_sha       = "$3"
exclude          = ["__pycache__/"]
verify           = "skip"
unverifiable_ack = true
unverifiable_ack_owner  = "synthetic"
unverifiable_ack_reason = "synthetic fixture"
M
}
RED_SHA="$(git -C "$T/up_red" rev-parse HEAD)"
GREEN_SHA="$(git -C "$T/up_green" rev-parse HEAD)"
OLD_SHA="$(printf '%039d1' 0)"  # built from parts: a literal 40-digit run trips the PII shape scan
rungate() { # <root> <upstream-repo>
    ( cd "$1" && CM019="$2" VENDOR_FRESH_STRICT=1 bash scripts/verify_vendor_fresh.sh 2>&1 ); }

# base = pin OLD, vendored health at 3 (CM051's own divergence)
mkroot "$T/cm051" 3 "$OLD_SHA"; mkrepo "$T/cm051" base
sed -i.bak "s/$OLD_SHA/$RED_SHA/" "$T/cm051/vendor/VENDOR_MANIFEST.toml"; rm -f "$T/cm051/vendor/VENDOR_MANIFEST.toml.bak"
export VENDOR_BASE_REF=HEAD
out="$(rungate "$T/cm051" "$T/up_red")"; rc=$?
n=$(printf '%s\n' "$out" | grep -c '^REFUSED: services/ingest/src/parsers/apple.py@[0-9a-f]*:[0-9]* compartment_level=5')
[ "$rc" = 1 ] && [ "$n" = 3 ] && ok "GATE RED: re-pin to a health-at-5 upstream refused, 3 sites (rc=1)" || bad "gate re-pin red rc=$rc n=$n: $out"

sed -i.bak "s/$RED_SHA/$GREEN_SHA/" "$T/cm051/vendor/VENDOR_MANIFEST.toml"; rm -f "$T/cm051/vendor/VENDOR_MANIFEST.toml.bak"
out="$(rungate "$T/cm051" "$T/up_green")"; rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q 're-pin\|RE-PIN' && ok "GATE GREEN: re-pin to a clean upstream passes (rc=0)" || bad "gate re-pin green rc=$rc: $out"

# upstream unreadable on a re-pin: CANNOT-RUN, and STRICT makes the gate non-zero
out="$(rungate "$T/cm051" "$T/does_not_exist")"; rc=$?
[ "$rc" != 0 ] && printf '%s\n' "$out" | grep -q 'CANNOT-RUN' && ok "GATE CANNOT-RUN: re-pin with unreadable upstream is not a pass (rc=$rc)" || bad "gate cannot-run rc=$rc: $out"

# shipped bytes: vendored apple.py itself carries health at 5 -> RED even with no re-pin
mkroot "$T/cm051b" 5 "$OLD_SHA"; mkrepo "$T/cm051b" base
out="$(rungate "$T/cm051b" "$T/up_green")"; rc=$?
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'REFUSED: vendor/cm019_preferences/services/ingest/src/parsers/apple.py:' && ok "GATE RED: vendored bytes with health at 5 refused without any re-pin" || bad "vendored red rc=$rc: $out"

# no re-pin, clean vendored bytes: pin equal to base -> GREEN with no upstream needed
mkroot "$T/cm051c" 3 "$OLD_SHA"; mkrepo "$T/cm051c" base
out="$(rungate "$T/cm051c" "$T/does_not_exist")"; rc=$?
[ "$rc" = 0 ] && ok "GATE GREEN: unchanged pin and clean vendored bytes (rc=0)" || bad "unchanged pin rc=$rc: $out"

echo "== mutant: break the health predicate, the RED scenario must go green-wrong (test must notice)"
sed 's/r"health|workout|sleep|HK\[A-Za-z\]\*(Identifier|Type)"/r"zzzz_never"/' "$HELPER" > "$T/mutant.py"
cmp -s "$HELPER" "$T/mutant.py" && bad "mutant did not apply" || {
    python3 -I "$T/mutant.py" --rev HEAD --source-repo "$T/up_red" >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ] && ok "MUTANT applied and caught: with the predicate broken the RED fixture passes (rc=0), so the RED assertion above is discriminating" || bad "mutant still refused rc=$rc"
}

echo "test_cm019_health_not_compartment5: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
