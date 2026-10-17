#!/usr/bin/env bash
# RED TEAM DMG #27 F3-1 (walk #27 item 6b): install.sh bootstrapped Homebrew
# from a MOVING branch (brew tarball/main) and piped install.sh at HEAD
# straight into bash, with no checksum. Asserts:
#   1. no Homebrew fetch targets a moving ref, and nothing is piped into bash
#   2. both pins exist: a brew release tag + sha256, an installer commit + sha256
#   3. the REAL verifier (_ostler_fetch_verified, carved out of install.sh)
#      accepts the right sha256 and refuses, and deletes, a wrong one
#   4. ONLINE=1 only: the pinned URLs really hash to the pinned values
# Runs under bash 3.2.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
echo "test_homebrew_bootstrap_is_pinned"
CODE="$(/usr/bin/sed -e 's/^[[:space:]]*#.*$//' "$INSTALL")"

# Here-strings, not `printf | grep -q`: under pipefail an early-exiting grep -q
# SIGPIPEs the printf and the pipeline reads as "no match".
if grep -qE 'Homebrew/brew/tarball/(main|master)|Homebrew/install/(HEAD|master|main)/' <<<"$CODE"; then
    bad "a Homebrew fetch still targets a moving branch: $(printf '%s\n' "$CODE" | grep -nE 'Homebrew/brew/tarball/|Homebrew/install/(HEAD|master|main)/' | head -2)"
else ok "no Homebrew fetch targets a moving branch"; fi
if grep -qE 'curl[^|]*Homebrew[^|]*\|[[:space:]]*(/bin/)?(ba)?sh|bash -c "\$\(curl[^)]*Homebrew' <<<"$CODE"; then
    bad "a Homebrew download is still run straight from curl"
else ok "no Homebrew download is run straight from curl"; fi

PINS="$(awk '/# OSTLER_BREW_PINS_BEGIN/{f=1;next} /# OSTLER_BREW_PINS_END/{f=0} f' "$INSTALL")"
eval "$(printf '%s\n' "$PINS" | sed 's/^[[:space:]]*//')" 2>/dev/null || true
[[ "${OSTLER_BREW_TAG:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "brew is pinned to release tag ${OSTLER_BREW_TAG}" || bad "no brew release tag pin"
[[ "${OSTLER_BREW_TARBALL_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] && ok "the brew tarball carries a sha256" || bad "no brew tarball sha256"
[[ "${OSTLER_BREW_INSTALLER_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] && ok "the official installer is pinned to a commit" || bad "no installer commit pin"
[[ "${OSTLER_BREW_INSTALLER_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] && ok "the official installer carries a sha256" || bad "no installer sha256"

FN="$(awk '/^    _ostler_fetch_verified\(\) \{/{f=1} f{print} f&&/^    \}$/{exit}' "$INSTALL")"
if [ -z "$FN" ]; then
    bad "no _ostler_fetch_verified in install.sh"
else
    WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
    printf 'synthetic payload\n' > "$WORK/src"
    good="$(/usr/bin/shasum -a 256 "$WORK/src" | awk '{print $1}')"
    run() { BREW_INSTALL_LOG="$WORK/log" /bin/bash -c "$FN"'
        _ostler_fetch_verified "$1" "$2" "$3"' _ "file://$WORK/src" "$1" "$WORK/out"; }
    run "$good"; rc=$?
    [ $rc -eq 0 ] && [ -f "$WORK/out" ] && ok "the verifier accepts the right sha256" || bad "the verifier refused the right sha256 (rc=$rc)"
    rm -f "$WORK/out"
    wrong="$(printf "a%.0s" $(seq 1 64))"   # composed, not a literal
    run "$wrong"; rc=$?
    [ $rc -ne 0 ] && [ ! -e "$WORK/out" ] && ok "the verifier refuses a wrong sha256 and deletes the download" || bad "a wrong sha256 was accepted or left on disk (rc=$rc)"
fi

if [ "${ONLINE:-0}" = "1" ]; then
    T="$(mktemp -d)"
    h1="$(curl -fsSL --max-time 60 "https://github.com/Homebrew/brew/archive/refs/tags/${OSTLER_BREW_TAG}.tar.gz" | /usr/bin/shasum -a 256 | awk '{print $1}')"
    h2="$(curl -fsSL --max-time 60 "https://raw.githubusercontent.com/Homebrew/install/${OSTLER_BREW_INSTALLER_COMMIT}/install.sh" | /usr/bin/shasum -a 256 | awk '{print $1}')"
    [ "$h1" = "$OSTLER_BREW_TARBALL_SHA256" ] && ok "ONLINE: the pinned brew tarball hashes to its pin" || bad "ONLINE: brew tarball hashes to $h1"
    [ "$h2" = "$OSTLER_BREW_INSTALLER_SHA256" ] && ok "ONLINE: the pinned installer hashes to its pin" || bad "ONLINE: installer hashes to $h2"
    rm -rf "$T"
fi
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
