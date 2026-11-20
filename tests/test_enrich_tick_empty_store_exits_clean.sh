#!/usr/bin/env bash
# tests/test_enrich_tick_empty_store_exits_clean.sh
# ============================================================================
# The recurring enrichment tick, run for real against a store with ZERO people.
# A customer with no exports has zero preferences, and the agent now installs
# for them, so the tick must run clean there: exit 0, and say nothing was
# enriched because there was nothing to enrich.
#
# WHAT RUNS
#   - the tick wrapper, lifted verbatim from install.sh (the ENRTICKEOF heredoc)
#   - the vendored CM019 enrich CLI, from vendor/cm019_preferences, with the real
#     Python dependencies (python3 must import them; CI installs the shipped
#     requirements.txt before this runs)
#   - a stub HTTP server standing in for Qdrant and Oxigraph, answering "empty"
#     to every request: no points, no bindings
#
# SCENARIOS
#   E1  accepted, zero people -> tick exits 0, log has NOTHING TO ENRICH, and
#       not ENRICHMENT COMPLETE
#   E2  declined              -> tick exits 0 before any enrichment, and logs
#       that public look-ups are not agreed
#   E3  unreachable store     -> XFAIL (CB137-ENRICH-CLI-FALSE-ABSENCE)
#   E4  engine tree absent    -> exit 0, 'engine not installed', no traceback
#   E5  enrich package absent -> the same named state
#
# Exit: 0 pass, 1 an assertion failed, 2 cannot-run.
# ============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${INSTALL_SH:-${REPO}/install.sh}"
PY="${ENRICH_PY:-python3}"
CM019_SRC="${REPO}/vendor/cm019_preferences"
WORK="$(mktemp -d)"
STORE_PID=""
cleanup() {
    [ -n "$STORE_PID" ] && kill "$STORE_PID" 2>/dev/null
    chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT
cannot() { echo "CANNOT-RUN: $*" >&2; exit 2; }
status=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; status=1; }

[ -r "$SRC" ] || cannot "cannot read $SRC"
[ -d "$CM019_SRC/services/enrich/src" ] || cannot "vendored CM019 enrich tree not found at $CM019_SRC"
"$PY" -c 'import click, httpx, pydantic_settings, aiolimiter, yaml' 2>/dev/null \
    || cannot "$PY lacks the enrich CLI's dependencies (click httpx pydantic-settings aiolimiter pyyaml); set ENRICH_PY or install vendor/cm019_preferences/requirements.txt"

# ---- (1) the real tick wrapper, verbatim ----------------------------------
HOME_DIR="$WORK/home"
# The tick runs with the REAL HOME, so the interpreter sees the same site
# packages as the dependency check above (a per-user site under a temp HOME
# would be invisible to one and not the other).
REAL_HOME="$HOME"
OSTLER_HOME="${HOME_DIR}/.ostler"
mkdir -p "${OSTLER_HOME}/bin" "${OSTLER_HOME}/config" "${OSTLER_HOME}/logs" "${OSTLER_HOME}/state"
WRAPPER="${OSTLER_HOME}/bin/ostler-enrich-tick"
awk '/^    cat > "\$wrapper" <<'"'"'ENRTICKEOF'"'"'$/ {f=1; next} f && /^ENRTICKEOF$/ {exit} f {print}' "$SRC" > "$WRAPPER"
[ -s "$WRAPPER" ] || cannot "tick wrapper heredoc (ENRTICKEOF) not found in $SRC"
chmod +x "$WRAPPER"

