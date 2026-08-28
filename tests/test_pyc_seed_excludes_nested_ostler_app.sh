#!/usr/bin/env bash
# The arm-8 pyc seed must leave the already-sealed nested Ostler.app BYTE-IDENTICAL.
#
# WHAT THIS ADDS THAT #1200 DID NOT HAVE. #1200 shipped the fix with two guards:
# a structural assertion in test_installer_app_pyc_is_seeded.sh (the recipe
# PASSES an exclusion) and an in-build probe in the seeder (the pattern MATCHES
# at least one .py). Both are worth having and neither answers the question the
# cut actually failed on:
#
#     after a real seeding run, are the nested .pyc still the same bytes?
#
# A pattern can be passed, match files, and still be the wrong files. This test
# runs the REAL seeder over a fixture shaped like the build and compares
# digests, with a mutation arm that drops the argument and must go RED.
#
# THE DEFECT, MEASURED. v1.0.49 attempt 4, run 33142445217 step 8:
#
#     [OK] nested Ostler.app: codesign rc=1, file added=0, file modified=86
#     ERROR: seeding $(APP_PATH) disturbed the nested Ostler.app seal.
#
# 86 of 86 -- the whole nested payload -- rewritten inside a signature nothing
# reseals, because sign-python-bundle signs that root WITHOUT --deep. Shipped,
# that is the v1.0.45 brick one bundle down: macOS refuses the Hub.
#
# 🔴 THE REASON IS `co_filename`, NOT THE INTERPRETER. compileall bakes the
# ABSOLUTE SOURCE PATH into every code object. Arm 1 seeds Ostler.app at
# $(OSTLER_APP_PATH); `release` COPIES that sealed bundle in; arm 8 reaches it
# at the NEW path and every .pyc comes out different. Same interpreter, same
# bytes, different path. The mechanism is pinned separately in
# tests/test_pyc_bytes_depend_on_compile_path.sh -- guard the reason, not only
# the flag, or the next reader pins the interpreter and deletes the -x.
#
# THIS TEST NEEDS NO 3.11. It drives the real script through a wrapper that
# reports cache_tag cpython-311 while execing whatever python3 the host has.
# The seeder's audit hardcodes `.cpython-311.pyc`, so on a non-3.11 host the
# run refuses at the END -- AFTER the compile this test is about. So every
# assertion reads the FILES, never the exit code, and a two-sided control
# proves the run did something rather than nothing.

# Herestrings, not `producer | grep -q` -- under `set -o pipefail` a successful
# early-exiting grep can return non-zero and invert the verdict.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/gui/scripts/seed-hub-payload-pyc.sh"
MK="$REPO_ROOT/gui/Makefile"
FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

[[ -f "$SCRIPT" ]] || { echo "FAIL [script-missing]: $SCRIPT. CANNOT-RUN is not a pass." >&2; exit 2; }
[[ -f "$MK" ]]     || { echo "FAIL [makefile-missing]: $MK. CANNOT-RUN is not a pass." >&2; exit 2; }

HOST_PY="$(command -v python3 || true)"
[[ -n "$HOST_PY" ]] || { echo "FAIL [no-python3]: no python3 on PATH. CANNOT-RUN is not a pass." >&2; exit 2; }

# THE PATTERN UNDER TEST IS READ OUT OF THE MAKEFILE, never retyped here. A
# copy would drift, and this suite would then prove a pattern the build does
# not use -- the instrument measuring a surface the defect has left.
#
# 🔴 READ THE INVOCATION, NEVER A MENTION. The first version of this matched the
# first line under the target containing "Contents/Resources/Ostler" -- and the
# moment #1202 added a COMMENT naming both nested bundles, that line won:
#
#     [i] exclusion under test: "#   Contents/Resources/Ostler.app   EXCLUDED"
#
# which as a regex matches nothing recognisable, so the seeder excluded
# everything and seeded ZERO files. It was caught only because the control arm
# below reports the outer count (0 -> 0) instead of trusting arm 1 alone -- the
# same class as the estate's gate-inventory defect, in my own instrument, on the
# same night I wrote the lesson down. Comment lines are STRIPPED first, then
# continuations joined, then the quoted argument taken from the real recipe line.
RECIPE_CODE="$(awk '
    /^seed-installer-app-pyc:/ { inrec = 1; next }
    inrec && /^[a-zA-Z0-9_.-]+:/ { exit }
    !inrec { next }
    { line = $0; sub(/^[ \t]+/, "", line) }
    line ~ /^#/ { next }                        # a comment is not an invocation
    { sub(/\\$/, "", line); printf "%s ", line }  # join continuations
    ' "$MK")"
