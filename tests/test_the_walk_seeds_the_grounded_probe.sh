#!/usr/bin/env bash
# tests/test_the_walk_seeds_the_grounded_probe.sh
# ============================================================================
# assistant_answers_grounded is BLOCKING, and its content assertion exists only
# when OSTLER_GATE_KNOWN_PERSON and OSTLER_GATE_EXPECT_FACT are set. Nothing in
# the walk set them, so the probe ran against an empty graph with no fixture:
# the configuration recorded FAILED in walks/v1.0.74.tsv. It has passed once,
# on v1.0.75, and only because the seed was run by hand first.
#
# scripts/box_walk_probes/lib/grounding_seed.sh closes that. This test pins the
# two things that make it worth having:
#
#   1. IT IS WIRED. The runner sources the lib and calls it ABOVE the phase-2
#      measurement loop, and calls the forget step below it. A lib nothing
#      invokes is the "unwired" case the directive names, and it would look
#      exactly like this one from the file alone.
#   2. A SEED THAT DID NOT WORK DOES NOT LOOK LIKE A PRODUCT DEFECT. The gate
#      values are exported ONLY on loader exit 0. On exit 1, exit 2, a missing
#      oracle, a pre-fix oracle, or an explicit skip, nothing is exported and
#      the reason is printed, so the probe runs unseeded and the walk says why.
#
# The loader is stubbed. This test is about the WIRING and the three-outcome
# discipline, not about whether OS003's loader can talk to a daemon: that is
# load_seed.py's own --self-test, and stubbing it here is what makes these arms
# deterministic and runnable with no box.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/box_walk_probes/lib/grounding_seed.sh"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"

