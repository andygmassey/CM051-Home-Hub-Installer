#!/usr/bin/env bash
# tests/test_the_converge_wait_resolves_the_credential_path.sh
# ============================================================================
# THE DEFECT, measured on the v1.0.79 walk. lib/converge_wait.sh built the store
# credential path as the literal
#
#     $HOME/.ostler/secrets/store-curl.conf          (backslash-dollar)
#
# and then interpolated it SINGLE-QUOTED into the command sent to the box:
#
#     -K '${conf}'
#
# Single quotes stop the remote shell expanding $HOME. curl received a path with
# a dollar sign in it, exited 26 BEFORE issuing any request, the python fallback
# read empty stdin and printed "x", and it did that for both stores on every
# reading. The walk logged 45 consecutive
#
#     [NNNNs] unreadable: x x (streak reset)
#
# one a minute, against two stores that were healthy the entire time. The wait
# had never read a store on ANY box, and the run ended with the two people
# probes CANNOT-RUN by the harness's own hand.
#
# WHY NO EXISTING ARM CAUGHT IT. The 21 arms in
# test_the_walk_waits_for_converge.sh all STUB _cw_read_pair, because they are
# about the stability logic. Not one of them executes the quoting, so the seam
# between this file and the shell on the other side of _cw_box_exec was never
# crossed by any test. A suite can be complete about a decision and blind to the
# command that feeds it.
#
# WHAT THIS ASSERTS, end to end rather than textually: point _cw_box_exec at a
# local /bin/sh, put a real credential file at the real expanded path, stand up
# a store that RECORDS whether the request arrived, and require _cw_read_pair to
# come back with the two numbers. The must-fail arm restores the old
# single-quoted literal and requires "x x".
#
# HOME IS REDIRECTED INTO A TEMP DIR ON PURPOSE. The path under test is
# literally "$HOME/.ostler/secrets/store-curl.conf", and this machine has a real
# PWG store with a real credential at exactly that path. A test that wrote there
# to exercise an expansion would be a test that damages the thing it measures.
#
# NO PIPE INTO grep -q ANYWHERE: it SIGPIPEs the producer and under pipefail
# reports failure for a pattern it found. Counted form only.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/box_walk_probes/lib/converge_wait.sh"

PASS=0
FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$*" | sed 's/^/         /'; FAIL=$((FAIL + 1)); }

[ -r "$LIB" ] || { printf 'CANNOT-RUN: no converge_wait.sh at %s\n' "$LIB"; exit 78; }
command -v python3 >/dev/null 2>&1 || { printf 'CANNOT-RUN: no python3 for the store stub\n'; exit 78; }

