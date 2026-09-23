#!/usr/bin/env bash
# A hydrate skip must be corroborated at the destination (#2311)
# ==============================================================
#
# THE INPUT THIS TEST REPLAYS
#
# macmini16-walk, 2026-09-23. One install run, one log, 750 lines apart:
#
#     install.log:497   [ok] Safari: 8831 visits across 100 domains
#     install.log:1246  No browsing history to import. You can re-run later ...
#     install.log:1247  STEP_END id=hydrate_browsing status=ok elapsed_s=0
#
# and an hour later the hourly top-up agent had to CREATE the destination the
# install was supposed to have filled:
#
#     fda-rerun.err:8033  GET  .../collections/safari_history  404 Not Found
#     fda-rerun.err:8034  PUT  .../collections/safari_history  200 OK
#
# exactly one 404 and one creation in 8,283 lines. Qdrant does not self-create
# collections, so nothing had written a single row before that agent ran.
#
# WHY THE STEP COULD NOT HAVE DONE ANYTHING ELSE
#
#     ~/.ostler/state/hydrate/browsing.done
#     recorded_at=2026-09-22T19:25:23Z
#     status=ok
#     payload=sent=8626,skipped=205
#
# eight hours before the install. `_hydrate_sentinel_fresh browsing` was
# therefore true and the block took its first arm. The sentinel was not lying
# about what it recorded. It was asked a question it cannot answer: it records
# that a RUN completed, and it was read as a claim that the DATA IS STILL
# THERE. A sentinel file under ~/.ostler and a Qdrant volume inside the
# container VM have independent lifetimes -- delete the VM, prune a volume,
# reset the container engine -- and when they diverge the sentinel still reads
# fresh and ok over an empty store.
#
# Neither downstream net could see it. `safari_history` is not in
# _OSTLER_REQUIRED_QDRANT_COLLECTIONS, so the membership check could not report
# it missing, and the initial_hydrate retry fires only on a POSITIVELY EMPTY
# store, which this one was not (CX106_QDRANT_BEFORE count=5).
#
# WHAT THIS TEST ASSERTS
#
#   A   ORIGINAL FAILING INPUT. Fresh ok sentinel + a store that answers 404
#       for the collection + an export file present. The block must RUN the
#       ingest, and must not print "No browsing history to import".
#   A'  THE SAME INPUT, AGAINST A MUTANT OF THE CURRENT TREE whose guard is
#       the one-line pre-fix `if _hydrate_sentinel_fresh "browsing"`. It must
#       skip, print that sentence, and close status=ok in zero seconds. Without
#       A' passing, A proves only that the test is green, not that it can see
#       the defect. The mutation is verified to have APPLIED and to PARSE
#       before anything leans on its result.
#   B   POSITIVE CONTROL, THE SKIP STILL WORKS. Fresh ok sentinel + a store
#       that answers 200 with points_count=8626. The block must NOT re-ingest,
#       and must say so in its own sentence. Without this, a "fix" that simply
#       never skips would pass A.
#   C   THREE OUTCOMES, NOT TWO. Fresh ok sentinel + a store that cannot be
#       read at all (nothing listening). "The collection is gone" and "I could
#       not look" are different facts: C must re-import AND say it could not
#       verify, never that the index is empty.
#   D   A STEP THAT STORED NOTHING MAY NOT CLOSE `ok`. Ingest exits 0 having
#       sent nothing, store still empty -> STEP_END status=warn, the
#       nothing-stored sentence, and a sentinel reason that names it.
#   E   POSITIVE CONTROL FOR D. Ingest sends 5,000 -> STEP_END status=ok. Without
#       this, a harness that stamped every step warn would pass D.
#   F   THE MIRROR IMAGE. A customer whose history is genuinely empty: the
#       reader saw nothing, sent nothing, and the store is empty. All three are
#       true and none is a fault. D and F differ ONLY in `total`, which is what
#       makes that field the discriminator rather than a decoration.
#
# HOW IT AVOIDS BEING GREEN BY CONSTRUCTION
#
# It EXTRACTS the real hydrate_browsing block and the real helpers from
# install.sh and EXECUTES them, and it sources the real lib/progress_emitter.sh
# and the real en-GB strings catalogue. Nothing about the decision is copied
# into this file. The store is a real HTTP server on a real port, so the 200,
# the 404 and the connection refusal are real curl outcomes rather than a
# shimmed exit code -- the distinction between them is the whole fix, and a
# curl stub would be the boundary the defect lives on.
#
# The only synthetic part is the ingest interpreter, which is replaced by a
# script that prints a counts-only JSON line this test controls and touches a
# marker so "did the ingest run" is a measurement rather than an inference.
# Fixture data is synthetic throughout: no real URLs, titles, domains or
# visits appear anywhere in this file or in what it writes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
EMITTER="${REPO_ROOT}/lib/progress_emitter.sh"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"

