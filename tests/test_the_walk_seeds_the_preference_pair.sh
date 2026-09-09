#!/usr/bin/env bash
# tests/test_the_walk_seeds_the_preference_pair.sh
# ============================================================================
# grounding_seed.sh puts a PERSON in the graph before the grounded probe asks
# about one. Nothing put a PREFERENCE there, so an empty preference wiki, an
# ingest that never ran and a broken write route were three faults wearing one
# face. On v1.0.81 the root cause was the first: cm019_setup logged "already
# set up" with elapsed_s=0 and install.log holds no ingest-dir and no "Files
# processed".
#
# scripts/box_walk_probes/lib/preference_seed.sh closes that. This test pins
# the four things that make it worth having:
#
#   1. IT IS WIRED. The runner sources the lib and calls it ABOVE the phase-2
#      measurement loop, with the forget step below. A lib nothing invokes is
#      the "unwired" case the directive names.
#   2. THE STAGED TREE IS CHECKED BY CONTENT. A box running different cm019
#      code is a CANNOT-RUN, because the seed counts would not mean what the
#      fixture says. Measured against the REAL vendor tree, not a stub, and
#      the stale arm mutates one staged byte.
#   3. BOTH FLOOR ARMS ARE LOAD-BEARING. interests >= 1 AND suppressed >= 1.
#      A profile with interests and no suppressions cannot tell a working
#      screen from an absent one, so the suppressed arm has its own MUST-FAIL.
#   4. WHAT WE COULD NOT LOOK AT IS NOT A FAIL. Every path prints a named
#      CANNOT-RUN or a named FINDING, never a bare red.
#
# The loader and the compiler are stubbed. This test is about the WIRING, the
# currency check and the three-outcome discipline. Whether OS003's loader can
# talk to a store is load_preference_seed.py's own --self-test.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/box_walk_probes/lib/preference_seed.sh"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"
VENDOR="$REPO/vendor/cm019_preferences"

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
[ -d "$VENDOR" ] || { printf 'CANNOT-RUN: no vendor tree at %s\n' "$VENDOR"; exit 78; }
PY3="$(command -v python3 || true)"
[ -n "$PY3" ] || { printf 'CANNOT-RUN: no python3 on PATH\n'; exit 78; }

# The four files the lib hashes. Kept in the test as a LITERAL rather than
# read out of the lib, so a PR that quietly narrows the currency check to one
# file has to change this list too and be seen doing it.
CURRENCY="services/ingest/src/pipeline.py
services/ingest/src/filters.py
services/ingest/src/parsers/spotify.py
services/ingest/src/parsers/twitter.py"

# A stand-in for the cm019 bundle INSIDE THE ARTEFACT. Real vendor files are
# used as its content only because they are convenient bytes; nothing in the
# lib may read the checkout, and arm 4 is what proves that.
make_bundle() { # $1 = bundle dir to build
    local b="$1"
    for f in $CURRENCY; do
        mkdir -p "$b/$(dirname "$f")"
        cp "$VENDOR/$f" "$b/$f"
    done
}

# A fake ~/.ostler whose staged cm019 tree is a copy of a given bundle, which
# is what install.sh does: cp -R "${CM019_BUNDLE}/" "$CM019_DIR/".
make_staged_tree() { # $1 = OSTLER_DIR to build, $2 = bundle to copy from
    local root="$1" b="$2"
    for f in $CURRENCY; do
        mkdir -p "$root/services/cm019/$(dirname "$f")"
        cp "$b/$f" "$root/services/cm019/$f"
    done
}

# A fake staged interest-profile compiler plus the rendered tick that names
# the interpreter. $2/$3 are the numbers build_from_live() will report.
make_stub_compiler() { # $1 = OSTLER_DIR, $2 = interests, $3 = suppressed
    local root="$1"
    mkdir -p "$root/bin" "$root/services/cm059-editor/compiler"
    printf 'PYTHON_BIN="%s"\n' "$PY3" > "$root/bin/editor-frontpage-tick.sh"
    : > "$root/services/cm059-editor/compiler/__init__.py"
    cat > "$root/services/cm059-editor/compiler/interest_profile.py" <<PY
def build_from_live(*a, **k):
    return {"stats": {"interests": $2, "suppressed_low_confidence": $3,
                      "dislikes": 0, "domains": 1, "raw_rows": 2},
            "domains": [{"domain": "Music", "count": $2,
                         "interests": [{"subject": "stub row", "confidence": 0.2991}][:$2]}]}
PY
}