WORK="$(mktemp -d)"
STUB_PID=""
cleanup() {
    # `kill` on a job of THIS shell makes bash print "Terminated: 15" to its own
    # stderr after the trap returns, which reads as a failure in CI output.
    # Disowning first removes the job-table entry that produces that line.
    if [ -n "$STUB_PID" ]; then
        disown "$STUB_PID" 2>/dev/null || true
        kill "$STUB_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

printf 'THE CONVERGE WAIT RESOLVES THE CREDENTIAL PATH\n\n'

# ---------------------------------------------------------------------------
# A store that RECORDS what reached it. Ephemeral loopback port, and it carries
# a nonce so a proxy or any other listener answering for 127.0.0.1 cannot be
# mistaken for it -- on this machine something really does answer on the store
# ports, which is exactly how a fake pass would be manufactured.
# ---------------------------------------------------------------------------
NONCE="cw$$_$(date +%s)"
cat > "$WORK/stub.py" <<'PY'
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
hits = os.environ["STUB_HITS"]; nonce = os.environ["STUB_NONCE"]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _emit(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _record(self):
        with open(hits, "a") as f:
            f.write("%s %s auth=%s\n" % (self.command, self.path,
                    self.headers.get("X-Test-Nonce", "NONE")))
    def do_GET(self):
        self._record()
        self._emit({"result": {"points_count": 4242}, "nonce": nonce})
    def do_POST(self):
        self._record()
        self._emit({"results": {"bindings": [{"n": {"value": "1717"}}]}, "nonce": nonce})
srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
STUB_HITS="$WORK/hits" STUB_NONCE="$NONCE" python3 "$WORK/stub.py" > "$WORK/port" 2>"$WORK/stub.err" &
STUB_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/port" ] && break; sleep 0.3; done
PORT="$(tr -d '\r\n' < "$WORK/port" 2>/dev/null)"
if [ -z "$PORT" ]; then
    bad "CANNOT-RUN: the store stub never reported a port" "$(cat "$WORK/stub.err" 2>/dev/null)"
    printf '\n== %s pass / %s fail ==\n' "$PASS" "$FAIL"; exit 78
fi
ok "store stub listening on 127.0.0.1:${PORT} (ephemeral, nonce ${NONCE})"

# ---------------------------------------------------------------------------
# A credential at the REAL expanded path, under a redirected HOME.
# ---------------------------------------------------------------------------
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.ostler/secrets"
printf 'header = "X-Test-Nonce: %s"\n' "$NONCE" > "$FAKE_HOME/.ostler/secrets/store-curl.conf"
ok "credential written at \$HOME/.ostler/secrets/store-curl.conf under a redirected HOME"

# ---------------------------------------------------------------------------
# THE SEAM. OSTLER_BOX_HOST unset, so _cw_box_exec runs /bin/sh -c locally --
# the same shell semantics as the remote side, which is where the quoting is
# decided. OSTLER_PROBE_STORE_CURL_CONF unset, so the DEFAULT carrying the
# literal $HOME is the thing under test.
# ---------------------------------------------------------------------------
run_reader() { # $1 = "" for shipped, or a sed script to mutate the lib first
    local mut="$1" lib="$LIB"
    if [ -n "$mut" ]; then
        lib="$WORK/mutant.sh"
        sed "$mut" "$LIB" > "$lib"
    fi
    (
        set +u
        unset OSTLER_BOX_HOST
        unset OSTLER_PROBE_STORE_CURL_CONF
        HOME="$FAKE_HOME"
        OSTLER_OXIGRAPH_URL="http://127.0.0.1:${PORT}/query"
        OSTLER_QDRANT_URL="http://127.0.0.1:${PORT}"
        export HOME OSTLER_OXIGRAPH_URL OSTLER_QDRANT_URL
        . "$lib"
        _cw_read_pair
    ) 2>/dev/null | tr -d '\r' | tail -1
}

: > "$WORK/hits"
out="$(run_reader "")"
[ "$(printf '%s\n' "$out" | grep -c 'x')" -eq 0 ] \
    && ok "the shipped reader returns two NUMBERS, not x: [${out}]" \
    || bad "the shipped reader still cannot read the stores: [${out}]"
[ "$(printf '%s\n' "$out" | grep -c '^1717 4242$')" -gt 0 ] \
    && ok "and they are the values the store actually served" \
    || bad "the numbers are not the store's" "$out"

# The request REACHED the store, and carried the header from the credential
# file. That is the proof curl opened the file rather than merely being handed
# a plausible-looking path.
[ "$(grep -c "auth=${NONCE}" "$WORK/hits" 2>/dev/null)" -ge 2 ] \
    && ok "both requests arrived carrying the header from the credential file, so -K opened it" \
    || bad "the store was not reached with the credential's header" "$(cat "$WORK/hits" 2>/dev/null)"

# ---------------------------------------------------------------------------
# The command that crosses the seam must contain NO literal dollar-HOME.
# ---------------------------------------------------------------------------
seen="$( set +u
    unset OSTLER_BOX_HOST OSTLER_PROBE_STORE_CURL_CONF
    HOME="$FAKE_HOME"; export HOME
    . "$LIB"
    # The stub must still PERFORM the resolve, or CONVERGE_CONF_PATH is set to
    # the stub's own canned reply and the assertion below inspects "-K '1 1'".
    # A stub that answers every call identically cannot measure a two-step
    # protocol; it has to keep the step it is not standing in for.
    # Leading "(" on each pattern is REQUIRED here, not style: this function is
    # defined inside $( ... ), and bash 3.2 lets a case pattern's unbalanced ")"
    # close the command substitution early, giving "unexpected EOF while looking
    # for matching quote" two hundred lines further down.
    _cw_box_exec() {
        case "$1" in
            (printf*) /bin/sh -c "$1" ;;
            (*) printf '%s' "$1" > "$WORK/cmd"; printf '1 1\n' ;;
        esac
    }
    _cw_read_pair >/dev/null 2>&1
    cat "$WORK/cmd" 2>/dev/null )"
if [ "$(printf '%s' "$seen" | grep -c '\$HOME')" -eq 0 ]; then
    ok "the command crossing the seam carries NO literal \$HOME"
else
    bad "the command still carries an unexpanded \$HOME, which is the whole defect" \
        "$(printf '%s' "$seen" | grep -o '\-K [^ ]*' | head -2)"
fi
[ "$(printf '%s' "$seen" | grep -c -- "-K '${FAKE_HOME}/.ostler/secrets/store-curl.conf'")" -gt 0 ] \
    && ok "it carries the RESOLVED path, quoted" \
    || bad "the resolved path is not what reaches the -K site" "$(printf '%s' "$seen" | grep -o "\-K '[^']*'" | head -2)"

