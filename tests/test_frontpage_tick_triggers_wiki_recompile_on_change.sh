#!/usr/bin/env bash
#
# CM051 walk #5, finding 2: the compiled wiki's "Needs you now" and the live
# app's front_page.json showed ZERO cards in common. Reproduced read-only on
# macmini16-walk: the wiki-compiler service has the correct editor mount and
# OSTLER_FRONT_PAGE_JSON, and genuinely reads and uses the feed -- the
# compose service definition was never the bug. The gap is that nothing
# ever told the wiki a new front_page.json had landed: editor-frontpage-tick
# runs hourly and is the only writer of front_page.json, wiki-recompile
# ships daily (86400s) by deliberate v1 design (CM051 #20's own "open
# question", chosen for disk/battery cost across the WHOLE wiki), and the
# two are not linked. "Needs you now" could run stale by up to a day.
#
# The fix lives in editor-frontpage-tick.sh Step 3: after a successful
# front-page emit, compare front_page.json's hash against the last one the
# wiki picked up, and background a wiki recompile ONLY when it changed --
# so a quiet feed never reopens the daily-cadence decision for the rest of
# the wiki, and a changed feed catches up within one tick.
#
# This is a BEHAVIOURAL test: it runs Step 3's real logic (sourced out of
# the actual tick script, not retyped here) against a fake OSTLER_DIR and a
# stub "wiki-recompile-tick.sh" that just timestamps its own invocations,
# so a passing run proves the trigger fires, not merely that some string
# appears in the file.
#
# Runs under bash 3.2 (the macOS system bash the installed box provides).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICK="${REPO_ROOT}/vendor/cm059_editor/bin/editor-frontpage-tick.sh"

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

echo "test_frontpage_tick_triggers_wiki_recompile_on_change"
echo "  subject: ${TICK#$REPO_ROOT/}"

if [ ! -f "$TICK" ]; then
    bad "premise: tick script NOT FOUND at $TICK -- every assertion below is vacuous"
    echo "  $pass passed, $fail failed"
    exit 1
fi
ok "premise: the tick script exists"

PY_BIN="$(command -v python3 || true)"
if [ -z "$PY_BIN" ]; then
    echo "  CANNOT-RUN: no python3 on PATH -- the functional limbs below cannot execute."
    echo "  $pass passed, $fail failed (0 of the behavioural limbs ran)"
    exit 2
fi

# ── Harness: a fake install tree the tick can run against for real ────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OSTLER_DIR="${WORK}/ostler"
SOURCE_DIR="${WORK}/cm059-editor"
mkdir -p "${OSTLER_DIR}/editor" "${OSTLER_DIR}/bin" "${SOURCE_DIR}/compiler"

# Stub compiler package: emit_frontpage/emit_artefact/project_preferences
# are all optional per the tick's own existence guards except emit_frontpage,
# which the tick's top-level source-present guard requires. A no-op that
# accepts --oxigraph and exits 0 is enough -- this test seeds front_page.json
# itself so it does not depend on the stub actually writing anything.
: > "${SOURCE_DIR}/compiler/__init__.py"
cat > "${SOURCE_DIR}/compiler/emit_frontpage.py" <<'EOF'
import sys
sys.exit(0)
EOF

# Stub wiki-recompile-tick.sh: records one line per invocation instead of
# touching docker/Oxigraph/anything real.
WIKI_CALLS="${WORK}/wiki_recompile_calls.log"
: > "$WIKI_CALLS"
cat > "${OSTLER_DIR}/bin/wiki-recompile-tick.sh" <<EOF
#!/usr/bin/env bash
date -u +%s >> "${WIKI_CALLS}"
exit 0
EOF
chmod +x "${OSTLER_DIR}/bin/wiki-recompile-tick.sh"

run_tick() {
    OSTLER_DIR="$OSTLER_DIR" OSTLER_RESOURCE_GOVERNOR=0 \
        PYTHONPYCACHEPREFIX="${WORK}/pycache" \
        OXIGRAPH_URL="http://127.0.0.1:7878" \
        bash -c '
            set -e
            TICK="$1"; SRC="$2"; PY="$3"
            sed -e "s#__OSTLER_PYTHON__#${PY}#" -e "s#__OSTLER_SOURCE_DIR__#${SRC}#" "$TICK" > "'"$WORK"'/rendered-tick.sh"
            chmod +x "'"$WORK"'/rendered-tick.sh"
            "'"$WORK"'/rendered-tick.sh"
        ' _ "$TICK" "$SOURCE_DIR" "$PY_BIN"
}

