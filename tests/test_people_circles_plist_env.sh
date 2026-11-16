#!/bin/bash
# The assistant plist gets the non-secret inner-circle env, and no secret.
# Uses PlistBuddy on a temp plist (macOS). Fake token value; no real secret read.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$HERE/lib/ostler-people-circles-env.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAKE_TOKEN="tok-plist-probe-0123456789"
[[ -f "$LIB" ]] || { echo "FAIL: $LIB is missing"; exit 1; }
# shellcheck disable=SC1090
source "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }
PLIST="$T/assistant.plist"
cat > "$PLIST" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>probe</string><key>EnvironmentVariables</key><dict/></dict></plist>
XML
OD="$T/ostler"; PD="$T/import-pipeline"
mkdir -p "$OD/secrets"; printf '%s\n' "$FAKE_TOKEN" > "$OD/secrets/oxigraph_token"
fails=0
check() { if [[ "$2" == "0" ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
ostler_people_circles_env_apply "$PLIST" "$OD" "$PD" "http://localhost:7878" "u-probe" >"$T/out" 2>&1
check "apply returns 0 when every key reads back" "$?"
val() { /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:$1" "$PLIST" 2>/dev/null; }
[[ "$(val OSTLER_PYTHON)" == "$OD/services/cm048/.venv/bin/python3" ]]; check "OSTLER_PYTHON is the cm048 venv" "$?"
[[ "$(val OSTLER_OXIGRAPH_QUERY_URL)" == "http://localhost:7878/query" ]]; check "query URL" "$?"
[[ "$(val OSTLER_OXIGRAPH_UPDATE_URL)" == "http://localhost:7878/update" ]]; check "update URL" "$?"
[[ "$(val OSTLER_USER_ID)" == "u-probe" ]]; check "user id" "$?"
[[ "$(val OSTLER_CM041_RELATION_CONSUMER)" == "$PD/contact_syncer/relation_consumer.py" ]]; check "relation consumer path" "$?"
# the token is in a file the plist never references, and never in the plist
if grep -q "$FAKE_TOKEN" "$PLIST"; then check "no secret in the plist" 1; else check "no secret in the plist" 0; fi
if grep -q "$FAKE_TOKEN" "$T/out"; then check "no secret in the output" 1; else check "no secret in the output" 0; fi
# idempotent: a second apply with a new user id replaces the value
ostler_people_circles_env_apply "$PLIST" "$OD" "$PD" "http://localhost:7878" "u-two" >/dev/null 2>&1
[[ "$(val OSTLER_USER_ID)" == "u-two" ]]; check "re-apply replaces, not duplicates" "$?"
echo "people-circles plist env: $fails failure(s)"
exit $fails
