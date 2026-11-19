#!/bin/sh
# scripts/box_walk_probes/probes/derived_themes_still_learning.sh
# ============================================================================
# READ-ONLY. GET /api/v1/preferences/derived must answer 200 with JSON and no
# error field, and EITHER serve items (PASS: the surface is live) OR, with no
# levelled records, answer items [] with a "Still learning" state (PASS).
#
# THE ROUTE IS ON :8090, NOT :8089 (CB135-PROBE-THEMES-WRONG-PORT). The route is
# owned by the assistant service (ical-server, ical-server.py handler, the
# preferences/derived branch). The Doctor on :8089 does not proxy it: the
# DOCTOR_PROXY_PATHS list in install.sh has no preferences/derived entry, so
# :8089 answers 404 by design. An earlier version of this probe read :8089 and
# so could never pass. The shared DOCTOR_URL in lib/walk134_common.sh is
# correct for the Doctor and is NOT changed; this probe has its own variable.
#
# Auth: the on-box service token is read ON THE BOX and passed to curl through
# a config on stdin, so it never appears in argv, in this file or in the output.
# The request declares X-Ostler-Destination: owner_own_brief (the owner's brief
# view), never owner_local.
#
# Defect it exists for: PWG #543, CB135-DERIVED-THEMES-EMPTY. The unit test
# tests/test_derived_still_learning_surface.py covers the server in isolation;
# this is the same answer read off the box.
# ============================================================================
set -u
. "$(dirname "$0")/../lib/probe.sh"
. "$(dirname "$0")/../lib/walk134_common.sh"

PROBE_NAME="derived_themes_still_learning"
PROBE_QUESTION="does GET /api/v1/preferences/derived answer 200 JSON with no error, serving items or a Still learning state?"
PROBE_UNIT="derived responses"

# The assistant service's port. Overridable for the self-test's fake servers only.
THEMES_URL="${OSTLER_THEMES_URL:-http://127.0.0.1:8090}"
THEMES_PATH="/api/v1/preferences/derived"

# The remote command. Single-quoted: nothing expands on this side, and the token
# is read on the box and piped into curl's config, never placed in argv.
themes_remote_cmd() {
    cat <<REMOTE
t="\$(cat "\$HOME/.ostler/secrets/service_token" 2>/dev/null)"
if [ -z "\$t" ]; then echo NO_SERVICE_TOKEN; exit 0; fi
{ printf 'header = "Authorization: Bearer %s"\\n' "\$t"
  printf 'header = "X-Ostler-Destination: owner_own_brief"\\n'; } \
  | curl -s -i --noproxy '*' --max-time 60 -K - '${THEMES_URL}${THEMES_PATH}'
REMOTE
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing inspected"
    _raw="$(mktemp)"
    box_run "$(themes_remote_cmd)" > "${_raw}"
    if [ ! -s "${_raw}" ]; then
        rm -f "${_raw}"
        probe_examined 0 "derived responses"
        probe_cannot_run "no answer from ${THEMES_URL}${THEMES_PATH} on the box: nothing measured"
    fi
    if grep -qx 'NO_SERVICE_TOKEN' "${_raw}"; then
        rm -f "${_raw}"
        probe_examined 0 "derived responses"
        probe_cannot_run "the on-box service token (~/.ostler/secrets/service_token) is absent or empty, so the owner's view cannot be requested. Nothing measured."
    fi
    walk134_judge_and_report themes "${_raw}"
}

