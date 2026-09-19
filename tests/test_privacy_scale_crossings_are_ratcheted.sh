#!/usr/bin/env bash
# THE NUMBER OF FILES THAT KNOW ABOUT BOTH PRIVACY SCALES MAY ONLY GO DOWN.
#
# ============================================================================
# WHAT THE TWO SCALES ARE, AND WHY A FILE THAT HOLDS BOTH IS THE HAZARD
# ============================================================================
#
# Ostler carries two numeric privacy scales. They run in OPPOSITE directions,
# they are BOTH spelled L<n>, and one is converted into the other.
#
#   privacy_level       L0 to L3, HIGHER is more private, L3 is hidden.
#                       FAIL-CLOSED: missing, empty or unparseable reads as L3
#                       and the record is withheld. Defined and enforced in
#                       vendor/cm041/pwg_privacy.py. A broken label HIDES data.
#
#   compartment_level   0 to 6, LOWER is more private, 0 is L0Personal.
#                       No fail-closed equivalent. Defined in
#                       vendor/cm019_preferences/services/ingest/src/parsers/base.py
#                       (_compartment_uri). A broken label EXPOSES data.
#
# vendor/cm041/contact_syncer/privacy_model.py converts between them, and its
# own comment calls the result "the inverted sense": compartments 4, 5 and 6
# all collapse onto privacy LEVEL_L2, which is publishable.
#
# THE DEFECT THIS ALREADY CAUSED. apple.py wrote compartment_level=5 at four
# sites, each commented HIGHEST PRIVACY. 5 is L5Commercial, which the map above
# resolves to publishable. A customer's Apple Health and Apple Notes were
# labelled one step from Broadcast. The full account is docs/PRIVACY_LEVELS.md.
#
# So the dangerous file is not one that uses a scale. It is one that holds BOTH,
# because that is the only place a number can be copied from a scale where it is
# nearly private onto a scale where it is nearly public, and 5 is not 5.
#
# ============================================================================
# WHY A RATCHET AND NOT A BAN
# ============================================================================
#
# Unifying, renaming or renumbering the scales is deliberately DEFERRED to
# HR015 issue #960, post-launch, because picking a direction silently re-scopes
# every privacy-filtered read in the product and both directions look like a
# working filter from the outside. Measured on this tree, the surface is 82
# files touching compartment_level and 65 touching privacy_level. Demanding
# zero crossings today is a gate that lands red, and a gate that lands red is
# a gate people route around.
#
# What CAN be held today is the count of crossing points. Three files convert
# or compare across the scales. That set is small enough to review by hand, and
# every new member of it is a new place the apple.py defect can be written
# again. This file freezes the set, names it, and fails when it grows.
#
# ============================================================================
# THE POPULATION, AND WHAT IS DELIBERATELY OUTSIDE IT
# ============================================================================
#
# Everything in the tree EXCEPT the four exclusions below. The exclusions are
# stated here and in the baseline header, and each is proved by a discriminator
# in limb 3 rather than trusted.
#
#   .git/                 not source.
#
#   tests/ and */tests/   a test that compares the two scales is the REMEDY,
#                         not the defect. tests/test_writer_reader_vocabulary_contracts.py
#                         names both on purpose, and so does this file. Counting
#                         a test would mean the only way to go green is to stop
#                         testing the thing.
#
#   docs/ and */docs/     prose cannot convert a number. docs/PRIVACY_LEVELS.md
#                         exists precisely to name both scales and warn about
#                         them; counting it would demand deleting the only
#                         document that carries the warning.
#
#   cut-manifests/        release-review registers. Measured on this tree: 27 of
#                         them mention a scale, inside multi-paragraph gate
#                         narratives QUOTING the defect. They are a record of
#                         the finding, not a site of it.
#
# NOTE WHAT IS *NOT* EXCLUDED. .github/, *.md outside docs/, *.yml, and the
# vendored LLM prompts under vendor/cm048_pipeline/prompts/ are all in the
# population. A prompt is a functional artefact and a workflow can carry an
# inline heredoc; neither gets a pass for its file extension.
#
# ============================================================================
# EXIT CODES
# ============================================================================
#
#   0  the crossing set is exactly the baselined set
#   1  the set GREW (a new crossing point), or SHRANK without the baseline
#      being lowered (slack the next regression hides in)
#   2  CANNOT-RUN: no baseline, no grep, or an empty scan. "No new crossings"
#      and "I could not look" print identically otherwise, and a gate that
#      passes on an empty scan manufactures the confidence it exists to remove.
#
# British English throughout. En dashes, never em dashes.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

