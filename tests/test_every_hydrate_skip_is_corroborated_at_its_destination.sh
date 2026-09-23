#!/usr/bin/env bash
# Every hydrate skip is corroborated at ITS OWN destination (#2314)
# =================================================================
#
# WHAT #2313 FIXED, AND WHAT IT LEFT
#
# macmini16-walk, 2026-09-23. `browsing.done` said `status=ok payload=sent=8626`,
# written eight hours before the install; the `safari_history` collection did
# not exist; the step skipped in zero seconds and told the customer they had no
# browsing history over 8,831 visits the reader had logged 750 lines earlier.
# The sentinel was not lying about what it recorded. It records that a RUN
# completed and it was read as a claim that THE DATA IS STILL THERE, and those
# two facts have independent lifetimes: the sentinel is a file under ~/.ostler,
# the rows are in a volume inside the container VM.
#
# #2313 corroborated that ONE leg. `_hydrate_sentinel_fresh` has EIGHT skip
# call sites in install.sh, and the other seven skipped on exactly the same
# evidence:
#
#     install.sh   if _hydrate_sentinel_fresh "whatsapp"
#     install.sh   if _hydrate_sentinel_fresh "email_preferences"
#     install.sh   if _hydrate_sentinel_fresh "imessage"
#     install.sh   if _hydrate_sentinel_fresh "apple_notes"
#     install.sh   if _hydrate_sentinel_fresh "reminders_knowledge"
#     install.sh   if _hydrate_sentinel_fresh "people"
#     install.sh   if _hydrate_sentinel_fresh "ai_conversations"   <- see below
#
# `reminders_knowledge` has already shipped this failure once in its own right:
# the v1.0.101 walk logged "[ok] Reminders: 2369 total", "No Reminders to read"
# and "STEP_END id=hydrate_reminders status=ok elapsed_s=0" in one run, with
# reminders_knowledge and apple_notes_knowledge ABSENT against populated
# controls.
#
# THREE DESTINATIONS, NOT ONE, WHICH IS WHY THIS IS NOT SEVEN COPIES OF #2313
#
#   email_preferences   Qdrant `preferences`          (QDRANT_COLLECTION=preferences)
#   apple_notes         Qdrant $_HYDRATE_APPLENOTES_COLLECTION
#   reminders_knowledge Qdrant $_HYDRATE_REMINDERS_COLLECTION
#   people              Qdrant `people`               (PEOPLE_QDRANT_COLLECTION)
#   whatsapp            Oxigraph, pwg:identifierLabel "WHATSAPP"
#   imessage            Oxigraph, pwg:identifierLabel "IMESSAGE"
#   ai_conversations    NOT CORROBORATED. A named gap, pinned at the end of
#                       this file rather than filled.
#
# `ingest_whatsapp` and `ingest_imessage` contain ZERO Qdrant references; they
# INSERT into Oxigraph, which sits in the SAME container VM and dies with it, so
# a live read of it IS a read of the store the ingest writes to. They get a
# reader of their own with the same three-valued contract.
#
# `ai_conversations` gets none, on purpose. Its visible destination is a markdown
# tree under $HOME, and the sentinel is a file under $HOME: THEY SHARE A
# LIFETIME, so counting it would read `ok` in exactly the case this change
# exists for, while adding the appearance of a check. Its VM-side half is
# CM048's, whose collection nothing in this repo names. The last section of this
# file pins that gap: the leg may acquire a real store-side corroboration at any
# time, and may not acquire one that reads a path under $HOME.
#
# WHAT THIS ASSERTS, PER SOURCE
#
#   A   THE DEFECT. Fresh `status=ok` sentinel + a destination that is
#       POSITIVELY empty. The leg must NOT take the skip, must reach its
#       ingest arm, and must say the rows are gone.
#   A'  THE SAME INPUT ON THE PRE-FIX GUARD, built by MUTATING the current
#       tree. It must take the skip and print the sentence the customer saw.
#       Without A' passing, A proves only that the test is green.
#   B   POSITIVE CONTROL. Same sentinel, destination HOLDS ROWS: the skip is
#       earned, happens, and reports the count the destination gave. Without
#       this, a fix that merely stopped skipping would pass A.
#   C   CANNOT-RUN IS NOT EMPTY. Destination unreadable: re-import AND say it
#       could not be checked, never that it is empty.
#   D   NO SENTINEL AT ALL. The leg runs and says nothing about re-importing,
#       because there is nothing to explain.
#   P   THE PINNED GAP. ai_conversations still skips on the sentinel alone, says
#       at the line why it cannot be corroborated yet, and has acquired no
#       $HOME-rooted probe. With an anti-vacuity control: the same predicate
#       must FIRE on a seeded copy that adds one.
#
# AND TWO MUTATIONS OF THIS PR'S OWN FIX, one per destination class, each
# asserted CAUGHT rather than run by hand once and written up.
#
# HOW IT AVOIDS BEING GREEN BY CONSTRUCTION
#
# It EXTRACTS the real guard region of each of the seven legs from install.sh
# and EXECUTES it, with the real helpers and the real en-GB catalogue. Nothing
# about the decision is copied into this file. The stores are a REAL http
# server on a REAL port answering both the Qdrant collection endpoint and the
# Oxigraph /query endpoint, so the 200, the 404 and the refused connection are
# real curl outcomes; a curl stub would be the boundary the defect lives on.
#
# Fixture data is synthetic throughout: counts, example.invalid paths and
# fictional collection contents. No real names, handles, addresses or messages.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"

