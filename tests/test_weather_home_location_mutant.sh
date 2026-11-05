#!/usr/bin/env bash
# Mutant control: a helper whose city lookup returns empty must turn
# test_weather_home_location.sh RED.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{ cat "$ROOT/lib/ostler-weather-home.sh"; echo 'ostler_weather_city_from_tz() { return 0; }'; } > "$T/mutant.sh"
if WEATHER_LIB="$T/mutant.sh" bash "$ROOT/tests/test_weather_home_location.sh" >"$T/out" 2>&1; then
  echo "FAIL: mutant passed"; exit 1
fi
echo "PASS: mutant went RED ($(grep -c '^FAIL' "$T/out") assertions failed)"
