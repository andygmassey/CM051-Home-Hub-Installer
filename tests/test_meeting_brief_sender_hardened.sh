#!/usr/bin/env bash
#
# tests/test_meeting_brief_sender_hardened.sh
#
# Behavioural test for the NO-MERGE hardened pre-meeting brief sender
# (scripts/ostler-meeting-brief-sender-hardened.sh). Unlike
# test_meeting_brief_sender.sh (which greps install.sh text), this
# actually RUNS the script against a stub hub + stub assistant and
# asserts the new reliability properties:
#
#   1. Loud-fail: a health JSON is written on EVERY run, recording
#      status / last_run / consecutive_failures, so a wedged trigger is
#      detectable rather than silent.
#   2. consecutive_failures increments across repeated hub outages and
#      resets to 0 on the next good poll.
#   3. Lead-time guarantee: the default look-ahead window is >= 30 min.
#   4. Quiet hours and idempotency still hold.
#
# Requires: bash, python3, sqlite3, curl. Uses a localhost stub server.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SENDER="${REPO_ROOT}/scripts/ostler-meeting-brief-sender-hardened.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "${SENDER}" ]] || fail "hardened sender not found at ${SENDER}"

if ! bash -n "${SENDER}"; then
    fail "hardened sender fails bash -n parse check"
fi
pass "hardened sender parses"

for bin in python3 sqlite3 curl; do
    command -v "${bin}" >/dev/null 2>&1 || { echo "SKIP: ${bin} unavailable"; exit 0; }
done

# ── Isolated workspace ───────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"; [[ -n "${HUB_PID:-}" ]] && kill "${HUB_PID}" 2>/dev/null || true' EXIT
export OSTLER_DIR="${WORK}/ostler"
HEALTH="${OSTLER_DIR}/state/meeting-brief-sender.health.json"

# Force out of quiet hours (07:00-21:00) regardless of wall clock.
export OSTLER_BRIEF_QUIET_START=23
export OSTLER_BRIEF_QUIET_END=0

_free_port() {
    python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0))
print(s.getsockname()[1]); s.close()
PY
}

# ── Stub hub + stub assistant on one port ────────────────────────────
# /api/v1/meeting/upcoming -> served from ${WORK}/hub_response.json
# /announce                -> 200 (records the call)
HUB_PORT="$(_free_port)"
export OSTLER_HUB_HOST="http://127.0.0.1:${HUB_PORT}"
export OSTLER_ASSISTANT_URL="http://127.0.0.1:${HUB_PORT}"
ANNOUNCE_LOG="${WORK}/announce.log"
: > "${ANNOUNCE_LOG}"

start_hub() {
    RESPONSE_FILE="${WORK}/hub_response.json" ANNOUNCE_LOG="${ANNOUNCE_LOG}" \
    python3 - "${HUB_PORT}" <<'PY' &
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

resp_file = os.environ["RESPONSE_FILE"]
announce_log = os.environ["ANNOUNCE_LOG"]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/api/v1/meeting/upcoming"):
            try:
                body = open(resp_file, "rb").read()
            except FileNotFoundError:
                body = b'{"meetings": []}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        if self.path == "/announce":
            n = int(self.headers.get("Content-Length", 0) or 0)
            self.rfile.read(n)
            with open(announce_log, "a") as fh:
                fh.write("announce\n")
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
        else:
            self.send_response(404); self.end_headers()

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
    HUB_PID=$!
    for _ in $(seq 1 50); do
        curl -sS -m 1 "${OSTLER_HUB_HOST}/api/v1/meeting/upcoming" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    fail "stub hub did not come up"
}

_health_field() {
    python3 - "${HEALTH}" "$1" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception:
    print("__MISSING__")
PY
}

# ── 1. Lead-time guarantee: default window >= 30 min ─────────────────
# Assert via the recorded within_minutes in the heartbeat after a run.
start_hub
echo '{"meetings": [], "degraded": false}' > "${WORK}/hub_response.json"
bash "${SENDER}" >/dev/null 2>&1 || fail "sender exited non-zero on empty window"
[[ -f "${HEALTH}" ]] || fail "no heartbeat written on a clean empty run"
WIN="$(_health_field within_minutes)"
[[ "${WIN}" -ge 30 ]] || fail "lead-time window ${WIN} < 30 min (no guarantee)"
pass "default look-ahead window is ${WIN} min (>= 30: lead-time guaranteed)"