FAILURES=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

for f in "$INSTALL_SH" "$STRINGS"; do
    if [ ! -f "$f" ]; then
        printf 'FATAL: expected file not found: %s\n' "$f" >&2
        exit 1
    fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hydrate-corroborate-all.XXXXXX")"
STORE_PID=""
cleanup() {
    if [ -n "$STORE_PID" ]; then
        kill "$STORE_PID" 2>/dev/null
        wait "$STORE_PID" 2>/dev/null
    fi
    chmod -R u+rwX "$WORK" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# ── REAL STORES ON A REAL PORT ────────────────────────────────────────────
#
# One server, two surfaces, both mode-driven and re-read per request:
#
#   GET  /collections/<name>   -> 404, or 200 with points_count
#   POST /query                -> 200 text/csv "n\n<count>\n"  (Oxigraph shape)
#
# A connection refusal is produced by pointing the client at a port nothing is
# listening on, not by faking an exit code.
STORE_MODE="${WORK}/store_mode"
GRAPH_MODE="${WORK}/graph_mode"
PORT_FILE="${WORK}/port"
printf '404\n' > "$STORE_MODE"
printf '0\n' > "$GRAPH_MODE"

cat > "${WORK}/fake_stores.py" <<'STOREPY'
# Test-only stand-in for the Qdrant collection endpoint and the Oxigraph SPARQL
# endpoint. Not shipped.
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

store_mode, graph_mode, port_path = sys.argv[1], sys.argv[2], sys.argv[3]


def _read(path):
    with open(path) as fh:
        return fh.read().split()


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        mode = _read(store_mode)
        if mode and mode[0] == "200":
            body = json.dumps({"result": {"points_count": int(mode[1])},
                               "status": "ok"}).encode()
            self._send(200, body, "application/json")
        else:
            self._send(404, b'{"status":{"error":"Not found"},"result":null}',
                       "application/json")

    def do_POST(self):
        # Drain the body so curl sees a clean exchange.
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        mode = _read(graph_mode)
        if mode and mode[0] == "400":
            self._send(400, b"bad query", "text/plain")
            return
        count = mode[0] if mode else "0"
        self._send(200, ("n\n%s\n" % count).encode(), "text/csv")

    def log_message(self, *a):
        pass


srv = HTTPServer(("127.0.0.1", 0), H)
with open(port_path, "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
STOREPY

python3 "${WORK}/fake_stores.py" "$STORE_MODE" "$GRAPH_MODE" "$PORT_FILE" &
STORE_PID=$!

# Bounded wait. A poll loop with no delay is not a wait.
_waited=0
while [ ! -s "$PORT_FILE" ] && [ "$_waited" -lt 100 ]; do
    sleep 0.1
    _waited=$((_waited + 1))
done
if [ ! -s "$PORT_FILE" ]; then
    printf 'FATAL: the fake stores never bound a port. Every assertion below would be measuring the harness.\n' >&2
    exit 1
fi
PORT="$(cat "$PORT_FILE")"
LIVE_URL="http://127.0.0.1:${PORT}"
# A port nothing is listening on. Real ECONNREFUSED, real curl exit code.
DEAD_URL="http://127.0.0.1:1"

# ── VALIDATE THE PROBE BEFORE BELIEVING ITS ANSWER ────────────────────────
#
# Both surfaces, both directions. A server stuck on one answer would silently
# decide every scenario below, and a control that can only return one value is
# not a control.
printf '404\n' > "$STORE_MODE"
_q404="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 \
    "${LIVE_URL}/collections/anything")"
printf '200 4242\n' > "$STORE_MODE"
_q200="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 \
    "${LIVE_URL}/collections/anything")"
printf '7\n' > "$GRAPH_MODE"
_g="$(curl -s --noproxy '*' --max-time 5 -H 'Accept: text/csv' \
    --data-urlencode 'query=SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }' \
    "${LIVE_URL}/query" | tail -n 1 | tr -d ' \r')"
_dead="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 \
    "${DEAD_URL}/collections/anything" 2>/dev/null)"
if [ "$_q404" != "404" ] || [ "$_q200" != "200" ] || [ "$_g" != "7" ] || [ "$_dead" = "200" ]; then
    printf 'FATAL: harness controls disagree. collection 404 mode -> %s, 200 mode -> %s, graph count -> %s, dead port -> %s\n' \
        "$_q404" "$_q200" "$_g" "$_dead" >&2
    exit 1
fi
printf 'Harness: on port %s the collection endpoint answers 404 and 200 on demand, the SPARQL endpoint returns a count, and %s refuses.\n' \
    "$PORT" "$DEAD_URL"

# ── EXTRACT THE REAL CODE ─────────────────────────────────────────────────
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$2"
}

# The guard region of one leg: from its corroboration preamble down to and
# including the re-import warning that the ingest arm opens with. Everything in
# between -- every intermediate elif of the real chain -- comes along verbatim.
extract_guard() {
    awk -v start="$1" -v endmark="$2" '
        index($0, start) > 0 { inside = 1 }
        inside { print }
        inside && index($0, endmark) > 0 { tail = 2; next }
        tail > 0 { tail--; if (tail == 0) exit }
    ' "$3"
}

HELPERS="${WORK}/helpers.sh"
: > "$HELPERS"
for fn in _hydrate_sentinel_fresh _hydrate_collection_rows \
          _hydrate_collection_has_rows _hydrate_graph_matches; do
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

# source -> config, as a case rather than an associative array: bash 3.2 is the
# cut host's interpreter and has none.
#   1 var prefix   2 sentinel key   3 class   4 MSG stem   5 old false sentence
src_cfg() {
    case "$1" in
      whatsapp)            printf '%s\n' _HYDRATE_WHATSAPP whatsapp graph HYDRATE_WHATSAPP 'No WhatsApp chats to read.' ;;
      email_preferences)   printf '%s\n' _HYDRATE_EMAILPREFS email_preferences qdrant HYDRATE_EMAIL_PREFERENCES 'No email-preferences file configured.' ;;
      imessage)            printf '%s\n' _HYDRATE_IMESSAGE imessage graph HYDRATE_IMESSAGE 'No iMessage history to read.' ;;
      apple_notes)         printf '%s\n' _HYDRATE_APPLENOTES apple_notes qdrant HYDRATE_APPLE_NOTES 'Your Apple Notes are already in your knowledge base. Skipping.' ;;
      reminders_knowledge) printf '%s\n' _HYDRATE_REMINDERS reminders_knowledge qdrant HYDRATE_REMINDERS 'Your Reminders are already in your knowledge base. Skipping.' ;;
      people)              printf '%s\n' _HYDRATE_PEOPLE people qdrant HYDRATE_PEOPLE 'No people to index yet.' ;;
    esac
}