SCALE_A='compartment_level'
SCALE_B='privacy_level'
BASELINE_FILE='tests/privacy_scale_crossings_baseline.txt'
GREP=/usr/bin/grep

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
cannot() { printf '\n  CANNOT-RUN  %s\n' "$*" >&2; exit 2; }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

printf '\n=== crossing points between the two privacy scales ===\n\n'

# ---------------------------------------------------------------------------
# CANNOT-RUN PRECONDITIONS, TAKEN BEFORE ANY MEASUREMENT
# ---------------------------------------------------------------------------
[ -x "$GREP" ] || cannot "${GREP} is not executable. Nothing was scanned. This is not a pass."
command -v comm >/dev/null 2>&1 || cannot "comm is unavailable, so the two sets cannot be intersected."

# ---------------------------------------------------------------------------
# THE SCANNER
# ---------------------------------------------------------------------------
# Two whole-tree greps and an intersection, rather than a per-file loop: 1992
# files means 3984 process spawns the other way, and this runs on every PR.
#
# `-I` skips binary files. `--exclude-dir=.git` keeps the pack files out; both
# flags exist on BSD grep (macOS, /usr/bin/grep 2.6.0-FreeBSD) and GNU grep
# (the CI runner), which is why the binary is NAMED rather than taken from
# PATH. The `grep` on PATH on this estate may be ugrep and answers differently.
#
# `sed 's#^\./##'` is load-bearing. `grep -r PAT .` emits './vendor/x.py' and
# the baseline stores 'vendor/x.py'. Without the strip the two sets are
# DISJOINT, and a set comparison between disjoint sets can still agree on
# cardinality. That exact defect shipped in the sibling ratchet
# tests/test_pipefail_shortcircuit_inversion.sh and went unnoticed for weeks
# because its failure path had never executed. Limb 4 drives the comparison
# against a known answer so it cannot happen here unobserved.
#
# 🔴 NO `2>/dev/null` ON ANY PROBE HERE, DELIBERATELY. grep exits 2 with a
# message and NO output on a usage error, and an unsupported `--exclude-dir` on
# some other grep would do exactly that. Swallowing stderr turns that into an
# empty list, which is indistinguishable from a clean tree: the gate would
# report "no crossing points" about a scan that never happened. Measured on
# this host: both greps and the find below emit ZERO stderr lines on a clean
# run, so there is no noise being traded away. The denominator guard below is
# the second half of it, and it is what converts the resulting zero into
# CANNOT-RUN rather than a pass.
_files_matching() {
    ( cd "$1" && "$GREP" -rlI --exclude-dir=.git -- "$2" . ) \
        | sed 's#^\./##' | sort
}

