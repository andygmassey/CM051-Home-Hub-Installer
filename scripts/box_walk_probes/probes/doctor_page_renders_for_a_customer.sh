#!/usr/bin/env bash
# probes/doctor_page_renders_for_a_customer.sh
# ============================================================================
# QUESTION: when a customer opens the Doctor, do they see a page -- or an error?
#
# THE DEFECT THIS EXISTS FOR. On v1.0.98, and for the two builds before it,
# GET /doctor returned HTTP 500 and 21 bytes of "Internal Server Error" on
# EVERY load. render_source_status() calls html.escape four times and
# web_ui.py never imported html, so the route raised NameError at
# web_ui.py:1336 and the whole dashboard died.
#
# NOTHING CAUGHT IT, AND HERE IS WHY: /api/v1/sources answered 200 the entire
# time. Every check we had asked the ENDPOINT whether the data existed. None
# asked the PAGE whether a person could read it. Andy walked three builds
# asking where the per-source ingest table was; the table was built, merged,
# delivered, and rendered onto a page that was dead.
#
# A NameError inside a route body is invisible to import, to syntax checks,
# and to any test that does not actually fetch the page. So this probe fetches
# the page.
#
# THE RULE THIS PROBE ENCODES: the subject of the assertion is the CUSTOMER
# and the thing they see. Not a file, not an endpoint behind the thing they
# see. If a future assertion here has a file as its subject, it is in the
# wrong probe.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="doctor_page_renders_for_a_customer"
PROBE_QUESTION="does GET /doctor return a page a customer can read, or an error?"

_DOCTOR_PORT="${DOCTOR_PORT:-8089}"
_DOCTOR_HOST="${OSTLER_PROBE_DOCTOR_HOST:-127.0.0.1}"

# No 2>/dev/null anywhere in here. A curl usage error must not be laundered
# into "the page is missing"; we want to see it.
_code() { curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time "${2:-12}" "$1"; }
_body() { curl -s --noproxy '*' --max-time "${2:-12}" "$1"; }

run_probe() {
    local base="http://${_DOCTOR_HOST}:${_DOCTOR_PORT}"

    # POSITIVE CONTROL FIRST, and it is deliberately a DIFFERENT surface from
    # the subject. If the Doctor is not serving at all, a 500 on /doctor would
    # be indistinguishable from a box that never came up, and reporting a
    # defect for an absent service is how a walk wastes a morning.
    local control; control="$(_code "${base}/api/v1/sources")"
    if [ "${control}" != "200" ]; then
        probe_examined 1 "control surface (/api/v1/sources) before judging the page"
        probe_cannot_run "the Doctor is not serving: /api/v1/sources answered ${control}, not 200. Nothing about the PAGE is measurable while the service is down."
    fi

    local code body bytes
    code="$(_code "${base}/doctor")"
    body="$(_body "${base}/doctor")"
    bytes="${#body}"

    if [ "${code}" != "200" ]; then
        probe_examined 1 "GET /doctor, with /api/v1/sources confirmed 200 in the same run"
        probe_fail "a customer opening the Doctor gets HTTP ${code} and ${bytes} bytes. The data endpoint behind it answers 200, so this is the PAGE failing, not the box."
    fi

    # 200 is not enough. The 500 had a body too. Require the thing the page
    # exists to show: the per-source table Andy has asked for across three
    # builds.
    if ! printf '%s' "${body}" | /usr/bin/grep -qi '<table'; then
        probe_examined 1 "GET /doctor body, ${bytes} bytes"
        probe_fail "the Doctor answers 200 but renders no table in ${bytes} bytes. The page loads and shows the customer nothing."
    fi

    probe_examined 1 "GET /doctor, fetched as a browser would, plus a control on a different surface"
    probe_pass "a customer opening the Doctor gets HTTP 200, ${bytes} bytes, containing a rendered table."
}

# ── SELF-TEST ───────────────────────────────────────────────────────────────
# A probe that cannot demonstrate a FAIL has not earned a PASS. Each arm points
# the probe at a server whose behaviour we CHOSE, and requires the verdict that
# behaviour deserves. The 500 arm reproduces the exact defect: a body, a 500,
# and a healthy control beside it.
self_test() {
    local fails=0 port rc out root
    root="$(mktemp -d)"

    # One server per arm, PID captured explicitly. `kill %1` and pkill
    # patterns were BOTH wrong here and left servers running: the subshell
    # job table is not the caller's, and the pattern matched nothing. A
    # self-test that cannot clean up hangs the walk it is meant to protect.
    _arm() { # $1=label $2=port $3=status $4=body $5=expected-exit
        local pid rc out
        python3 -c '
import sys, http.server
port, status, body = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/api/v1/sources"):
            payload, code = b"{\"sources\":[]}", 200
        elif self.path.startswith("/doctor"):
            payload, code = body.encode(), status
        else:
            payload, code = b"", 404
        self.send_response(code)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
' "$2" "$3" "$4" &
        pid=$!
        # Wait for it to answer rather than sleeping a guessed interval.
        local i=0
        while [ $i -lt 40 ]; do
            if curl -s -o /dev/null --noproxy '*' --max-time 1 "http://127.0.0.1:$2/api/v1/sources"; then break; fi
            i=$((i+1))
        done
        out="$(OSTLER_PROBE_DOCTOR_HOST=127.0.0.1 DOCTOR_PORT="$2" bash "$0")"; rc=$?
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        if [ "$rc" -ne "$5" ]; then
            printf '  ARM FAILED: %s expected exit %s, got %s\n%s\n' "$1" "$5" "$rc" "$out"
            fails=$((fails+1))
        else
            printf '  ok: %s -> exit %s\n' "$1" "$rc"
        fi
    }

    # 1. THE REAL DEFECT: 500 with a body, control healthy. Must FAIL.
    _arm "500 Internal Server Error (the v1.0.98 shape)" 18901 500 'Internal Server Error' "$PROBE_EX_FAIL"
    # 2. 200 but no table. Must FAIL: loading is not the same as showing.
    _arm "200 with no table" 18902 200 '<html><body><p>nothing here</p></body></html>' "$PROBE_EX_FAIL"
    # 3. 200 with a table. Must PASS.
    _arm "200 with a rendered table" 18903 200 '<html><body><table><tr><td>a source</td></tr></table></body></html>' 0

    rm -rf "${root}"
    if [ "$fails" -gt 0 ]; then
        probe_examined "$fails" "self-test arm(s) that did NOT behave as required"
        probe_pass "SELF-TEST BROKEN: ${fails} arm(s) failed, so this probe's real verdict must not be trusted."
    fi
    probe_examined 3 "self-test arms (500-with-body FAILs, 200-without-a-table FAILs, 200-with-a-table PASSes)"
    probe_fail "negative control behaved correctly on all 3 arms: the probe can distinguish a dead page from a bare page from a working one."
}

probe_main "$@"
