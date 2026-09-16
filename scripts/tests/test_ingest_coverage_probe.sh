#!/usr/bin/env bash
# test_ingest_coverage_probe.sh
# ============================================================================
# Proves the store-credential + transport-guard + three-part-401 adjudication
# added to ingest_coverage.sh. count_store used to query Qdrant BARE; on an
# enforce-ON box that 401s, and the probe read the 401 as UNAVAILABLE ->
# "not one of the stores answered", conflating a missing credential with a down
# store. Now count_store presents the install's -K config and returns AUTH /
# TRANSPORT sentinels that the aggregate verdict adjudicates:
#
#   401 WITH a credential presented   -> FAIL        (a key the store refuses is real)
#   401 with NO usable credential     -> CANNOT-RUN  (keyless, coverage not measured)
#   000 (no HTTP status at all)       -> CANNOT-RUN  (transport failure)
#
# Every arm asserts the VERDICT REASON, never the exit code alone. A #1284
# mutation arm proves the literal-$HOME -K path is caught. python3 fake Qdrant
# on loopback + a controlled -K config; no real store, no ssh; bash 3.2.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${HERE}/../box_walk_probes/probes/ingest_coverage.sh"
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t ingcov)"
MUT="$(dirname "$PROBE")/.mutant_ingest_$$.sh"
trap 'kill "${FAKE_PID:-}" 2>/dev/null; rm -rf "$WORK"; rm -f "$MUT"' EXIT

FAILURES=""
note() { printf '  %s\n' "$1"; }
fail() { FAILURES="${FAILURES} $1"; printf '  FAIL [%s]: %s\n' "$1" "$2"; }

FAKE_PY="${WORK}/fake_qdrant.py"
cat > "$FAKE_PY" <<'PY'
import http.server, os, sys
CODE = int(os.environ.get("FAKE_CODE", "401"))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(CODE)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":{"error":"Unauthorized"}}' if CODE == 401 else b'{"status":"ok","result":{"points_count":1}}')
srv = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
srv.serve_forever()
PY

start_fake() { FAKE_CODE="$2" python3 "$FAKE_PY" "$1" >/dev/null 2>&1 & FAKE_PID=$!
    local i=0; while [ $i -lt 50 ]; do curl -s -o /dev/null -m 1 "http://127.0.0.1:$1/" 2>/dev/null && return 0; i=$((i+1)); sleep 0.05 2>/dev/null || true; done; }
stop_fake() { kill "${FAKE_PID:-}" 2>/dev/null; FAKE_PID=""; }

OK_PORT=16333
CLOSED_PORT=16399

run_probe_capture() { # $1 qdrant url  $2 conf path  $3 auth|noauth  $4 probe
    local url="$1" confpath="$2" mode="$3" probe="${4:-$PROBE}" realconf
    realconf="$(HOME="$WORK" bash -lc "printf '%s' \"$confpath\"")"
    mkdir -p "$(dirname "$realconf")"
    case "$mode" in
        auth)       printf 'header = "Authorization: Bearer t"\n' > "$realconf" ;;
        unreadable) printf 'header = "Authorization: Bearer t"\n' > "$realconf"; chmod 000 "$realconf" ;;
        absent)     rm -f "$realconf" ;;
        *)          : > "$realconf" ;;
    esac
    HOME="$WORK" OSTLER_QDRANT_URL="$url" OSTLER_PROBE_STORE_CURL_CONF="$confpath" \
        OSTLER_INGEST_BASELINE="${WORK}/baseline.tsv" OSTLER_BOX_HOST="" bash "$probe" 2>&1
}
verdict_of() { printf '%s' "$1" | grep -oE 'VERDICT: (PASS|FAIL|CANNOT-RUN|BROKEN)' | head -1; }

printf 'test_ingest_coverage_probe\n'

start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}" "${WORK}/conf_auth" auth)"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: FAIL" ]; then fail arm1 "401+cred got '${V}', expected FAIL"
elif [ "$(printf '%s' "$OUT" | grep -cF 'store credential presented')" -eq 0 ]; then fail arm1-reason "FAIL but reason does not name the presented key"
else note "arm1 401+cred -> FAIL, reason names presented key ✅"; fi

start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}" "${WORK}/conf_noauth" noauth)"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm2 "401+nocred got '${V}', expected CANNOT-RUN"
elif [ "$(printf '%s' "$OUT" | grep -cF 'NO store credential')" -eq 0 ]; then fail arm2-reason "CANNOT-RUN but reason does not say credential absent"
else note "arm2 401+nocred -> CANNOT-RUN, keyless ✅"; fi