# A stand-in for OS003 gates/seed. $2 is the loader's exit code; the marker is
# what _ps_loader_is_current looks for, so --stale produces exactly the
# pre-read-back shape the guard exists to refuse.
make_seed_dir() { # $1 dir, $2 rc, $3 optional --stale
    mkdir -p "$1/preferences/exports"
    printf '{}\n' > "$1/preferences/preference_fixture.json"
    printf '[]\n' > "$1/preferences/exports/StreamingHistory0.json"
    printf 'window.YTD.personalization.part0 = []\n' > "$1/preferences/exports/personalization.js"
    if [ "${3:-}" = "--stale" ]; then
        cat > "$1/load_preference_seed.py" <<PY
import sys
# pre-read-back loader: reports the ingest exit code and calls that a pass
sys.exit($2)
PY
    else
        cat > "$1/load_preference_seed.py" <<PY
import os, sys
# current loader marker: the graph read-back is SELECT (COUNT(DISTINCT ?s) ...)
if "--digest" in sys.argv:
    # stdout is the digest ALONE, as the real one guarantees
    print("stubdigest-" + os.path.basename(sys.argv[sys.argv.index("--digest") + 1]))
    sys.exit(0)
with open("$1/RAN", "a") as fh:
    fh.write("ARGS " + " ".join(sys.argv[1:]) + "\n")
    fh.write("DIGEST " + os.environ.get("OSTLER_PREF_SEED_CM019_DIGEST", "") + "\n")
    fh.write("SOURCE " + os.environ.get("OSTLER_PREF_SEED_CM019_DIGEST_SOURCE", "") + "\n")
sys.stderr.write("stub loader says: rc=$2\n")
sys.exit($2)
PY
    fi
}

# Source the lib in a child shell, call the step, report what it decided.
run_apply() { # $1 = lib, rest = env assignments
    local lib="$1"; shift
    env -u OSTLER_PREF_SEED_SKIP -u OSTLER_SEED_DIR \
        -u OSTLER_ALLOW_INSTALLED_APP_BUNDLE \
        OSTLER_BOX_HOST= OSTLER_CM019_BUNDLE="${BUNDLE:-}" \
        OSTLER_PREF_SEED_VOLUMES_DIR="${EMPTY_VOLUMES:-/nonexistent-volumes}" "$@" \
        bash -c '
            . "$1"
            preference_seed_apply
            printf "RC=%s\n" "$?"
            printf "STATE=%s\n" "${PREFERENCE_SEED_STATE}"
        ' _ "$lib" 2>&1
}

printf 'THE WALK SEEDS THE PREFERENCE PAIR\n\n'

# ---------------------------------------------------------------------------
printf -- '-- 1. it is wired into the runner, in the right order --\n'
# ---------------------------------------------------------------------------
src_line="$(grep -n 'lib/preference_seed.sh' "$RUNNER" | head -1 | cut -d: -f1)"
apply_line="$(grep -n '^preference_seed_apply' "$RUNNER" | head -1 | cut -d: -f1)"
forget_line="$(grep -n '^preference_seed_forget' "$RUNNER" | head -1 | cut -d: -f1)"
loop_line="$(grep -n '^    out="$(bash "$p" 2>&1)"' "$RUNNER" | head -1 | cut -d: -f1)"

[ -n "$src_line" ] && [ -n "$apply_line" ]
arm "the runner sources the lib and calls preference_seed_apply" $? \
    "source line='$src_line' apply line='$apply_line'"

[ -n "$loop_line" ] && [ -n "$apply_line" ] && [ "$apply_line" -lt "$loop_line" ]
arm "the seed runs BEFORE the phase-2 probe loop (a seed after it seeds nothing)" $? \
    "apply at $apply_line, probe loop at $loop_line"

[ -n "$forget_line" ] && [ -n "$loop_line" ] && [ "$forget_line" -gt "$loop_line" ]
arm "the forget step runs AFTER the loop, so it cannot change a verdict" $? \
    "forget at $forget_line, probe loop at $loop_line"

# The three line citations at the top of the runner must survive this wiring.
[ "$(sed -n '42p' "$RUNNER")" = 'PROBE_DIR="$HERE/probes"' ] \
    && [ "$(sed -n '44p' "$RUNNER")" = 'EX_CANNOT_RUN=78' ] \
    && [ "$(sed -n '83p' "$RUNNER")" = 'for f in "$PROBE_DIR"/*.sh; do' ]