# THE SELF-TEST. Canned answers through the judge, then the real curl path against
# local fake servers: one that answers like the Doctor (404 on this route), and
# one that answers like the owner's service in each state.
self_test() {
    walk134_self_judge_selftest
    _st_py="$(mktemp)"
    cat > "${_st_py}" <<'PYSRV'
import http.server, sys
MODE = sys.argv[2]
BODY = {
    "items": '{"items": [{"name": "x"}], "still_learning": null}',
    "still": '{"items": [], "still_learning": {"text": "Still learning"}}',
    "degraded": '{"items": [], "error": "store unreachable"}',
}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if MODE == "doctor404" or self.path.split("?")[0] != "/api/v1/preferences/derived":
            code, body = 404, "Not Found"
        elif MODE == "e500":
            code, body = 500, "{}"
        else:
            code, body = 200, BODY[MODE]
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYSRV
    _st_home="$(mktemp -d)"
    mkdir -p "${_st_home}/.ostler/secrets"
    printf 'fake-service-token-for-self-test\n' > "${_st_home}/.ostler/secrets/service_token"
    _st_port=18190
    _st_arm() {   # _st_arm <label> <mode> <expected rc> <must-say>
        python3 "${_st_py}" "${_st_port}" "$2" >/dev/null 2>&1 &
        _st_pid=$!
        _i=0; while [ $_i -lt 40 ]; do curl -s -o /dev/null -m 1 "http://127.0.0.1:${_st_port}/" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1 2>/dev/null || true; done
        out="$(export HOME="${_st_home}"; THEMES_URL="http://127.0.0.1:${_st_port}"; SELF_TEST_LOCAL=1; run_probe 2>&1)"; rc=$?
        kill "${_st_pid}" 2>/dev/null; wait "${_st_pid}" 2>/dev/null
        if [ "$rc" -ne "$3" ]; then _st_tick; printf '  SELF-TEST FAIL [%s]: expected exit %s, got %s\n' "$1" "$3" "$rc"; _st_fail=$((_st_fail+1))
        elif ! grep -qF -- "$4" <<< "$out"; then _st_tick; printf '  SELF-TEST FAIL [%s]: output never says "%s"\n' "$1" "$4"; _st_fail=$((_st_fail+1))
        else _st_tick; printf '  ok [%s] exit %s\n' "$1" "$rc"; fi
        _st_port=$((_st_port+1))
    }
    _st_n=0; _st_fail=0
    _st_tick() { _st_n=$((_st_n+1)); }
    # 1. the Doctor's answer on this route: 404 -> FAIL, named as the port/route problem
    _st_arm "404 from the Doctor-shaped server -> FAIL" doctor404 "$PROBE_EX_FAIL" "answered HTTP 404"
    # 2. degraded: 200 with an error field -> FAIL
    _st_arm "degraded (error field) -> FAIL" degraded "$PROBE_EX_FAIL" "error field"
    # 3. a 500 -> FAIL
    _st_arm "HTTP 500 -> FAIL" e500 "$PROBE_EX_FAIL" "not 200"
    # 4. still learning -> PASS
    _st_arm "still_learning state -> PASS" still "$PROBE_EX_PASS" "Still learning"
    # 5. served items -> PASS, not CANNOT-RUN
    _st_arm "served items -> PASS" items "$PROBE_EX_PASS" "serves 1 derived items"
    # 6. no service token on the box -> CANNOT-RUN, named, nothing requested
    rm -f "${_st_home}/.ostler/secrets/service_token"
    _st_port=18200
    out="$(export HOME="${_st_home}"; THEMES_URL="http://127.0.0.1:1"; SELF_TEST_LOCAL=1; run_probe 2>&1)"; rc=$?
    if [ "$rc" -eq "$PROBE_EX_CANNOT_RUN" ] && grep -qF "service token" <<< "$out"; then _st_tick; printf '  ok [no service token -> CANNOT-RUN, named] exit %s\n' "$rc"
    else _st_tick; printf '  SELF-TEST FAIL [no service token -> CANNOT-RUN]: rc=%s\n' "$rc"; _st_fail=$((_st_fail+1)); fi
    # 7. THE MUTANT: the probe pointed back at the Doctor's port. The 404 is the proof
    #    the route is not there, so the probe must refuse to pass it.
    printf 'fake-service-token-for-self-test\n' > "${_st_home}/.ostler/secrets/service_token"
    _st_arm "MUTANT: pointed back at the Doctor-shaped server -> FAIL, not PASS" doctor404 "$PROBE_EX_FAIL" "answered HTTP 404"
    rm -f "$_st_py"; rm -rf "$_st_home"
    probe_examined "$_st_n" "fake-server and judge cases, counted at runtime (the probe's own self-test)"
    if [ "$_st_fail" -ne 0 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT BEHAVE: ${_st_fail} of ${_st_n} self-test arms returned the wrong outcome"
    fi
    probe_fail "negative control behaved correctly on all ${_st_n} arms: a 404 from the Doctor-shaped port is a FAIL, a degraded or 500 answer is a FAIL, still_learning and served items are PASS, and a missing token is CANNOT-RUN"
}

probe_main "$@"