SOURCES="whatsapp email_preferences imessage apple_notes reminders_knowledge people"

# One guard region per source, plus the proof it came out of install.sh intact.
for s in $SOURCES; do
    set -- $(src_cfg "$s" | tr '\n' ' ')
    var="$1"; stem="$4"
    g="${WORK}/guard_${s}.sh"
    extract_guard "${var}_SENTINEL_FRESH=false" "MSG_WARN_${stem}_REIMPORT_STORE_EMPTY" \
        "$INSTALL_SH" > "$g"
    printf 'fi\n' >> "$g"
    if [ ! -s "$g" ]; then
        printf 'FATAL: could not extract the %s guard region from install.sh.\n' "$s" >&2
        exit 1
    fi
    if ! grep -q "_hydrate_sentinel_fresh \"${2}\"" "$g"; then
        printf 'FATAL: the extracted %s region does not contain its own sentinel read.\n' "$s" >&2
        exit 1
    fi
    if ! grep -q "_hydrate_collection_has_rows" "$g"; then
        printf 'FATAL: the extracted %s region has no corroboration in it.\n' "$s" >&2
        exit 1
    fi
    if ! bash -n "$g"; then
        printf 'FATAL: the extracted %s region does not parse.\n' "$s" >&2
        exit 1
    fi
