#!/usr/bin/env bash
# The Doctor's credential routes must refuse a browser driving them from
# another site, AND must still answer the callers that legitimately have no
# credential at all.
#
# WHAT THIS IS ABOUT.
#
# vendor/doctor/agent/web_ui.py registers 34 routes, contains zero uses of
# FastAPI's Depends(, and mounts exactly one middleware: CORS with
# allow_origins=["*"] and allow_credentials=False. Four of those routes vend
# or rotate a credential:
#
#   POST /api/v1/auth/chat-token   mints a ZeroClaw device bearer
#   GET  /api/v1/extension/token   returns the browser-extension ingest key
#   GET  /api/v1/pair/status       returns the pairing envelope (the QR
#                                  payload IS the pairing token)
#   POST /api/v1/pair/regenerate   rotates that pairing credential
#
# A bodyless POST with no custom header is a CORS "simple request", so before
# this gate ANY page the customer opened could call the mint and read the
# bearer straight out of the response. That is the hole.
#
# 🔴 THE REFUSAL IS NOT AUTHENTICATION AND THIS TEST DOES NOT CLAIM IT IS. A
# local process running as the customer sets whatever headers it likes and is
# not touched by any assertion here; neither is a non-browser tailnet peer.
# Both stay open deliberately, because the shipped CM031 Companion presents NO
# credential on the chat-token mint, so requiring one would break pairing to
# chat for every customer. See the block comment in web_ui.py.
#
# WHY THE SUCCESS CASES ARE HALF THE TEST. A test that only proves the refusal
# cannot tell "closed the hole" from "broke the feature". Every refusal below
# is paired with the same request in the legitimate caller's shape against the
# same running server, and that one must succeed.
#
# This boots the REAL app over REAL HTTP. It does not read the source for the
# word "refusal".

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="${REPO}/vendor/doctor/agent"
EDITOR_HOME="${REPO}/vendor/cm059_editor"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

echo "== Doctor credential routes refuse cross-site, and still serve the real callers =="

PY="${OSTLER_TEST_PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || {
    echo "  [CANNOT-RUN] no python3 on PATH. NOTHING was examined."; exit 2; }
if ! "$PY" -c 'import fastapi, uvicorn, httpx, qrcode' ; then
    echo "  [CANNOT-RUN] the Doctor's runtime deps (fastapi uvicorn httpx qrcode)"
    echo "               are not importable by ${PY}. NOTHING was examined."
    echo "               This is CANNOT-RUN, not a pass: install"
    echo "               vendor/doctor/agent/requirements.txt and re-run."
    exit 2
fi

