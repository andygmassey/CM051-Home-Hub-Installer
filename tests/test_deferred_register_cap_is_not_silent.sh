#!/usr/bin/env bash
# test_deferred_register_cap_is_not_silent.sh
#
# The deferred device-registration retry used to hit a licence cap, write
# `cap_reached <timestamp>` into ~/.ostler/state/registration_warning.txt,
# and exit 0. THAT FILE WAS READ BY NOTHING. The only other mention of it in
# the whole repo was a comment in FingerprintState.swift describing a Doctor
# banner that was never built. A customer at cap on the deferred path was
# told nothing, by anything, ever.
#
# This is a BEHAVIOURAL test, not a grep. It runs the real shipped script
# against a stub Worker that returns a real 409 with a real body, and asserts
# the script produces a record a reader can consume. A source grep would pass
# on a fix that never executes; this only passes if the 409 arm actually runs.
#
# ⚠️ FIXTURE HYGIENE (this repo has been bitten): the stub binds an EPHEMERAL
# port on loopback -- never a real service port -- and identifies itself in
# its own response body, so if it ever leaks into someone else's tcpdump it
# announces what it is instead of impersonating a service.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/deferred-register-device.sh"

rc=0
fail() { printf 'FAIL: %s\n' "$*" >&2; rc=1; }
pass() { printf 'ok: %s\n' "$*"; }

[ -r "${SCRIPT}" ] || { printf 'CANNOT-RUN: %s not readable\n' "${SCRIPT}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'CANNOT-RUN: no python3\n' >&2; exit 2; }

SANDBOX="$(mktemp -d -t ostler-defreg-test)"
PORT_FILE="${SANDBOX}/port"
SERVER_PID=""
cleanup() {
    [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null || true
    rm -rf "${SANDBOX}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Stub Worker: 409 + the body CM050's register-device.ts actually returns.
# Port 0 => the kernel picks a free ephemeral port, which it then writes out.
# ---------------------------------------------------------------------------
python3 - "${PORT_FILE}" <<'PYEOF' &
import http.server, json, socketserver, sys, threading

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        body = json.dumps({
            "error": "device limit reached",
            "max_hardware_fingerprints": 2,
            "registered_count": 2,
            "_fixture": "CM051 test_deferred_register_cap_is_not_silent stub, not a real service",
        }).encode()
        self.send_response(409)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
    with open(sys.argv[1], "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()
PYEOF
SERVER_PID=$!

# Wait for the port file rather than sleeping blind.
for _ in $(seq 1 50); do
    [ -s "${PORT_FILE}" ] && break
    sleep 0.1
done
if [ ! -s "${PORT_FILE}" ]; then
    printf 'CANNOT-RUN: stub server never reported a port\n' >&2
    exit 2
fi
PORT="$(cat "${PORT_FILE}")"

# ---------------------------------------------------------------------------
# POSITIVE CONTROL: prove the stub really answers 409 before we believe
# anything about the script's behaviour against it. Without this, a dead stub
# would drive the script down its "000 transport failed" arm and the absence
# of a cap record would look like a code defect rather than a dead fixture.
# ---------------------------------------------------------------------------
CTRL=$(/usr/bin/curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST -H 'Content-Type: application/json' -d '{}' \
    "http://127.0.0.1:${PORT}/register-device" || echo "000")
if [ "${CTRL}" != "409" ]; then
    printf 'CANNOT-RUN: control failed -- stub returned %s, not 409. A missing\n' "${CTRL}" >&2
    printf '            cap record below would be a dead fixture, not a defect.\n' >&2
    exit 2
fi
pass "control: stub Worker answers 409 on 127.0.0.1:${PORT} (ephemeral, self-identifying)"

# ---------------------------------------------------------------------------
# Run the REAL script against it, in a sandboxed OSTLER_DIR.
# ---------------------------------------------------------------------------
export OSTLER_DIR="${SANDBOX}/.ostler"
export OSTLER_REGISTER_ENDPOINT="http://127.0.0.1:${PORT}/register-device"
mkdir -p "${OSTLER_DIR}/state"
cat > "${OSTLER_DIR}/state/pending_registration.json" <<'JSON'
{"license_id": "TEST-FIXTURE-NOT-A-REAL-LICENCE", "fingerprint": "sha256:0000000000000000000000000000000000000000000000000000000000000000", "queued_at": "2026-09-02T00:00:00Z"}
JSON

set +e
bash "${SCRIPT}"
SCRIPT_RC=$?
set -e

[ "${SCRIPT_RC}" -eq 0 ] \
    && pass "script exits 0 on a cap (launchd must not retry a hopeless case)" \
    || fail "script exited ${SCRIPT_RC} on the 409 arm; expected 0"

# ---------------------------------------------------------------------------
# THE SUBJECT: a cap must produce a record a reader can consume.
# ---------------------------------------------------------------------------
JSON_OUT="${OSTLER_DIR}/state/registration_warning.json"
if [ ! -f "${JSON_OUT}" ]; then
    fail "NO structured record at state/registration_warning.json. This is the \
original defect: the cap was recorded only in a plain-text file nothing read."
else
    pass "structured record written"
    python3 - "${JSON_OUT}" <<'PYEOF' || fail "structured record is wrong (see above)"
import json, sys
d = json.load(open(sys.argv[1]))
errs = []
if d.get("state") != "cap_reached":
    errs.append(f'state={d.get("state")!r}, expected "cap_reached"')
# The counts must come FROM THE RESPONSE BODY, not be hardcoded. The stub
# returns 2/2; -1 would mean the parse silently failed and the record would
# tell the customer nothing about their own licence.
if d.get("max_hardware_fingerprints") != 2:
    errs.append(f'max={d.get("max_hardware_fingerprints")!r}, expected 2 from the 409 body')
if d.get("registered_count") != 2:
    errs.append(f'count={d.get("registered_count")!r}, expected 2 from the 409 body')
if not str(d.get("customer_message", "")).strip():
    errs.append("customer_message is empty -- a record with no sentence in it is not a surface")
if errs:
    for e in errs:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print("ok: record says cap_reached, carries 2/2 parsed from the 409 body, and has a customer sentence")
PYEOF
fi

# The legacy file must SURVIVE. Something may still read it, and silently
# dropping it while adding the JSON would be a second silent regression.
[ -f "${OSTLER_DIR}/state/registration_warning.txt" ] \
    && pass "legacy registration_warning.txt still written (no silent drop)" \
    || fail "legacy registration_warning.txt is gone -- adding the JSON must not remove it"

# The queue must be cleared, or launchd re-hammers a hopeless endpoint hourly.
[ ! -f "${OSTLER_DIR}/state/pending_registration.json" ] \
    && pass "pending queue cleared" \
    || fail "pending_registration.json survived a 409; launchd will retry forever"

# A cap is NOT a success: the fingerprint cache must not be written, or the
# Hub would believe this Mac is registered when the server refused it.
[ ! -f "${OSTLER_DIR}/state/fingerprint.txt" ] \
    && pass "fingerprint cache NOT written on a cap (a refusal is not a registration)" \
    || fail "fingerprint.txt written on a 409 -- the Hub now believes a refused Mac is registered"

exit "${rc}"
