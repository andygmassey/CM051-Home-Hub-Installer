#!/usr/bin/env bash
# lib/ostler-weather-home.sh
#
# Sourced by install.sh. Seeds `[weather] home_location` in the assistant
# config.toml so the daily brief's weather line (ostler-assistant #671) fires.
# Without the key the brief omits weather: the key defaults to None and the
# installer never wrote it.
#
# CITY LEVEL ONLY, from the Mac's timezone (/etc/localtime). Never GPS, never
# an IP lookup. wttr.in then sees "Hong Kong", the same egress the weather tool
# already documents (docs/EGRESS_INVENTORY.md). Table/key names and the value
# form are the ostler-assistant WeatherConfig (`[weather]`, `home_location`);
# validate_place_name accepts letters, space, comma, dot, apostrophe, hyphen,
# and the tool turns spaces into "+" for the wttr.in URL.
#
# Sourcing has no side effects. Every function prints nothing when it cannot
# answer, so a caller that omits the key leaves behaviour unchanged.

# ostler_weather_city_from_tz [tzname]
# Default tzname comes from the /etc/localtime symlink (override with
# OSTLER_LOCALTIME_PATH for tests). Area/City or Area/Region/City -> "City".
ostler_weather_city_from_tz() {
    local tz="${1:-}" target
    if [[ -z "$tz" ]]; then
        target="$(readlink "${OSTLER_LOCALTIME_PATH:-/etc/localtime}" 2>/dev/null)" || return 0
        tz="${target##*zoneinfo/}"
    fi
    case "$tz" in
        */*) ;;
        *) return 0 ;;                     # UTC, GMT, bare names
    esac
    case "$tz" in
        Etc/*|SystemV/*|posix/*|right/*|Antarctica/*) return 0 ;;
    esac
    local city="${tz##*/}"
    city="${city//_/ }"
    # Letters, space, hyphen, apostrophe only; anything else, say nothing.
    [[ "$city" =~ ^[A-Za-z][A-Za-z\ \'-]*$ ]] || return 0
    printf '%s\n' "$city"
}

# ostler_weather_existing_home <config.toml>
# Prints the value of an existing `home_location = "..."` under [weather].
# Call BEFORE the config is truncated for regeneration.
ostler_weather_existing_home() {
    local f="${1:-}"
    [[ -f "$f" ]] || return 0
    awk '
        /^\[/ { inw = ($0 ~ /^\[weather\][[:space:]]*$/); next }
        inw && /^[[:space:]]*home_location[[:space:]]*=/ {
            v = $0; sub(/^[^=]*=[[:space:]]*"/, "", v); sub(/"[[:space:]]*$/, "", v)
            print v; exit
        }' "$f" 2>/dev/null
}

# ostler_weather_home_resolve <config.toml>
# Existing customer value wins; else derive from the timezone; else nothing.
ostler_weather_home_resolve() {
    local v
    v="$(ostler_weather_existing_home "${1:-}")"
    [[ -n "$v" ]] || v="$(ostler_weather_city_from_tz)"
    [[ -n "$v" ]] && printf '%s\n' "$v"
    return 0
}

# ostler_weather_emit_block <place>
# Emits the TOML table, or nothing when <place> is empty.
ostler_weather_emit_block() {
    local p="${1:-}"
    [[ -n "$p" ]] || return 0
    p="${p//\\/\\\\}"; p="${p//\"/\\\"}"
    printf '[weather]\nhome_location = "%s"\n\n' "$p"
}