RX="$(printf '%s\n' "$RECIPE_CODE" | sed -n "s/.*seed-hub-payload-pyc\.sh[^']*'\([^']*\)'.*/\1/p")"
if [[ -z "$RX" ]]; then
    echo "FAIL [no-pattern]: could not read the exclusion out of the seed-installer-app-pyc recipe." >&2
    echo "  Refusing to substitute one of my own: that would test a pattern the build does not run." >&2
    exit 2
fi
echo "[i] exclusion under test, read from gui/Makefile: ${RX}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- the interpreter shim -------------------------------------------------
mkdir -p "$WORK/shim/src/python/bin"
cat > "$WORK/shim/src/python/bin/python3.11" <<SHIM
#!/bin/sh
case "\${2:-}" in
  *cache_tag*) echo "cpython-311"; exit 0 ;;
  *sys.version*) echo "3.11.0"; exit 0 ;;
esac
exec "$HOST_PY" "\$@"
SHIM
chmod +x "$WORK/shim/src/python/bin/python3.11"
( cd "$WORK/shim/src" && tar -czf "$WORK/shim/bundle.tar.gz" python )
TARBALL="$WORK/shim/bundle.tar.gz"
SHIM_PY="$WORK/shim/src/python/bin/python3.11"

# ---- the fixture ----------------------------------------------------------
# Reproduces the build's shape: a bundle seeded AT ONE PATH, then copied into
# the outer app at a DIFFERENT path. The path change is the whole defect, so a
# fixture that seeds in place would prove nothing.
build_fixture() {
    local root="$1" i=0
    rm -rf "$root"; mkdir -p "$root/sealed-elsewhere/Contents/Resources"
    while [[ $i -lt 6 ]]; do
        printf 'NESTED = %d\n' "$i" > "$root/sealed-elsewhere/Contents/Resources/n$i.py"
        i=$((i+1))
    done
    env PYTHONDONTWRITEBYTECODE=1 "$SHIM_PY" -m compileall -q -f \
        --invalidation-mode unchecked-hash "$root/sealed-elsewhere" >/dev/null 2>&1

    mkdir -p "$root/Outer.app/Contents/Resources"
    i=0
    while [[ $i -lt 25 ]]; do
        printf 'OUTER = %d\n' "$i" > "$root/Outer.app/Contents/Resources/m$i.py"
        i=$((i+1))
    done
    cp -R "$root/sealed-elsewhere" "$root/Outer.app/Contents/Resources/Ostler.app"
}

digest_pyc() {
    ( cd "$1" && find . -name '*.pyc' -type f | LC_ALL=C sort | \
        while IFS= read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; done )
}
count_pyc() { find "$1" -name '*.pyc' -type f | wc -l | tr -d ' '; }

# ---- 1. WITH the exclusion: the nested bundle is untouched ----------------
build_fixture "$WORK/keep"
NESTED="$WORK/keep/Outer.app/Contents/Resources/Ostler.app"
OUTER_ONLY="$WORK/keep/Outer.app/Contents/Resources"
BEFORE_NESTED="$(digest_pyc "$NESTED")"
BEFORE_NESTED_N="$(count_pyc "$NESTED")"
BEFORE_OUTER_N="$(find "$OUTER_ONLY" -maxdepth 2 -name '*.pyc' -type f | wc -l | tr -d ' ')"

# ANTI-VACUITY ON THE FIXTURE. If arm 1's seed produced nothing, "the nested
# tree did not change" is trivially true and this whole file proves nothing.
if [[ "$BEFORE_NESTED_N" -lt 6 ]]; then
    fail "fixture-vacuous" "the nested bundle carries only $BEFORE_NESTED_N .pyc before the run; expected >= 6. The fixture did not seed, so 'unchanged' would be an empty verdict"
fi

"$SCRIPT" "$WORK/keep/Outer.app" "$TARBALL" "Outer.app" 20 "$RX" > "$WORK/keep.out" 2>&1
AFTER_NESTED="$(digest_pyc "$NESTED")"
AFTER_OUTER_N="$(find "$OUTER_ONLY" -maxdepth 2 -name '*.pyc' -type f | wc -l | tr -d ' ')"

if [[ "$BEFORE_NESTED" != "$AFTER_NESTED" ]]; then
    fail "exclusion-did-not-hold" "the nested Ostler.app .pyc CHANGED despite the exclusion. On a real cut that is codesign rc=1 and a Hub macOS refuses to launch"
else
    pass "with the exclusion, all $BEFORE_NESTED_N nested .pyc are byte-identical after the seed"
fi

# THE OTHER SIDE OF THE CONTROL. A run that did nothing would also leave the
# nested tree unchanged. A control on ONE side is not a control.
if [[ "$AFTER_OUTER_N" -le "$BEFORE_OUTER_N" ]]; then
    fail "control-nothing-happened" "the outer app gained no .pyc ($BEFORE_OUTER_N -> $AFTER_OUTER_N), so 'nested unchanged' is satisfied by the seed never running at all. Assertion 1 proves nothing without this"
else
    pass "control: the outer app WAS seeded in the same run ($BEFORE_OUTER_N -> $AFTER_OUTER_N .pyc) -- the exclusion is selective, not inert"
fi

# ---- 2. MUTATION: without the exclusion, the defect returns ---------------
# If this arm does not go RED, assertion 1 cannot tell a fix from a no-op.
build_fixture "$WORK/mutate"
MNESTED="$WORK/mutate/Outer.app/Contents/Resources/Ostler.app"
MBEFORE="$(digest_pyc "$MNESTED")"
"$SCRIPT" "$WORK/mutate/Outer.app" "$TARBALL" "Outer.app" 20 > "$WORK/mutate.out" 2>&1
MAFTER="$(digest_pyc "$MNESTED")"

if [[ "$MBEFORE" == "$MAFTER" ]]; then
    fail "mutation-survived" "WITHOUT the exclusion the nested .pyc were STILL identical. Either this host writes path-independent bytecode or the fixture is wrong; either way assertion 1 cannot distinguish a fix from a no-op and must not be trusted"
else
    pass "mutation: dropping the exclusion DOES rewrite the nested .pyc -- assertion 1 can fail, so it means something"
fi

# ---- 3. arm 1 is unchanged: no 5th argument means no exclusion ------------
# Arm 1's nested-bundle seeding is CORRECT (a --force --deep reseal follows it)
# and must keep happening. A fix that silenced arm 1 would ship .pyc-less .py
# inside Ostler.app -- the v1.0.48 residual, reopened.
if grep -q 'excluding .* from the WRITE' <<< "$(cat "$WORK/mutate.out")"; then
    fail "arm1-changed" "a call with no 5th argument still excluded something; arm 1's behaviour is not preserved"
else
    pass "arm 1 (no 5th argument) excludes nothing, exactly as before"
fi

# ---- 4. an exclusion that matches nothing is refused ----------------------
# A silent no-op here restores the defect while the build reads as protected.
build_fixture "$WORK/vacuous"
OUT4="$("$SCRIPT" "$WORK/vacuous/Outer.app" "$TARBALL" "Outer.app" 20 '/no/such/path/' 2>&1)"
RC4=$?
if [[ "$RC4" -eq 0 ]]; then
    fail "vacuous-exclusion-accepted" "an exclusion matching zero .py exited 0. The seed silently reverts to touching everything"
elif ! grep -q 'matches ZERO .py' <<< "$OUT4"; then
    fail "vacuous-exclusion-wrong-reason" "the script exited $RC4 but not on the vacuity check; its output never says 'matches ZERO .py', so this assertion would pass with that guard deleted"
else
    pass "an exclusion matching zero .py is refused ON THAT GROUND"
fi

# ---- 5. a malformed pattern is refused, not silently ignored --------------
OUT5="$("$SCRIPT" "$WORK/vacuous/Outer.app" "$TARBALL" "Outer.app" 20 '[unclosed' 2>&1)"
RC5=$?
if [[ "$RC5" -eq 0 ]]; then
    fail "bad-regex-accepted" "an invalid regular expression exited 0 -- an unparseable exclusion excludes nothing"
else
    pass "an invalid regular expression is refused (rc=$RC5)"
fi

# ---- 6. the exclusion must not be so broad it swallows the outer tree -----
# The inverse failure. `.` or `.*` would satisfy every other assertion here --
# nested unchanged, hits > 0 -- while seeding NOTHING, which is the v1.0.45
# brick in the outer bundle instead of the nested one.
build_fixture "$WORK/broad"
BOUTER="$WORK/broad/Outer.app/Contents/Resources"
"$SCRIPT" "$WORK/broad/Outer.app" "$TARBALL" "Outer.app" 20 "$RX" > /dev/null 2>&1
BN="$(find "$BOUTER" -maxdepth 2 -name '*.pyc' -type f | wc -l | tr -d ' ')"
if [[ "$BN" -lt 25 ]]; then
    fail "exclusion-too-broad" "only $BN of 25 outer .py were seeded under the shipped pattern. An over-broad exclusion protects the nested seal by seeding nothing, which breaks the OUTER one instead"
else
    pass "the shipped pattern leaves all 25 outer .py seeded -- it is narrow as well as effective"
fi

# ---- the structural arms read CODE ONLY ----------------------------------
# 🔴 THE FIRST VERSION OF ARMS 7 AND 8 WAS SATISFIED BY COMMENTS. Archie caught
# it after merge and I re-derived it by mutation: delete all 30 code lines from
# the recipe and keep only its 57 comment lines, and every predicate still
# passed --
#     Contents/Resources/Ostler   comments-only 1   code-only 3
#     file modified               comments-only 1   code-only 2
#     file added                  comments-only 1   code-only 2
# because #1200's and #1202's comments quote the very strings the arms look for
# ("[OK] nested Ostler.app: codesign rc=1, file added=0, file modified=86").
#
# I had ALREADY stripped comments to build RECIPE_CODE for the pattern
# extractor, then used the raw body two lines later. Same file, same defect
# class, twice in one night. A GATE THAT SCORES A COMMENT MEASURES
# DOCUMENTATION, NOT CODE.
[[ -n "$RECIPE_CODE" ]] || fail "no-recipe-code" "seed-installer-app-pyc has no non-comment lines in $MK"

# The comments-only body is kept as a LIVE NEGATIVE CONTROL: whatever these arms
# assert must be FALSE of it, or they are blind again and nobody will notice.
RECIPE_COMMENTS="$(awk '
    /^seed-installer-app-pyc:/ { inrec = 1; next }
    inrec && /^[a-zA-Z0-9_.-]+:/ { exit }
    !inrec { next }
    { line = $0; sub(/^[ \t]+/, "", line) }
    line ~ /^#/ { printf "%s ", line }
    ' "$MK")"

# ---- 7. the arm-8 CALL SITE still asks for it ----------------------------
# Behaviour proves the script CAN exclude. This proves the ship chain DOES ask.
if ! grep -q 'Contents/Resources/Ostler' <<< "$RECIPE_CODE"; then
    fail "call-site-has-no-exclusion" "the recipe's CODE passes no exclusion for the nested Ostler.app -- v1.0.49's failure returns verbatim"
else
    pass "the arm-8 recipe passes an exclusion for the nested Ostler.app"
fi

# ---- 8. the assertion that CAUGHT this must still be in the recipe -------
# The temptation after a fix is to relax the check that found it. BOTH VERBS:
# v1.0.47 passed an added-only check and shipped the defect anyway.
#
# 🔴 THE SUBJECT IS THE COUNT, NOT THE WORDS. Moving this arm off the comments
# was NOT enough -- I mutation-tested my own fix and it still passed. Deleting
# the two counting lines leaves the REPORT line behind, and it says the words:
#
#   18  added="$$(... | grep -c 'file added:')"          <- the subject
#   19  modified="$$(... | grep -c 'file modified:')"    <- the subject
#   20  printf '... file added=%s, file modified=%s\n'   <- satisfies a loose grep
#
# So the predicate must name the COUNT (`grep -c 'file added:'`, with codesign's
# trailing colon) AND the comparison that acts on it. Counting without comparing
# is inert; the pair is the guard. Mutation-proved: delete 18-19 and this arm
# goes RED, where the loose version stayed green.
A8=1
grep -q "grep -c 'file added:'"    <<< "$RECIPE_CODE" || { A8=0; MISS="counts 'file added:'"; }
grep -q "grep -c 'file modified:'" <<< "$RECIPE_CODE" || { A8=0; MISS="counts 'file modified:'"; }
grep -q 'added" -ne 0'             <<< "$RECIPE_CODE" || { A8=0; MISS="compares \$added against 0"; }
grep -q 'modified" -ne 0'          <<< "$RECIPE_CODE" || { A8=0; MISS="compares \$modified against 0"; }
if [[ "$A8" -eq 0 ]]; then
    fail "assertion-weakened" "the recipe's CODE no longer $MISS. That is the assertion that caught v1.0.49's 86-file seal break; a rewritten-in-place file is a MODIFICATION, not an addition, and without BOTH the count and the comparison the step reports and continues"
else
    pass "the post-seed assertion still COUNTS both added and modified AND refuses on either"
fi

# ---- 9. CONTROL: prove the loose predicate WOULD have been blind ---------
# This arm exists because two weaker versions of arms 7-8 shipped: the first
# scored COMMENTS, the second scored the report line. Both looked right. The
# control demonstrates, on the live recipe, that the loose form is satisfiable
# where the tight form is not -- so nobody "simplifies" arm 8 back.
LOOSE_IN_COMMENTS=0; TIGHT_IN_COMMENTS=0
grep -q 'file added'             <<< "$RECIPE_COMMENTS" && LOOSE_IN_COMMENTS=1
grep -q "grep -c 'file added:'"  <<< "$RECIPE_COMMENTS" && TIGHT_IN_COMMENTS=1
if [[ "$LOOSE_IN_COMMENTS" -eq 0 ]]; then
    fail "control-vacuous" "the recipe's comments do not quote 'file added' at all, so this control cannot show the loose predicate is blind. It would pass for the wrong reason"
elif [[ "$TIGHT_IN_COMMENTS" -eq 1 ]]; then
    fail "tight-predicate-also-in-comments" "the comments now quote the counting expression verbatim, so arm 8 is comment-satisfiable again. Tighten it further or stop quoting it"
else
    pass "control: 'file added' IS in the comments (loose form would be blind); the counting expression is NOT (arm 8 reads code only)"
fi

# ---- 10. CONTROL: arm 7 must be blind to the comments too ----------------
if grep -q 'Contents/Resources/Ostler' <<< "$RECIPE_COMMENTS" \
   && ! grep -q 'Contents/Resources/Ostler' <<< "$RECIPE_CODE"; then
    fail "arm7-satisfied-by-comment" "'Contents/Resources/Ostler' is present ONLY in the comments -- arm 7 would pass over a deleted argument"
elif ! grep -q 'Contents/Resources/Ostler' <<< "$RECIPE_COMMENTS"; then
    pass "control: arm 7's string is not in the comments (nothing to be fooled by)"
else
    pass "control: the comments mention it AND the code does too -- arm 7 reads code only"
fi

if [[ "$FAILED" -ne 0 ]]; then exit 1; fi
echo
echo "ALL NESTED-BUNDLE SEED EXCLUSION TESTS PASSED"
