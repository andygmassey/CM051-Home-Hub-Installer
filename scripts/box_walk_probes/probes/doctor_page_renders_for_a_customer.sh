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
#
# ---------------------------------------------------------------------------
# THE SECOND DEFECT, 2026-09-23, AND IT COST TWO WALKS OF COVERAGE.
#
# This probe reported CANNOT-RUN on the v1.0.100 and v1.0.101 walks with:
#
#     the Doctor is not serving: /api/v1/sources answered 000, not 200
#
# Both times that sentence was FALSE. The Doctor was up and answering on the
# box. Two facts settle it, taken from the walk box itself:
#
#   * ~/.ostler/logs/doctor.log carries
#         GET /api/v1/sources HTTP/1.1" 200 OK
#     written INSIDE the probe window, under a startup line reading
#         Uvicorn running on http://127.0.0.1:8089
#   * source_status_artefact_is_served -- a probe that GETs THE SAME URL on the
#     same box in the same walk -- PASSED in the walk that recorded this one as
#     not measured. It reaches the box through box_run. This one did not.
#
# TWO SEPARATE THINGS WERE WRONG.
#
# 1. THE TRANSPORT. run_box_walk.sh executes each probe LOCALLY, on the machine
#    driving the walk, and hands it OSTLER_BOX_HOST. Reaching the box is the
#    PROBE's job, through box_run / box_run_v in lib/probe.sh. 28 of the 29
#    probes did that. This one ran bare curl against 127.0.0.1:8089, which is
#    the DRIVER's loopback, where nothing listens. The 000 was the driver
#    refusing its own connection.
#
#    Pointing it at the box's LAN address would NOT have fixed it. The Doctor
#    binds 127.0.0.1 on the box on purpose -- it is the single auth boundary,
#    and off-box reachability is a thing the product refuses. The request has
#    to be ISSUED ON the box. That is what box_run_v does.
#
# 2. THE REASON, WHICH IS THE WORSE HALF. CANNOT-RUN was the right outcome
#    word. The reason attached to it asserted a CAUSE the probe had no
#    instrument to see. "000" is not a status a server sent; it is curl saying
#    it never got one. Refused, timed out, proxied, sent to the wrong machine
#    and never-issued all print 000, and only one of those is "the Doctor is
#    not serving". A probe that cannot tell "the server refused" from "I could
#    not reach the server" must say WHICH IT CANNOT TELL, not pick one.
#
#    So every verdict below names the machine the request was issued from, and
#    a transport failure is reported as a transport failure with curl's own
#    exit code, explicitly disclaiming any verdict about the service.
# ============================================================================
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="doctor_page_renders_for_a_customer"
PROBE_QUESTION="does GET /doctor return a page a customer can read, or an error?"

_DOCTOR_PORT="${DOCTOR_PORT:-8089}"
# 127.0.0.1 is correct AND is the whole trap: it is only the right answer when
# the request is issued ON the box. See _issued_from, which puts that fact in
# every verdict this probe writes.
_DOCTOR_HOST="${OSTLER_PROBE_DOCTOR_HOST:-127.0.0.1}"

# WHERE THE REQUEST WAS ISSUED FROM. Named in every verdict, because the defect
# above was a confident sentence about the wrong machine and nothing in the
# output said which machine had been measured.
_issued_from() {
    if [ -n "${OSTLER_BOX_HOST:-}" ]; then
        printf 'the box %s, where curl ran over ssh' "${OSTLER_BOX_HOST}"
    else
        # Both readings are live: run_box_walk.sh supports being run ON the box
        # with no host set, and post_walk_qa.sh always sets one. Naming the
        # ambiguity is the point -- the two walks this probe lost were lost to
        # a verdict that quietly assumed the second reading was the first.
        printf 'THIS machine, because OSTLER_BOX_HOST is unset: that is the box when the suite is run on it, and the walk driver when it is not'
    fi
}

