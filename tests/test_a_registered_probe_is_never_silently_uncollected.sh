#!/usr/bin/env bash
# tests/test_a_registered_probe_is_never_silently_uncollected.sh
# ============================================================================
# A REGISTERED PROBE THE WALK CANNOT COLLECT MUST BE NAMED, NEVER OMITTED.
#
# WHY THIS EXISTS (CM051 row 1152).
#
# Two registers decide what a cut believes it measured, and until now nothing
# compared them:
#
#   scripts/box_walk_probes/probes/*.sh    what run_box_walk.sh actually runs
#   cut-manifests/permanent.yaml           what the cut says is a box_walk_probe
#
# MEASURED on origin/main at 923c5067, by parsing the YAML rather than grepping:
#   registered 29, collected 28, registered-and-not-collected 1, and the one is
#   acceptance_gate_v1013. The runner printed nothing about it, ever. It is not
#   in the four numbers, not in the NOT MEASURED block, and therefore not in
#   walks/<version>.tsv, whose own `measured N of N` line claims those buckets
#   "partition the suite".
#
# THE PERSON THIS IS ABOUT. Andy reads walks/v1.0.NN.tsv and decides whether to
# ship. "measured 26 of 26" told him the suite was whole. The suite was the
# glob, the register was wider, and the difference was printed nowhere, so the
# denominator he was deciding on was smaller than the one he was shown.
#
# WHAT THE RUNNER NOW HAS TO DO, and what each arm below drives:
#   registered + collected      graded as before, four numbers unchanged
#   registered + not collected  NAMED, with the reason and a denominator:
#       ... but resolvable beside the runner   graded by the cut manifest in
#                                              phase 2, so NOT counted as
#                                              CANNOT-RUN (that would be a
#                                              false not-measured about a
#                                              probe phase 2 runs minutes
#                                              later in the same suite)
#       ... resolvable by nothing              CANNOT-RUN, counted, named
#   register absent, unreadable, or yielding
#   zero names                  CANNOT-RUN for the cross-check, stated in the
#                               REGISTER line, never "nothing missing"
#
# WHY THE GATE THAT LOOKS LIKE THIS ONE DOES NOT COVER IT.
# tests/test_no_probe_lives_outside_the_walk_glob.sh asks the same question
# from the directory side, and it passes green today. Its predicate for "a
# probe" is a file matching ^PROBE_NAME=, and acceptance_gate_v1013.sh declares
# no PROBE_NAME at all, by design: its own header says it is deliberately not
# probe-shaped. So that gate reports "0 probe-shaped files outside the glob"
# while a registered probe sits outside the glob. Its denominator excludes its
# own subject, which is why its zero is true and useless here.
# (Measured in passing, and NOT fixed here: the same predicate counts 27 of the
# 28 files in probes/, because probes/the_recovery_key_reached_the_customer.sh
# also declares no PROBE_NAME. It is collected and does run; only that gate's
# floor undercounts.)
#
# This gate starts from the REGISTER instead, so PROBE_NAME plays no part in it.
#
# Exit 0 pass, 1 fail, 2 cannot-run. bash 3.2 and bash 5 both.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"
REAL_REGISTRY="$REPO/cut-manifests/permanent.yaml"
PROBES_DIR="$REPO/scripts/box_walk_probes/probes"
QA="$REPO/scripts/post_walk_qa.sh"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
cant() { printf '  CANNOT-RUN  %s\n' "$1"; printf 'VERDICT: CANNOT-RUN, nothing was measured\n'; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf 'A REGISTERED PROBE IS NEVER SILENTLY UNCOLLECTED\n'
printf '================================================\n'

[ -r "$RUNNER" ]        || cant "no runner at $RUNNER"
[ -r "$REAL_REGISTRY" ] || cant "no register at $REAL_REGISTRY"
[ -d "$PROBES_DIR" ]    || cant "no probe directory at $PROBES_DIR"

# A probe that certainly exists, used as the --only selector so every run below
# is one probe long. Taken from the directory rather than named, so this test
# does not rot when probes are renamed.
SELECTOR="$(ls "$PROBES_DIR"/*.sh 2>/dev/null | head -1 | sed 's|.*/||; s|\.sh$||')"
[ -n "$SELECTOR" ] || cant "the probe directory is empty, so there is nothing to select"

N_COLLECTED="$(ls "$PROBES_DIR"/*.sh 2>/dev/null | wc -l | tr -d ' ')"
N_REGISTERED="$(sed -n 's/^[[:space:]]*probe:[[:space:]]*"\{0,1\}\([A-Za-z0-9._-][A-Za-z0-9._-]*\)"\{0,1\}[[:space:]]*$/\1/p' \
    "$REAL_REGISTRY" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
printf 'DENOMINATORS: %s probe file(s) collected by the glob, %s name(s) registered in permanent.yaml\n' \
    "$N_COLLECTED" "$N_REGISTERED"
[ "$N_REGISTERED" -gt 0 ] || cant "extracted ZERO registered names from the real register, so this test cannot tell a missing probe from a broken reader"
[ "$N_COLLECTED" -gt 0 ]  || cant "the glob collects nothing, so there is no suite to compare against"

# The registered names that have no file in probes/. Computed here
# independently of the runner, so the arms below compare two readers rather
# than asking the subject to confirm itself.
UNCOLLECTED_EXPECTED=""
for r in $(sed -n 's/^[[:space:]]*probe:[[:space:]]*"\{0,1\}\([A-Za-z0-9._-][A-Za-z0-9._-]*\)"\{0,1\}[[:space:]]*$/\1/p' \
           "$REAL_REGISTRY" | LC_ALL=C sort -u); do
    [ -f "$PROBES_DIR/$r.sh" ] && continue
    UNCOLLECTED_EXPECTED="$UNCOLLECTED_EXPECTED $r"
done
printf 'REGISTERED BUT NOT COLLECTED (independent reader):%s\n\n' "${UNCOLLECTED_EXPECTED:- none}"

list_run() { # $1 = register path or empty for the real one
    if [ -n "${1:-}" ]; then
        OSTLER_BOX_WALK_REGISTRY="$1" /bin/bash "$RUNNER" --list --only "$SELECTOR" 2>&1
    else
        /bin/bash "$RUNNER" --list --only "$SELECTOR" 2>&1
    fi
}

# ===== ARM 1: every uncollected registered probe is NAMED, with a control ===
out="$(list_run "")"
if [ -z "$UNCOLLECTED_EXPECTED" ]; then
    ok "arm 1: the register and the glob agree, so there is nothing to name (registered=$N_REGISTERED)"
else
    missing=""
    for r in $UNCOLLECTED_EXPECTED; do
        case "$out" in *"$r"*) ;; *) missing="$missing $r" ;; esac
    done
    if [ -n "$missing" ]; then
        bad "arm 1: the runner named none of:$missing" "a registered probe the glob cannot collect is invisible to whoever reads the walk"
    else
        ok "arm 1: every registered-but-uncollected probe is named in the runner's own output:$UNCOLLECTED_EXPECTED"
    fi
