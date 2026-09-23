#!/usr/bin/env bash
# THE PRODUCER OF THE PREFERENCE GRAPH MUST RUN BEFORE THE COMPILE THAT READS IT.
#
# vendor/cm059_editor/bin/editor-frontpage-tick.sh runs two steps against the
# SAME store in one tick:
#
#   compiler.project_preferences   WRITES  <ontology>LikePreference nodes into
#                                          Oxigraph's default graph, projected
#                                          from the Qdrant `preferences`
#                                          collection.
#   compiler.emit_artefact         READS   those nodes, via
#                                          interest_profile.build_from_live ->
#                                          fetch_preferences -> _pref_query,
#                                          and writes
#                                          ~/.ostler/preferences/interest_profile.json
#
# Both sides name the same ontology host, the same two node types, the same
# four required predicates, and neither uses a GRAPH clause, so they meet in
# the default graph. That is the dependency: the reader cannot see a row the
# writer has not yet written.
#
# THE DEFECT THIS TEST WAS BORN RED AGAINST. The writer was invoked AFTER the
# reader, in a block labelled "Step 1.5" sitting below Step 1, so every compile
# read the graph as the PREVIOUS tick left it. The file's own comment asserted
# the opposite ("It runs BEFORE emit_artefact because emit_artefact reads what
# this writes"), which is how it survived review.
#
# WHY IT IS INVISIBLE IN NORMAL USE, and why it bites exactly where it hurts:
# it is a ONE-TICK LAG, not a permanent zero. A box that has been up for two
# hourly ticks looks fine. It bites only in the window between ingest
# completing and the following tick, which is the window a thin walk runs in.
# The measured consequence on the walked box: interest_profile.json count 0 and
# stats.raw_rows 0 over a graph holding 4,718 preference nodes, so
# GET /api/v1/preferences served an empty set with HTTP 200, so the assistant's
# pwg_preferences tool answered "No preferences were found in the personal
# graph", so the BLOCKING walk probe assistant_answers_grounded scored
# tool_found_nothing.
#
# THIS TEST RUNS THE REAL CALL SITE, NOT THE TWO FUNCTIONS. That distinction is
# the whole reason it exists. A near-identical fix on this project was tested by
# calling the underlying function directly, which passed on the UNFIXED tree
# because the function was never the defect: the call site was. So the subject
# here is the shipped wrapper, rendered exactly as INSTALL_SNIPPET.sh renders it
# (the same two sed substitutions), executed by bash, with a stub interpreter
# standing in for the compiler package. The stub MODELS THE STORE: the writer
# arm deposits rows, the reader arm can only report what is deposited when it
# runs. So the assertion is not "line A precedes line B" but "the artefact the
# Hub serves is non-empty after ONE tick on a cold box".
#
# CONTROLS, because a green result must not be obtainable from a dead harness:
#   POSITIVE  the same stub, driven in the known-good order by the harness
#             itself, must produce a NON-zero count. If it cannot, the harness
#             is broken and this test reports CANNOT-RUN rather than a pass.
#   NEGATIVE  the same stub, driven reader-first, must produce zero. If a
#             reversed order still comes out non-zero the harness is not
#             sensitive to the property under test, and a pass would be
#             meaningless.
#   LIVENESS  the tick must be observed invoking BOTH modules. A tick that
#             exited early (operator pause, lock contention, absent source)
#             also yields a zero count, and that zero is CANNOT-RUN, not FAIL.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TICK="${REPO}/vendor/cm059_editor/bin/editor-frontpage-tick.sh"
SNIPPET="${REPO}/vendor/cm059_editor/INSTALL_SNIPPET.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cannot_run() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -f "$TICK" ] || cannot_run "no tick wrapper at ${TICK}"
[ -f "$SNIPPET" ] || cannot_run "no install snippet at ${SNIPPET}"

# The two placeholders this test substitutes are the ones INSTALL_SNIPPET.sh
# substitutes. If either name moves, this harness would render a script that
# still contains a literal placeholder and fail for the wrong reason, so the
# names are asserted against BOTH files rather than assumed.
for ph in __OSTLER_PYTHON__ __OSTLER_SOURCE_DIR__; do
    if [ "$(/usr/bin/grep -c -- "$ph" "$TICK")" -eq 0 ]; then
        cannot_run "the wrapper no longer carries the ${ph} placeholder; this harness renders it the way the installer does and cannot do so blind"
    fi
    if [ "$(/usr/bin/grep -c -- "$ph" "$SNIPPET")" -eq 0 ]; then
        cannot_run "INSTALL_SNIPPET.sh no longer substitutes ${ph}; the render this harness performs is no longer the render the customer gets"
    fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/prefordering.XXXXXX")" || cannot_run "could not make a work directory"
trap 'rm -rf "$WORK"' EXIT