done
printf 'Harness: extracted four helpers and the guard region of all six corroborated legs from install.sh.\n'

# ── THE MUTANT: the guard as it stood before this change ──────────────────
#
# Rebuilt by DELETING the corroboration from the current tree, so it cannot
# drift away from the code under test the way a hand-copied snapshot would.
for s in $SOURCES; do
    set -- $(src_cfg "$s" | tr '\n' ' ')
    python3 - "${WORK}/guard_${s}.sh" "${WORK}/prefix_${s}.sh" "$1" "$2" "$5" <<'MUTPY'
import sys
src_path, out_path, var, key, old_sentence = sys.argv[1:6]
src = open(src_path).read()
indent = ' ' * (len(src) - len(src.lstrip(' ')))
start = src.index(var + '_SENTINEL_FRESH=false')
end = src.index('%s   && _hydrate_collection_has_rows' % indent)
end = src.index('\n', src.index('\n', end) + 1) + 1   # past the ok(...) line
head = src[:start]
tail = src[end:]
# The one-question guard that shipped, and the sentence it printed.
mutated = (head
           + '%sif _hydrate_sentinel_fresh "%s"; then\n' % (indent, key)
           + '%s    printf \'%%s\\n\' "PREFIX_SKIP_SENTENCE"\n' % indent
           + tail)
# The pre-fix tail had no corroborated re-import warning at all.
lines, out, drop = mutated.split('\n'), [], False
for ln in lines:
    if ln.strip().startswith('if [[ "$%s_SENTINEL_FRESH" == "true" ]]; then' % var) and not drop:
        drop = True
        depth = 0
    if drop:
        st = ln.strip()
        if st.startswith('if ') or st.startswith('if[['):
            depth += 1
        if st == 'fi':
            depth -= 1
            if depth == 0:
                drop = False
        continue
    out.append(ln)
open(out_path, 'w').write('\n'.join(out))
MUTPY
    m="${WORK}/prefix_${s}.sh"
    if [ ! -s "$m" ]; then
        printf 'FATAL: the %s mutant is empty.\n' "$s" >&2
        exit 1
    fi
    if grep -q '_hydrate_collection_has_rows' "$m"; then
        printf "FATAL: the %s mutation did not remove the corroboration. A' would be testing the fixed guard.\n" "$s" >&2
        exit 1
    fi
    if ! grep -q "_hydrate_sentinel_fresh \"${2}\"; then" "$m"; then
        printf 'FATAL: the %s mutation did not install the pre-fix guard.\n' "$s" >&2
        exit 1
    fi
    if ! bash -n "$m"; then
        printf "FATAL: the %s mutant does not parse, so A' would fail for the wrong reason.\n" "$s" >&2
        exit 1
    fi
done
printf 'Harness: the pre-fix mutant of all six legs applied, removed the corroboration, and parses.\n\n'