fi
# POSITIVE CONTROL, same corpus, same reader: a probe that IS collected also
# appears. Without this, a runner that printed nothing at all would pass arm 1
# whenever the register happened to agree with the glob.
case "$out" in
    *"$SELECTOR"*) ok "arm 1 control: the collected probe $SELECTOR is present in the same output, so the reader can see a name when there is one" ;;
    *) bad "arm 1 control: $SELECTOR is absent from the output too" "the output was not captured, so arm 1 proved nothing" ;;
esac

# ===== ARM 2: the REGISTER line states a denominator, and it is the right one
case "$out" in
    *"read $N_REGISTERED registered probe"*)
        ok "arm 2: the REGISTER line states the register's own denominator ($N_REGISTERED)" ;;
    *)
        bad "arm 2: no REGISTER line stating $N_REGISTERED registered probes" "$(printf '%s' "$out" | head -3)" ;;
esac

# ===== ARM 3: a registered probe resolvable by NOTHING is flagged ===========
# The planted register names a probe that exists in neither directory. This is
# the regression that matters: a rename or a deletion that leaves the row
# behind, which no instrument can then resolve.
# The name CONTAINS the selector on purpose. Only the unresolvable bucket
# honours --only (it is the bucket that enters the four numbers, and --only
# scopes the run), so a ghost the selector does not match would be filtered out
# and this arm would pass without ever driving the code it is aimed at.
GHOST="${SELECTOR}_that_exists_nowhere_$$"
cat > "$TMP/ghost.yaml" <<YEOF
entries:
  - id: planted
    proof:
      kind: box_walk_probe
      probe: "$GHOST"
