#!/usr/bin/env bash
# followup_keys_match_chat_threads: the probe can say PASS, FAIL and
# CANNOT-RUN, each for its own reason, and it is read-only.
#
# Hermetic: the "box" is this runner, the daemon is a loopback fake serving
# GET /api/status with a synthetic `followup` block, and the token is a
# synthetic file. No chat.db, no real identifiers.
#
# Arms:
#   1. the judge's own self-test lands every case on its own verdict
#   2. the probe's --self-test exits 1 with "negative control behaved"
#   3. a mutant judge (FAIL turned into PASS) makes the probe's self-test BROKEN
#   4. end to end through run_probe: PASS, FAIL, CANNOT-RUN (no FDA), CANNOT-RUN
#      (daemon predates the block), CANNOT-RUN (denominator 0)
#   5. it declares WALK_READ_ONLY and carries no writing shape
#
# EXIT 0 pass, 1 fail, 2 cannot-run. BASH 3.2.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="${ROOT}/scripts/box_walk_probes/probes/followup_keys_match_chat_threads.sh"
LIB="${ROOT}/scripts/box_walk_probes/lib/followup_keys_probe.py"
[ -f "$PROBE" ] && [ -f "$LIB" ] || { echo "CANNOT-RUN: probe or lib missing" >&2; exit 2; }
command -v python3 >/dev/null || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
W="$(mktemp -d)"; GW_PID=""
cleanup() { [ -n "$GW_PID" ] && { kill "$GW_PID" 2>/dev/null; wait "$GW_PID" 2>/dev/null; }; rm -rf "$W"; }
trap cleanup EXIT

echo "--- 1. judge self-test ---"
python3 "$LIB" --self-test >"$W/lib.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "judge self-test: every case on its own verdict ($(grep -c '^  ok' "$W/lib.out") cases)" \
    || { cat "$W/lib.out"; bad "judge self-test rc=$rc"; }

echo "--- 2. probe self-test goes red ---"
out="$(bash "$PROBE" --self-test 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'negative control behaved' <<< "$out"; then
    ok "probe --self-test exits 1 with 'negative control behaved'"
else printf '%s\n' "$out"; bad "probe --self-test rc=$rc"; fi

echo "--- 3. a mutant judge breaks the self-test ---"
M="$W/mut"; mkdir -p "$M/probes" "$M/lib"
cp "$PROBE" "$M/probes/"; cp "${ROOT}/scripts/box_walk_probes/lib/probe.sh" "$M/lib/"
python3 -c "import sys; s=sys.stdin.read(); a='rows match any chat.db thread'; i=s.index(a); j=s.index('return lines, EX_FAIL', i); sys.stdout.write(s[:j]+'return lines, EX_PASS'+s[j+len('return lines, EX_FAIL'):])" < "$LIB" > "$M/lib/followup_keys_probe.py"
if cmp -s "$LIB" "$M/lib/followup_keys_probe.py"; then bad "mutant did not apply"; else
    out="$(bash "$M/probes/followup_keys_match_chat_threads.sh" --self-test 2>&1)"; rc=$?
    if [ "$rc" -ne 1 ] || ! grep -q 'negative control behaved' <<< "$out"; then
        ok "with the display-name FAIL turned into PASS, the self-test no longer claims a behaved control (rc=$rc)"
    else bad "the self-test still reports a behaved control against a mutant judge"; fi
fi

echo "--- 4. end to end through run_probe against a loopback fake daemon ---"
mkdir -p "$W/secrets"; echo synthetic-token > "$W/secrets/zeroclaw_admin_token"
cat > "$W/gw.py" <<'PY'
import http.server, json, sys
state = {"body": {}}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/api/status" or self.headers.get("Authorization") != "Bearer synthetic-token":
            self.send_response(401); self.end_headers(); return
        b = open(sys.argv[2]).read().encode()
        self.send_response(200); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$W/gw.py" "$W/port" "$W/body.json" & GW_PID=$!
i=0; while [ ! -s "$W/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
[ -s "$W/port" ] || { echo "CANNOT-RUN: fake daemon did not start" >&2; exit 2; }
PORT="$(cat "$W/port")"
fu() { printf '{"followup": {"available": true, "measured": true, "enabled": true, "chat_db_readable": %s, "keyed_rows": %s, "keys_matching_one_to_one": %s, "keys_matching_group": %s, "completed_by_followup": 0, "reopened": 0}}\n' "$1" "$2" "$3" "$4"; }
arm() { # arm <label> <want rc> <want verdict word> <body>
    printf '%s\n' "$4" > "$W/body.json"
    out="$(unset OSTLER_BOX_HOST; OSTLER_PROBE_GATEWAY="http://127.0.0.1:${PORT}" OSTLER_SECRETS_DIR="$W/secrets" HOME="$W" bash "$PROBE" 2>&1)"; rc=$?
    if [ "$rc" -eq "$2" ] && grep -q "^VERDICT: $3 " <<< "$out"; then ok "$1 -> $3"
    else printf '%s\n' "$out"; bad "$1: rc=$rc, wanted $2 / $3"; fi
}
arm "1 of 4 rows matches a 1:1 chat" 0 PASS "$(fu true 4 1 0)"
arm "4 rows, none match (display-name keys)" 1 FAIL "$(fu true 4 0 0)"
arm "daemon cannot read chat.db" 78 CANNOT-RUN "$(fu false 4 0 0)"
arm "denominator 0" 78 CANNOT-RUN "$(fu true 0 0 0)"
arm "daemon predates the followup block" 78 CANNOT-RUN '{"reminders_list": {}}'
# The denominator is printed on a PASS.
printf '%s\n' "$(fu true 4 1 0)" > "$W/body.json"
out="$(unset OSTLER_BOX_HOST; OSTLER_PROBE_GATEWAY="http://127.0.0.1:${PORT}" OSTLER_SECRETS_DIR="$W/secrets" HOME="$W" bash "$PROBE" 2>&1)"
grep -q 'denominator: 4 pushed map row' <<< "$out" && ok "a PASS prints its denominator" || bad "no denominator on PASS"

echo "--- 5. read-only ---"
[ "$(grep -c '^# WALK_READ_ONLY:' "$PROBE")" -eq 1 ] && ok "declares WALK_READ_ONLY" || bad "no WALK_READ_ONLY marker"
SHAPES='launchctl[[:space:]]+(kickstart|bootstrap|bootout|load|unload)|-X[[:space:]]+(POST|PUT|PATCH|DELETE)|INSERT[[:space:]]+(DATA|INTO)|DELETE[[:space:]]+(WHERE|DATA|FROM)|sqlite3|osascript|imsg|send'
n="$(cat "$PROBE" "$LIB" | grep -v -E '^[[:space:]]*#' | grep -c -E "$SHAPES")"
[ "$n" -eq 0 ] && ok "no writing or sending shape in the probe or its reader" || bad "$n writing/sending shape(s) found"
# Control: the shape check sees a writer.
printf 'sqlite3 x "INSERT INTO t VALUES (1)"\n' | grep -c -E "$SHAPES" >/dev/null && ok "control: the shape check flags a writer" || bad "shape check is blind"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