# ── ONE CASE ──────────────────────────────────────────────────────────────
#
# run_case <source> <guard file> <sentinel: fresh|absent> <dest: rows|empty|unreadable>
#
# Everything the region reads is built under a synthetic OSTLER_DIR and HOME,
# so the real branch conditions inside the region are evaluated unmodified.
ROWS_COUNT=4242
run_case() {
    local s="$1" guard="$2" sentinel="$3" dest="$4"
    set -- $(src_cfg "$s" | tr '\n' ' ')
    local var="$1" key="$2" class="$3"
    local dir="${WORK}/run_${s}_${sentinel}_${dest}_$$_${RANDOM}"
    mkdir -p "${dir}/state/hydrate" "${dir}/imports/fda" \
             "${dir}/services/email-ingest/.venv/bin" "${dir}/home"

    if [ "$sentinel" = "fresh" ]; then
        # Exactly the shape measured on the walk box, with synthetic counts.
        cat > "${dir}/state/hydrate/${key}.done" <<SENTINEL
recorded_at=2026-09-22T19:25:23Z
source=${key}
status=ok
item_count=8626
last_update_at=2026-09-22T19:25:23Z
payload=sent=8626
SENTINEL
    fi

    # Inputs the real elif chain needs so the ingest arm is reachable.
    : > "${dir}/services/email-ingest/.venv/bin/python"
    chmod +x "${dir}/services/email-ingest/.venv/bin/python"
    printf '{"synthetic": true}\n' > "${dir}/imports/fda/input.json"
    mkdir -p "${dir}/home/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
    : > "${dir}/home/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"

    local qurl="$LIVE_URL" ourl="$LIVE_URL"
    case "$class" in
      qdrant)
        if [ "$dest" = "unreadable" ]; then qurl="$DEAD_URL"
        elif [ "$dest" = "rows" ]; then printf '200 %s\n' "$ROWS_COUNT" > "$STORE_MODE"
        else printf '404\n' > "$STORE_MODE"; fi ;;
      graph)
        if [ "$dest" = "unreadable" ]; then ourl="$DEAD_URL"
        elif [ "$dest" = "rows" ]; then printf '%s\n' "$ROWS_COUNT" > "$GRAPH_MODE"
        else printf '0\n' > "$GRAPH_MODE"; fi ;;
    esac

    OSTLER_DIR="$dir" _T_HOME="${dir}/home" _T_GUARD="$guard" _T_STRINGS="$STRINGS" \
    _T_HELPERS="$HELPERS" _T_QDRANT="$qurl" _T_OXIGRAPH="$ourl" \
    bash > "${dir}/out.txt" 2>&1 <<'DRIVER'
set -uo pipefail
HOME="${_T_HOME}"
QDRANT_URL="${_T_QDRANT}"
OXIGRAPH_URL="${_T_OXIGRAPH}"
_HYDRATE_SENTINEL_DIR="${OSTLER_DIR}/state/hydrate"
_OSTLER_STORE_CURL_ARGS=()
REPAIR_MODE=0

# Every branch condition of the real chains, fed so the ingest arm is the one
# the guard can fall through to. None of these is under test.
_PY="${OSTLER_DIR}/services/email-ingest/.venv/bin/python"
_JSON="${OSTLER_DIR}/imports/fda/input.json"
_HYDRATE_WHATSAPP_PY="$_PY"
_HYDRATE_WHATSAPP_DB="${HOME}/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
_HYDRATE_EMAILPREFS_PY="$_PY"
_HYDRATE_EMAILPREFS_FILE="$_JSON"
_HYDRATE_IMESSAGE_PY="$_PY"
_HYDRATE_IMESSAGE_JSON_FILE="$_JSON"
_HYDRATE_APPLENOTES_BIN_OK=true
_HYDRATE_APPLENOTES_JSON_FILE="$_JSON"
_HYDRATE_APPLENOTES_COLLECTION="apple_notes_knowledge"
_HYDRATE_REMINDERS_BIN_OK=true
_HYDRATE_REMINDERS_JSON_FILE="$_JSON"
_HYDRATE_REMINDERS_COLLECTION="reminders_knowledge"
_HYDRATE_PEOPLE_PY="$_PY"