YEOF
out3="$(list_run "$TMP/ghost.yaml")"
case "$out3" in
    *"$GHOST"*"resolvable by NOTHING"*)
        ok "arm 3: a registered probe with no file anywhere is flagged as resolvable by nothing" ;;
    *)
        bad "arm 3: the ghost row was not flagged" "$(printf '%s' "$out3" | head -4)" ;;
esac

# ===== ARM 4: and it is COUNTED, not merely mentioned =======================
# Differential, so the arm does not depend on how the other probes fare on
# whatever machine this runs on: the same selector, twice, with and without the
# ghost row.
base="$(/bin/bash "$RUNNER" --only "$SELECTOR" 2>&1)"
ghost_run="$(OSTLER_BOX_WALK_REGISTRY="$TMP/ghost.yaml" /bin/bash "$RUNNER" --only "$SELECTOR" 2>&1)"
count_of() { printf '%s\n' "$2" | awk -v k="$1" '$1 == k && NF == 2 && $2 ~ /^[0-9]+$/ { print $2; exit }'; }
c_base="$(count_of 'CANNOT-RUN' "$base")"
c_ghost="$(count_of 'CANNOT-RUN' "$ghost_run")"
p_base="$(printf '%s\n' "$base" | awk '$1 == "of" && NF == 3 && $3 == "probes" { print $2; exit }')"
p_ghost="$(printf '%s\n' "$ghost_run" | awk '$1 == "of" && NF == 3 && $3 == "probes" { print $2; exit }')"
if [ -z "$c_base" ] || [ -z "$c_ghost" ] || [ -z "$p_base" ] || [ -z "$p_ghost" ]; then
    cant "could not parse the four-number summary from a run (cannot-run base='$c_base' ghost='$c_ghost', probes base='$p_base' ghost='$p_ghost')"
fi
printf '  measured: CANNOT-RUN %s then %s, probe total %s then %s\n' "$c_base" "$c_ghost" "$p_base" "$p_ghost"
if [ "$c_ghost" -eq "$((c_base + 1))" ] && [ "$p_ghost" -eq "$((p_base + 1))" ]; then
    ok "arm 4: the unresolvable probe adds one CANNOT-RUN and one to the denominator, so the buckets still partition the suite"
else
    bad "arm 4: counts did not move by exactly one" "cannot-run $c_base to $c_ghost, probes $p_base to $p_ghost"
fi
case "$ghost_run" in
    *"NOT MEASURED"*"$GHOST"*)
        ok "arm 4b: it is listed under NOT MEASURED, which is the block scripts/post_walk_qa.sh turns into not_measured_probe rows" ;;
    *)
        bad "arm 4b: absent from the NOT MEASURED block, so it would never reach walks/<version>.tsv" ;;
esac