FAILURES=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

for f in "$INSTALL_SH" "$EMITTER" "$STRINGS"; do
    if [ ! -f "$f" ]; then
        printf 'FATAL: expected file not found: %s\n' "$f" >&2
        exit 1
    fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/browsing-corroborate.XXXXXX")"
STORE_PID=""
cleanup() {
    [ -n "$STORE_PID" ] && kill "$STORE_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# ── A REAL STORE ON A REAL PORT ───────────────────────────────────────────
#
# Answers whatever the mode file says, re-read on every request so one server
# serves every scenario:
#
#     404          -> 404, the collection is positively absent
#     200 <n>      -> 200 with points_count=<n>
#
# A connection refusal (scenario C) is produced by stopping it, not by faking
# an exit code.
STORE_MODE="${WORK}/store_mode"
STORE_PORT_FILE="${WORK}/store_port"
printf '404\n' > "$STORE_MODE"

cat > "${WORK}/fake_store.py" <<'STOREPY'
# Test-only stand-in for the Qdrant collection endpoint. Not shipped.
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

mode_path, port_path = sys.argv[1], sys.argv[2]

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        with open(mode_path) as fh:
            mode = fh.read().split()
        if mode and mode[0] == "200":
            body = json.dumps({"result": {"points_count": int(mode[1])},
                               "status": "ok"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            body = b'{"status":{"error":"Not found"},"result":null}'
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, *a):
        pass

srv = HTTPServer(("127.0.0.1", 0), H)
with open(port_path, "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
STOREPY

python3 "${WORK}/fake_store.py" "$STORE_MODE" "$STORE_PORT_FILE" &
STORE_PID=$!

# Wait for the port file, bounded. A poll loop with no delay is not a wait.
_waited=0
while [ ! -s "$STORE_PORT_FILE" ] && [ "$_waited" -lt 100 ]; do
    sleep 0.1
    _waited=$((_waited + 1))
done
if [ ! -s "$STORE_PORT_FILE" ]; then
    printf 'FATAL: the fake store never bound a port. Every assertion below would be measuring the harness.\n' >&2
    exit 1
fi
STORE_PORT="$(cat "$STORE_PORT_FILE")"
QDRANT_URL="http://127.0.0.1:${STORE_PORT}"

# ── VALIDATE THE PROBE BEFORE BELIEVING ITS ANSWER ────────────────────────
#
# Both directions, because a store stuck on one answer would silently decide
# every scenario below. A control that can only ever return one value is not a
# control.
printf '404\n' > "$STORE_MODE"
_code404="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 \
    "${QDRANT_URL}/collections/safari_history")"
printf '200 8626\n' > "$STORE_MODE"
_code200="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 \
    "${QDRANT_URL}/collections/safari_history")"
if [ "$_code404" != "404" ] || [ "$_code200" != "200" ]; then
    printf 'FATAL: the fake store answered %s for its 404 mode and %s for its 200 mode. It cannot tell the scenarios apart.\n' \
        "$_code404" "$_code200" >&2
    exit 1
fi
printf 'Harness: the fake store answers 404 and 200 on demand, on port %s.\n' "$STORE_PORT"

# ── EXTRACT THE REAL CODE ─────────────────────────────────────────────────
extract_fn() {
    # extract_fn <name> <file>  prints the function from its opening line to
    # the first `}` at column 0.
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$2"
}

extract_block() {
    # extract_block <file>  prints the hydrate_browsing region verbatim,
    # between two anchors that are unique in install.sh.
    awk '
        /^progress "Hydrating your browsing history" "hydrate_browsing"$/ { inside = 1 }
        inside { print }
        inside && /^unset _HYDRATE_BROWSING_SENTINEL_FRESH/ { exit }
    ' "$1"
}

HELPERS="${WORK}/helpers.sh"
: > "$HELPERS"
for fn in _hydrate_sentinel_fresh _hydrate_collection_rows \
          _hydrate_collection_has_rows _hydrate_qdrant_points \
          _hydrate_payload_count _hydrate_compute_change \
          _hydrate_payload_is_all_zero _hydrate_sentinel_record \
          _hydrate_sentinel_record_error _hydrate_sentinel_record_no_data \
          _hydrate_heartbeat_start _hydrate_heartbeat_stop progress; do
    extract_fn "$fn" "$INSTALL_SH" >> "$HELPERS"
    printf '\n' >> "$HELPERS"
    if ! grep -q "^${fn}() {" "$HELPERS"; then
        printf 'FATAL: could not extract %s from install.sh. The test is measuring nothing.\n' "$fn" >&2
        exit 1
    fi
done
if ! bash -n "$HELPERS"; then
    printf 'FATAL: the extracted helpers do not parse. Extraction is broken, not the code.\n' >&2
    exit 1
fi

BLOCK="${WORK}/block.sh"
extract_block "$INSTALL_SH" > "$BLOCK"
if [ ! -s "$BLOCK" ] || ! grep -q '_hydrate_sentinel_fresh "browsing"' "$BLOCK"; then
    printf 'FATAL: could not extract the hydrate_browsing block from install.sh.\n' >&2
    exit 1
fi
if ! bash -n "$BLOCK"; then
    printf 'FATAL: the extracted hydrate_browsing block does not parse.\n' >&2
    exit 1
fi
printf 'Harness: extracted the hydrate_browsing block (%s lines) and 12 helpers from install.sh.\n' \
    "$(wc -l < "$BLOCK" | tr -d ' ')"

# ── THE MUTANT: the guard as it stood before the fix ──────────────────────
#
# The pre-fix block asked one question and skipped on the answer. Rebuilding it
# by deleting the corroboration is a mutation of the CURRENT tree, so it cannot
# drift away from the code under test the way a hand-copied snapshot would.
MUTANT="${WORK}/block_prefix.sh"
python3 - "$BLOCK" "$MUTANT" <<'MUTPY'
import re, sys
src = open(sys.argv[1]).read()
# Replace everything from the corroboration preamble up to and including the
# corroborated-skip arm with the single-question guard that shipped.
start = src.index('_HYDRATE_BROWSING_SENTINEL_FRESH=false')
end = src.index('elif [[ -x "$_HYDRATE_BROWSING_PY" ]]')
mutated = (src[:start]
           + 'if _hydrate_sentinel_fresh "browsing"; then\n'
             '    info "$MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA"\n'
           + src[end:])
# The pre-fix tail had no corroborated re-import warning and no warn close.
mutated = mutated.replace('if [[ "$_HYDRATE_BROWSING_SENTINEL_FRESH" == "true" ]]; then\n'
                          '        if [[ "$_HYDRATE_BROWSING_ROWS" == "unknown" ]]; then\n'
                          '            warn "$MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED"\n'
                          '        else\n'
                          '            warn "$MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY"\n'
                          '        fi\n'
                          '    fi\n', '')
open(sys.argv[2], 'w').write(mutated)
MUTPY

# 🔴 A MUTANT THAT DID NOT APPLY LOOKS EXACTLY LIKE ONE THAT WAS NOT CAUGHT.
if [ ! -s "$MUTANT" ]; then
    printf 'FATAL: the mutant is empty.\n' >&2
    exit 1
fi
if ! grep -qE '^if _hydrate_sentinel_fresh "browsing"; then$' "$MUTANT"; then
    printf 'FATAL: the mutation did not apply -- the pre-fix guard is not in the mutant.\n' >&2
    exit 1
fi
if grep -q '_hydrate_collection_has_rows "\$_HYDRATE_BROWSING_ROWS"' "$MUTANT"; then
    printf 'FATAL: the mutation did not remove the corroboration. A\x27 would be testing the fixed guard.\n' >&2
    exit 1
fi
if ! bash -n "$MUTANT"; then
    printf 'FATAL: the mutant does not parse, so A\x27 would fail for the wrong reason.\n' >&2
    exit 1
fi
printf 'Harness: the pre-fix mutant applied, removed the corroboration, and parses.\n\n'

# ── ONE SCENARIO ──────────────────────────────────────────────────────────
#
# run_scenario <name> <block> <sentinel: fresh|absent> <store mode|down>
#              <ingest sent> <ingest skipped>
#
# Everything the block reads is built under a synthetic OSTLER_DIR, so the real
# path logic inside the block runs unmodified.
run_scenario() {
    local name="$1" block="$2" sentinel="$3" store="$4" sent="$5" skipped="$6"
    # How many rows the reader SAW. Defaults to `sent`, so every existing
    # scenario keeps its meaning; F sets it independently.
    local total="${7:-$5}"
    local dir="${WORK}/${name}"
    mkdir -p "${dir}/state/hydrate" \
             "${dir}/imports/fda" \
             "${dir}/services/email-ingest/.venv/bin" \
             "${dir}/diagnostics"

    # Synthetic export fixture. Counts and shape only; no real browsing data.
    cat > "${dir}/imports/fda/safari_history.json" <<'FIXTURE'
[{"url": "https://example.invalid/synthetic-a", "title": "Synthetic fixture A",
  "visit_time": "2026-01-01T00:00:00Z", "visit_count": 1},
 {"url": "https://example.invalid/synthetic-b", "title": "Synthetic fixture B",
  "visit_time": "2026-01-01T00:01:00Z", "visit_count": 1}]
FIXTURE

    if [ "$sentinel" = "fresh" ]; then
        # A completed run recorded hours ago: exactly the file measured on the
        # walk box, with synthetic counts.
        cat > "${dir}/state/hydrate/browsing.done" <<'SENTINEL'
recorded_at=2026-09-22T19:25:23Z
source=browsing
status=ok
item_count=8626
last_update_at=2026-09-22T19:25:23Z
payload=sent=8626,skipped=205
SENTINEL
    fi

    # The ingest interpreter, replaced so the counts are this test's to choose
    # and so "did it run at all" is a measurement.
    cat > "${dir}/services/email-ingest/.venv/bin/python" <<INGEST
#!/usr/bin/env bash
# Test-only stand-in for the venv interpreter. Not shipped.
printf 'ran\n' >> "${dir}/ingest_ran"
printf '{"status": "ok", "sent": ${sent}, "points_created": ${sent}, "skipped_sensitive": ${skipped}, "total": ${total}}\n'
INGEST
    chmod +x "${dir}/services/email-ingest/.venv/bin/python"

    if [ "$store" = "down" ]; then
        # A real connection refusal on a port nothing is listening on.
        local url="http://127.0.0.1:1"
    else
        printf '%s\n' "$store" > "$STORE_MODE"
        local url="$QDRANT_URL"
    fi

    OSTLER_GUI=1 \
    _T_DIR="$dir" _T_BLOCK="$block" _T_EMITTER="$EMITTER" \
    _T_STRINGS="$STRINGS" _T_HELPERS="$HELPERS" _T_QDRANT="$url" \
    bash > "${dir}/stdout.txt" 2> "${dir}/markers.txt" <<'DRIVER'
set -uo pipefail

OSTLER_DIR="${_T_DIR}"
OSTLER_DIAG_DIR="${_T_DIR}/diagnostics"
QDRANT_URL="${_T_QDRANT}"
_HYDRATE_SENTINEL_DIR="${OSTLER_DIR}/state/hydrate"
_OSTLER_STORE_CURL_ARGS=()
REPAIR_MODE=0

# progress() globals. Values only keep the bar arithmetic alive.
TOTAL_STEPS=4; CURRENT_STEP=0; PHASE3_START=$(date +%s)
BOLD=""; BLUE=""; GREEN=""; YELLOW=""; NC=""

# shellcheck source=/dev/null
. "${_T_EMITTER}"
# shellcheck source=/dev/null
. "${_T_STRINGS}"
# shellcheck source=/dev/null
. "${_T_HELPERS}"

# The three output helpers, defined exactly as install.sh defines them. They
# are not the boundary under test: every sentence they carry comes from the
# real catalogue sourced above, and every STEP_END comes from the real emitter.
info()  { gui_active || echo "[info]  $*"; gui_log info "$*"; }
ok()    { gui_active || echo "[ok]    $*"; gui_log info "$*"; }
warn()  { gui_active || echo "[warn]  $*"; gui_warn "$*"; }

set -Eeuo pipefail
_ostler_on_err() { :; }
trap '_ostler_on_err' ERR

# shellcheck source=/dev/null
. "${_T_BLOCK}"
set +e

# Close the step the way the next progress() call would, so the STEP_END is on
# the wire for the assertions. A block that already closed it explicitly leaves
# __OSTLER_STEP_ID empty and this is a no-op, which is the behaviour being
# asserted in D.
if [[ -n "${__OSTLER_STEP_ID:-}" ]]; then
    gui_step_end
fi
DRIVER
    return 0
}

step_end_line() {
    # The STEP_END for hydrate_browsing, from the marker stream.
    grep -F 'STEP_END' "$1" | grep -F 'id=hydrate_browsing' | tail -n 1
}

# grep -c exits 1 on zero, so it is never in an && chain and its count is read
# from stdout, never from $?.
count_in() {
    local n
    n="$(grep -F -c "$2" "$1" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}

ingest_ran() {
    [ -s "${WORK}/$1/ingest_ran" ]
}

NO_DATA_SENTENCE="No browsing history to import."
ALREADY_SENTENCE="is already imported"
UNVERIFIED_SENTENCE="Could not check whether your browsing history"
STORE_EMPTY_SENTENCE="no longer holds it"
NOTHING_STORED_SENTENCE="did not reach your search index"

# ── A'  THE DEFECT REPRODUCES ON THE PRE-FIX GUARD ────────────────────────
# Run FIRST: if this does not reproduce, nothing below is evidence of a fix.
run_scenario "Aprime" "$MUTANT" fresh 404 8626 205
_line="$(step_end_line "${WORK}/Aprime/markers.txt")"
if ingest_ran Aprime; then
    fail "A': the pre-fix guard ran the ingest. The original failing input did not reproduce, so A proves nothing."
elif [ "$(count_in "${WORK}/Aprime/markers.txt" "$NO_DATA_SENTENCE")" = "0" ]; then
    fail "A': the pre-fix guard did not print the sentence the customer saw."
elif ! grep -qF 'status=ok' <<< "$_line" || ! grep -qF 'elapsed_s=0' <<< "$_line"; then
    fail "A': expected the walk's own line (status=ok elapsed_s=0), got: ${_line:-<none>}"
else
    pass "A': the pre-fix guard skips a live export over an absent collection, says 'No browsing history to import', and closes status=ok in zero seconds"
fi

# ── A   THE SAME INPUT, FIXED ─────────────────────────────────────────────
run_scenario "A" "$BLOCK" fresh 404 8626 205
_line="$(step_end_line "${WORK}/A/markers.txt")"
if ! ingest_ran A; then
    fail "A: a fresh sentinel over an ABSENT collection still skipped the ingest. This is the shipped defect."
elif [ "$(count_in "${WORK}/A/markers.txt" "$NO_DATA_SENTENCE")" != "0" ]; then
    fail "A: the customer was still told there is no browsing history to import."
elif [ "$(count_in "${WORK}/A/markers.txt" "$STORE_EMPTY_SENTENCE")" = "0" ]; then
    fail "A: the re-import happened but never said why."
elif ! grep -qF 'status=ok' <<< "$_line"; then
    fail "A: a successful re-import must close status=ok, got: ${_line:-<none>}"
else
    pass "A: a fresh sentinel over an absent collection re-imports, names the reason, and closes ok"
fi

# ── B   POSITIVE CONTROL: THE EARNED SKIP STILL SKIPS ─────────────────────
run_scenario "B" "$BLOCK" fresh "200 8626" 8626 205
_line="$(step_end_line "${WORK}/B/markers.txt")"
if ingest_ran B; then
    fail "B: re-imported 8,626 rows that were already in the store. The fix has removed skipping rather than corroborating it."
elif [ "$(count_in "${WORK}/B/markers.txt" "$ALREADY_SENTENCE")" = "0" ]; then
    fail "B: the corroborated skip did not print its own sentence."
elif [ "$(count_in "${WORK}/B/markers.txt" "$NO_DATA_SENTENCE")" != "0" ]; then
    fail "B: a corroborated skip still printed the no-data sentence."
elif ! grep -qF 'status=ok' <<< "$_line"; then
    fail "B: an earned skip must close status=ok, got: ${_line:-<none>}"
else
    pass "B: a fresh sentinel WITH the rows present skips, in its own words, and closes ok"
fi

# ── C   COULD NOT LOOK IS NOT LOOKED AND FOUND NOTHING ────────────────────
run_scenario "C" "$BLOCK" fresh down 8626 205
if ! ingest_ran C; then
    fail "C: an unreadable store was treated as evidence the rows are there. A skip on a read that never happened is the defect one step sideways."
elif [ "$(count_in "${WORK}/C/markers.txt" "$UNVERIFIED_SENTENCE")" = "0" ]; then
    fail "C: the run did not say it could not verify."
elif [ "$(count_in "${WORK}/C/markers.txt" "$STORE_EMPTY_SENTENCE")" != "0" ]; then
    fail "C: an unreadable store was reported as a positively empty one."
else
    pass "C: an unreadable store re-imports and says it could not check, never that the index is empty"
fi

# ── D   STORED NOTHING, SO NOT `ok` ───────────────────────────────────────
run_scenario "D" "$BLOCK" absent 404 0 0 8831
_line="$(step_end_line "${WORK}/D/markers.txt")"
_sentinel="${WORK}/D/state/hydrate/browsing.done"
if ! ingest_ran D; then
    fail "D: the ingest did not run, so the scenario never reached the branch under test."
elif ! grep -qF 'status=warn' <<< "$_line"; then
    fail "D: a step that read the history and stored none of it closed as: ${_line:-<none>}"
elif [ "$(count_in "${WORK}/D/markers.txt" "$NOTHING_STORED_SENTENCE")" = "0" ]; then
    fail "D: nothing was stored and the customer was not told."
elif [ ! -f "$_sentinel" ] || [ "$(count_in "$_sentinel" "nothing_sent_and_store_empty")" = "0" ]; then
    fail "D: the durable record does not name what happened. Contents: $(cat "$_sentinel" 2>/dev/null | tr '\n' ' ')"
else
    pass "D: an ingest that exits 0 over an empty store closes status=warn, says so, and records why"
fi

# ── E   POSITIVE CONTROL FOR D ────────────────────────────────────────────
run_scenario "E" "$BLOCK" absent 404 5000 12
_line="$(step_end_line "${WORK}/E/markers.txt")"
if ! ingest_ran E; then
    fail "E: the ingest did not run."
elif ! grep -qF 'status=ok' <<< "$_line"; then
    fail "E: a delivering ingest must still close status=ok, got: ${_line:-<none>}. D's warn could be a harness stamping everything."
elif [ "$(count_in "${WORK}/E/markers.txt" "Imported 5000")" = "0" ]; then
    fail "E: the count was not reported to the customer."
else
    pass "E: an ingest that delivers 5,000 pages still closes status=ok and reports the count"
fi

# ── F   THE CUSTOMER WHO GENUINELY HAS NONE ──────────────────────────────
# The mirror image of the defect. A brand-new Mac writes an empty export, the
# ingest sees nothing and sends nothing, and the store is empty -- all three
# true at once, and none of it a fault. Warning THAT customer that their
# history was lost is the same false statement pointed the other way, so the
# discriminator is `total`: what the reader SAW, not what the store HOLDS.
run_scenario "F" "$BLOCK" absent 404 0 0 0
_line="$(step_end_line "${WORK}/F/markers.txt")"
if ! ingest_ran F; then
    fail "F: the ingest did not run, so the scenario never reached the branch under test."
elif [ "$(count_in "${WORK}/F/markers.txt" "$NO_DATA_SENTENCE")" = "0" ]; then
    fail "F: a customer with no browsing history was not told the one thing that is true."
elif [ "$(count_in "${WORK}/F/markers.txt" "$NOTHING_STORED_SENTENCE")" != "0" ]; then
    fail "F: a customer with no history was warned that their history was lost."
elif ! grep -qF 'status=ok' <<< "$_line"; then
    fail "F: nothing to import is not a fault and must close ok, got: ${_line:-<none>}"
else
    pass "F: an empty history reads as an empty history, not as a loss, and closes ok"
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf 'OK: a hydrate skip is corroborated at the destination, and a leg that stored nothing does not report ok.\n'
    exit 0
fi
printf 'FAILED: %s assertion(s).\n' "$FAILURES"
exit 1