# shellcheck source=/dev/null
. "${_T_STRINGS}"
# shellcheck source=/dev/null
. "${_T_HELPERS}"

# The three output helpers. They are not the boundary under test: every
# sentence they carry comes from the real catalogue sourced above.
info() { printf '[info]  %s\n' "$*"; }
ok()   { printf '[ok]    %s\n' "$*"; }
warn() { printf '[warn]  %s\n' "$*"; }

# shellcheck source=/dev/null
. "${_T_GUARD}"
DRIVER
    chmod -R u+rwX "$dir" 2>/dev/null
    printf '%s' "${dir}/out.txt"
}

# grep -c exits 1 on zero, so it is never in an && chain and its count is read
# from stdout, never from $?.
saw() {
    local n
    n="$(grep -F -c "$2" "$1" 2>/dev/null || true)"
    [ "${n:-0}" != "0" ]
}

# The catalogue is the only source of the sentences asserted on.
# shellcheck source=/dev/null
. "$STRINGS"

started_sentence() {
    case "$1" in
      whatsapp)            printf '%s' "$MSG_HYDRATE_WHATSAPP_STARTED" ;;
      email_preferences)   printf '%s' "$MSG_HYDRATE_EMAIL_PREFERENCES_STARTED" ;;
      imessage)            printf '%s' "$MSG_HYDRATE_IMESSAGE_STARTED" ;;
      apple_notes)         printf '%s' "$MSG_HYDRATE_APPLE_NOTES_STARTED" ;;
      reminders_knowledge) printf '%s' "$MSG_HYDRATE_REMINDERS_STARTED" ;;
      people)              printf '%s' "$MSG_HYDRATE_PEOPLE_STARTED" ;;
    esac
}
msg_of() { eval "printf '%s' \"\${$1}\""; }

# ── THE MATRIX ────────────────────────────────────────────────────────────
for s in $SOURCES; do
    set -- $(src_cfg "$s" | tr '\n' ' ')
    var="$1"; class="$3"; stem="$4"
    old_false="$(src_cfg "$s" | sed -n '5p')"
    guard="${WORK}/guard_${s}.sh"
    mutant="${WORK}/prefix_${s}.sh"
    started="$(started_sentence "$s")"
    already_fmt="$(msg_of "MSG_${stem}_ALREADY_IMPORTED")"
    already="${already_fmt%%(*}"
    empty_line="$(msg_of "MSG_WARN_${stem}_REIMPORT_STORE_EMPTY")"
    unver_line="$(msg_of "MSG_WARN_${stem}_REIMPORT_UNVERIFIED")"

    printf -- '-- %s (%s) --\n' "$s" "$class"

    # A'  the defect reproduces on the pre-fix guard. First, because if this
    #     does not reproduce then A below is evidence of nothing.
    out="$(run_case "$s" "$mutant" fresh empty)"
    if ! saw "$out" "PREFIX_SKIP_SENTENCE"; then
        fail "A' ${s}: the pre-fix guard did not skip a fresh sentinel over an empty destination. The original failing input did not reproduce."
    elif saw "$out" "$started"; then
        fail "A' ${s}: the pre-fix guard reached the ingest arm, so it was not the shipped guard."
    else
        pass "A' ${s}: the pre-fix guard skips on the sentinel alone, over a destination holding nothing"
    fi

    # A   the same input, fixed
    out="$(run_case "$s" "$guard" fresh empty)"
    if ! saw "$out" "$started"; then
        fail "A ${s}: a fresh sentinel over an EMPTY destination still skipped. This is the shipped defect."
    elif ! saw "$out" "$empty_line"; then
        fail "A ${s}: it re-imported but never said why. Output: $(tr '\n' '|' < "$out")"
    elif [ -n "$old_false" ] && saw "$out" "$old_false"; then
        fail "A ${s}: the customer was still told the old sentence: ${old_false}"
    else
        pass "A ${s}: a fresh sentinel over an empty destination re-imports and names the reason"
    fi

    # B   positive control: the earned skip still skips, and reports the count
    out="$(run_case "$s" "$guard" fresh rows)"
    if saw "$out" "$started"; then
        fail "B ${s}: re-imported over a destination that HOLDS the rows. The fix removed skipping rather than corroborating it."
    elif ! saw "$out" "$already"; then
        fail "B ${s}: the corroborated skip did not print its own sentence. Output: $(tr '\n' '|' < "$out")"
    elif ! saw "$out" "$ROWS_COUNT"; then
        fail "B ${s}: the skip did not report the count the destination gave (${ROWS_COUNT})."
    else
        pass "B ${s}: a fresh sentinel WITH the rows present skips, in its own words, and reports the count"
    fi

    # C   could not look is not looked and found nothing
    out="$(run_case "$s" "$guard" fresh unreadable)"
    if ! saw "$out" "$started"; then
        fail "C ${s}: an unreadable destination was treated as evidence the rows are there."
    elif ! saw "$out" "$unver_line"; then
        fail "C ${s}: the run did not say it could not check. Output: $(tr '\n' '|' < "$out")"
    elif saw "$out" "$empty_line"; then
        fail "C ${s}: an unreadable destination was reported as a positively empty one."
    else
        pass "C ${s}: an unreadable destination re-imports and says it could not check, never that it is empty"
    fi

    # D   no sentinel: nothing to explain, so nothing is explained
    out="$(run_case "$s" "$guard" absent empty)"
    if ! saw "$out" "$started"; then
        fail "D ${s}: no sentinel at all and the leg still did not run."
    elif saw "$out" "$empty_line" || saw "$out" "$unver_line"; then
        fail "D ${s}: a first-ever run was told its data had gone missing."
    else
        pass "D ${s}: a first-ever run imports and says nothing about re-importing"
    fi