# ===== ARM 5: refusal states, none of which may read as "nothing missing" ===
for state in absent empty; do
    case "$state" in
        absent) reg="$TMP/there-is-no-such-file.yaml" ;;
        empty)  reg="$TMP/empty.yaml"; printf 'entries: []\n' > "$reg" ;;
    esac
    outr="$(list_run "$reg")"
    case "$outr" in
        *"CANNOT-RUN"*)
            ok "arm 5 ($state register): the cross-check refuses out loud" ;;
        *)
            bad "arm 5 ($state register): no CANNOT-RUN in the REGISTER line" "$(printf '%s' "$outr" | head -3)" ;;
    esac
    case "$outr" in
        *"0 resolvable by neither"*)
            bad "arm 5 ($state register): it reported a clean cross-check over a register it could not read" \
                "'could not look' and 'found nothing' printed the same words, which is the defect this suite exists to refuse" ;;
        *)
            ok "arm 5 ($state register): it does not claim a clean cross-check" ;;
    esac
done

# ===== ARM 6: the phase 1 record must never REPLACE a probe's only real run =
# verify_cut_manifest.py takes a phase 1 verdict only for probes run_box_walk.sh
# marks seed-fixture. acceptance_gate_v1013 is graded ONLY by its manifest row,
# so listing it as seed-dependent would delete the single run it gets.
seedline="$(sed -n 's/^SEED_DEPENDENT_PROBES="\(.*\)"$/\1/p' "$RUNNER")"
if [ -z "$seedline" ]; then
    cant "could not read SEED_DEPENDENT_PROBES out of the runner, so this arm measured nothing"
fi
bad_seed=""
for r in $UNCOLLECTED_EXPECTED; do
    case " $seedline " in *" $r "*) bad_seed="$bad_seed $r" ;; esac
done
if [ -n "$bad_seed" ]; then
    bad "arm 6:$bad_seed is uncollected AND marked seed-dependent" \
        "verify_cut_manifest.py would take the phase 1 verdict and skip the only run this probe gets"
else
    ok "arm 6: no uncollected probe is marked seed-dependent, so its cut-manifest row still measures independently (seed list: $seedline)"
fi

# ===== ARM 7: the walk record must not be polluted ==========================
# scripts/post_walk_qa.sh lifts names out of "FAILED:", "NOT MEASURED" and
# "BROKEN (" with index($0, hdr) == 1 and a bare-name pattern. The new block
# must land in none of them: a delegated probe is not a failure and did not
# fail to be measured.
if [ ! -r "$QA" ]; then
    cant "no post_walk_qa.sh at $QA, so the record-pollution arm could not run"
fi
section_names() {
    printf '%s\n' "$1" | awk -v hdr="$2" '
        index($0, hdr) == 1 { grab = 1; next }
        grab && $0 ~ /^[[:space:]]*$/ { exit }
        grab && $0 ~ /^  [A-Za-z0-9._-]+$/ { sub(/^  /, ""); print; next }
        grab { exit }'
}
polluted=""
for hdr in 'FAILED:' 'NOT MEASURED' 'BROKEN ('; do
    names="$(section_names "$base" "$hdr")"
    for r in $UNCOLLECTED_EXPECTED; do
        case " $(printf '%s' "$names" | tr '\n' ' ') " in
            *" $r "*) polluted="$polluted $r/$hdr" ;;
        esac
    done
done
if [ -n "$polluted" ]; then
    bad "arm 7: a delegated probe reached a walk-record section:$polluted" \
        "walks/<version>.tsv would carry a failed_probe or not_measured_probe row for a probe the cut manifest grades"
else
    ok "arm 7: no delegated probe leaks into the FAILED / NOT MEASURED / BROKEN sections post_walk_qa.sh publishes"
fi

printf '\n================================================\n'
printf 'RESULT: %s pass / %s fail (of %s assertions)\n' "$pass" "$fail" "$((pass + fail))"
[ "$fail" -eq 0 ] || exit 1
exit 0