PASS=0
FAIL=0
arm() { # $1 = label, $2 = condition already evaluated (0/1), $3 = detail on failure
    if [ "$2" -eq 0 ]; then
        printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s\n' "$1"; printf '%s\n' "$3" | sed 's/^/         /'; FAIL=$((FAIL + 1))
    fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$LIB" ] || { printf 'CANNOT-RUN: no lib at %s\n' "$LIB"; exit 78; }
[ -f "$RUNNER" ] || { printf 'CANNOT-RUN: no runner at %s\n' "$RUNNER"; exit 78; }

# A stand-in for OS003 gates/seed. $2 is the exit code the loader returns; the
# marker string is what _gs_loader_is_current looks for, so `--stale` produces
# exactly the pre-fix shape the guard exists to refuse.
make_seed_dir() { # $1 dir, $2 rc, $3 known_person, $4 expect_fact, $5 optional --stale
    mkdir -p "$1"
    if [ "${5:-}" = "--stale" ]; then
        cat > "$1/load_seed.py" <<PY
import sys
# pre-fix loader: writes a vault note, never touches the product write route
sys.stderr.write("SEED-LOAD FAIL: not queryable after 180s\n")
sys.exit($2)
PY
    else
        cat > "$1/load_seed.py" <<PY
import sys
# current loader marker: POST /api/v1/memory/assert
open("$1/RAN", "w").write(" ".join(sys.argv[1:]))
sys.stderr.write("stub loader says: rc=$2\n")
sys.exit($2)
PY
    fi
    cat > "$1/seed_fixture.json" <<JSON
{"person": {"display_name": "$3", "slug": "stub"},
 "gate": {"known_person": "$3", "expect_fact": "$4"}}
JSON
}

# Source the lib in a child shell, call the step, and report what it exported.
# OSTLER_BOX_HOST empty means "this machine", so the stub runs locally.
run_apply() { # $1 = lib to source, rest = env assignments
    local lib="$1"; shift
    env -u OSTLER_GATE_KNOWN_PERSON -u OSTLER_GATE_EXPECT_FACT \
        -u OSTLER_SEED_SKIP -u OSTLER_SEED_DIR \
        OSTLER_BOX_HOST= "$@" \
        bash -c '
            . "$1"
            grounding_seed_apply
            printf "RC=%s\n" "$?"
            printf "STATE=%s\n" "${GROUNDING_SEED_STATE}"
            printf "KP=[%s]\n" "${OSTLER_GATE_KNOWN_PERSON:-}"
            printf "EF=[%s]\n" "${OSTLER_GATE_EXPECT_FACT:-}"
        ' _ "$lib" 2>&1
}

printf 'THE WALK SEEDS THE GROUNDED PROBE\n\n'

# ---------------------------------------------------------------------------
printf -- '-- 1. it is wired into the runner, in the right order --\n'
# ---------------------------------------------------------------------------
src_line="$(grep -n 'lib/grounding_seed.sh' "$RUNNER" | head -1 | cut -d: -f1)"
apply_line="$(grep -n '^grounding_seed_apply' "$RUNNER" | head -1 | cut -d: -f1)"
forget_line="$(grep -n '^grounding_seed_forget' "$RUNNER" | head -1 | cut -d: -f1)"
# The phase-2 loop is the one that runs each probe for real.
loop_line="$(grep -n '^    out="$(bash "$p" 2>&1)"' "$RUNNER" | head -1 | cut -d: -f1)"

[ -n "$src_line" ] && [ -n "$apply_line" ]
arm "the runner sources the lib and calls grounding_seed_apply" $? \
    "source line='$src_line' apply line='$apply_line'"

[ -n "$loop_line" ] && [ -n "$apply_line" ] && [ "$apply_line" -lt "$loop_line" ]
arm "the seed runs BEFORE the phase-2 probe loop (a seed after it seeds nothing)" $? \
    "apply at $apply_line, probe loop at $loop_line"

[ -n "$forget_line" ] && [ -n "$loop_line" ] && [ "$forget_line" -gt "$loop_line" ]
arm "the forget step runs AFTER the loop, so it cannot change a verdict" $? \
    "forget at $forget_line, probe loop at $loop_line"

# ---------------------------------------------------------------------------
printf -- '\n-- 2. loader exit 0: the gate values are exported, FROM THE FIXTURE --\n'
# ---------------------------------------------------------------------------
D0="$WORK/ok"; make_seed_dir "$D0" 0 "Jane Doe" "cable engineer at example.com"
out="$(run_apply "$LIB" OSTLER_SEED_DIR="$D0")"
grep -q 'RC=0' <<< "$out" && grep -q 'STATE=seeded' <<< "$out" \
    && grep -q 'KP=\[Jane Doe\]' <<< "$out" \
    && grep -q 'EF=\[cable engineer at example.com\]' <<< "$out"
arm "exit 0 exports both gate values" $? "$out"

[ -f "$D0/RAN" ]
arm "the loader actually ran, and was handed the fixture path" $? \
    "no RAN sentinel in $D0"

# A DIFFERENT fixture must produce DIFFERENT exports, or the assertion above
# would also pass against hardcoded values.
D1="$WORK/other"; make_seed_dir "$D1" 0 "Sam Patel" "harbour pilot at example.com"
out1="$(run_apply "$LIB" OSTLER_SEED_DIR="$D1")"
grep -q 'KP=\[Sam Patel\]' <<< "$out1" && grep -q 'EF=\[harbour pilot at example.com\]' <<< "$out1"
arm "the exported values come from the fixture, not from the script" $? "$out1"

# ---------------------------------------------------------------------------
printf -- '\n-- 3. a seed that did not work exports NOTHING --\n'
# ---------------------------------------------------------------------------
D2="$WORK/absentfact"; make_seed_dir "$D2" 1 "Jane Doe" "cable engineer at example.com"
out2="$(run_apply "$LIB" OSTLER_SEED_DIR="$D2")"
grep -q 'STATE=failed' <<< "$out2" && grep -q 'KP=\[\]' <<< "$out2" && grep -q 'EF=\[\]' <<< "$out2"
arm "loader exit 1 (fact not readable) exports nothing" $? "$out2"
grep -q 'not readable' <<< "$out2"
arm "and it says the person reached the graph but the fact did not" $? "$out2"

D3="$WORK/cannotrun"; make_seed_dir "$D3" 2 "Jane Doe" "cable engineer at example.com"
out3="$(run_apply "$LIB" OSTLER_SEED_DIR="$D3")"
grep -q 'STATE=failed' <<< "$out3" && grep -q 'KP=\[\]' <<< "$out3"
arm "loader exit 2 exports nothing" $? "$out3"
grep -q 'CANNOT-RUN' <<< "$out3"
arm "and it is named CANNOT-RUN, not FAIL" $? "$out3"

# ---------------------------------------------------------------------------
printf -- '\n-- 4. the oracle is missing, stale, or waived --\n'
# ---------------------------------------------------------------------------
out4="$(run_apply "$LIB" OSTLER_SEED_DIR="$WORK/nothing-here")"
grep -q 'STATE=absent' <<< "$out4" && grep -q 'KP=\[\]' <<< "$out4" && grep -q 'OSTLER_SEED_DIR' <<< "$out4"
arm "a missing oracle exports nothing and names the variable that fixes it" $? "$out4"

D5="$WORK/stale"; make_seed_dir "$D5" 0 "Jane Doe" "cable engineer at example.com" --stale
out5="$(run_apply "$LIB" OSTLER_SEED_DIR="$D5")"
grep -q 'STATE=absent' <<< "$out5" && grep -q 'KP=\[\]' <<< "$out5" && grep -q 'PRE-FIX' <<< "$out5"
arm "a PRE-FIX loader is refused rather than run to a timeout" $? "$out5"

out6="$(run_apply "$LIB" OSTLER_SEED_DIR="$D0" OSTLER_SEED_SKIP=1)"
grep -q 'STATE=skipped' <<< "$out6" && grep -q 'KP=\[\]' <<< "$out6"
arm "OSTLER_SEED_SKIP=1 seeds nothing and says the probe will run unseeded" $? "$out6"

# ---------------------------------------------------------------------------
printf -- '\n-- 5. an operator who set the gate values keeps them --\n'
# ---------------------------------------------------------------------------
D7="$WORK/override"; make_seed_dir "$D7" 0 "Jane Doe" "cable engineer at example.com"
out7="$(env OSTLER_BOX_HOST= OSTLER_SEED_DIR="$D7" \
    OSTLER_GATE_KNOWN_PERSON="A Real Contact" \
    OSTLER_GATE_EXPECT_FACT="a fact this box already holds" \
    bash -c '. "$1"; grounding_seed_apply; printf "RC=%s\n" "$?"; printf "KP=[%s]\n" "${OSTLER_GATE_KNOWN_PERSON:-}"' _ "$LIB" 2>&1)"
grep -q 'KP=\[A Real Contact\]' <<< "$out7"
arm "operator-set gate values are not overwritten" $? "$out7"
[ ! -f "$D7/RAN" ]
arm "and the loader is not run at all in that case" $? "the RAN sentinel exists in $D7"

# ---------------------------------------------------------------------------
printf -- '\n-- 6. MUTATION: with the exports removed, arm 2 must fail --\n'
# ---------------------------------------------------------------------------
# Arm 2 is the load-bearing assertion. If it would pass against a lib that
# exports nothing, it is not measuring the wiring at all.
MUT="$WORK/mutant.sh"
sed 's/^        export OSTLER_GATE_KNOWN_PERSON=.*$/        : ;/; s/^        export OSTLER_GATE_EXPECT_FACT=.*$/        : ;/' "$LIB" > "$MUT"
# NO PIPE INTO A SHORT-CIRCUITING CONSUMER. `grep -c x | grep -q '^0$'` exits
# non-zero under pipefail precisely when the count IS zero, which is the state
# this arm exists to assert. Count into a variable, then compare it.
mut_left="$(grep -c '^        export OSTLER_GATE' "$MUT" || true)"
[ "$mut_left" = "0" ]
arm "the mutant really has the export lines removed (the injection landed)" $? \
    "still present: $mut_left line(s)"

D8="$WORK/mutcheck"; make_seed_dir "$D8" 0 "Jane Doe" "cable engineer at example.com"
outm="$(run_apply "$MUT" OSTLER_SEED_DIR="$D8")"
grep -q 'KP=\[Jane Doe\]' <<< "$outm"
if [ $? -ne 0 ]; then mut_rc=0; else mut_rc=1; fi
arm "MUST-FAIL: the mutant exports nothing, so arm 2 is a real assertion" "$mut_rc" \
    "the mutant still exported the gate values: $outm"

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