OUT="$(run_probe_capture "http://127.0.0.1:${CLOSED_PORT}" "${WORK}/conf_auth" auth)"
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm3 "000 got '${V}', expected CANNOT-RUN"
elif [ "$(printf '%s' "$OUT" | grep -cF 'no HTTP response')" -eq 0 ]; then fail arm3-reason "CANNOT-RUN but reason not a transport failure"
else note "arm3 000 transport -> CANNOT-RUN ✅"; fi

# #1284: literal-$HOME conf. Fixed probe expands it (STORE_CONF_PATH) -> presents key -> 401 -> FAIL.
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}" '$HOME/conf_home' auth)"; stop_fake
V="$(verdict_of "$OUT")"
[ "$V" = "VERDICT: FAIL" ] && note "arm4a fixed expands \$HOME conf -> FAIL ✅" || fail arm4a "fixed literal-\$HOME got '${V}', expected FAIL"
# mutant: -K on literal STORE_CURL_CONF -> curl rc=26 -> TRANSPORT -> CANNOT-RUN, never FAIL
sed "s/-K '\${STORE_CONF_PATH}'/-K '\${STORE_CURL_CONF}'/" "$PROBE" > "$MUT"
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}" '$HOME/conf_home' auth "$MUT")"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" = "VERDICT: FAIL" ]; then fail arm4b-mutant-FAIL "#1284 mutant produced FAIL -- literal-\$HOME -K not caught"
elif [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm4b "#1284 mutant got '${V}', expected CANNOT-RUN"
else note "arm4b #1284 mutant -> CANNOT-RUN (transport), not a false FAIL ✅"; fi


# ARM 5: ABSENT conf -> keyless -> CANNOT-RUN that NAMES absence, not "empty".
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}" "${WORK}/conf_absent" absent)"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm5-absent "got '${V}', expected CANNOT-RUN"
elif [ "$(printf '%s' "$OUT" | grep -cF 'does not exist')" -eq 0 ]; then fail arm5-absent-reason "absent conf reported as something other than absence -- residual-a collapse"
else note "arm5 absent conf -> CANNOT-RUN, reason names absence ✅"; fi

# ARM 6: POPULATED-but-UNREADABLE conf (0600 owner-only, wrong account) -> must
# read as a PERMISSION problem, never as "empty". This is the #549/#550 misread
# TNM named: a probe running as a second account gets denied on a file full of
# headers, and the walk record must not tell a tired human the credential is empty.
start_fake "$OK_PORT" 401
OUT="$(run_probe_capture "http://127.0.0.1:${OK_PORT}" "${WORK}/conf_noread" unreadable)"; stop_fake
V="$(verdict_of "$OUT")"
if [ "$V" != "VERDICT: CANNOT-RUN" ]; then fail arm6-unreadable "got '${V}', expected CANNOT-RUN"
elif [ "$(printf '%s' "$OUT" | grep -cF 'not readable')" -eq 0 ]; then fail arm6-unreadable-reason "populated unreadable conf reported as empty, not as denied -- the exact residual-a defect"
else note "arm6 unreadable populated conf -> CANNOT-RUN, reason names permission not emptiness ✅"; fi

# ============================================================================
# THE TOP-UP AGENT PARSER, DRIVEN ON REAL launchctl print TEXT (v1.0.82 walk,
# 2026-09-09). Until this section existed the self-test substituted the WHOLE
# health verdict (FAKE_topup_health) and returned before the awk, so no test
# had ever run the parser: this file read 0 for "last exit code" and 0 for
# "never exited". The walk then printed "top-up agent com.ostler.fda-rerun :
# DEAD:(never" about an agent whose launchctl print said runs = 0 and last
# exit code = (never exited), and convicted the box.
#
# Same shape as tests/test_an_absent_launchd_domain_is_not_a_service_that_is_down.sh:
# extract the reader by FUNCTION NAME (never a line number), drive it against
# fixture text, and pin a negative control to the pre-fix blob so the harness
# is shown to measure the change. Exit 2 (CANNOT-RUN) when a reader or the
# control blob cannot be read: scanning nothing is not a pass.
# ============================================================================
printf '\nparser arms: topup_health_from_print on the four launchctl print forms\n'

# The four forms as launchctl print renders them (tab-indented, one body).
# No "path = " line: the parser never reads it, and a home-directory-shaped
# literal trips the operator-PII shape scan.
_lc_body() { # $1 = the value after "last exit code = "   $2 = runs
    printf 'gui/502/com.ostler.fda-rerun = {\n\tactive count = 0\n\ttype = LaunchAgent\n\tstate = not running\n\n\tprogram = /bin/bash\n\n\truns = %s\n\tlast exit code = %s\n\n\trun interval = 3600 seconds\n}\n' "$2" "$1"
}
LC_NEVER="$(_lc_body '(never exited)' 0)"
LC_ZERO="$(_lc_body '0' 3)"
LC_ONE="$(_lc_body '1' 3)"
LC_EX_CONFIG="$(_lc_body '78: EX_CONFIG' 3)"

