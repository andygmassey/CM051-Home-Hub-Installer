#!/usr/bin/env bash
# RED TEAM DMG #27 F3-2 (walk #27 item 6a): install.sh staged its pre-FDA tree
# at /tmp/ostler-prelaunch-$$, predictable and in a world-writable directory,
# and `mkdir -p` + `chmod 700` followed whatever another account had put there.
# This carves the REAL staging and check blocks out of install.sh and runs them
# in a sandbox HOME (a dry run of exactly those lines):
#   1. the staging dir is under $HOME/.ostler, mode 0700, owned by this user,
#      unpredictable (two runs differ), and keeps "ostler-prelaunch" in its name
#   2. a staging path that is a symlink is refused
#   3. a ~/.ostler that is a symlink is refused
# Runs under bash 3.2.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
echo "test_prelaunch_staging_is_owner_only"
STAGE="$(awk '/^# OSTLER_PRELAUNCH_STAGING_BEGIN$/{f=1;next} /^# OSTLER_PRELAUNCH_STAGING_END$/{f=0} f' "$INSTALL")"
CHECK="$(awk '/^# OSTLER_PRELAUNCH_CHECK_BEGIN$/{f=1;next} /^# OSTLER_PRELAUNCH_CHECK_END$/{f=0} f' "$INSTALL")"
if [ -z "$STAGE" ] || [ -z "$CHECK" ]; then
    bad "install.sh has no private staging block (still the predictable $(grep -o '/tmp/ostler-prelaunch-\$\$' "$INSTALL" | head -1) path)"
    echo "  $pass passed, $fail failed"; exit 1
fi
WORK="$(mktemp -d)"; trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

run() {  # $1 = HOME, $2 = preset OSTLER_PRELAUNCH_DIR or empty -> prints the dir or REFUSED
    HOME="$1" OSTLER_PRELAUNCH_DIR="$2" /bin/bash -c '
        set -u
        fail_with_code() { echo "REFUSED $1"; exit 3; }
        OSTLER_FINAL_DIR="${HOME}/.ostler"
        '"$STAGE"'
        '"$CHECK"'
        echo "DIR=$OSTLER_PRELAUNCH_DIR"
    ' 2>&1
}

H="${WORK}/home1"; mkdir -p "$H"
o1="$(run "$H" "")"; d1="${o1#DIR=}"
o2="$(run "$H" "")"; d2="${o2#DIR=}"
case "$d1" in "$H/.ostler/"*) ok "staged under \$HOME/.ostler ($(basename "$d1"))" ;; *) bad "not under \$HOME/.ostler: $o1" ;; esac
case "$d1" in *ostler-prelaunch*) ok "the name keeps ostler-prelaunch for the frozen-path gates" ;; *) bad "name lost ostler-prelaunch: $d1" ;; esac
[ "$(/usr/bin/stat -f '%Lp' "$d1" 2>/dev/null)" = "700" ] && ok "mode 0700" || bad "mode is $(/usr/bin/stat -f '%Lp' "$d1" 2>/dev/null)"
[ "$(/usr/bin/stat -f '%Lp' "$H/.ostler" 2>/dev/null)" = "700" ] && ok "~/.ostler is 0700" || bad "~/.ostler mode $(/usr/bin/stat -f '%Lp' "$H/.ostler")"
[ -O "$d1" ] && ok "owned by this user" || bad "not owned by this user"
[ -n "$d2" ] && [ "$d1" != "$d2" ] && ok "unpredictable: two runs get different directories" || bad "two runs got the same directory: $d1"

# 2. a pre-planted symlink at the staging path is refused
mkdir -p "${WORK}/elsewhere"; ln -s "${WORK}/elsewhere" "${WORK}/planted"
o3="$(run "$H" "${WORK}/planted")"
case "$o3" in REFUSED*) ok "a staging path that is a symlink is refused" ;; *) bad "symlinked staging path accepted: $o3" ;; esac
[ "$(/usr/bin/stat -f '%Lp' "${WORK}/elsewhere")" != "700" ] || bad "the link target was chmod'ed through the symlink"

# 3. ~/.ostler itself a symlink is refused
H2="${WORK}/home2"; mkdir -p "$H2" "${WORK}/attacker"; ln -s "${WORK}/attacker" "$H2/.ostler"
o4="$(run "$H2" "")"
case "$o4" in REFUSED*) ok "a ~/.ostler that is a symlink is refused" ;; *) bad "symlinked ~/.ostler accepted: $o4" ;; esac
[ -z "$(ls -A "${WORK}/attacker")" ] && ok "nothing was staged into the link target" || bad "staged into the link target"

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