TMP="$(mktemp -d)"
DOCTOR_PID=""; STUB_PID=""
cleanup() {
    [ -n "$DOCTOR_PID" ] && kill "$DOCTOR_PID" 2>/dev/null
    [ -n "$STUB_PID" ]   && kill "$STUB_PID"   2>/dev/null
    wait "$DOCTOR_PID" "$STUB_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

free_port() { "$PY" - <<'PYEOF'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PYEOF
}

DOCTOR_PORT_T="$(free_port)"
STUB_PORT="$(free_port)"

# ── A stand-in ZeroClaw gateway ──────────────────────────────────────
#
# The mint is a two-hop proxy (admin-authenticated /api/pairing/initiate, then
# public /api/pair). Standing in for it is what lets the SUCCESS case return a
# real 200 with a real token field, so "the legitimate caller still works" is
# measured rather than assumed. The token it returns is generated here and
# never leaves this box.
cat > "${TMP}/stub_gateway.py" <<'PYEOF'
import json
import secrets
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

CODE = secrets.token_hex(4)


class Handler(BaseHTTPRequestHandler):
    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path == "/api/pairing/initiate":
            if not self.headers.get("Authorization", "").startswith("Bearer "):
                self._json(401, {"error": "no admin token"})
                return
            self._json(200, {"pairing_code": CODE})
        elif self.path == "/api/pair":
            self._json(200, {"token": secrets.token_hex(16)})
        else:
            self._json(404, {"error": "no such stub route"})

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PYEOF

"$PY" "${TMP}/stub_gateway.py" "$STUB_PORT" > "${TMP}/stub.log" 2>&1 &
STUB_PID=$!

# A synthetic admin token, generated here, never printed. Its only job is to
# let read_admin_token() succeed so the mint reaches the gateway stub.
"$PY" -c 'import secrets,sys; open(sys.argv[1],"w").write(secrets.token_hex(16))' \
    "${TMP}/admin_token"
chmod 0600 "${TMP}/admin_token"

mkdir -p "${TMP}/editor"
# A local proxy will answer for EVERY host the Doctor dials, including
# 127.0.0.1, and then the mint fails for a reason that has nothing to do with
# this gate. Measured on this box: Privoxy returned an HTML error page for the
# loopback stub. curl below already passes --noproxy '*'; the SERVER needs the
# same treatment through its environment.
(
  cd "$AGENT" || exit 1
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
  no_proxy='*' NO_PROXY='*' \
  DOCTOR_PORT="$DOCTOR_PORT_T" \
  OSTLER_CHAT_GATEWAY_PORT="$STUB_PORT" \
  OSTLER_CHAT_ADMIN_TOKEN_FILE="${TMP}/admin_token" \
  OSTLER_EDITOR_HOME="$EDITOR_HOME" \
  OSTLER_EDITOR_DIR="${TMP}/editor" \
  OSTLER_EXTENSION_TOKEN="not-a-real-token-$$" \
  exec "$PY" web_ui.py
) > "${TMP}/doctor.log" 2>&1 &
DOCTOR_PID=$!

BASE="http://127.0.0.1:${DOCTOR_PORT_T}"
ready=0
for _ in $(seq 1 100); do
    if curl -s --noproxy '*' -o /dev/null -m 2 "${BASE}/doctor/api/health"; then
        ready=1; break
    fi
    "$PY" -c 'import time; time.sleep(0.3)'
done
if [ "$ready" -ne 1 ]; then
    echo "  [CANNOT-RUN] the Doctor did not come up on ${BASE}. NOTHING was examined."
    echo "  ---- doctor stderr ----"
    cat "${TMP}/doctor.log"
    exit 2
fi

# probe <name> <expected-status> <method> <path> [extra curl args...]
# Writes the body to $BODY so a caller can assert on it.
BODY=""
probe() {
    local name="$1" want="$2" method="$3" path="$4"; shift 4
    local out status
    out="$(curl -s --noproxy '*' -m 10 -X "$method" \
           -w '\n%{http_code}' "$@" "${BASE}${path}")"
    status="${out##*$'\n'}"
    BODY="${out%$'\n'*}"
    if [ "$status" = "$want" ]; then
        ok "${name}: HTTP ${status}"
    else
        # Capped. These bodies are config and pairing payloads read off
        # whichever box is running the gate, and this log is public.
        bad "${name}: expected HTTP ${want}, got ${status} -- body[0:160]: ${BODY:0:160}"
    fi
}

echo
echo "-- POST /api/v1/auth/chat-token (mints a device bearer) --"

probe "a page on another site is REFUSED" 403 POST /api/v1/auth/chat-token \
    -H 'Origin: https://evil.example' -H 'Sec-Fetch-Site: cross-site'
case "$BODY" in
    *refused*) ok "the refusal says so in the body" ;;
    *)         bad "the 403 body does not name the refusal: ${BODY}" ;;
esac
case "$BODY" in
    *token*) bad "🔴 the refusal body mentions a token" ;;
    *)       ok "the refusal hands back no token" ;;
esac

# The older-browser arm. No Sec-Fetch-Site at all, so only the Origin half of
# the predicate can catch this one. Without it the refusal above is a single
# point of failure that any pre-2020 browser walks straight past.
probe "an older browser with only an Origin is REFUSED" 403 POST \
    /api/v1/auth/chat-token -H 'Origin: https://evil.example'

# THE OTHER HALF. The shipped iOS Companion sends no Origin and no
# Sec-Fetch-Site (CM031 ChatTokenService.mint sets Accept and nothing else).
probe "the iOS Companion shape SUCCEEDS" 200 POST /api/v1/auth/chat-token \
    -H 'Accept: application/json'
case "$BODY" in
    *'"token"'*) ok "the mint returned a token to the legitimate caller" ;;
    *)           bad "no token field in the success body: ${BODY}" ;;
esac

probe "the Hub's own page SUCCEEDS" 200 POST /api/v1/auth/chat-token \
    -H "Origin: ${BASE}" -H 'Sec-Fetch-Site: same-origin'

echo
echo "-- GET /api/v1/extension/token (vends the browser-extension key) --"
probe "a page on another site is REFUSED" 403 GET /api/v1/extension/token \
    -H 'Sec-Fetch-Site: cross-site'