arm "the runner's three cited lines (:42 :44 :83) still say what is cited" $? \
    "42=[$(sed -n '42p' "$RUNNER")] 44=[$(sed -n '44p' "$RUNNER")] 83=[$(sed -n '83p' "$RUNNER")]"

# ---------------------------------------------------------------------------
printf -- '\n-- 2. both floor arms, on a staged tree that matches --\n'
# ---------------------------------------------------------------------------
BUNDLE="$WORK/bundle"; make_bundle "$BUNDLE"
OK_ROOT="$WORK/ok-root"; make_staged_tree "$OK_ROOT" "$BUNDLE"; make_stub_compiler "$OK_ROOT" 1 1
D0="$WORK/seed-ok"; make_seed_dir "$D0" 0
out="$(run_apply "$LIB" OSTLER_SEED_DIR="$D0" OSTLER_DIR="$OK_ROOT")"
grep -q 'RC=0' <<< "$out" && grep -q 'STATE=seeded' <<< "$out"
arm "one interest cleared and one row screened is a pass" $? "$out"

[ -f "$D0/RAN" ]
arm "the loader actually ran" $? "no RAN sentinel in $D0"

grep -q 'DOES NOT CLEAR #1872' <<< "$out"
arm "and a pass says in words that it does not clear #1872" $? "$out"

# ---------------------------------------------------------------------------
printf -- '\n-- 3. each floor arm is load-bearing on its own --\n'
# ---------------------------------------------------------------------------
NO_INT="$WORK/no-int"; make_staged_tree "$NO_INT" "$BUNDLE"; make_stub_compiler "$NO_INT" 0 1
D1="$WORK/seed-noint"; make_seed_dir "$D1" 0
out1="$(run_apply "$LIB" OSTLER_SEED_DIR="$D1" OSTLER_DIR="$NO_INT")"
grep -q 'STATE=screen-moved' <<< "$out1" && grep -q 'FINDING: interests=0' <<< "$out1"
arm "interests=0 is a named FINDING, not a pass" $? "$out1"

NO_SUP="$WORK/no-sup"; make_staged_tree "$NO_SUP" "$BUNDLE"; make_stub_compiler "$NO_SUP" 1 0
D2="$WORK/seed-nosup"; make_seed_dir "$D2" 0
out2="$(run_apply "$LIB" OSTLER_SEED_DIR="$D2" OSTLER_DIR="$NO_SUP")"
grep -q 'STATE=screen-moved' <<< "$out2" && grep -q 'FINDING: suppressed=0' <<< "$out2"
arm "suppressed=0 is a named FINDING: a screen that never screens is not a screen" $? "$out2"

# ---------------------------------------------------------------------------
mkdir -p "$WORK/empty-volumes"
R5x="$WORK/r5x"; make_staged_tree "$R5x" "$BUNDLE"; make_stub_compiler "$R5x" 1 1
printf -- '\n-- 4. the staged tree is checked BY CONTENT, against the ARTEFACT --\n'
# ---------------------------------------------------------------------------
STALE="$WORK/stale-root"; make_staged_tree "$STALE" "$BUNDLE"; make_stub_compiler "$STALE" 1 1
# One byte, in one of the four measured files. An mtime check would not see it
# at all; that is the #1874 shape this arm exists for.
printf '\n# drifted\n' >> "$STALE/services/cm019/services/ingest/src/filters.py"
# ...and make the venv look FRESH, so a mtime-based check would call it current.
mkdir -p "$STALE/services/cm019/.venv/bin"; : > "$STALE/services/cm019/.venv/bin/python"
D3="$WORK/seed-stale"; make_seed_dir "$D3" 0
out3="$(run_apply "$LIB" OSTLER_SEED_DIR="$D3" OSTLER_DIR="$STALE")"
grep -q 'STATE=stale' <<< "$out3" && grep -q 'CANNOT-RUN' <<< "$out3"
arm "a drifted staged file is CANNOT-RUN, not a product FAIL" $? "$out3"
grep -q 'filters.py' <<< "$out3"
arm "and the report NAMES the file that drifted" $? "$out3"
[ ! -f "$D3/RAN" ]
arm "nothing is seeded onto a box running different code" $? "the loader ran anyway"