# curl's exit code is the only instrument that separates the causes 000 hides.
_curl_rc_meaning() {
    case "$1" in
        7)   printf 'curl exit 7, connection refused: nothing accepted a TCP connection on that port' ;;
        28)  printf 'curl exit 28, timed out: the connection or the response did not complete in the budget' ;;
        6)   printf 'curl exit 6, could not resolve host' ;;
        5)   printf 'curl exit 5, could not resolve proxy' ;;
        35)  printf 'curl exit 35, TLS handshake failed' ;;
        52)  printf 'curl exit 52, empty reply: a server accepted the connection and sent nothing' ;;
        56)  printf 'curl exit 56, failure receiving data' ;;
        255) printf 'exit 255, which is ssh failing rather than curl: the command may never have run on the box at all' ;;
        transport)
             printf 'the transport returned nothing parseable, so curl may never have been invoked' ;;
        *)   printf 'curl exit %s' "$1" ;;
    esac
}

# ONE remote call per read, returning BOTH the http_code and curl's exit code.
# The two together are the discriminator; either alone is ambiguous.
#
# box_run_v, not box_run: box_run sends the remote stderr to /dev/null, and
# this probe's whole job in the failure case is to explain why it saw nothing.
# That is also why there is no 2>/dev/null anywhere in this file.
_HTTP_CODE=""
_CURL_RC=""
_probe_http() {
    _ph_out="$(box_run_v "c=\$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time ${2:-12} '${1}'); r=\$?; printf '%s %s\n' \"\$c\" \"\$r\"" | tail -n 1)"
    case "${_ph_out}" in
        [0-9][0-9][0-9]\ [0-9]*)
            _HTTP_CODE="${_ph_out%% *}"
            _CURL_RC="${_ph_out##* }"
            ;;
        *)
            # Not the shape we asked for. Do NOT read it as a status.
            _HTTP_CODE="000"
            _CURL_RC="transport"
            ;;
    esac
}

_probe_body() {
    box_run_v "/usr/bin/curl -s --noproxy '*' --max-time ${2:-12} '${1}'"
}

run_probe() {
    local base issued
    base="http://${_DOCTOR_HOST}:${_DOCTOR_PORT}"
    issued="$(_issued_from)"

    # TRANSPORT BEFORE ANY VERDICT ABOUT THE SERVER. If the walk cannot reach
    # the box, nothing that follows is a statement about the Doctor.
    if ! box_reachable; then
        probe_examined 0 "HTTP surfaces: the ssh transport to ${OSTLER_BOX_HOST:-this machine} failed before any request was issued"
        probe_cannot_run "could not reach ${OSTLER_BOX_HOST:-this machine} over ssh, so no request was ever issued. This is a fact about the WALK CONNECTION and says nothing about whether the Doctor is up."
    fi

    # POSITIVE CONTROL FIRST, and it is deliberately a DIFFERENT surface from
    # the subject. If the Doctor is not serving at all, a 500 on /doctor would
    # be indistinguishable from a box that never came up, and reporting a
    # defect for an absent service is how a walk wastes a morning.
    _probe_http "${base}/api/v1/sources"

    if [ "${_CURL_RC}" != "0" ]; then
        probe_examined 1 "one request to ${base}/api/v1/sources, issued from ${issued}"
        probe_cannot_run "NO HTTP RESPONSE from ${base}/api/v1/sources, issued from ${issued}: $(_curl_rc_meaning "${_CURL_RC}"). The 000 is curl reporting that it never received a status line, NOT a status the server sent. This does not establish that the Doctor is down: refused, timed out, proxied and never-issued all look identical here. What is established is that this request did not reach an HTTP server."
    fi

    if [ "${_HTTP_CODE}" != "200" ]; then
        probe_examined 1 "one request to ${base}/api/v1/sources, issued from ${issued}"
        probe_cannot_run "a server ANSWERED on ${base}/api/v1/sources from ${issued} with HTTP ${_HTTP_CODE}, not 200. The service is listening and responding, so this is the control surface being unhealthy rather than an unreachable Doctor -- but with the control off 200, nothing about the PAGE is measurable."
    fi

    local code rc body bytes
    _probe_http "${base}/doctor"
    code="${_HTTP_CODE}"
    rc="${_CURL_RC}"
    body="$(_probe_body "${base}/doctor")"
    bytes="${#body}"

    if [ "${rc}" != "0" ]; then
        probe_examined 2 "two requests issued from ${issued}: /api/v1/sources answered 200, then GET /doctor"
        probe_cannot_run "/api/v1/sources answered 200 from ${issued}, so the Doctor IS serving, but GET /doctor produced no HTTP response at all: $(_curl_rc_meaning "${rc}"). A read that did not complete is not a verdict on the page."
    fi

    if [ "${code}" != "200" ]; then
        probe_examined 1 "GET /doctor from ${issued}, with /api/v1/sources confirmed 200 in the same run"
        probe_fail "a customer opening the Doctor gets HTTP ${code} and ${bytes} bytes. The data endpoint behind it answers 200 from ${issued}, so this is the PAGE failing, not the box."
    fi

    # 200 is not enough. The 500 had a body too. Require the thing the page
    # exists to show: the per-source table Andy has asked for across three
    # builds.
    if ! printf '%s' "${body}" | /usr/bin/grep -qi '<table'; then
        probe_examined 1 "GET /doctor body from ${issued}, ${bytes} bytes"
        probe_fail "the Doctor answers 200 but renders no table in ${bytes} bytes. The page loads and shows the customer nothing."
    fi

    probe_examined 1 "GET /doctor from ${issued}, fetched as a browser would, plus a control on a different surface"
    probe_pass "a customer opening the Doctor gets HTTP 200, ${bytes} bytes, containing a rendered table, measured from ${issued}."
}

