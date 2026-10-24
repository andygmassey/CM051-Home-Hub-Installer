#!/usr/bin/env bash
# Walk #27 shape sweep S7c: the walk's forgets ran only on the normal path, so
# an aborted walk kept everything it seeded. run_box_walk.sh must run every
# forget and the companion unpair from a trap, once, on abort and on a normal
# finish. This test lifts the REAL cleanup block (walk_cleanup and its traps)
# out of run_box_walk.sh, stubs each forget to record its call, and kills the
# script mid-walk. Runs under bash 3.2.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${REPO_ROOT}/scripts/box_walk_probes/run_box_walk.sh"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
echo "test_walk_cleanup_runs_on_abort"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

BLOCK="$(awk '/^WALK_CLEANUP_DONE=0$/{f=1} f{print} /^trap .exit 143. TERM$/{exit}' "$RUNNER")"
if [ -z "$BLOCK" ]; then
    bad "run_box_walk.sh has no walk_cleanup block run from a trap"
    echo "  $pass passed, $fail failed"; exit 1
fi
FORGETS="grounding_seed_forget preference_seed_forget conversation_seed_forget usage_seed_forget owner_employer_seed_forget conversation_capture_seed_forget scale_fixture_forget contact_cards_forget companion_walk_unpair"

# The normal path calls the same forgets flush left (other tests pin those
# lines) and then marks the cleanup done; the two lists must match.
NORMAL="$(awk '/^grounding_seed_forget \|\| true$/{f=1} f{print} /^WALK_CLEANUP_DONE=1$/{exit}' "$RUNNER")"
missing=""
for f in $FORGETS; do grep -q "^${f} || true$" <<< "$NORMAL" || missing="$missing $f"; done
if [ -n "$NORMAL" ] && [ -z "$missing" ] && grep -qx 'WALK_CLEANUP_DONE=1' <<< "$NORMAL"; then
    ok "the normal end runs the same forgets as the trap, then marks the cleanup done"
else
    bad "the normal end and the trap differ (missing on the normal path:${missing:- none}, or no WALK_CLEANUP_DONE=1)"
fi

make_script() {  # $1 = how the walk ends: abort | normal ; $2 READ_ONLY
    {
        echo 'set -uo pipefail'
        echo "READ_ONLY=$2"
        echo "CALLS='${WORK}/calls.$1.$2'"
        for f in $FORGETS; do echo "$f() { echo $f >> \"\$CALLS\"; }"; done
        printf '%s\n' "$BLOCK"
        echo 'TMPF="$(mktemp)"; WALK_TEMP_FILES="$TMPF"; echo "$TMPF" > "$CALLS.tmpf"'
        if [ "$1" = abort ]; then
            echo 'kill -TERM $$; sleep 5; echo "survived the abort" >> "$CALLS"'
        else
            for f in $FORGETS; do echo "$f"; done; echo 'WALK_CLEANUP_DONE=1'; echo 'exit 0'
        fi
    } > "${WORK}/walk.$1.$2.sh"
}

for mode in abort normal; do
    make_script "$mode" 0
    bash "${WORK}/walk.${mode}.0.sh" >/dev/null 2>&1
    calls="${WORK}/calls.${mode}.0"
    missing=""
    for f in $FORGETS; do
        n="$(grep -cx "$f" "$calls" 2>/dev/null || true)"
        [ "$n" = "1" ] || missing="$missing $f(x${n:-0})"
    done
    if [ -z "$missing" ]; then ok "$mode: every forget and the unpair ran exactly once"; else bad "$mode: not run exactly once:$missing"; fi
    if [ -f "$(cat "${calls}.tmpf" 2>/dev/null)" ]; then bad "$mode: the walk's temp files were left behind"; else ok "$mode: the walk's temp files are removed by the same trap"; fi
done
if grep -q "survived the abort" "${WORK}/calls.abort.0" 2>/dev/null; then bad "the walk kept running after TERM"; else ok "TERM ends the walk"; fi

make_script abort 1
bash "${WORK}/walk.abort.1.sh" >/dev/null 2>&1
if [ ! -s "${WORK}/calls.abort.1" ]; then ok "read-only: an aborted walk writes nothing"; else bad "read-only abort ran: $(tr '\n' ' ' < "${WORK}/calls.abort.1")"; fi

# Control: the same harness on a block whose trap is removed must go red.
BLOCK="$(printf '%s\n' "$BLOCK" | grep -v '^trap ')"
make_script abort 0
: > "${WORK}/calls.abort.0"
bash "${WORK}/walk.abort.0.sh" >/dev/null 2>&1
if grep -qx scale_fixture_forget "${WORK}/calls.abort.0"; then bad "control: forgets ran with no trap, so the abort limb proves nothing"; else ok "control: without the trap an abort runs no forget"; fi

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