MISS="$WORK/missing-root"; make_staged_tree "$MISS" "$BUNDLE"; make_stub_compiler "$MISS" 1 1
rm -f "$MISS/services/cm019/services/ingest/src/parsers/twitter.py"
D4="$WORK/seed-missing"; make_seed_dir "$D4" 0
out4="$(run_apply "$LIB" OSTLER_SEED_DIR="$D4" OSTLER_DIR="$MISS")"
grep -q 'STATE=stale' <<< "$out4" && grep -q 'twitter.py' <<< "$out4"
arm "a staged file that is absent is caught too, and named" $? "$out4"

# THE SHARP ONE. The comparison must be BUNDLE vs BOX, never CHECKOUT vs BOX.
# Here the bundle and the staged tree agree with each other and BOTH differ
# from vendor/. A lib that reads the checkout goes red; the right one passes.
OTHER="$WORK/other-bundle"; make_bundle "$OTHER"
printf '\n# this artefact is not this checkout\n' >> "$OTHER/services/ingest/src/filters.py"
OTHER_ROOT="$WORK/other-root"; make_staged_tree "$OTHER_ROOT" "$OTHER"; make_stub_compiler "$OTHER_ROOT" 1 1
D4b="$WORK/seed-other"; make_seed_dir "$D4b" 0
out4b="$(run_apply "$LIB" OSTLER_SEED_DIR="$D4b" OSTLER_DIR="$OTHER_ROOT" OSTLER_CM019_BUNDLE="$OTHER")"
grep -q 'STATE=seeded' <<< "$out4b"
arm "a bundle that differs from vendor/ but matches the box PASSES (no checkout is read)" $? "$out4b"

# ...and the digest that reached the loader is the BUNDLE's, computed by the
# loader's own --digest, not invented here.
grep -q "^DIGEST stubdigest-$(basename "$OTHER")\$" "$D4b/RAN"
arm "the loader was handed the digest of THAT bundle, and its source" $? \
    "RAN says: $(cat "$D4b/RAN" 2>/dev/null)"
grep -q '^SOURCE OSTLER_CM019_BUNDLE$' "$D4b/RAN"
arm "and the source string travels with it, so a mismatch can say which side" $? \
    "RAN says: $(cat "$D4b/RAN" 2>/dev/null)"

# No bundle anywhere: refuse, and name the variable. EMPTY_VOLUMES points the
# mount scan at a directory with nothing in it, so this arm cannot depend on
# whether the machine running the test happens to have a DMG mounted.
D4c="$WORK/seed-nobundle"; make_seed_dir "$D4c" 0
out4c="$(env -u OSTLER_CM019_BUNDLE -u OSTLER_ALLOW_INSTALLED_APP_BUNDLE \
    OSTLER_BOX_HOST= OSTLER_SEED_DIR="$D4c" OSTLER_DIR="$R5x" \
    OSTLER_PREF_SEED_VOLUMES_DIR="$WORK/empty-volumes" \
    bash -c '. "$1"; preference_seed_apply; printf "RC=%s\n" "$?"; printf "STATE=%s\n" "${PREFERENCE_SEED_STATE}"' _ "$LIB" 2>&1)"
grep -q 'STATE=absent' <<< "$out4c" && grep -q 'OSTLER_CM019_BUNDLE' <<< "$out4c"
arm "no artefact bundle is CANNOT-RUN and names the variable that fixes it" $? "$out4c"
grep -q 'OSTLER_ALLOW_INSTALLED_APP_BUNDLE' <<< "$out4c"
arm "and it says /Applications is not used unless asked for by name" $? "$out4c"
[ ! -f "$D4c/RAN" ]
arm "nothing is seeded when there is no artefact to compare against" $? "the loader ran anyway"

# ---------------------------------------------------------------------------
printf -- '\n-- 5. a seed that did not work asserts NOTHING --\n'
# ---------------------------------------------------------------------------
R5="$WORK/r5"; make_staged_tree "$R5" "$BUNDLE"; make_stub_compiler "$R5" 1 1
D5="$WORK/seed-rc1"; make_seed_dir "$D5" 1
out5="$(run_apply "$LIB" OSTLER_SEED_DIR="$D5" OSTLER_DIR="$R5")"
grep -q 'STATE=failed' <<< "$out5" && grep -q 'FINDING (loader exit 1)' <<< "$out5"
arm "loader exit 1 is a FINDING about the write route" $? "$out5"

D6="$WORK/seed-rc2"; make_seed_dir "$D6" 2
out6="$(run_apply "$LIB" OSTLER_SEED_DIR="$D6" OSTLER_DIR="$R5")"
grep -q 'STATE=failed' <<< "$out6" && grep -q 'CANNOT-RUN (loader exit 2)' <<< "$out6"
arm "loader exit 2 is a named CANNOT-RUN, never a FAIL" $? "$out6"