done

# ── MUTATE THE FIX, ONE PER DESTINATION CLASS ─────────────────────────────
#
# Each of these is a plausible way to write the reader wrong, and each is the
# SAME two-valued collapse in a different place. A mutation that nothing goes
# red for is a gap in this file, not a compliment to the code.
printf '\n-- mutations of this change, one per destination class --\n'

mutate_helpers() {
    python3 - "$HELPERS" "${WORK}/helpers_mut.sh" "$1" <<'MUTHELP'
import sys
src = open(sys.argv[1]).read()
which = sys.argv[3]
if which == 'qdrant':
    # The _hydrate_qdrant_points defect: a positive 404 collapsed into "could
    # not read". The collection being gone stops being sayable.
    before = src
    src = src.replace("        404) printf 'absent';  return 0 ;;",
                      "        404) printf 'unknown'; return 0 ;;")
    assert src != before, 'qdrant mutation did not apply'
elif which == 'graph':
    # Read the body and ignore the status, the way _guard_email_coverage does.
    # A refused connection then reads as a graph that positively holds nothing.
    before = src
    src = src.replace('''    [[ "$code" == "200" ]] || { printf 'unknown'; return 0; }''',
                      '''    [[ "$code" == "200" ]] || { printf '0'; return 0; }''')
    assert src != before, 'graph mutation did not apply'
open(sys.argv[2], 'w').write(src)
MUTHELP
}

mutation_case() {
    # mutation_case <class> <source> <sentinel> <dest> -- runs with the mutated
    # helpers in place of the real ones.
    local keep="${WORK}/helpers_real.sh"
    cp "$HELPERS" "$keep"
    mutate_helpers "$1" || return 2
    cp "${WORK}/helpers_mut.sh" "$HELPERS"
    run_case "$2" "${WORK}/guard_${2}.sh" "$3" "$4"
    cp "$keep" "$HELPERS"
}

# qdrant class: A must go red, because `absent` can no longer be said.
out="$(mutation_case qdrant people fresh empty)"
if saw "$out" "$(msg_of MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY)"; then
    fail "MUTATION qdrant: folding the 404 into 'unknown' was NOT caught. A's discriminator is decorative."
else
    pass "MUTATION qdrant: folding a positive 404 into 'unknown' is caught -- the leg stops being able to say the rows are gone"