# Extract one function from a tree, pinned to its name.
_extract_fn() { # $1 tree  $2 function name
    awk -v fn="$2" '
        $0 ~ ("^" fn "\\(\\) \\{") { f = 1 }
        f { print }
        f && /^\}$/ { exit }
    ' "$1"
}

# Drive the NEW parser (pure: text in, state out) from a tree. Prints the state.
_drive_parser() { # $1 tree  $2 launchctl text
    local fn r="${WORK}/parser"
    rm -rf "$r"; mkdir -p "$r"
    fn="$(_extract_fn "$1" topup_health_from_print)"
    [ -n "$fn" ] || { printf 'NOFN'; return; }
    printf '%s' "$2" > "$r/fixture"
    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' "$fn"
        printf '%s\n' 'topup_health_from_print "$(cat "$1")"'
    } > "$r/run.sh"
    bash "$r/run.sh" "$r/fixture" 2>/dev/null
}

# Drive the OLD reader (topup_agent_health, which read the box itself) from a
# tree, with box_run stubbed so the launchctl text is presented deterministically.
_drive_old() { # $1 tree  $2 launchctl text
    local fn r="${WORK}/old"
    rm -rf "$r"; mkdir -p "$r"
    fn="$(_extract_fn "$1" topup_agent_health)"
    [ -n "$fn" ] || { printf 'NOFN'; return; }
    printf '%s' "$2" > "$r/fixture"
    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' 'TOPUP_AGENT=com.ostler.fda-rerun'
        printf '%s\n' 'box_run() { case "$1" in "id -u") printf "502\n" ;; *launchctl*) cat "$FIXTURE" ;; *) : ;; esac; }'
        printf '%s\n' "$fn"
        printf '%s\n' 'topup_agent_health'
    } > "$r/run.sh"
    FIXTURE="$r/fixture" SELF_TEST_LOCAL=0 bash "$r/run.sh" 2>/dev/null
}

# ── subject: this tree ──
S="$(_drive_parser "$PROBE" "$LC_NEVER")"
case "$S" in
    NOFN) echo "CANNOT-RUN: topup_health_from_print was not found in ${PROBE}." >&2; exit 2 ;;
    NEVER-RAN:runs=0) note "parser: (never exited) + runs = 0 -> ${S} ✅" ;;
    DEAD:*) fail parser-never-DEAD "(never exited) read as ${S}: the v1.0.82 conviction, an agent that never fired called dying" ;;
    *) fail parser-never "(never exited) read as '${S}', expected NEVER-RAN:runs=0" ;;
esac

S="$(_drive_parser "$PROBE" "$LC_ONE")"
case "$S" in
    DEAD:1) note "parser CONTROL: a genuine last exit code = 1 (runs = 3) -> ${S}, never NEVER-RAN ✅" ;;
    NEVER-RAN:*) fail parser-one-neverran "a real exit 1 read as ${S}: the fix blinded the reader to a dying agent" ;;
    *) fail parser-one "last exit code = 1 read as '${S}', expected DEAD:1" ;;
esac

S="$(_drive_parser "$PROBE" "$LC_ZERO")"
[ "$S" = "HEALTHY" ] && note "parser CONTROL: last exit code = 0 -> HEALTHY ✅" || fail parser-zero "last exit code = 0 read as '${S}', expected HEALTHY"

S="$(_drive_parser "$PROBE" "$LC_EX_CONFIG")"
case "$S" in
    DEAD:78) note "parser: last exit code = 78: EX_CONFIG -> ${S}, the code alone, no trailing colon ✅" ;;
    DEAD:78:*) fail parser-exconfig-colon "78: EX_CONFIG read as '${S}': a malformed reason code would reach walks/*.tsv" ;;
    *) fail parser-exconfig "78: EX_CONFIG read as '${S}', expected DEAD:78" ;;
esac

S="$(_drive_parser "$PROBE" "$(printf 'gui/502/com.ostler.fda-rerun = {\n\tstate = not running\n}\n')")"
[ "$S" = "UNKNOWN:NO_EXIT_CODE_FIELD" ] && note "parser CONTROL: a body with no exit-code field -> ${S}, not a guess ✅" || fail parser-nofield "field-less body read as '${S}', expected UNKNOWN:NO_EXIT_CODE_FIELD"