STAGED="${WORK}/services/cm059-editor"
mkdir -p "${STAGED}/compiler"
# The wrapper guards each step on the module file existing. Three empty files
# are enough: the stub interpreter below never imports them, it is the module
# NAME on the command line that identifies the step, which is exactly what the
# wrapper controls and this test is about.
: > "${STAGED}/compiler/emit_frontpage.py"
: > "${STAGED}/compiler/emit_artefact.py"
: > "${STAGED}/compiler/project_preferences.py"

# --- the stub interpreter: a store with a writer and a reader ---------------
# GRAPH  stands in for Oxigraph's default graph. Absent == a cold box.
# ARTEFACT stands in for ~/.ostler/preferences/interest_profile.json.
# ORDER  records which module ran, in the order it ran.
PY="${WORK}/python3-stub"
cat > "$PY" <<'STUB'
#!/usr/bin/env bash
# Stands in for the staged CM059 compiler package. Reads only its own -m
# module argument; models the graph as a file so the read/write dependency is
# real rather than asserted.
set -uo pipefail
mod=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-m" ]; then shift; mod="${1:-}"; fi
    shift || break
done
printf '%s\n' "$mod" >> "$OSTLER_TEST_ORDER"
case "$mod" in
    compiler.project_preferences)
        # The projector reads Qdrant and writes preference nodes into the graph.
        printf '%s\n' "$OSTLER_TEST_QDRANT_ROWS" > "$OSTLER_TEST_GRAPH"
        ;;
    compiler.emit_artefact)
        # The emitter compiles from the LIVE graph and writes the artefact the
        # Hub serves. A graph it cannot read is an empty graph, which is exactly
        # how the real emitter behaves and why the defect is silent.
        rows=0
        [ -f "$OSTLER_TEST_GRAPH" ] && rows="$(cat "$OSTLER_TEST_GRAPH")"
        printf '{"count": %s, "stats": {"raw_rows": %s}}\n' "$rows" "$rows" \
            > "$OSTLER_TEST_ARTEFACT"
        ;;
    compiler.emit_frontpage)
        : # the Dashboard front page; not the subject here
        ;;
esac
exit 0
STUB
chmod 0755 "$PY"

QROWS=4718   # the count measured in the graph on the walked box

# Render the wrapper exactly as INSTALL_SNIPPET.sh does: the same two -e
# expressions, the same escaping of the replacement.
render() {
    # render <destination>
    esc_py="$(printf '%s' "$PY"     | sed 's/[&/\]/\\&/g')"
    esc_src="$(printf '%s' "$STAGED" | sed 's/[&/\]/\\&/g')"
    sed -e "s/__OSTLER_PYTHON__/$esc_py/g" \
        -e "s/__OSTLER_SOURCE_DIR__/$esc_src/g" \
        "$TICK" > "$1"
    chmod 0755 "$1"
}

RENDERED="${WORK}/editor-frontpage-tick.sh"
render "$RENDERED"
if [ "$(/usr/bin/grep -c -- '__OSTLER_' "$RENDERED")" -ne 0 ]; then
    cannot_run "the rendered wrapper still holds an unsubstituted placeholder"
fi

# --- CONTROLS ---------------------------------------------------------------
# Taken BEFORE the subject runs, and taken by driving the stub directly, so a
# harness that cannot produce a non-zero at all is caught before its zero is
# read as a verdict.
control_run() {
    # control_run <first-module> <second-module>  -> prints the resulting count
    local g="${WORK}/ctl.graph" a="${WORK}/ctl.artefact" o="${WORK}/ctl.order"
    rm -f "$g" "$a" "$o"
    OSTLER_TEST_GRAPH="$g" OSTLER_TEST_ARTEFACT="$a" OSTLER_TEST_ORDER="$o" \
        OSTLER_TEST_QDRANT_ROWS="$QROWS" "$PY" -m "$1" >/dev/null 2>&1
    OSTLER_TEST_GRAPH="$g" OSTLER_TEST_ARTEFACT="$a" OSTLER_TEST_ORDER="$o" \
        OSTLER_TEST_QDRANT_ROWS="$QROWS" "$PY" -m "$2" >/dev/null 2>&1
    sed -n 's/.*"count": \([0-9]*\).*/\1/p' "$a" 2>/dev/null | head -1
}

POS="$(control_run compiler.project_preferences compiler.emit_artefact)"
if [ "${POS:-0}" -le 0 ]; then
    cannot_run "POSITIVE CONTROL FAILED: writer-then-reader produced count '${POS:-<none>}'. The harness cannot produce a non-zero artefact at all, so a zero from the subject would prove nothing about ordering."
fi
ok "positive control: writer then reader yields count ${POS} (the harness can go green)"

NEG="$(control_run compiler.emit_artefact compiler.project_preferences)"
if [ "${NEG:-0}" -ne 0 ]; then
    cannot_run "NEGATIVE CONTROL FAILED: reader-then-writer produced count '${NEG:-<none>}' instead of 0. The harness is not sensitive to the ordering it is here to measure."
fi
ok "negative control: reader then writer yields count 0 (the harness can go red)"