# ---- (2) the CM019 tree, as step 14 installs it, with the real interpreter ---
mkdir -p "${OSTLER_HOME}/services"
cp -R "$CM019_SRC" "${OSTLER_HOME}/services/cm019"
mkdir -p "${OSTLER_HOME}/services/cm019/.venv/bin"
# A shim, not a symlink: a symlink to a venv's interpreter loses the venv's
# site-packages when run from elsewhere. The shim execs the interpreter that
# has the dependencies, with the tick's own arguments.
printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v "$PY")" > "${OSTLER_HOME}/services/cm019/.venv/bin/python3"
chmod +x "${OSTLER_HOME}/services/cm019/.venv/bin/python3"
ENRICH_NS="$(grep -ohE 'https?://[a-z0-9./-]+/ontology#' \
    "${OSTLER_HOME}/services/cm019/services/enrich/src/enricher.py" 2>/dev/null | sort -u | head -1)"
[ -n "$ENRICH_NS" ] || cannot "could not read the enrichment namespace from the vendored enricher"

# ---- (3) an empty store on a free local port -------------------------------
cat > "$WORK/stub_store.py" <<'STUBEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def _send(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def _any(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        if self.path.endswith("/query"):
            self._send({"head": {"vars": ["n"]}, "results": {"bindings": []}})
        elif self.path.rstrip("/").endswith("/collections"):
            self._send({"result": {"collections": []}, "status": "ok", "time": 0})
        else:
            self._send({"result": {"points": [], "next_page_offset": None, "count": 0}, "status": "ok", "time": 0})
    do_GET = _any
    do_POST = _any
    def log_message(self, *a):
        pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
STUBEOF
PORT=$(( 20000 + (RANDOM % 20000) ))
"$PY" -I "$WORK/stub_store.py" "$PORT" >/dev/null 2>&1 &
STORE_PID=$!
for _ in $(seq 1 50); do
    curl -s -m 1 -o /dev/null "http://127.0.0.1:${PORT}/collections" && break
    sleep 0.1
done
curl -s -m 2 -o /dev/null "http://127.0.0.1:${PORT}/collections" || cannot "the stub store did not start on port $PORT"

store_env() {
    env -i PATH="$PATH" HOME="$REAL_HOME" OSTLER_DIR="$OSTLER_HOME" \
        OSTLER_ENRICH_NS="$ENRICH_NS" OSTLER_ENRICH_BUDGET_SECONDS=60 \
        OSTLER_ENRICH_USER=ostler QDRANT_COLLECTION=preferences \
        QDRANT_HOST=127.0.0.1 QDRANT_PORT="${TICK_PORT:-$PORT}" \
        OXIGRAPH_HOST=127.0.0.1 OXIGRAPH_PORT="${TICK_PORT:-$PORT}" \
        OXIGRAPH_URL="http://127.0.0.1:${TICK_PORT:-$PORT}" \
        "$@"
}

# ---- E1: accepted, zero people ---------------------------------------------
printf 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"\n' > "${OSTLER_HOME}/config/.env"
: > "${OSTLER_HOME}/logs/enrich.log"
store_env bash "$WRAPPER"; rc=$?
LOG="${OSTLER_HOME}/logs/enrich.log"
[ "$rc" = 0 ] && pass "E1: the tick exits 0 on an empty store" || fail "E1: the tick exited $rc on an empty store"
if grep -q 'NOTHING TO ENRICH' "$LOG"; then pass "E1: the log says NOTHING TO ENRICH"
else fail "E1: the log does not say NOTHING TO ENRICH"; sed 's/^/    /' "$LOG" | tail -25 >&2; fi
# Empty, not unreachable: the store answered, so no connection error may appear.
if grep -q 'All connection attempts failed\|Error querying Qdrant' "$LOG"; then
    fail "E1: the log shows a connection error; this was not an empty read"
else pass "E1: the store answered (no connection error in the log), so the zero is a real empty read"; fi
if grep -q 'ENRICHMENT COMPLETE' "$LOG"; then fail "E1: the log claims ENRICHMENT COMPLETE over zero people"
else pass "E1: the log does not claim ENRICHMENT COMPLETE over zero people"; fi
if grep -q 'tick finished rc=0:' "$LOG"; then pass "E1: the wrapper recorded its own finish with rc=0"
else fail "E1: the wrapper did not record a finish with rc=0"; fi

