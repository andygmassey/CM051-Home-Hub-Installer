#!/bin/bash
# inner-circle: the non-secret environment the assistant daemon needs to reach
# the circle provider and the owner-correction writer (oa #708, CM048 #140,
# CM041 #270). Sourced by install.sh; defines functions only, no side effects.
#
# Secrets are NOT set here. The store bearer is read by the Python clients from
# the 0600 file install.sh seeds (~/.ostler/secrets/oxigraph_token), the same way
# the other store clients read it (CM051 #550). Nothing secret is written to the
# plist, to argv, or to a log.
#
# ostler_people_circles_env_apply <plist> <ostler_dir> <pipeline_dir> <oxigraph_url> <user_id>
#   Sets the keys in the plist's EnvironmentVariables with PlistBuddy (Set, else
#   Add). Returns 0 only when every key reads back with the value it was given.
#   Returns non-zero (and says which key) otherwise, so a caller can refuse to
#   bootstrap a daemon that would silently run without circles.
#
# ostler_people_circles_env_apply reads PLISTBUDDY (default /usr/libexec/PlistBuddy).

_ostler_pc_set() {  # <plist> <key> <value>
    local _pb="${PLISTBUDDY:-/usr/libexec/PlistBuddy}" _p="$1" _k="$2" _v="$3"
    "$_pb" -c "Print :EnvironmentVariables" "$_p" >/dev/null 2>&1 \
        || "$_pb" -c "Add :EnvironmentVariables dict" "$_p" >/dev/null 2>&1 || true
    if "$_pb" -c "Print :EnvironmentVariables:${_k}" "$_p" >/dev/null 2>&1; then
        "$_pb" -c "Set :EnvironmentVariables:${_k} ${_v}" "$_p" >/dev/null 2>&1 || return 1
    else
        "$_pb" -c "Add :EnvironmentVariables:${_k} string ${_v}" "$_p" >/dev/null 2>&1 || return 1
    fi
    local _back
    _back="$("$_pb" -c "Print :EnvironmentVariables:${_k}" "$_p" 2>/dev/null)" || return 1
    [[ "$_back" == "$_v" ]]
}

ostler_people_circles_env_apply() {
    local plist="$1" ostler_dir="$2" pipeline_dir="$3" oxigraph_url="$4" user_id="$5"
    [[ -f "$plist" ]] || { echo "people-circles: no plist at $plist" >&2; return 1; }
    local cm048="${ostler_dir}/services/cm048"
    local ok=0 pair key val
    # key=value pairs, one per line. Paths and URLs only.
    while IFS= read -r pair; do
        [[ -n "$pair" ]] || continue
        key="${pair%%=*}"; val="${pair#*=}"
        if ! _ostler_pc_set "$plist" "$key" "$val"; then
            echo "people-circles: could not set ${key} in $(basename "$plist")" >&2
            ok=1
        fi
    done <<PAIRS
OSTLER_PYTHON=${cm048}/.venv/bin/python3
OSTLER_INNER_CIRCLE_SCRIPT=${cm048}/src/inner_circle.py
OSTLER_INNER_CIRCLE_ADAPTER=${cm048}/src/inner_circle_signals.py
OSTLER_CM041_RELATION_CONSUMER=${pipeline_dir}/contact_syncer/relation_consumer.py
OSTLER_OXIGRAPH_QUERY_URL=${oxigraph_url}/query
OSTLER_OXIGRAPH_UPDATE_URL=${oxigraph_url}/update
OSTLER_USER_ID=${user_id}
PAIRS
    return $ok
}