# ── SELF-TEST ───────────────────────────────────────────────────────────────
# A probe that cannot demonstrate a FAIL has not earned a PASS. Each arm points
# the probe at a server whose behaviour we CHOSE, and requires the verdict that
# behaviour deserves. The 500 arm reproduces the exact defect: a body, a 500,
# and a healthy control beside it. Arm 4 reproduces the SECOND defect: nothing
# listening at all, where the probe must refuse WITHOUT inventing a cause.
#
# EVERY ARM FORCES OSTLER_BOX_HOST EMPTY, which is what makes box_run_v run the
# command here rather than over ssh. The fixture servers are local by
# construction, so local is the honest target for them -- and run_box_walk.sh
# invokes --self-test with OSTLER_BOX_HOST already set, so without this the
# arms would ssh to the walk box and measure ports nothing there has ever
# opened. That is the same class of mistake the arms exist to catch.
#
# WHAT THE SELF-TEST THEREFORE DOES NOT COVER, stated rather than implied: it
# does not exercise the ssh transport. tests/test_a_probe_must_measure_the_box_not_the_driver.sh
# covers that, with a stub ssh that records what crossed it.
self_test() {
    local fails=0 arms=0

    # One server per arm, PID captured explicitly. `kill %1` and pkill
    # patterns were BOTH wrong here and left servers running: the subshell
    # job table is not the caller's, and the pattern matched nothing. A
    # self-test that cannot clean up hangs the walk it is meant to protect.
    _arm() { # $1=label $2=port $3=sources-status or "none" $4=page-status
             # $5=page-body $6=expected-exit $7=required text $8=forbidden text
        local pid="" rc out i
        arms=$((arms+1))

        if [ "$3" = "none" ]; then
            # The arm IS the absence of a server, so prove the port is closed
            # before trusting the result. A stray listener would turn this arm
            # into a pass for entirely the wrong reason.
            # The curl here is deliberately bare and local: it is staging a
            # LOCAL fixture, not measuring the box.
            if curl -s -o /dev/null --noproxy '*' --max-time 1 "http://127.0.0.1:$2/api/v1/sources"; then
                printf '  ARM CANNOT BE CONSTRUCTED: %s -- something is already listening on 127.0.0.1:%s\n' "$1" "$2"
                fails=$((fails+1))
                return
            fi
        else
            python3 -c '
import sys, http.server
port, s_status, p_status, body = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/api/v1/sources"):
            payload, code = b"{\"sources\":[]}", s_status
        elif self.path.startswith("/doctor"):
            payload, code = body.encode(), p_status
        else:
            payload, code = b"", 404
        self.send_response(code)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
' "$2" "$3" "$4" "$5" &
            pid=$!
            # Wait for it to answer rather than sleeping a guessed interval.
            i=0
            while [ $i -lt 40 ]; do
                if curl -s -o /dev/null --noproxy '*' --max-time 1 "http://127.0.0.1:$2/api/v1/sources"; then break; fi
                i=$((i+1))
            done
        fi

        out="$(OSTLER_BOX_HOST= OSTLER_PROBE_DOCTOR_HOST=127.0.0.1 DOCTOR_PORT="$2" bash "$0" 2>&1)"; rc=$?
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi

        if [ "$rc" -ne "$6" ]; then
            printf '  ARM FAILED: %s expected exit %s, got %s\n%s\n' "$1" "$6" "$rc" "$out"
            fails=$((fails+1))
            return
        fi
        if [ -n "${7:-}" ]; then
            case "$out" in
                *"$7"*) : ;;
                *) printf '  ARM FAILED: %s produced the right exit code with the wrong reason. Required text absent: %s\n%s\n' "$1" "$7" "$out"
                   fails=$((fails+1)); return ;;
            esac
        fi
        if [ -n "${8:-}" ]; then
            case "$out" in
                *"$8"*) printf '  ARM FAILED: %s asserted a cause it cannot see. Forbidden text present: %s\n%s\n' "$1" "$8" "$out"
                        fails=$((fails+1)); return ;;
                *) : ;;
            esac
        fi
        printf '  ok: %s -> exit %s\n' "$1" "$rc"
    }

    # 1. THE REAL DEFECT: 500 with a body, control healthy. Must FAIL.
    _arm "500 Internal Server Error (the v1.0.98 shape)" 18901 200 500 'Internal Server Error' "$PROBE_EX_FAIL"
    # 2. 200 but no table. Must FAIL: loading is not the same as showing.
    _arm "200 with no table" 18902 200 200 '<html><body><p>nothing here</p></body></html>' "$PROBE_EX_FAIL"
    # 3. 200 with a table. Must PASS.
    _arm "200 with a rendered table" 18903 200 200 '<html><body><table><tr><td>a source</td></tr></table></body></html>' 0
    # 4. THE SECOND DEFECT (v1.0.100, v1.0.101): nothing listening. Must
    #    CANNOT-RUN, must say no response arrived, and must NOT claim to know
    #    that the service is down -- that is the sentence that was untrue twice.
    _arm "nothing listening at all (the v1.0.100 shape)" 18904 none 0 '' "$PROBE_EX_CANNOT_RUN" \
         'NO HTTP RESPONSE' 'the Doctor is not serving'
    # 5. The opposite confusion: a server that ANSWERS, with a status that is
    #    not 200. Must CANNOT-RUN, and must NOT be described as no response.
    _arm "the control surface answers 503 (a reply, not a refusal)" 18905 503 200 '<html><body><table></table></body></html>' "$PROBE_EX_CANNOT_RUN" \
         'a server ANSWERED' 'NO HTTP RESPONSE'

    if [ "$fails" -gt 0 ]; then
        probe_examined "$fails" "self-test arm(s) that did NOT behave as required, out of ${arms} run"
        probe_pass "SELF-TEST BROKEN: ${fails} of ${arms} arm(s) failed, so this probe's real verdict must not be trusted."
    fi
    # Counted as the arms ran, never typed: a literal here stays green when an
    # arm is deleted.
    probe_examined "$arms" "self-test arms (500-with-body FAILs, 200-without-a-table FAILs, 200-with-a-table PASSes, nothing-listening CANNOT-RUNs without naming a cause, 503-control CANNOT-RUNs as a reply)"
    probe_fail "negative control behaved correctly on all ${arms} arms: the probe can distinguish a dead page from a bare page from a working one, and an unreachable server from one that answered."
}

probe_main "$@"