probe "the Hub's own extension-setup panel SUCCEEDS" 200 GET \
    /api/v1/extension/token -H 'Sec-Fetch-Site: same-origin'

echo
echo "-- GET /api/v1/pair/status (the QR payload IS the pairing token) --"
probe "a page on another site is REFUSED" 403 GET /api/v1/pair/status \
    -H 'Sec-Fetch-Site: cross-site'
probe "the Hub's own pair-ios panel SUCCEEDS" 200 GET /api/v1/pair/status \
    -H 'Sec-Fetch-Site: same-origin'

echo
echo "-- POST /api/v1/pair/regenerate (rotates the pairing credential) --"
probe "an older browser with only an Origin is REFUSED" 403 POST \
    /api/v1/pair/regenerate -H 'Origin: https://evil.example'
probe "the Hub's own pair-ios panel SUCCEEDS" 200 POST /api/v1/pair/regenerate \
    -H "Origin: ${BASE}" -H 'Sec-Fetch-Site: same-origin'

echo
echo "-- GET /api/v1/config (the customer's settings) --"
probe "a page on another site is REFUSED" 403 GET /api/v1/config \
    -H 'Sec-Fetch-Site: cross-site'
probe "the Hub's own config panel SUCCEEDS" 200 GET /api/v1/config \
    -H 'Sec-Fetch-Site: same-origin'

echo
echo "-- the control: a route that must NOT have grown a guard --"
#
# If the refusal had been mounted as middleware rather than on the named
# routes, EVERY route would refuse and every assertion above would still pass.
# This is the negative control that tells those two apart.
#
# The hydration passthrough is deliberately unauthenticated (#178: the wiki's
# first-run panel polls it with no bearer). Its exact status depends on
# whether the upstream ical-server is up, which this test does not control --
# so the assertion is on the PROPERTY, not on a number: it must not be a 403,
# and its body must not carry the refusal.
hyd="$(curl -s --noproxy '*' -m 10 -w '\n%{http_code}' \
       -H 'Sec-Fetch-Site: cross-site' "${BASE}/api/v1/hydration/status")"
hyd_status="${hyd##*$'\n'}"
hyd_body="${hyd%$'\n'*}"
if [ "$hyd_status" = "403" ]; then
    bad "the guard leaked onto /api/v1/hydration/status (HTTP 403) -- it has been mounted too widely"
else
    ok "/api/v1/hydration/status is untouched by the guard (HTTP ${hyd_status})"
fi
case "$hyd_body" in
    *"not available to another site"*)
        bad "the hydration passthrough carries the credential-route refusal" ;;
    *)  ok "the hydration passthrough body carries no refusal" ;;
esac

echo
echo "-- the box walk is a consumer: the four probes that curl :8089 --"
#
# freshness_panel_has_dates, people_count_agreement and pair_state_agreement
# are BLOCKING in scripts/walk_promote_scope.tsv; source_status_artefact_is_served
# is too. All four curl the Doctor with no Origin and no Sec-Fetch-Site, which
# is the non-browser shape the predicate lets through by construction. None of
# the four touches a guarded route, which is measured here rather than claimed:
#
#   pair_state_agreement            /doctor/api/health
#   people_count_agreement          /api/v1/hydration/status   (public path)
#   source_status_artefact_is_served /api/v1/sources
#   freshness_panel_has_dates       /openapi.json
#
# A probe that degrades to CANNOT-RUN is not a probe that passes, so this
# asserts each path answers as it did before, not merely that it is not a 403.
probe_walk_path() {
    local name="$1" path="$2"
    local out status
    out="$(curl -sS --noproxy '*' -m 10 -w '\n%{http_code}' "${BASE}${path}")"
    status="${out##*$'\n'}"
    if [ "$status" = "403" ]; then
        bad "${name}: the guard reached a walk probe path (${path} -> 403)"
    else
        ok "${name}: ${path} -> HTTP ${status}, unguarded"
    fi
}
probe_walk_path "pair_state_agreement (BLOCKING)"             /doctor/api/health
probe_walk_path "people_count_agreement (BLOCKING)"           /api/v1/hydration/status
probe_walk_path "source_status_artefact_is_served (BLOCKING)" /api/v1/sources
probe_walk_path "freshness_panel_has_dates (BLOCKING)"        /openapi.json

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "GREEN"