wait_for_calls() {
    # The trigger is intentionally backgrounded (must not block the tick),
    # so give the detached stub a moment to append before counting lines.
    local want="$1" waited=0
    while [ "$(wc -l < "$WIKI_CALLS" | tr -d ' ')" -lt "$want" ] && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
}

# ── 1. First tick, front_page.json present: no prior hash on record, so
#       this must count as "changed" and trigger exactly one recompile. ───
printf '{"cards":[{"id":"card_aaa"}]}' > "${OSTLER_DIR}/editor/front_page.json"
run_tick
wait_for_calls 1
_n1="$(wc -l < "$WIKI_CALLS" | tr -d ' ')"
if [ "$_n1" = "1" ]; then
    ok "first tick (no prior hash on record) triggers exactly one wiki recompile"
else
    bad "first tick triggered ${_n1} recompiles, wanted 1"
fi

# ── 2. Second tick, UNCHANGED front_page.json: must NOT trigger again. ────
run_tick
sleep 0.3
_n2="$(wc -l < "$WIKI_CALLS" | tr -d ' ')"
if [ "$_n2" = "$_n1" ]; then
    ok "unchanged front_page.json does not re-trigger a recompile (daily cadence left alone)"
else
    bad "unchanged content still triggered a recompile: count went ${_n1} -> ${_n2}"
fi

# ── 3. Third tick, front_page.json CHANGED: must trigger again -- this is
#       the coordinator's required test, "feed written after the compile ->
#       the page reflects it within one tick". ────────────────────────────
printf '{"cards":[{"id":"card_bbb"}]}' > "${OSTLER_DIR}/editor/front_page.json"
run_tick
wait_for_calls $((_n2 + 1))
_n3="$(wc -l < "$WIKI_CALLS" | tr -d ' ')"
if [ "$_n3" = "$((_n2 + 1))" ]; then
    ok "feed written after the last compile triggers a recompile within one tick"
else
    bad "changed content did not trigger a recompile: count stayed at ${_n3}, wanted $((_n2 + 1))"
fi

# ── 4. The front-page emit itself is untouched by this change. ────────────
if grep -q 'compiler\.emit_frontpage' "$TICK"; then
    ok "the front-page emit is still invoked (Step 3 is additive, not a replacement)"
else
    bad "compiler.emit_frontpage is GONE -- unrelated regression"
fi

# ── 5. Syntax ───────────────────────────────────────────────────────────
if bash -n "$TICK" 2>/dev/null; then
    ok "tick parses under bash -n"
else
    bad "tick has a SYNTAX ERROR -- it would never run at all"
fi

# ── 6. NEGATIVE CONTROL ────────────────────────────────────────────────
# Prove limb 3 can actually return FAIL. Mutate a copy so the trigger never
# fires (force the hash comparison false) and re-run the same scenario.
# If it still "passes", the predicate measures nothing.
_mutant="${WORK}/mutant-tick.sh"
sed 's/\[ "\$_new_hash" != "\$_old_hash" \]/[ 1 -eq 0 ]/' "$TICK" > "$_mutant"
chmod +x "$_mutant"
if grep -q '\[ 1 -eq 0 \]' "$_mutant"; then
    : > "$WIKI_CALLS"
    printf '{"cards":[{"id":"card_ccc"}]}' > "${OSTLER_DIR}/editor/front_page.json"
    rm -f "${OSTLER_DIR}/state/wiki-recompile-last-frontpage.sha256"
    OSTLER_DIR="$OSTLER_DIR" OSTLER_RESOURCE_GOVERNOR=0 \
        PYTHONPYCACHEPREFIX="${WORK}/pycache" \
        bash -c '
            set -e
            sed -e "s#__OSTLER_PYTHON__#'"$PY_BIN"'#" -e "s#__OSTLER_SOURCE_DIR__#'"$SOURCE_DIR"'#" "'"$_mutant"'" > "'"$WORK"'/rendered-mutant.sh"
            chmod +x "'"$WORK"'/rendered-mutant.sh"
            "'"$WORK"'/rendered-mutant.sh"
        '
    sleep 0.3
    _nm="$(wc -l < "$WIKI_CALLS" | tr -d ' ')"
    if [ "$_nm" = "0" ]; then
        ok "negative control: a tick whose change-check is forced false never triggers a recompile"
    else
        bad "negative control DID NOT FIRE: the mutant still triggered ${_nm} recompile(s), so limb 3 proves nothing"
    fi
else
    bad "negative control could not be constructed -- the hash-comparison line has moved; update this test's sed pattern"
fi

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
