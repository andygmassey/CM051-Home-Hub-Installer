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
# wiki picked up, and on a change ask launchd to start the SEPARATE
# wiki-recompile LaunchAgent job via `launchctl kickstart`.
#
# WHY NOT FORK THE TICK DIRECTLY (Archie review on #2633, round 1): this
# plist has no AbandonProcessGroup, so launchd kills this job's whole
# process group -- including a plain `( cmd & )` child -- the instant this
# script exits. That is the exact v1.0.107 defect. `launchctl kickstart`
# starts the OTHER LaunchAgent (whose own plist DOES set
# AbandonProcessGroup) under launchd's own supervision, independent of this
# script's lifetime.
#
# This is a BEHAVIOURAL test: it runs Step 3's real logic (sourced out of
# the actual tick script, not retyped here) against a fake OSTLER_DIR and a
# stub `launchctl` on PATH that just records its own invocations, so a
# passing run proves launchd is actually being asked to start the right
# job, not merely that some string appears in the file.
#
# Runs under bash 3.2 (the macOS system bash the installed box provides).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICK="${REPO_ROOT}/vendor/cm059_editor/bin/editor-frontpage-tick.sh"
WIKI_RECOMPILE_LABEL="com.creativemachines.ostler.wiki-recompile"

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

# ── Harness: a fake install tree, plus a stub launchctl, the tick can run
#    against for real. ──────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OSTLER_DIR="${WORK}/ostler"
SOURCE_DIR="${WORK}/cm059-editor"
STUB_BIN="${WORK}/stubbin"
mkdir -p "${OSTLER_DIR}/editor" "${OSTLER_DIR}/bin" "${SOURCE_DIR}/compiler" "$STUB_BIN"

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

# Stub launchctl: records every invocation verbatim instead of touching
# real launchd. Placed ahead of the real one on PATH.
LAUNCHCTL_CALLS="${WORK}/launchctl_calls.log"
: > "$LAUNCHCTL_CALLS"
cat > "${STUB_BIN}/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${LAUNCHCTL_CALLS}"
exit 0
EOF
chmod +x "${STUB_BIN}/launchctl"

run_tick() {
    OSTLER_DIR="$OSTLER_DIR" OSTLER_RESOURCE_GOVERNOR=0 \
        PYTHONPYCACHEPREFIX="${WORK}/pycache" \
        OXIGRAPH_URL="http://127.0.0.1:7878" \
        PATH="${STUB_BIN}:${PATH}" \
        bash -c '
            set -e
            TICK="$1"; SRC="$2"; PY="$3"
            sed -e "s#__OSTLER_PYTHON__#${PY}#" -e "s#__OSTLER_SOURCE_DIR__#${SRC}#" "$TICK" > "'"$WORK"'/rendered-tick.sh"
            chmod +x "'"$WORK"'/rendered-tick.sh"
            "'"$WORK"'/rendered-tick.sh"
        ' _ "$TICK" "$SOURCE_DIR" "$PY_BIN"
}

kickstart_count() {
    grep -c "kickstart .*${WIKI_RECOMPILE_LABEL}" "$LAUNCHCTL_CALLS" 2>/dev/null || true
}

# ── 1. First tick, front_page.json present: no prior hash on record, so
#       this must count as "changed" and trigger exactly one kickstart. ───
printf '{"cards":[{"id":"card_aaa"}]}' > "${OSTLER_DIR}/editor/front_page.json"
run_tick
_n1="$(kickstart_count)"
if [ "$_n1" = "1" ]; then
    ok "first tick (no prior hash on record) kickstarts ${WIKI_RECOMPILE_LABEL} exactly once"
else
    bad "first tick kickstarted it ${_n1} time(s), wanted 1 -- log: $(cat "$LAUNCHCTL_CALLS")"
fi

# ── 2. Second tick, UNCHANGED front_page.json: must NOT trigger again. ────
run_tick
_n2="$(kickstart_count)"
if [ "$_n2" = "$_n1" ]; then
    ok "unchanged front_page.json does not re-kickstart (daily cadence left alone)"
else
    bad "unchanged content still kickstarted it: count went ${_n1} -> ${_n2}"
