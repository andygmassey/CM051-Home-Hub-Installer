#!/usr/bin/env bash
# tests/test_ttywalk_exports_the_cm019_bundle.sh
# v1.0.115 walk H2: the preference seed (runs on the DRIVER, from the main
# checkout) read CANNOT-RUN "no cm019 bundle" because the DMG is mounted under
# mktemp and the seed's staged-payload lookup keys on its own location.
# ttywalk.sh --from-dmg must export OSTLER_CM019_BUNDLE for the whole run.
# Arms: (1) fake mount layout -> exported, and the REAL seed lookup, run from a
# driver-shaped checkout with no /Volumes mount, finds the bundle through it;
# (2) missing bundle -> unset (an inherited stale value too) and the seed
# returns CANNOT-RUN; (3) ttywalk sources the lib and calls it inside the
# --from-dmg block; (4) MUST-FAIL mutant: lib that exports nothing.
# 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WALK="$REPO/scripts/ttywalk.sh"
LIB="$REPO/scripts/lib_walk_cm019_bundle.sh"
SEED="$REPO/scripts/box_walk_probes/lib/preference_seed.sh"
[ -f "$WALK" ] && [ -f "$SEED" ] || { echo "CANNOT-RUN: subject missing"; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
arm() { if [ "$2" -eq 0 ]; then echo "  [PASS] $1"; PASS=$((PASS+1)); else echo "  [FAIL] $1"; FAIL=$((FAIL+1)); fi; }

# Fake mount: <mnt>/Ostler.app/Contents/Resources with install.sh + bundle.
GOOD="$T/mnt-good/Ostler.app/Contents/Resources"; mkdir -p "$GOOD/cm019_preferences"; : > "$GOOD/install.sh"
BAD="$T/mnt-bad/Ostler.app/Contents/Resources"; mkdir -p "$BAD"; : > "$BAD/install.sh"
# Driver-shaped checkout: the seed lib sits in a tree with no install.sh+bundle.
DRV="$T/driver/scripts/box_walk_probes/lib"; mkdir -p "$DRV" "$T/novol"; cp "$SEED" "$DRV/preference_seed.sh"

# $1 lib, $2 payload root, $3 stale inherited value; prints exported|unset|nolib, then seed result
run() {
  ( unset OSTLER_ALLOW_INSTALLED_APP_BUNDLE OSTLER_CM019_BUNDLE
    [ -n "${3:-}" ] && export OSTLER_CM019_BUNDLE="$3"
    export OSTLER_PREF_SEED_VOLUMES_DIR="$T/novol"
    [ -f "$1" ] || { echo "nolib"; exit 0; }
    . "$1"; walk_export_cm019_bundle "$2" >/dev/null
    # Child process: only an EXPORTED variable reaches it, as on the real run.
    v="$(/bin/bash -c 'printf %s "${OSTLER_CM019_BUNDLE:-}"')"
    if [ -n "$v" ]; then echo "exported $v"; else echo unset; fi
    /bin/bash -c '. "$1" >/dev/null 2>&1; if _ps_find_bundle; then echo "found ${PREFERENCE_SEED_BUNDLE}"; else echo CANNOT-RUN; fi' _ "$DRV/preference_seed.sh" )
}
r="$(run "$LIB" "$GOOD")"
[ "$(echo "$r" | sed -n 1p)" = "exported $GOOD" ]; arm "fake mount: OSTLER_CM019_BUNDLE exported (payload root)" $?
[ "$(echo "$r" | sed -n 2p)" = "found $GOOD/cm019_preferences" ]; arm "fake mount: the seed, run from the driver checkout, finds the bundle" $?
r="$(run "$LIB" "$BAD")"
[ "$(echo "$r" | sed -n 1p)" = "unset" ] && [ "$(echo "$r" | sed -n 2p)" = "CANNOT-RUN" ]; arm "missing bundle: unset and the seed reads CANNOT-RUN" $?
r="$(run "$LIB" "$BAD" "$T/stale")"
[ "$(echo "$r" | sed -n 1p)" = "unset" ]; arm "missing bundle: an inherited stale value is cleared, not trusted" $?
out="$( . "$LIB" 2>/dev/null; walk_export_cm019_bundle "$BAD")"
case "$out" in *"no cm019_preferences in the mounted payload"*"CANNOT-RUN"*) rc=0;; *) rc=1;; esac; arm "missing bundle: the reason is stated" $rc
# Wiring: sourced, and called after STAGE_SRC is set inside the --from-dmg block.
grep -q 'lib_walk_cm019_bundle.sh' "$WALK"; arm "ttywalk sources the lib" $?
a="$(grep -n '^    STAGE_KIND="artefact"' "$WALK" | head -1 | cut -d: -f1)"
b="$(grep -n 'walk_export_cm019_bundle "\$_res"' "$WALK" | head -1 | cut -d: -f1)"
[ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] && [ $((b-a)) -lt 8 ]; arm "ttywalk calls it right after staging the mounted payload" $?
# Mutant: export removed.
M="$T/mut.sh"; sed 's/^        export OSTLER_CM019_BUNDLE$/        :/' "$LIB" > "$M"
cmp -s "$M" "$LIB" && { echo "CANNOT-RUN: mutant did not apply"; exit 2; }
r="$(run "$M" "$GOOD")"
[ "$(echo "$r" | sed -n 2p)" = "found $GOOD/cm019_preferences" ]; arm "MUST-FAIL: mutant (no export) is caught" $([ $? -eq 0 ] && echo 1 || echo 0)
echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
