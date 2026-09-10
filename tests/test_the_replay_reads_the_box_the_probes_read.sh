#!/usr/bin/env bash
# tests/test_the_replay_reads_the_box_the_probes_read.sh
#
# On the v1.0.87 record the manifest replay read people_stores_reconcile AFTER
# run_box_walk.sh had removed its synthetic person, against a wiki compiled
# with the person in it: graph 1838, vectors 1838, tile 1839, two FAIL rows,
# no defect. The walk changes the box, so the walk must recompile the artefact
# that describes the box before it hands over to the replay.
#
# Asserts, statically (the recompile needs a box; the wiring does not):
#   1. the lib defines wiki_baseline_resync and it waits for the tick's own
#      "wiki baseline published" line, counted only AFTER the kickstart;
#   2. run_box_walk.sh calls it AFTER all four *_forget calls, and the call is
#      guarded so it can never fail the walk;
#   3. CONTROL: a copy of the runner with the call removed is caught by arm 2.
#
# THREE STATES. 0 every arm held, 1 an arm failed, 78 a prerequisite is absent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/box_walk_probes/lib/wiki_summaries_wait.sh"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }
[ -r "$LIB" ] || { printf 'CANNOT-RUN: no lib at %s\n' "$LIB"; exit 78; }
[ -r "$RUNNER" ] || { printf 'CANNOT-RUN: no runner at %s\n' "$RUNNER"; exit 78; }

# The check under test, as a function, so the control can run it on a mutant.
call_after_forgets() { # $1 = runner path; prints ok|missing|before
    local f4 c
    f4="$(grep -nE '^usage_seed_forget \|\| true$' "$1" | tail -1 | cut -d: -f1)"
    c="$(grep -nE '^wiki_baseline_resync \|\| true$' "$1" | tail -1 | cut -d: -f1)"
    if [ -z "$c" ]; then echo missing
    elif [ -z "$f4" ] || [ "$c" -le "$f4" ]; then echo before
    else echo ok; fi
}

echo "== 1. the lib defines the resync and waits for the baseline line after the kickstart =="
if grep -qE '^wiki_baseline_resync\(\)' "$LIB"; then ok "wiki_baseline_resync is defined"; else bad "wiki_baseline_resync is not defined in the lib"; fi
if grep -q 'wiki baseline published' "$LIB"; then ok "it waits for the tick's own 'wiki baseline published' line"; else bad "it does not wait for the tick's baseline line"; fi
if grep -qE 'tail -n \+\$\(\(n \+ 1\)\)' "$LIB"; then ok "it counts only lines written after the kickstart, so an old baseline line cannot satisfy it"; else bad "it does not restrict the search to lines after the kickstart"; fi
if grep -qE '_ww_kickstart' "$LIB"; then ok "it kickstarts the same tick the summaries wait kickstarts"; else bad "it does not kickstart the tick"; fi

echo "== 1b. the resync's own success check cannot invert under the caller's pipefail =="
n_pipes="$(sed -n '/^wiki_baseline_resync()/,/^}/p' "$LIB" | grep -cE '\| *grep -q' || true)"
if [ "${n_pipes}" -eq 0 ]; then ok "no pipe into grep -q inside wiki_baseline_resync (a match must not read as could-not-run)"; else bad "wiki_baseline_resync pipes into grep -q ${n_pipes}x; under run_box_walk.sh's pipefail a MATCH can read as could-not-run"; fi

echo "== 2. the runner calls it after every forget, guarded =="
case "$(call_after_forgets "$RUNNER")" in
    ok)      ok "run_box_walk.sh calls wiki_baseline_resync after the fourth forget, guarded with || true" ;;
    missing) bad "run_box_walk.sh never calls wiki_baseline_resync (guarded form)" ;;
    before)  bad "wiki_baseline_resync is called BEFORE the forgets, so it recompiles the wrong box" ;;
esac

echo "== 3. CONTROL: the arm catches a runner without the call =="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
grep -vE '^wiki_baseline_resync \|\| true$' "$RUNNER" > "$WORK/mutant.sh"
if [ "$(call_after_forgets "$WORK/mutant.sh")" = "missing" ]; then ok "CONTROL: a runner with the call deleted reads 'missing'"; else bad "CONTROL: the mutant was not caught, so arm 2 proves nothing"; fi

echo
echo "== ${pass} pass / ${fail} fail / $((pass+fail)) total =="
[ "$fail" -eq 0 ]
