#!/usr/bin/env bash
# tests/test_the_early_pass_adds_no_assertion_the_full_pass_lacks.sh
#
# WHY: ttywalk.sh no longer runs the EARLY PASS by default (scripts/early_repeat_
# fail_pass.sh). That is only sound if every assertion it can make is also made
# by the full pass. This test LISTS BOTH SETS and compares them:
#   EARLY = every probe name the early pass is able to run: probes/<name>.sh
#           that exists and is not seed-dependent (it refuses the rest).
#   FULL  = every probe run_box_walk.sh collects in a full walk (the same
#           probes/*.sh glob, read from the runner), PLUS the seed-dependent ones.
# EARLY must be a subset of FULL. Then the only way the early pass differs is
# --read-only mode, so every probe that reads OSTLER_WALK_READ_ONLY is listed
# and must only SKIP work there (probe_cannot_run, or seed off), never assert
# something the read-write full pass does not.
# Mutation: removing one probe from FULL must turn the subset check red.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"
PROBES="$REPO/scripts/box_walk_probes/probes"
EARLY="$REPO/scripts/early_repeat_fail_pass.sh"
TTY="$REPO/scripts/ttywalk.sh"
PASS=0; FAIL=0
arm() { if [ "$2" -eq 0 ]; then echo "  [PASS] $1"; PASS=$((PASS+1)); else echo "  [FAIL] $1"; printf '%s\n' "$3" | sed 's/^/         /'; FAIL=$((FAIL+1)); fi; }

seed_dep="$(sed -n 's/^SEED_DEPENDENT_PROBES="\(.*\)"$/\1/p' "$RUNNER")"
[ -n "$seed_dep" ] || { echo "CANNOT-RUN: SEED_DEPENDENT_PROBES not readable from the runner"; exit 78; }

full_set() { for f in "$PROBES"/*.sh; do basename "$f" .sh; done | LC_ALL=C sort; }
early_set() { # what the early pass can run: exists, and not seed-dependent
    for f in "$PROBES"/*.sh; do
        b="$(basename "$f" .sh)"
        case " $seed_dep " in *" $b "*) continue ;; esac
        echo "$b"
    done | LC_ALL=C sort
}
FULL="$(full_set)"; EARLYSET="$(early_set)"
printf 'EARLY set (%s probes) and FULL set (%s probes), listed:\n' "$(wc -l <<<"$EARLYSET" | tr -d ' ')" "$(wc -l <<<"$FULL" | tr -d ' ')"
printf '%s\n' "$FULL" | sed 's/^/  full  /' | head -3; echo "  ... (full list: ls scripts/box_walk_probes/probes)"

# The runner's collection glob is the one full_set mirrors.
grep -q 'for f in "$PROBE_DIR"/\*.sh; do' "$RUNNER"; arm "the runner collects probes/*.sh (the FULL set is that glob)" $? "glob line missing"
grep -q 'PROBE_DIR="$HERE/probes"' "$RUNNER"; arm "PROBE_DIR is probes/" $? "PROBE_DIR changed"

subset() { # $1 = early list, $2 = full list; prints names in early and not in full
    comm -23 <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}
missing="$(subset "$EARLYSET" "$FULL")"
[ -z "$missing" ]; arm "EARLY is a subset of FULL: no probe the early pass can run is absent from the full pass" $? "only in early: $missing"
only_full="$(subset "$FULL" "$EARLYSET")"
echo "  in FULL only (seed-dependent, which the early pass refuses): $(echo $only_full)"
for b in $only_full; do case " $seed_dep " in *" $b "*) ;; *) arm "FULL-only probe $b is seed-dependent" 1 "$b"; esac; done

# MUTATION: drop one probe from FULL; the subset check must go red.
mut_full="$(printf '%s\n' "$FULL" | sed '1d')"
mut_missing="$(subset "$EARLYSET" "$mut_full")"
[ -n "$mut_missing" ]; arm "MUST-FAIL: with one probe removed from FULL the subset check reports it ($mut_missing)" $? "mutant not caught"

# The early pass refuses names with no probes/<name>.sh and seed-dependent ones.
grep -q 'no probes/<name>.sh\|a name with no probes' "$EARLY" && grep -q 'seed-dependent' "$EARLY"
arm "the early pass refuses unregistered names and seed-dependent probes" $? "refusal text missing"

# READ-ONLY mode can only remove assertions: the complete list of probes that
# read OSTLER_WALK_READ_ONLY, and what each does with it.
ro="$(grep -l 'OSTLER_WALK_READ_ONLY' "$PROBES"/*.sh | xargs -n1 basename | sed 's/\.sh$//' | LC_ALL=C sort | tr '\n' ' ')"
want="fda_rerun_second_tick_lands_a_new_row listener_watchdog_recovers_a_wedged_listener owner_knowledge_score "
[ "$ro" = "$want" ]; arm "exactly the 3 reviewed probes read OSTLER_WALK_READ_ONLY (a new one needs review here)" $? "got: $ro"
for b in fda_rerun_second_tick_lands_a_new_row listener_watchdog_recovers_a_wedged_listener; do
    grep -A1 'OSTLER_WALK_READ_ONLY' "$PROBES/$b.sh" | grep -q 'probe_cannot_run'
    arm "$b: read-only means CANNOT-RUN (skips), asserts nothing extra" $? "no probe_cannot_run under the read-only test"
done
grep -q 'OSTLER_OWNER_SCORE_SEED:-.*OSTLER_WALK_READ_ONLY.*echo 0 || echo 1' "$PROBES/owner_knowledge_score.sh"
arm "owner_knowledge_score: read-only means seed off (fewer writes, same probe)" $? "seed default changed"

# The full pass already runs the previous walk's failures FIRST.
grep -q 'early_repeat_fail_pass.sh" --names-only' "$RUNNER" && grep -q 'PREVIOUS FAILS FIRST' "$RUNNER"
arm "the full pass promotes the previous walk's failed probes to run first (the early signal is kept)" $? "promotion missing"

# ttywalk default, and the announcement.
grep -q '^NO_EARLY_PASS=1$' "$TTY"; arm "ttywalk: early pass OFF by default" $? "default changed"
grep -q -- '--early-pass) NO_EARLY_PASS=0' "$TTY"; arm "ttywalk: --early-pass turns it back on" $? "flag missing"
grep -q 'early-pass: DROPPED by default (change vs before' "$TTY"; arm "ttywalk: the default is announced with a 'change vs before' line" $? "announce line missing"

printf '\n== %s pass / %s fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
