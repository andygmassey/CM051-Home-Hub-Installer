#!/usr/bin/env bash
# Pins: Homebrew's untrusted-tap warning block is dropped from the in-app log /
# support-email buffers (BrewTapWarningFilter) and never eats a real error.
# Controls: passthrough must RETAIN the block (else the fixture is not a block);
# the coordinator must call the filter (else it is unwired).
# EXIT 0 pass, 1 fail, 2 CANNOT-RUN. Tap name below is synthetic.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="${ROOT}/gui/OstlerInstaller/OutputLineBuffer.swift"
DRV="${ROOT}/tests/helpers/brew_tap_filter_driver.swift"
COORD="${ROOT}/gui/OstlerInstaller/InstallerCoordinator.swift"
FAIL=0
ok()  { printf '  [pass] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
command -v swiftc >/dev/null 2>&1 || { echo "CANNOT-RUN: swiftc missing" >&2; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/ostler-tapwarn.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
cp "$DRV" "$W/main.swift"
swiftc -O -swift-version 5 -o "$W/d" "$SRC" "$W/main.swift" >"$W/b.log" 2>&1 || { cat "$W/b.log" >&2; echo "CANNOT-RUN: compile failed" >&2; exit 2; }

BLOCK='Warning: The following taps are not trusted and their formulae will not be loaded:
  examplecorp/faketap

Run `brew tap-trust` to trust them. See https://docs.brew.sh/Tap-Trust for details.'
printf '%s\n' "==> Fetching downloads for: jq" "$BLOCK" "==> Pouring jq--1.7.arm64.bottle.tar.gz" > "$W/in1"
# Real error right after the warning, no Tap-Trust line: must survive.
printf '%s\n' "Warning: The following taps are not trusted and their formulae will not be loaded:" "  examplecorp/faketap" "Error: jq: no bottle available!" > "$W/in2"

p="$("$W/d" passthrough < "$W/in1")"
grep -qF "Tap-Trust" <<<"$p" && grep -qF "examplecorp/faketap" <<<"$p" && ok "control: passthrough keeps the block" || bad "control broken: fixture block not present in passthrough"

f="$("$W/d" filter < "$W/in1")"
if grep -qiF "not trusted" <<<"$f" || grep -qF "Tap-Trust" <<<"$f" || grep -qF "examplecorp/faketap" <<<"$f"; then bad "warning block leaked: $f"; else ok "block removed"; fi
grep -qF "==> Fetching downloads for: jq" <<<"$f" && grep -qF "==> Pouring" <<<"$f" && ok "surrounding lines kept" || bad "surrounding lines lost"

f2="$("$W/d" filter < "$W/in2")"
grep -qF "Error: jq: no bottle available!" <<<"$f2" && ok "real error after a truncated block is kept" || bad "real error was swallowed"

# Wiring: the coordinator's raw-log path must call the filter.
grep -q "brewTapFilter.keep(msg)" "$COORD" && ok "InstallerCoordinator calls the filter" || bad "UNWIRED: coordinator does not call BrewTapWarningFilter"
# Diagnostics file stays complete: install.sh must not strip it.
if grep -n "tap-trust\|taps are not trusted" "${ROOT}/install.sh" | grep -qi "grep -v\|sed"; then bad "install.sh strips the warning from the diagnostics log"; else ok "install.sh leaves the warning in install.log"; fi
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
