#!/usr/bin/env bash
# tests/test_cm019_bundle_accepts_the_payload_root.sh
#
# OSTLER_CM019_BUNDLE set to the payload root (<app>/Contents/Resources, the
# directory holding install.sh) must resolve to its cm019_preferences child.
# On the v1.0.103 candidate 4 walk the driver passed the payload root and the
# seed read every staged file as "bundle MISSING" (a harness CANNOT-RUN).
# Controls: the cm019_preferences directory itself still resolves to itself,
# and a Resources dir WITHOUT install.sh is not treated as a payload root.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$HERE/scripts/box_walk_probes/lib/preference_seed.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0; passes=0
check() { if [ "$2" = "$3" ]; then passes=$((passes+1)); printf 'PASS  %s\n' "$1"; else fails=$((fails+1)); printf 'FAIL  %s\n      got [%s] want [%s]\n' "$1" "$2" "$3"; fi; }
resolve() {
    ( OSTLER_CM019_BUNDLE="$1" OSTLER_PREF_SEED_VOLUMES_DIR="$T/novolumes" \
      bash -c '. "$0" >/dev/null 2>&1; _ps_find_bundle; echo "rc=$? bundle=$PREFERENCE_SEED_BUNDLE"' "$LIB" )
}
R="$T/OstlerInstaller.app/Contents/Resources"
mkdir -p "$R/cm019_preferences/services/ingest/src" "$T/novolumes" "$T/bare/Resources/cm019_preferences"
: > "$R/install.sh"
check "payload root descends into cm019_preferences" "$(resolve "$R")" "rc=0 bundle=$R/cm019_preferences"
check "control: the cm019_preferences dir resolves to itself" "$(resolve "$R/cm019_preferences")" "rc=0 bundle=$R/cm019_preferences"
check "control: a Resources dir without install.sh is taken as given" "$(resolve "$T/bare/Resources")" "rc=0 bundle=$T/bare/Resources"
check "control: a missing path is refused" "$(resolve "$T/nope")" "rc=1 bundle="
printf '\n%d pass, %d fail\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