# ---------------------------------------------------------------------------
printf -- '\n-- 6. the oracle is missing, pre-read-back, or waived --\n'
# ---------------------------------------------------------------------------
out7="$(run_apply "$LIB" OSTLER_SEED_DIR="$WORK/nothing-here" OSTLER_DIR="$R5")"
grep -q 'STATE=absent' <<< "$out7" && grep -q 'OSTLER_SEED_DIR' <<< "$out7"
arm "a missing oracle names the variable that fixes it" $? "$out7"

D8="$WORK/seed-preread"; make_seed_dir "$D8" 0 --stale
out8="$(run_apply "$LIB" OSTLER_SEED_DIR="$D8" OSTLER_DIR="$R5")"
grep -q 'STATE=absent' <<< "$out8" && grep -q 'PRE-READ-BACK' <<< "$out8"
arm "a loader with no graph read-back is refused, not run" $? "$out8"

out9="$(run_apply "$LIB" OSTLER_SEED_DIR="$D0" OSTLER_DIR="$R5" OSTLER_PREF_SEED_SKIP=1)"
grep -q 'STATE=skipped' <<< "$out9" && grep -q 'not a pass' <<< "$out9"
arm "OSTLER_PREF_SEED_SKIP=1 seeds nothing and says it is not a pass" $? "$out9"

# ---------------------------------------------------------------------------
printf -- '\n-- 7. the compiler itself cannot be reached --\n'
# ---------------------------------------------------------------------------
NOCOMP="$WORK/nocomp"; make_staged_tree "$NOCOMP" "$BUNDLE"; make_stub_compiler "$NOCOMP" 1 1
rm -rf "$NOCOMP/services/cm059-editor/compiler"
D10="$WORK/seed-nocomp"; make_seed_dir "$D10" 0
out10="$(run_apply "$LIB" OSTLER_SEED_DIR="$D10" OSTLER_DIR="$NOCOMP")"
grep -q 'STATE=failed' <<< "$out10" && grep -q 'CANNOT-RUN' <<< "$out10" \
    && grep -q 'NO-COMPILER' <<< "$out10"
arm "no staged compiler is CANNOT-RUN, and the rows are still reported written" $? "$out10"

NOTICK="$WORK/notick"; make_staged_tree "$NOTICK" "$BUNDLE"; make_stub_compiler "$NOTICK" 1 1
rm -f "$NOTICK/bin/editor-frontpage-tick.sh"
D11="$WORK/seed-notick"; make_seed_dir "$D11" 0
out11="$(run_apply "$LIB" OSTLER_SEED_DIR="$D11" OSTLER_DIR="$NOTICK")"
grep -q 'STATE=failed' <<< "$out11" && grep -q 'NO-TICK' <<< "$out11"
arm "no rendered tick means no interpreter, and that is CANNOT-RUN" $? "$out11"

# ---------------------------------------------------------------------------
printf -- '\n-- 8. MUTATION: with the suppressed arm removed, arm 3 must fail --\n'
# ---------------------------------------------------------------------------
# The suppressed arm is the one a future edit is most likely to drop, because
# it is the counter-intuitive half: it asserts that something was THROWN AWAY.
MUT="$WORK/mutant.sh"
sed 's/^    if \[ "${_ps_suppressed}" -lt 1 \]; then$/    if false; then/' "$LIB" > "$MUT"
mut_left="$(grep -c '_ps_suppressed}" -lt 1' "$MUT" || true)"
[ "$mut_left" = "0" ]
arm "the mutant really has the suppressed arm disabled (the injection landed)" $? \
    "still present: $mut_left line(s)"

MR="$WORK/mutroot"; make_staged_tree "$MR" "$BUNDLE"; make_stub_compiler "$MR" 1 0
D12="$WORK/seed-mut"; make_seed_dir "$D12" 0
outm="$(run_apply "$MUT" OSTLER_SEED_DIR="$D12" OSTLER_DIR="$MR")"
grep -q 'STATE=seeded' <<< "$outm"
if [ $? -eq 0 ]; then mut_rc=0; else mut_rc=1; fi
arm "MUST-FAIL: the mutant passes suppressed=0, so arm 3 is a real assertion" "$mut_rc" \
    "the mutant did not pass suppressed=0: $outm"

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