# The exclusions, in ONE place, used by both the live scan and the controls.
# A rule applied to the tree but not to the controls is a rule nobody tested.
_is_excluded() {
    case "$1" in
        tests/*|*/tests/*)  return 0 ;;
        docs/*|*/docs/*)    return 0 ;;
        cut-manifests/*)    return 0 ;;
    esac
    return 1
}

crossings_in() {
    local root="$1" rel
    comm -12 <(_files_matching "$root" "$SCALE_A") <(_files_matching "$root" "$SCALE_B") \
    | while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        _is_excluded "$rel" && continue
        printf '%s\n' "$rel"
      done
}

# ---------------------------------------------------------------------------
# 1. DENOMINATORS. A count with no denominator is a statement about the
#    reader, not about the tree.
# ---------------------------------------------------------------------------
N_ALL="$(( $( "$GREP" -rlI --exclude-dir=.git -- "$SCALE_A" . | wc -l ) ))"
N_B="$(( $( "$GREP" -rlI --exclude-dir=.git -- "$SCALE_B" . | wc -l ) ))"
N_TREE="$(( $( /usr/bin/find . -name '.git' -prune -o -type f -print | wc -l ) ))"

if [ "$N_TREE" -lt 100 ]; then
    cannot "the tree walk found only ${N_TREE} files. An empty or near-empty scan is not a clean result, it is a missing instrument."
fi
if [ "$N_ALL" -eq 0 ] || [ "$N_B" -eq 0 ]; then
    cannot "one of the two scale names matched ZERO files (${SCALE_A}=${N_ALL}, ${SCALE_B}=${N_B}). A uniform zero means a broken predicate, not a clean tree."
fi

POP="$(crossings_in .)"
POP_N="$(printf '%s\n' "$POP" | "$GREP" -c . || true)"

printf '        files in tree (excluding .git):          %s\n' "$N_TREE"
printf '        files naming %-20s %s\n' "${SCALE_A}:" "$N_ALL"
printf '        files naming %-20s %s\n' "${SCALE_B}:" "$N_B"
printf '        CROSSING POINTS after exclusions:        %s\n\n' "$POP_N"

# ---------------------------------------------------------------------------
# 2 and 3. POSITIVE CONTROL AND DISCRIMINATORS.
#
# The controls are SEEDED in a temp dir, never pointed at a real file. A control
# whose subject another open pull request is editing inverts the moment that
# pull request merges, and then reports the scanner blind when what actually
# happened is that the defect was fixed. Nobody will ever "fix" a fixture that
# exists in order to be found.
# ---------------------------------------------------------------------------
CTL_DIR="$(mktemp -d)"
trap 'rm -rf "$CTL_DIR"' EXIT

mkdir -p "$CTL_DIR/lib" "$CTL_DIR/tests" "$CTL_DIR/vendor/pkg/tests" \
         "$CTL_DIR/docs" "$CTL_DIR/vendor/pkg/docs" "$CTL_DIR/cut-manifests"

# MUST be found: an ordinary source file holding both scale names.
printf 'x = obj.%s\ny = obj.%s\n' "$SCALE_A" "$SCALE_B" > "$CTL_DIR/lib/converter.py"

# MUST NOT be found: one scale only. This is the discriminator that proves the
# scanner is intersecting rather than matching either name, which would inflate
# the population to 82 + 65 and make the baseline meaningless.
printf 'x = obj.%s\n' "$SCALE_A" > "$CTL_DIR/lib/only_compartment.py"
printf 'y = obj.%s\n' "$SCALE_B" > "$CTL_DIR/lib/only_privacy.py"

# MUST NOT be found: the four exclusions, each seeded with a file that WOULD
# otherwise be reported. An exclusion recorded only in a comment is not a
# guard; the next author writes the file and it is back.
for _ex in tests/contract.py vendor/pkg/tests/contract.py \
           docs/PRIVACY_LEVELS.md vendor/pkg/docs/NOTES.md \
           cut-manifests/v1.0.99.yaml; do
    printf 'names %s and %s\n' "$SCALE_A" "$SCALE_B" > "$CTL_DIR/$_ex"
done

CTL_POP="$(crossings_in "$CTL_DIR")"

if [ "$(printf '%s\n' "$CTL_POP" | "$GREP" -cx 'lib/converter.py')" -eq 1 ]; then
    ok "POSITIVE CONTROL: a seeded file naming BOTH scales is found"
else
    bad "POSITIVE CONTROL FAILED: the scanner did not find a file it was handed that names both scales. The scanner is blind and every count below is void."
fi
for _neg in lib/only_compartment.py lib/only_privacy.py; do
    if [ "$(printf '%s\n' "$CTL_POP" | "$GREP" -cx -- "$_neg")" -eq 0 ]; then
        ok "DISCRIMINATOR: ${_neg} names ONE scale, not reported"
    else
        bad "DISCRIMINATOR FAILED: ${_neg} names only one scale and was reported. The scanner is matching either name rather than both, so the population is the union and the baseline is meaningless."
    fi
done
for _neg in tests/contract.py vendor/pkg/tests/contract.py docs/PRIVACY_LEVELS.md \
            vendor/pkg/docs/NOTES.md cut-manifests/v1.0.99.yaml; do
    if [ "$(printf '%s\n' "$CTL_POP" | "$GREP" -cx -- "$_neg")" -eq 0 ]; then
        ok "DISCRIMINATOR: ${_neg} is excluded by declared rule, not reported"
    else
        bad "DISCRIMINATOR FAILED: ${_neg} was reported. The exclusion stated in this file's header and in the baseline header does not actually hold."
    fi
done

# THE CONTROL THAT PROVES THE EXCLUSIONS ARE NOT SWALLOWING THE TREE. Five
# exclusion fixtures and one positive: if the scanner returned the positive and
# nothing else, that is the right answer here AND it is the answer a scanner
# that excluded everything would give. So assert the exact set, by count.
if [ "$(printf '%s\n' "$CTL_POP" | "$GREP" -c . || true)" -eq 1 ]; then
    ok "CONTROL FLOOR: the seeded tree yields exactly 1 crossing, so the exclusions removed 5 and not 6"
else
    bad "CONTROL FLOOR: expected exactly 1 crossing in the seeded tree, got $(printf '%s\n' "$CTL_POP" | "$GREP" -c . || true). The controls above cannot be scored."
fi

rm -rf "$CTL_DIR"; trap - EXIT

# ---------------------------------------------------------------------------
# 4. THE COMPARISON ITSELF, DRIVEN AGAINST A KNOWN ANSWER.
#
# A count is a lossy summary of a set, and every way this ratchet can rot leaves
# the count intact: one crossing fixed and another introduced, or the two sides
# written in different path forms so they share no row at all while agreeing on
# a total. The sibling ratchet shipped exactly that, green, for weeks. So the
# comparison is exercised against a pair whose answer is already known, INCLUDING
# the pre-fix shape, before it is trusted with the real one.
# ---------------------------------------------------------------------------
baseline_rows() { "$GREP" -vE '^[[:space:]]*(#|$)' "$1" | sort; }
rows_added()    { comm -13 <(baseline_rows "$1") <(printf '%s\n' "$2" | "$GREP" -v '^$' | sort); }
rows_removed()  { comm -23 <(baseline_rows "$1") <(printf '%s\n' "$2" | "$GREP" -v '^$' | sort); }

SD="$(mktemp -d)"
trap 'rm -rf "$SD"' EXIT
printf 'a/one.py\na/two.py\n' > "$SD/base.txt"

got="$(rows_added "$SD/base.txt" "$(printf 'a/one.py\na/two.py\na/three.py\n')")"
if [ "$got" = "a/three.py" ]; then
    ok "COMPARISON: one added row is named, and only it"
else
    bad "COMPARISON: expected exactly 'a/three.py', got: ${got}. The failure message cannot be trusted to name the right files."
fi

got="$(rows_removed "$SD/base.txt" "$(printf 'a/one.py\n')")"
if [ "$got" = "a/two.py" ]; then
    ok "COMPARISON: one delisted row is named, and only it"
else
    bad "COMPARISON: expected exactly 'a/two.py', got: ${got}"
fi

n_add="$(rows_added   "$SD/base.txt" "$(printf './a/one.py\n./a/two.py\n')" | "$GREP" -c . || true)"
n_rem="$(rows_removed "$SD/base.txt" "$(printf './a/one.py\n./a/two.py\n')" | "$GREP" -c . || true)"
if [ "$n_add" -eq 2 ] && [ "$n_rem" -eq 2 ]; then
    ok "PRE-FIX SHAPE: a './'-prefixed population is fully disjoint from the baseline (2 added, 2 removed) while the totals agree"
else
    bad "PRE-FIX SHAPE: expected 2 added / 2 removed, got ${n_add}/${n_rem}. This limb can no longer demonstrate the defect it was written for."
fi
rm -rf "$SD"; trap - EXIT

# Herestring, never `printf | grep -q`. Under pipefail, grep -q exits on the
# first match and SIGPIPEs the producer, and pipefail then hands the pipeline
# printf's failure status: a successful match reported as a failure. This file
# is scanned by tests/test_pipefail_shortcircuit_inversion.sh and must obey the
# rule it is scanned against.
if "$GREP" -q '^\./' <<< "$POP"; then
    bad "population rows carry a './' prefix the baseline does not. The comparison below is between disjoint sets and can only ever agree by cardinality."
else
    ok "population rows are repo-relative, the same form the baseline stores"
fi

# ---------------------------------------------------------------------------
# 5. THE RATCHET.
# ---------------------------------------------------------------------------
if [ ! -f "$BASELINE_FILE" ]; then
    cannot "${BASELINE_FILE} is absent. There is nothing to ratchet against, so 'no new crossings' would be unfounded. A deleted baseline must never read as 'no limit'."
fi

BASE_N="$(baseline_rows "$BASELINE_FILE" | "$GREP" -c . || true)"
if [ "$BASE_N" -eq 0 ]; then
    cannot "${BASELINE_FILE} lists zero paths. An empty baseline makes every crossing 'new' or every scan 'clean' depending on which way it is read, and neither is a measurement."
fi

ADDED="$(rows_added "$BASELINE_FILE" "$POP")"
REMOVED="$(rows_removed "$BASELINE_FILE" "$POP")"

if [ -n "$ADDED" ]; then
    bad "RATCHET: NEW crossing points, not listed in ${BASELINE_FILE} (${POP_N} found, baseline ${BASE_N}):"
    sed 's/^/          /' <<< "$ADDED"
    printf '          A file that names BOTH scales is the only place 5 can be copied from a\n'
    printf '          scale where it is nearly private onto one where it is publishable.\n'
    printf '          Read docs/PRIVACY_LEVELS.md, then either remove the crossing or, if it\n'
    printf '          is a deliberate conversion, add the path to the baseline WITH a reason.\n'
    printf '          Adding a row is a reviewed decision, not a way to clear a red.\n'
else
    ok "RATCHET: no new crossing points. All ${POP_N} found are baselined."
fi

if [ -n "$REMOVED" ]; then
    # TWO CAUSES, TWO REMEDIES, so they are named apart. A red that carries a
    # wrong cause sends the reader somewhere else entirely, which is worse than
    # a red that carries none. Rows here are bare paths, so the path IS the row
    # and can be tested directly; the sibling ratchet stores 'path<TAB>count'
    # and tested the whole row as a path, which made one branch dead code.
    gone=""; kept=""
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        if [ -e "$row" ]; then kept="${kept}${row}"$'\n'; else gone="${gone}${row}"$'\n'; fi
    done <<< "$REMOVED"
    bad "RATCHET: ${BASELINE_FILE} lists paths this scan does NOT find. That is slack the next regression hides in. Delist them."
    [ -n "$kept" ] && { printf '          CROSSING REMOVED (or newly excluded), file still present:\n'; sed 's/^/            /' <<< "${kept%$'\n'}"; }
    [ -n "$gone" ] && { printf '          FILE NO LONGER EXISTS:\n'; sed 's/^/            /' <<< "${gone%$'\n'}"; }
    printf '          Lowering the baseline is the point of this gate. Do it in the same\n'
    printf '          commit as the fix, or the slack just earned silently permits the count\n'
    printf '          to grow back into it.\n'
else
    ok "NO BASELINE ROT: all ${BASE_N} baselined paths were found by this scan"
fi

finish