# ---------------------------------------------------------------------------
# MUST-FAIL: restore the old quoting. The reader must go back to printing x x.
# Without this the arms above would pass against a reader that had been correct
# all along, and would prove nothing about the fix.
# ---------------------------------------------------------------------------
MUT='s|^    local conf="$CONVERGE_CONF_PATH"$|    local conf="${OSTLER_PROBE_STORE_CURL_CONF:-\\$HOME/.ostler/secrets/store-curl.conf}"|'
sed "$MUT" "$LIB" > "$WORK/check_mutant.sh"
if [ "$(grep -c 'local conf="\$CONVERGE_CONF_PATH"' "$WORK/check_mutant.sh")" -gt 0 ]; then
    bad "the mutation did not land; the must-fail arm below would prove nothing"
else
    ok "the mutation landed (the reader uses the raw literal again)"
    : > "$WORK/hits"
    out_m="$(run_reader "$MUT")"
    if [ "$(printf '%s\n' "$out_m" | grep -c '^x x$')" -gt 0 ]; then
        ok "MUST-FAIL: with the old quoting the reader prints [x x], which is the v1.0.79 walk exactly"
    else
        bad "MUST-FAIL: the old quoting still read the stores; the arms above prove nothing" "$out_m"
    fi
    [ "$(grep -c . "$WORK/hits" 2>/dev/null)" -eq 0 ] \
        && ok "and NOTHING reached the store, so curl exited before issuing a request" \
        || bad "the old quoting still reached the store" "$(cat "$WORK/hits")"
fi

# ---------------------------------------------------------------------------
# THE DIAGNOSTIC HALF, DRIVEN RATHER THAN GREPPED.
#
# The first version of this suite asserted that the LIB CONTAINS the strings
# "CONVERGE_ERR_FILE" and "credential curl was given". Both were true, and the
# cause line still never printed, because the fix had removed only the OUTER
# 2>/dev/null and curl's own stderr was still going to /dev/null on the box.
# Archie caught it by reading the reader. A grep for the mechanism is not a
# test of the mechanism, which is the same mistake in a different costume as
# the bug this PR fixes.
#
# So: run the real converge_wait against a credential path that does not
# exist, and require the PRINTED line to carry curl's own words and the path.
# ---------------------------------------------------------------------------
ABSENT="$WORK/no-such-credential.conf"
[ -e "$ABSENT" ] && rm -f "$ABSENT"
diag="$( set +u
    unset OSTLER_BOX_HOST
    OSTLER_PROBE_STORE_CURL_CONF="$ABSENT"
    OSTLER_OXIGRAPH_URL="http://127.0.0.1:${PORT}/query"
    OSTLER_QDRANT_URL="http://127.0.0.1:${PORT}"
    OSTLER_CONVERGE_WAIT_S=1
    OSTLER_STABILITY_INTERVAL_S=0
    OSTLER_STABILITY_READS=2
    export OSTLER_PROBE_STORE_CURL_CONF OSTLER_OXIGRAPH_URL OSTLER_QDRANT_URL \
           OSTLER_CONVERGE_WAIT_S OSTLER_STABILITY_INTERVAL_S OSTLER_STABILITY_READS
    . "$LIB"
    converge_wait 2>&1 )"