fi

# ── 3. Third tick, front_page.json CHANGED: must trigger again -- this is
#       the coordinator's required test, "feed written after the compile ->
#       the page reflects it within one tick". ────────────────────────────
printf '{"cards":[{"id":"card_bbb"}]}' > "${OSTLER_DIR}/editor/front_page.json"
run_tick
_n3="$(kickstart_count)"
if [ "$_n3" = "$((_n2 + 1))" ]; then
    ok "feed written after the last compile kickstarts a recompile within one tick"
else
    bad "changed content did not kickstart it again: count stayed at ${_n3}, wanted $((_n2 + 1))"
fi

# ── 4. It is launchd being asked, never a forked child of this process. ───
# This is the actual defect Archie's review caught: a direct fork of
# wiki-recompile-tick.sh is a child of THIS script, and this plist has no
# AbandonProcessGroup, so launchd would kill it the instant this tick exits.
if grep -qE '\(\s*"\$WIKI_TICK"|\bWIKI_TICK=.*wiki-recompile-tick\.sh' "$TICK"; then
    bad "the tick still forks wiki-recompile-tick.sh directly -- launchd will kill it on exit (v1.0.107 shape), it must use launchctl kickstart instead"
else
    ok "the tick does not fork wiki-recompile-tick.sh as a child (no AbandonProcessGroup on this plist)"
fi
if grep -q 'launchctl kickstart' "$TICK"; then
    ok "the trigger goes through launchctl kickstart (survives this process exiting)"
else
    bad "no launchctl kickstart call found -- how is the recompile actually triggered?"
fi

# ── 5. The front-page emit itself is untouched by this change. ────────────
if grep -q 'compiler\.emit_frontpage' "$TICK"; then
    ok "the front-page emit is still invoked (Step 3 is additive, not a replacement)"
else
    bad "compiler.emit_frontpage is GONE -- unrelated regression"
fi

# ── 6. Syntax ───────────────────────────────────────────────────────────
if bash -n "$TICK" 2>/dev/null; then
    ok "tick parses under bash -n"
else
    bad "tick has a SYNTAX ERROR -- it would never run at all"
fi

# ── 7. NEGATIVE CONTROL ────────────────────────────────────────────────
# Prove limb 3 can actually return FAIL. Mutate a copy so the trigger never
# fires (force the hash comparison false) and re-run the same scenario.
# If it still "passes", the predicate measures nothing.
_mutant="${WORK}/mutant-tick.sh"
sed 's/\[ "\$_new_hash" != "\$_old_hash" \]/[ 1 -eq 0 ]/' "$TICK" > "$_mutant"
chmod +x "$_mutant"
if grep -q '\[ 1 -eq 0 \]' "$_mutant"; then
    : > "$LAUNCHCTL_CALLS"
    printf '{"cards":[{"id":"card_ccc"}]}' > "${OSTLER_DIR}/editor/front_page.json"
    rm -f "${OSTLER_DIR}/state/wiki-recompile-last-frontpage.sha256"
    OSTLER_DIR="$OSTLER_DIR" OSTLER_RESOURCE_GOVERNOR=0 \
        PYTHONPYCACHEPREFIX="${WORK}/pycache" \
        PATH="${STUB_BIN}:${PATH}" \
        bash -c '
            set -e
            sed -e "s#__OSTLER_PYTHON__#'"$PY_BIN"'#" -e "s#__OSTLER_SOURCE_DIR__#'"$SOURCE_DIR"'#" "'"$_mutant"'" > "'"$WORK"'/rendered-mutant.sh"
            chmod +x "'"$WORK"'/rendered-mutant.sh"
            "'"$WORK"'/rendered-mutant.sh"
        '
    _nm="$(kickstart_count)"
    if [ "$_nm" = "0" ]; then
        ok "negative control: a tick whose change-check is forced false never kickstarts a recompile"
    else
        bad "negative control DID NOT FIRE: the mutant still kickstarted it ${_nm} time(s), so limb 3 proves nothing"
    fi
else
    bad "negative control could not be constructed -- the hash-comparison line has moved; update this test's sed pattern"
fi

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