fi
# and the same mutation must NOT break the earned skip, or it would be caught
# for the wrong reason.
out="$(mutation_case qdrant people fresh rows)"
if saw "$out" "$(started_sentence people)"; then
    fail "MUTATION qdrant control: the earned skip broke too, so the red above is not specific."
else
    pass "MUTATION qdrant control: the earned skip is untouched by it, so the red above is specific to the 404"
fi

# graph class: C must go red, because a refusal becomes a positive zero.
out="$(mutation_case graph whatsapp fresh unreadable)"
if saw "$out" "$(msg_of MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED)"; then
    fail "MUTATION graph: ignoring the HTTP status was NOT caught. C's discriminator is decorative."
else
    pass "MUTATION graph: reading the body and ignoring the status is caught -- a refused connection stops being distinguishable from an empty graph"
fi


# ── P   THE PINNED GAP: ai_conversations ──────────────────────────────────
#
# This leg is NOT corroborated and must not be quietly "fixed" with a probe
# that cannot answer the question. Its visible destination is a markdown tree
# under $HOME; the sentinel is a file under $HOME. They share a lifetime, so a
# count of that tree reads `ok` in exactly the case this whole change exists
# for -- a container VM deleted out from under a surviving sentinel -- while
# adding the appearance of a check. Its VM-side half belongs to CM048, whose
# collection nothing in this repo names.
#
# The pin is deliberately one-sided. A real store-side corroboration may land
# here at any time and this section stays green; a $HOME-rooted one may not.
printf -- '-- ai_conversations (the gap this change does NOT close) --\n'

AICONV_REGION="${WORK}/aiconv_region.sh"
awk '
    index($0, "#2314: THIS LEG IS NOT CORROBORATED") > 0 { inside = 1 }
    inside { print }
    inside && index($0, "MSG_HYDRATE_AICONV_STARTED") > 0 { exit }
' "$INSTALL_SH" > "$AICONV_REGION"

# home_rooted_probe <file>  -- does this region corroborate against something
# that dies with the sentinel? Counts, never exit codes.
home_rooted_probe() {
    local n
    n="$(grep -E -c '_hydrate_artefact_files|OSTLER_AI_CONVERSATIONS_DIR|\$\{?HOME\}?/Documents' "$1" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}

if [ ! -s "$AICONV_REGION" ]; then
    fail "P ai_conversations: could not extract the region, so nothing below was measured."
elif ! grep -q '_hydrate_sentinel_fresh "ai_conversations"' "$AICONV_REGION"; then
    fail "P ai_conversations: the sentinel gate is gone from the region. Re-point this pin at wherever it moved."
elif [ "$(home_rooted_probe "$AICONV_REGION")" != "0" ]; then
    fail "P ai_conversations: this leg has acquired a corroboration that reads a path under \$HOME. That shares the sentinel's lifetime and cannot see the defect."
elif ! grep -q 'SHARE A LIFETIME' "$AICONV_REGION"; then
    fail "P ai_conversations: the gap is not explained at the line, so the next reader will fill it with the probe that does not work."
else
    pass "P ai_conversations: still skips on the sentinel alone, says at the line why, and has no \$HOME-rooted probe pretending otherwise"
fi

# ANTI-VACUITY. A predicate that can only ever return zero would pass the above
# over any region at all, including an empty one.
SEEDED="${WORK}/aiconv_seeded.sh"
{
    cat "$AICONV_REGION"
    printf '    _X_ROWS="$(_hydrate_artefact_files "${HOME}/Documents/Ostler/AI Conversations")"\n'
} > "$SEEDED"
if [ "$(home_rooted_probe "$SEEDED")" = "0" ]; then
    fail "P control: the predicate did not fire on a region that DOES carry a \$HOME-rooted probe. The pass above is vacuous."
else
    pass "P control: the same predicate fires on a seeded copy carrying exactly that probe, so the pass above is a measurement"
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf 'OK: six legs corroborate their skip at their own destination, two mutations of that are caught, and the seventh gap is pinned.\n'
    exit 0
fi
printf 'FAILED: %s assertion(s).\n' "$FAILURES"
exit 1