# ── the seam the WHOLE probe reads the text through (FAKE_topup_print) ──
# FLAT baseline + the never-exited body -> PASS naming NEVER-RAN and the interval.
BL_FLAT="${WORK}/bl_flat.tsv"
printf 'conversations\t1024\t2026-01-01T00:00:00Z\npeople\t6889\t2026-01-01T00:00:00Z\nsafari_history\t8788\t2026-01-01T00:00:00Z\npreferences\t9025\t2026-01-01T00:00:00Z\n' > "$BL_FLAT"
OUT="$(SELF_TEST_LOCAL=1 OSTLER_INGEST_BASELINE="$BL_FLAT" FAKE_topup_print="$LC_NEVER" FAKE_ollama=REACHABLE \
       FAKE_conversations=1024 FAKE_people=6889 FAKE_safari_history=8788 FAKE_preferences=9025 \
       bash "$PROBE" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then fail seam-rc "whole probe on FLAT + never-exited text exited ${RC}, expected 0 (PASS)"
elif [ "$(grep -c 'top-up agent com.ostler.fda-rerun : NEVER-RAN:runs=0' <<<"$OUT")" -ne 1 ]; then fail seam-state "PASS but the note does not carry NEVER-RAN:runs=0"
elif [ "$(grep -c 'StartInterval 3600s (read from launchctl print)' <<<"$OUT")" -ne 1 ]; then fail seam-interval "PASS but the interval was not read from the text"
else note "whole probe: FLAT + never-exited launchctl text -> PASS (rc 0), NEVER-RAN:runs=0, StartInterval 3600s read ✅"; fi

# ── NEGATIVE CONTROL, pinned to the tree that convicted v1.0.82 ──
_CONTROL_SHA="ae5707d4"
printf 'negative control: %s (the parser that ran on the v1.0.82 walk)\n' "$_CONTROL_SHA"
CTL="${WORK}/ctl_probe.sh"
if ! git -C "$HERE" show "${_CONTROL_SHA}:scripts/box_walk_probes/probes/ingest_coverage.sh" > "$CTL" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:scripts/box_walk_probes/probes/ingest_coverage.sh is unreadable." >&2
    echo "  A shallow clone cannot see it, and scanning nothing must not read as a passing control." >&2
    exit 2
fi
S="$(_drive_old "$CTL" "$LC_NEVER")"
case "$S" in
    NOFN) echo "CANNOT-RUN: topup_agent_health was not found in the control blob." >&2; exit 2 ;;
    "DEAD:(never") note "control ${_CONTROL_SHA}: (never exited) -> ${S}, the v1.0.82 reading reproduced ✅" ;;
    NEVER-RAN:*) fail control-already-fixed "control ${_CONTROL_SHA} already reads NEVER-RAN, so this harness is not measuring the change" ;;
    *) fail control-other "control ${_CONTROL_SHA} read '${S}'; the walk record says DEAD:(never, so the harness is not reproducing the defect" ;;
esac
S="$(_drive_old "$CTL" "$LC_EX_CONFIG")"
[ "$S" = "DEAD:78:" ] && note "control ${_CONTROL_SHA}: 78: EX_CONFIG -> ${S}, the trailing-colon code reproduced ✅" || fail control-exconfig "control read '${S}' for 78: EX_CONFIG, expected the malformed DEAD:78:"
# CONTROL ON THE CONTROL: the pre-fix reader must be RIGHT about the forms it
# did handle, or its red above could be general breakage of the harness.
S="$(_drive_old "$CTL" "$LC_ZERO")"
[ "$S" = "HEALTHY" ] && note "control on the control: pre-fix reader reads exit 0 as HEALTHY, so (never exited) is the discriminator ✅" || fail control-on-control "pre-fix reader read exit 0 as '${S}'; its red proves nothing specific"

# ── the probe's own negative control, as run_box_walk.sh PHASE 1 reads it ──
# Exit 1 means every arm behaved; anything else marks the probe BROKEN on the
# walk and its real measurement is discarded.
RC=0; SELF_OUT="$(bash "$PROBE" --self-test 2>&1)" || RC=$?
if [ "$RC" -ne 1 ]; then fail selftest-rc "probe --self-test exited ${RC}, expected 1; the walk would mark it BROKEN"
elif [ "$(grep -c 'BROKEN' <<<"$SELF_OUT")" -ne 0 ]; then fail selftest-broken "probe --self-test exited 1 but an arm printed BROKEN"
else note "probe --self-test: exit 1 with $(grep -c ' OK: ' <<<"$SELF_OUT") arms OK and 0 BROKEN ✅"; fi

echo
[ -n "$FAILURES" ] && { printf 'RESULT: FAILURES ->%s\n' "$FAILURES"; exit 1; }
printf 'RESULT: all arms passed\n'
