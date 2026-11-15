#!/usr/bin/env bash
# tests/test_pref_seed_finds_the_staged_payload.sh
# v1.0.112 walk33: the preference seed printed CANNOT-RUN "no cm019 bundle"
# because ttywalk mounts the DMG under mktemp (not /Volumes) and sets no env.
# Pins: (1) the staged payload root is found, (2) a repo-checkout shape is NOT,
# (3) the owner seed recompiles the interest profile before the digest refresh.
# MUST-FAIL arms: mutated lib (fallback removed) and mutated OES (compile removed).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/scripts/box_walk_probes/lib/preference_seed.sh"
OES="$REPO/scripts/box_walk_probes/lib/owner_employer_seed.sh"
[ -f "$LIB" ] && [ -f "$OES" ] || { echo "CANNOT-RUN: subject missing"; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
arm() { if [ "$2" -eq 0 ]; then echo "  [PASS] $1"; PASS=$((PASS+1)); else echo "  [FAIL] $1"; FAIL=$((FAIL+1)); fi; }
probe() { # $1 lib file, $2 root; prints bundle path or NONE
  local root="$2"; mkdir -p "$root/scripts/box_walk_probes/lib"; cp "$1" "$root/scripts/box_walk_probes/lib/preference_seed.sh"
  ( unset OSTLER_CM019_BUNDLE OSTLER_ALLOW_INSTALLED_APP_BUNDLE; export OSTLER_PREF_SEED_VOLUMES_DIR="$T/novol"; mkdir -p "$T/novol"
    . "$root/scripts/box_walk_probes/lib/preference_seed.sh" >/dev/null 2>&1
    if _ps_find_bundle; then echo "$PREFERENCE_SEED_BUNDLE"; else echo NONE; fi )
}
P="$T/payload"; mkdir -p "$P/cm019_preferences"; : > "$P/install.sh"
C="$T/checkout"; mkdir -p "$C/vendor/cm019_preferences"; : > "$C/install.sh"
r="$(probe "$LIB" "$P")"; [ "$r" = "$P/cm019_preferences" ]; arm "staged payload root is found" $?
r="$(probe "$LIB" "$C")"; [ "$r" = "NONE" ]; arm "a repo-checkout shape is not taken for the artefact" $?
M="$T/mut.sh"; python3 - "$LIB" "$M" <<'PY'
import sys
s=open(sys.argv[1]).read(); a=s.index('    _ps_root="$(cd'); b=s.index('    # Last, and only when asked')
open(sys.argv[2],'w').write(s[:a]+s[b:])
PY
[ "$(wc -c <"$M")" -lt "$(wc -c <"$LIB")" ] || { echo "CANNOT-RUN: mutant did not apply"; exit 2; }
r="$(probe "$M" "$P")"; [ "$r" = "NONE" ]; arm "MUST-FAIL: mutant without the fallback finds nothing" $?
grep -q 'com.creativemachines.ostler.editor-frontpage' "$OES"; arm "OES kickstarts the profile compile" $?
c="$(grep -n 'editor-frontpage' "$OES" | head -1 | cut -d: -f1)"; d="$(grep -n 'ostler.context-refresh >' "$OES" | head -1 | cut -d: -f1)"
[ -n "$c" ] && [ -n "$d" ] && [ "$c" -lt "$d" ]; arm "profile compile precedes the digest refresh" $?
grep -v 'editor-frontpage' "$OES" | grep -q 'editor-frontpage'; arm "MUST-FAIL: stripped OES has no compile" $([ $? -eq 0 ] && echo 1 || echo 0)
echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