# --- THE SUBJECT: one tick, on a cold box ----------------------------------
GRAPH="${WORK}/graph"        # deliberately absent: a cold box, first tick
ARTEFACT="${WORK}/interest_profile.json"
ORDER="${WORK}/order"
rm -f "$GRAPH" "$ARTEFACT" "$ORDER"
: > "$ORDER"

TICK_OUT="${WORK}/tick.out"
# OSTLER_DIR is pointed at the work dir so the wrapper's mutex and any operator
# pause file land there and never at the developer's real ~/.ostler.
# OSTLER_RESOURCE_GOVERNOR=0 disables the pause probe: an operator pause is a
# clean early exit and would look like this defect.
OSTLER_DIR="${WORK}/ostler" \
OSTLER_RESOURCE_GOVERNOR=0 \
OSTLER_TEST_GRAPH="$GRAPH" \
OSTLER_TEST_ARTEFACT="$ARTEFACT" \
OSTLER_TEST_ORDER="$ORDER" \
OSTLER_TEST_QDRANT_ROWS="$QROWS" \
    bash "$RENDERED" > "$TICK_OUT" 2>&1
TICK_RC=$?

if [ "$TICK_RC" -ne 0 ]; then
    printf 'CANNOT-RUN: the tick exited %s. Its output:\n' "$TICK_RC" >&2
    sed 's/^/    /' "$TICK_OUT" >&2
    exit 2
fi

# LIVENESS. Both modules must have been invoked. A tick that skipped the work
# also leaves a zero count behind, and that zero is CANNOT-RUN, not FAIL.
for m in compiler.project_preferences compiler.emit_artefact; do
    if [ "$(/usr/bin/grep -cx -- "$m" "$ORDER")" -eq 0 ]; then
        printf 'CANNOT-RUN: the tick never invoked %s, so nothing was ordered.\n' "$m" >&2
        printf '  modules the tick ran: %s\n' "$(tr '\n' ' ' < "$ORDER")" >&2
        sed 's/^/    /' "$TICK_OUT" >&2
        exit 2
    fi
done
ok "the tick invoked both the projector and the emitter in one run"

COUNT="$(sed -n 's/.*"count": \([0-9]*\).*/\1/p' "$ARTEFACT" 2>/dev/null | head -1)"
RAN="$(tr '\n' ' ' < "$ORDER")"

if [ -z "${COUNT:-}" ]; then
    printf 'CANNOT-RUN: no count could be read from the artefact at %s.\n' "$ARTEFACT" >&2
    exit 2
fi

if [ "$COUNT" -eq "$QROWS" ]; then
    ok "after ONE tick on a cold box the artefact carries ${COUNT} interests (module order: ${RAN})"
elif [ "$COUNT" -eq 0 ]; then
    bad "after ONE tick on a cold box the artefact carries 0 interests over ${QROWS} projectable rows. The emitter ran BEFORE the projector, so it compiled the graph as the previous tick left it. Module order was: ${RAN}. Move the compiler.project_preferences invocation ABOVE the compiler.emit_artefact invocation in vendor/cm059_editor/bin/editor-frontpage-tick.sh."
else
    bad "unexpected count ${COUNT} (expected ${QROWS} or 0); module order was: ${RAN}"
fi

# --- the comment must not contradict the code ------------------------------
# The claim "It runs BEFORE emit_artefact" was in the file while the code did
# the opposite, and that is how the defect survived review. A prose assertion
# about order is only allowed to stand while the order it asserts is true, so
# the text is checked against the lines rather than trusted.
ART_LINE="$(/usr/bin/grep -n -- '-m compiler.emit_artefact' "$TICK" | head -1 | cut -d: -f1)"
PRJ_LINE="$(/usr/bin/grep -n -- '-m compiler.project_preferences' "$TICK" | head -1 | cut -d: -f1)"
if [ -z "${ART_LINE:-}" ] || [ -z "${PRJ_LINE:-}" ]; then
    printf 'CANNOT-RUN: could not locate both invocations in %s (emit_artefact=%s project_preferences=%s).\n' \
        "$TICK" "${ART_LINE:-none}" "${PRJ_LINE:-none}" >&2
    exit 2
fi
if [ "$PRJ_LINE" -lt "$ART_LINE" ]; then
    ok "the projector is invoked at line ${PRJ_LINE}, above the emitter at line ${ART_LINE}"
else
    bad "the projector is invoked at line ${PRJ_LINE}, BELOW the emitter at line ${ART_LINE}"
fi

CLAIMS="$(/usr/bin/grep -c -- 'runs BEFORE emit_artefact' "$TICK")"
if [ "$CLAIMS" -gt 0 ] && [ "$PRJ_LINE" -gt "$ART_LINE" ]; then
    bad "the wrapper still says the projection 'runs BEFORE emit_artefact' while invoking it after. A comment that contradicts its own code is worse than no comment: it is what stopped this being seen."
else
    ok "no prose in the wrapper asserts an order the code does not keep"
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
