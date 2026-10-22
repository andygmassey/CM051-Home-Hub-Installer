#!/usr/bin/env bash
#
# tests/test_derived_prefs_probe_is_run_by_the_walk.sh
#
# smart-prefs walk probe: derived_preferences_reach_digest_and_tool. This drives
# the REAL run_box_walk.sh (--only, --read-only, OSTLER_BOX_HOST unset = this
# machine, a scratch HOME) against a fake Hub, so the probe is shown to be
# COLLECTED AND INVOKED by the runner and to grade three box states:
#
#   S1  the Hub has no derived route (404)            -> runner FAIL (route)
#   S2  the route serves, the digest names none       -> runner FAIL (digest)
#   S3  the route serves, the digest names a label    -> no FAIL: the digest
#       arm is ok, the chat arm CANNOT-RUN (no assistant here), never a pass
#   S4  the runner lists the probe (it is in the glob)
#
# On main's harness the probe does not exist: --only matches no probe and the
# runner prints FATAL, so S1..S3 cannot even run (that is the red).
#
# Synthetic labels only. Runs under bash 3.2.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${REPO}/scripts/box_walk_probes/run_box_walk.sh"
PROBE=derived_preferences_reach
PY="$(command -v python3 || true)"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
[ -n "$PY" ] && [ -f "$RUNNER" ] || { echo "CANNOT-RUN: python3 or the runner is missing"; exit 2; }
echo "test_derived_prefs_probe_is_run_by_the_walk"

WORK="$(mktemp -d)"; HUBPID=""
trap '[ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null; rm -rf "$WORK"' EXIT
cat > "$WORK/hub.py" <<'PYEOF'
import http.server, json, sys
mode = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if mode == "absent":
            self.send_response(404); self.end_headers(); return
        body = json.dumps({"items": [{"dimension": "media.film.genre", "label": "science fiction",
                                      "strength": 0.7, "confidence": 0.8, "because": ["Synthetic Film"]}],
                           "degraded": False}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
H="$WORK/home"; mkdir -p "$H/.ostler/assistant-config/workspace" "$H/.ostler/secrets"
CTX="$H/.ostler/assistant-config/workspace/CONTEXT.md"

walk() {  # $1 = mode (absent|serves), $2 = digest text; sets OUT, RC
    [ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null
    local port=$((20000 + RANDOM % 20000))
    "$PY" "$WORK/hub.py" "$port" "$1" & HUBPID=$!
    sleep 1
    printf '## Preferences and things to keep in mind\n%s\n' "$2" > "$CTX"
    OUT="$(HOME="$H" OSTLER_HUB_URL="http://127.0.0.1:${port}" OSTLER_DERIVED_WAIT_S=0 \
        OSTLER_BOX_HOST= bash "$RUNNER" --only "$PROBE" --read-only 2>&1)"; RC=$?
}
line() { /usr/bin/grep -E "$1" <<< "$OUT" | head -1; }

if /usr/bin/grep -q "derived_preferences_reach_digest_and_tool" <<< "$(bash "$RUNNER" --list 2>&1)"; then
    ok "S4: the runner lists the probe (the probes/ glob collects it)"
else
    bad "S4: the runner does not list derived_preferences_reach_digest_and_tool"
fi
if /usr/bin/grep -q "FATAL: --only item \"${PROBE}\" matches no probe" <<< "$(bash "$RUNNER" --only "$PROBE" --read-only 2>&1)"; then
    bad "S0: --only ${PROBE} matches no probe (the probe is not in the runner's glob)"
    echo "  $pass passed, $fail failed"; exit 1
fi

walk absent "- likes jazz"
if /usr/bin/grep -qE '^ +FAIL +route:' <<< "$OUT" && [ "$RC" -ne 0 ]; then ok "S1: no derived route -> the runner reports FAIL (route), rc=${RC}"; else bad "S1: absent route did not FAIL the route arm (rc=${RC}): $(line 'route:')"; fi

walk serves "- likes jazz"
if /usr/bin/grep -qE '^ +FAIL +digest:' <<< "$OUT" && /usr/bin/grep -qE '^ +ok +route:' <<< "$OUT"; then ok "S2: route serves but the digest names none -> FAIL (digest), route ok"; else bad "S2: expected FAIL digest + ok route: $(line 'digest:') / $(line 'route:')"; fi

walk serves "- loves science fiction films"
if /usr/bin/grep -qE '^ +ok +digest:' <<< "$OUT" && ! /usr/bin/grep -qE '^ +FAIL +(route|digest|tool):' <<< "$OUT" && /usr/bin/grep -qE '^ +CANNOT +tool:' <<< "$OUT"; then
    ok "S3: the digest names a served label -> digest ok, tool CANNOT-RUN (no assistant), no FAIL"
else
    bad "S3: expected ok digest, CANNOT tool, no FAIL: $(line 'digest:') / $(line 'tool:')"
fi

echo "  $pass passed, $fail failed (real run_box_walk.sh, 4 states, fake Hub)"
[ "$fail" -eq 0 ]