ST="$(_health_field status)"
[[ "${ST}" == "ok" ]] || fail "empty-but-reachable run should be status=ok, got ${ST}"
pass "clean poll records status=ok with a heartbeat (not silent)"

# ── 2. Loud-fail on hub outage + consecutive_failures climbs ─────────
kill "${HUB_PID}" 2>/dev/null; wait "${HUB_PID}" 2>/dev/null; HUB_PID=""
bash "${SENDER}" >/dev/null 2>&1 || fail "sender should exit 0 even when hub is down"
ST="$(_health_field status)"
[[ "${ST}" == "error" ]] || fail "hub-down run should record status=error, got ${ST}"
F1="$(_health_field consecutive_failures)"
[[ "${F1}" == "1" ]] || fail "first outage should set consecutive_failures=1, got ${F1}"
pass "hub outage is LOUD: status=error, consecutive_failures=1 (not silent exit 0)"

bash "${SENDER}" >/dev/null 2>&1 || fail "sender should exit 0 on second outage"
F2="$(_health_field consecutive_failures)"
[[ "${F2}" == "2" ]] || fail "second outage should climb to 2, got ${F2}"
pass "repeated outage escalates consecutive_failures to ${F2}"

# ── 3. Recovery resets the failure streak ────────────────────────────
start_hub
echo '{"meetings": [], "degraded": false}' > "${WORK}/hub_response.json"
bash "${SENDER}" >/dev/null 2>&1 || fail "sender failed after hub recovery"
F3="$(_health_field consecutive_failures)"
[[ "${F3}" == "0" ]] || fail "a good poll should reset consecutive_failures to 0, got ${F3}"
pass "recovery resets consecutive_failures to 0"

# ── 4. Delivery + idempotency ────────────────────────────────────────
cat > "${WORK}/hub_response.json" <<'JSON'
{
  "degraded": false,
  "meetings": [
    {
      "meeting": "Discovery call",
      "start": "2026-06-21 10:30",
      "start_iso": "20260621T103000",
      "uid": "evt-1",
      "location": "",
      "maps_url": "",
      "attendees": [{"name": "Alice Tester", "email": "alice@example.com"}]
    }
  ]
}
JSON
: > "${ANNOUNCE_LOG}"
bash "${SENDER}" >/dev/null 2>&1 || fail "sender failed on a deliverable meeting"
SENT="$(grep -c announce "${ANNOUNCE_LOG}" || true)"
[[ "${SENT}" == "1" ]] || fail "expected exactly 1 announce, got ${SENT}"
BS="$(_health_field briefs_sent_this_run)"
[[ "${BS}" == "1" ]] || fail "heartbeat should record briefs_sent_this_run=1, got ${BS}"
pass "delivers a brief and records briefs_sent_this_run=1"

# Second run must NOT re-send (idempotency via sent_briefs.db).
bash "${SENDER}" >/dev/null 2>&1 || fail "sender failed on idempotent re-run"
SENT2="$(grep -c announce "${ANNOUNCE_LOG}" || true)"
[[ "${SENT2}" == "1" ]] || fail "idempotency broken: re-sent (total announces=${SENT2})"
pass "idempotent: a second run does not re-send the same brief"

# ── 5. Quiet hours still skips (and does not count as failure) ───────
OSTLER_BRIEF_QUIET_START=0 OSTLER_BRIEF_QUIET_END=23 \
    bash "${SENDER}" >/dev/null 2>&1 || fail "sender failed during quiet hours"
ST="$(_health_field status)"
[[ "${ST}" == "skip" ]] || fail "quiet hours should record status=skip, got ${ST}"
F="$(_health_field consecutive_failures)"
[[ "${F}" == "0" ]] || fail "quiet-hours skip must not count as a failure, got ${F}"
pass "quiet-hours run records status=skip and does not inflate failures"

echo ""
echo "All hardened meeting-brief-sender behavioural checks passed."
