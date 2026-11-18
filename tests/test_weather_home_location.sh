#!/usr/bin/env bash
# lib/ostler-weather-home.sh: city from timezone -> [weather] home_location.
# Real TOML parser (tomllib) on the emitted table; mutant must go RED.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="${WEATHER_LIB:-$ROOT/lib/ostler-weather-home.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ck() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: got [$2] want [$3]"; fails=$((fails+1)); fi; }
# shellcheck disable=SC1090
source "$LIB"

ck tz-hong-kong "$(ostler_weather_city_from_tz Asia/Hong_Kong)" "Hong Kong"
ck tz-london    "$(ostler_weather_city_from_tz Europe/London)" "London"
ck tz-3part     "$(ostler_weather_city_from_tz America/Argentina/Buenos_Aires)" "Buenos Aires"
ck tz-utc       "$(ostler_weather_city_from_tz UTC)" ""
ck tz-etc       "$(ostler_weather_city_from_tz Etc/GMT+5)" ""
ck tz-garbage   "$(ostler_weather_city_from_tz 'Foo/Ba;r')" ""

# Via the /etc/localtime symlink form
ln -s /var/db/timezone/zoneinfo/Europe/London "$T/lt"
ck symlink "$(OSTLER_LOCALTIME_PATH="$T/lt" ostler_weather_city_from_tz)" "London"
ck no-symlink "$(OSTLER_LOCALTIME_PATH="$T/missing" ostler_weather_city_from_tz)" ""

# Existing customer value wins and survives; derived only when absent
printf '[weather]\nhome_location = "Lisbon"\n[x]\nhome_location = "no"\n' > "$T/c.toml"
ck keep-existing "$(OSTLER_LOCALTIME_PATH="$T/lt" ostler_weather_home_resolve "$T/c.toml")" "Lisbon"
ck derive-when-absent "$(OSTLER_LOCALTIME_PATH="$T/lt" ostler_weather_home_resolve "$T/none.toml")" "London"

# Emit + real parser
{ printf '[gateway]\nport = 8000\n\n'; ostler_weather_emit_block "Hong Kong"; printf '[web_search]\nprovider = "vane"\n'; } > "$T/o.toml"
got="$(python3 -c 'import tomllib,sys; print(tomllib.load(open(sys.argv[1],"rb"))["weather"]["home_location"])' "$T/o.toml" 2>&1)"
ck toml-parses "$got" "Hong Kong"
ck emit-empty-omits "$(ostler_weather_emit_block "")" ""

# Wired into install.sh (source, resolve before truncation, emit)
for s in 'source "${SCRIPT_DIR}/lib/ostler-weather-home.sh"' 'ostler_weather_home_resolve "$ASSISTANT_CONFIG"' 'ostler_weather_emit_block "$_OSTLER_WEATHER_HOME"'; do
  n="$(grep -cF -- "$s" "$ROOT/install.sh")"; ck "wired:$s" "$n" "1"
done
r="$(grep -nF 'ostler_weather_home_resolve "$ASSISTANT_CONFIG"' "$ROOT/install.sh" | cut -d: -f1)"
w="$(grep -n '^} > "\$ASSISTANT_CONFIG"' "$ROOT/install.sh" | head -1 | cut -d: -f1)"
[[ "$r" -lt "$w" ]] && ck resolve-before-truncate ok ok || ck resolve-before-truncate "$r>=$w" ok

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