[ "$(printf '%s\n' "$diag" | grep -c 'unreadable: x x')" -gt 0 ] \
    && ok "a missing credential still produces the x x reading (the symptom is reproduced)" \
    || bad "the failing case did not produce x x, so the arms below measure the wrong thing" "$diag"

# curl's OWN words. Not a string this test supplies: measured on this machine,
# `-K` on a missing file exits 26 and prints "curl: option -K: error
# encountered when reading a file". The assertion keys on the "curl:" prefix
# rather than the sentence, so a curl that words it differently still passes
# while a SILENT curl still fails.
if [ "$(printf '%s\n' "$diag" | grep -c '^ *cause: .*curl:')" -gt 0 ]; then
    ok "and the printed line carries CURL'S OWN cause: $(printf '%s\n' "$diag" | grep '^ *cause:' | head -1 | sed 's/^ *//')"
else
    bad "no cause line carrying curl's own text; the diagnostic half of this fix does not work" \
        "$(printf '%s\n' "$diag" | grep -A2 'unreadable' | head -4)"
fi

[ "$(printf '%s\n' "$diag" | grep -c "credential curl was given: ${ABSENT}")" -gt 0 ] \
    && ok "and it names the exact credential path curl was given" \
    || bad "the printed path is not the one curl was handed" "$(printf '%s\n' "$diag" | grep 'credential curl was given' | head -1)"

# MUST-FAIL on the diagnostic itself: put the inner curl redirects back and the
# cause line must go silent. Without this, the arm above could pass on a build
# where curl happened to print somewhere else.
# Gag curl again by appending the redirect to both curl target lines.
awk '{ if ($0 ~ /\047\$\{oxi\}\047 \\$/ || $0 ~ /collections\/\$\{coll\}\047 \\$/) { sub(/ \\$/, " 2>/dev/null \\") } print }' "$LIB" > "$WORK/gagged.sh"
if [ "$(grep -c "2>/dev/null" "$WORK/gagged.sh")" -le "$(grep -c "2>/dev/null" "$LIB")" ]; then
    bad "the gag mutation did not land; the diagnostic arm above is unproven" \
        "shipped has $(grep -c '2>/dev/null' "$LIB"), mutant has $(grep -c '2>/dev/null' "$WORK/gagged.sh")"
else
    ok "the gag mutation landed (curl's stderr sent back to /dev/null)"
    diag_m="$( set +u
        unset OSTLER_BOX_HOST
        OSTLER_PROBE_STORE_CURL_CONF="$ABSENT"
        OSTLER_OXIGRAPH_URL="http://127.0.0.1:${PORT}/query"
        OSTLER_QDRANT_URL="http://127.0.0.1:${PORT}"
        OSTLER_CONVERGE_WAIT_S=1
        OSTLER_STABILITY_INTERVAL_S=0
        OSTLER_STABILITY_READS=2
        export OSTLER_PROBE_STORE_CURL_CONF OSTLER_OXIGRAPH_URL OSTLER_QDRANT_URL \
               OSTLER_CONVERGE_WAIT_S OSTLER_STABILITY_INTERVAL_S OSTLER_STABILITY_READS
        . "$WORK/gagged.sh"
        converge_wait 2>&1 )"
    if [ "$(printf '%s\n' "$diag_m" | grep -c '^ *cause: .*curl:')" -eq 0 ]; then
        ok "MUST-FAIL: gagged, the cause line vanishes, which is v1.0.79's 45 silent readings exactly"
    else
        bad "MUST-FAIL: the cause still printed with curl gagged; the arm above proves nothing" "$diag_m"
    fi
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