# ---- E2: declined -------------------------------------------------------------
printf 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"\n' > "${OSTLER_HOME}/config/.env"
: > "$LOG"
store_env bash "$WRAPPER"; rc=$?
[ "$rc" = 0 ] && pass "E2: the tick exits 0 when declined" || fail "E2: the tick exited $rc when declined"
if grep -q 'public look-ups not agreed' "$LOG" && ! grep -q 'NOTHING TO ENRICH\|ENRICHMENT COMPLETE' "$LOG"; then
    pass "E2: declined stands down before any enrichment runs"
else fail "E2: declined did not stand down cleanly"; sed 's/^/    /' "$LOG" | tail -10 >&2; fi

# ---- E3: UNREACHABLE store (nothing listening). Must NOT read as empty. --------
# Known defect, CB137-ENRICH-CLI-FALSE-ABSENCE: today the CLI logs NOTHING TO ENRICH
# and exits 0 here. That is an expected failure, reported as XFAIL and not counted
# red, so CI stays honest about it. When the CLI exits non-zero with a named reason,
# this case passes and reports XPASS, and the note here should be removed.
DEAD_PORT=$(( 40000 + (RANDOM % 20000) ))
printf 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"\n' > "${OSTLER_HOME}/config/.env"
: > "$LOG"
TICK_PORT="$DEAD_PORT" store_env bash "$WRAPPER"; rc=$?
if [ "$rc" != 0 ] && ! grep -q 'NOTHING TO ENRICH' "$LOG"; then
    pass "E3: an unreachable store exits $rc and is not reported as empty (XPASS of CB137-ENRICH-CLI-FALSE-ABSENCE: delete its expected-fail note)"
elif grep -q 'NOTHING TO ENRICH' "$LOG"; then
    echo "XFAIL: E3 an unreachable store (rc=$rc) is reported as NOTHING TO ENRICH. Known defect CB137-ENRICH-CLI-FALSE-ABSENCE (vendor/cm019_preferences/services/enrich/src/enricher.py:616-618 swallows the connect error). Not counted red."
else
    fail "E3: unreachable store gave rc=$rc without a NOTHING TO ENRICH line; unexpected shape"; sed 's/^/    /' "$LOG" | tail -5 >&2
fi

# ---- E4 / E5: the ENGINE is absent. The agent is installed anyway (consent is
# all that gates it), so its first tick runs on a box with no engine. It must
# exit 0 with the named state, and must not print a stack trace.
engine_absent_case() {  # $1 = label, $2 = path (relative to the CM019 tree) to park
    local label="$1" parked="$WORK/parked_$1" target="${OSTLER_HOME}/services/cm019/$2"
    mkdir -p "$(dirname "$parked")"
    mv "$target" "$parked" || { fail "$label: could not park $target"; return; }
    printf 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"\n' > "${OSTLER_HOME}/config/.env"
    : > "$LOG"
    store_env bash "$WRAPPER"; local rc=$?
    mv "$parked" "$target"
    echo "    ${label} tick log line: $(tail -n 1 "$LOG")" >&2
    if [ "$rc" = 0 ] && grep -q 'engine not installed' "$LOG" && ! grep -q 'Traceback' "$LOG" \
       && ! grep -q 'NOTHING TO ENRICH' "$LOG"; then
        pass "$label: engine absent -> exit 0, named 'engine not installed', no traceback, not reported as nothing-to-enrich"
    else
        fail "$label: engine absent -> rc=$rc; expected exit 0 with 'engine not installed' and no traceback"
        sed 's/^/    /' "$LOG" | tail -8 >&2
    fi
}
engine_absent_case E4_engine_dir_absent ""
engine_absent_case E5_enrich_package_absent "services/enrich"

if [ "$status" = 0 ]; then echo "PASS: the tick runs clean on zero people (E1) and stands down when declined (E2)"; fi
exit $status
