#!/bin/bash
#
# tests/verify_venvs_install_store_shim.sh
#
# Every venv that ships must carry the store-auth shim (#550).
#
# WHY THIS EXISTS. A venv created by a bare `python -m venv` gets no shim, so
# its clients reach the data stores with no credential and 401 the moment
# enforcement is on. Creating and seeding in ONE call is what makes site N+1
# impossible to get wrong. This gate asserts the population property that the
# helper's own internal fatal cannot provide: that NO bare venv site survives
# outside it.
#
# THREE OUTCOMES, THREE EXIT CODES. A gate that could not run has not passed.
#   0 PASS         every venv site routes through the helper
#   1 FAIL         at least one bare site
#   2 CANNOT_RUN   the predicate itself is not trustworthy here
#
# ── THE REGION PROBLEM, AND WHY THIS IS NOT A LINE FILTER ─────────────
#
# The obvious implementation greps for `-m venv` and drops any line that also
# says `_ostler_make_venv`. That works only if the helper is written on ONE
# line. It is not: the definition and its `-m venv` sit five lines apart, so
# the helper's own body reads as a bare site and the gate FALSE-FAILS on the
# very artefact it exists to enforce.
#
# Measured 2026-08-28 against the real multi-line helper:
#     examined 1 venv-creating invocations; 1 outside _ostler_make_venv()
#     FAIL:  4:  "$PYTHON3_BIN" -m venv "$_venv" || return $?
#
# That was not a weak test suite. The earlier version had nine arms, three of
# them regression arms added by attacking it, and EVERY ONE wrote the helper
# as `_ostler_make_venv() { "$PY" -m venv "$1"; }`. The fixtures agreed with
# each other about a shape the real code does not have. So the fix is a REGION
# exclusion plus a self-test arm that uses the multi-line shape.
#
# ── THE POSITIVE CONTROL ──────────────────────────────────────────────
#
# An exclusion region is a hole in the predicate, so it needs its own proof.
# The helper body MUST contain exactly one venv-creating line. Zero means the
# helper stopped creating venvs and the exclusion now hides nothing but could
# hide anything; two means a second creation path was smuggled inside the
# region where this gate cannot see it. Both are CANNOT_RUN, not PASS.
#
# Portability: POSIX grep/sed/awk only. This runs on ubuntu-latest (GNU) while
# install.sh only ever executes under BSD on macOS, so no GNU-only flags (no
# -P, no \b) appear here.

set -uo pipefail

# Mode flags are not filenames. Reading $1 straight into INSTALL made `--ci`
# resolve as a path and report CANNOT_RUN "no such file: --ci" -- a mode flag
# masquerading as a missing input, which is exactly the shape of answer this
# gate exists to refuse. Caught by running it.
MODE=""
case "${1:-}" in
    --self-test|--ci) MODE="$1"; shift ;;
esac
INSTALL="${1:-install.sh}"
HELPER="_ostler_make_venv"
rc_pass=0; rc_fail=1; rc_cannot=2

# ── ANTI-VACUITY FLOOR (@TNM, 2026-08-28) ─────────────────────────────
#
# "0 sites means the predicate broke" is too weak a control. @TNM's first
# predicate for this same population scored THREE, not zero: it anchored on a
# lowercase `python` and was therefore blind to `"$PYTHON3_BIN"`, the dominant
# form, while also counting two comments. THREE LOOKS LIKE AN ANSWER. A zero
# check would have waved it through.
#
# So the floor is PINNED, not derived from a scan of the file being checked --
# a number derived from the same broken predicate degrades with it.
#
# ⚠️ THIS ROW IS NOT A SECURITY INVARIANT. It says only "install.sh contained
# at least 15 venv-creating sites when this was written". Same contract as
# MUST_STILL_PUBLISH in tests/test_stores_publish_no_host_port.sh: if a site is
# legitimately DELETED, lower this number IN THE SAME PR and say which site and
# why. Do not raise it to silence a failure.
#
#   15 measured on main 36085632, 2026-08-28, by @TNM and @ARCHIE independently
#   473 496 530 2529 6495 6638 12189 15582 15761 16157 17698 18228 18478
#   18737 25822
#
# ⛔ AND IT IS TWO FLOORS, NOT ONE. @TNM, same day:
#
#   "a single 15 would go green while the limb was empty"
#
# He is right and this is the partial-denominator shape one level up. The 15
# decompose 3 + 12: three sites are the Sparkle UPGRADE path (473 496 530,
# which dial `$_py` from _upg_resolve_python3) and twelve are the main install.
# An AGGREGATE floor of 15 is satisfied by 0 + 15 or by 15 + 0. It cannot see a
# compartment emptying, and the compartment most likely to empty silently is
# the upgrade limb -- which is the entire population this work exists for.
#
# So each compartment carries its own floor and each is asserted separately.
# The discriminator is the interpreter token, because that is what actually
# differs: the upgrade leg has no PYTHON3_BIN in scope.
OSTLER_VENV_FLOOR_UPGRADE="${OSTLER_VENV_FLOOR_UPGRADE:-3}"
OSTLER_VENV_FLOOR_MAIN="${OSTLER_VENV_FLOOR_MAIN:-12}"
OSTLER_VENV_SITE_FLOOR="${OSTLER_VENV_SITE_FLOOR:-15}"

# Lines that CREATE a venv, comments stripped.
#  - `-m *venv` also catches the joined `-mvenv` form
#  - `virtualenv` is a second idiom that creates a venv without matching -m venv
#  - trailing comments are stripped BEFORE any helper test, because a bare call
#    on a line that merely NAMES the helper in a comment used to pass (measured)
venv_sites() {
    sed 's/[[:space:]]#.*$//' "$1" \
      | grep -nE -- '(-m[[:space:]]*venv|virtualenv)' \
      | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

# The helper's body, as a line range. Opens at a column-0 definition, closes at
# the first column-0 `}`. Inner braces are indented in real shell style, so they
# do not terminate the region -- there is a self-test arm for exactly that.
helper_start() {
    grep -nE "^(function[[:space:]]+)?${HELPER}[[:space:]]*\(\)[[:space:]]*\{?" "$1" \
      | cut -d: -f1 || true
}
helper_end() {   # $1 = file, $2 = start line
    awk -v s="$2" 'NR > s && /^\}[[:space:]]*$/ { print NR; exit }' "$1"
}

verify() {
    local f="$1" sites total starts nstart start end body_sites bare
    [ -f "$f" ] || { printf 'CANNOT_RUN: no such file: %s\n' "$f"; return $rc_cannot; }
    [ -s "$f" ] || { printf 'CANNOT_RUN: empty file: %s\n' "$f"; return $rc_cannot; }

    sites="$(venv_sites "$f")"
    total="$(printf '%s\n' "$sites" | grep -c . || true)"
    if [ "${total:-0}" -eq 0 ]; then
        printf 'CANNOT_RUN: found 0 venv-creating invocations, predicate suspect\n'
        printf '  a file that installs Ostler creates venvs. Zero means the\n'
        printf '  pattern stopped matching, not that the property holds.\n'
        return $rc_cannot
    fi
    # PER-COMPARTMENT first, aggregate second. The aggregate alone is satisfied
    # by 0 + 15, so it cannot see the upgrade limb empty.
    local n_upg n_main
    n_upg="$(printf '%s\n' "$sites" | grep -c '\$_py' || true)"
    n_main=$(( total - ${n_upg:-0} ))
    printf 'population: %s upgrade-leg (\$_py) + %s main = %s\n' \
        "${n_upg:-0}" "$n_main" "$total"
    if [ "${n_upg:-0}" -lt "$OSTLER_VENV_FLOOR_UPGRADE" ] \
       || [ "$n_main" -lt "$OSTLER_VENV_FLOOR_MAIN" ] \
       || [ "$total" -lt "$OSTLER_VENV_SITE_FLOOR" ]; then
        printf 'CANNOT_RUN: population below a floor (upgrade %s/%s, main %s/%s, total %s/%s)\n' \
            "${n_upg:-0}" "$OSTLER_VENV_FLOOR_UPGRADE" \
            "$n_main" "$OSTLER_VENV_FLOOR_MAIN" \
            "$total" "$OSTLER_VENV_SITE_FLOOR"
        printf '  A NON-ZERO UNDERCOUNT IS AS DAMNING AS A ZERO and it reads as an\n'
        printf '  answer. The compartments are checked SEPARATELY because an\n'
        printf '  aggregate of 15 is satisfied by 0 upgrade + 15 main, and the\n'
        printf '  upgrade leg is the population this gate exists for.\n'
        printf '  If sites were legitimately deleted, lower THAT floor in the same\n'
        printf '  PR and name them. Do not assume the shortfall is real.\n'
        return $rc_cannot
    fi

    starts="$(helper_start "$f")"
    nstart="$(printf '%s\n' "$starts" | grep -c . || true)"

    if [ "${nstart:-0}" -eq 0 ]; then
        # No helper at all. Every site is bare by definition. This is the state
        # of origin/main and it is a FAIL, not a CANNOT_RUN: the predicate ran
        # fine and the answer is that nothing routes through a helper.
        printf 'examined %s venv-creating invocations; %s() is not defined in this file\n' \
            "$total" "$HELPER"
        printf 'FAIL: a venv is created without the store-auth shim\n'
        printf '%s\n' "$sites" | sed 's/^/  /'
        return $rc_fail
    fi
    if [ "${nstart:-0}" -gt 1 ]; then
        printf 'CANNOT_RUN: %s() is defined %s times; the exclusion region is ambiguous\n' \
            "$HELPER" "$nstart"
        return $rc_cannot
    fi

    start="$starts"
    end="$(helper_end "$f" "$start")"
    if [ -z "$end" ]; then
        printf 'CANNOT_RUN: %s() opens at line %s and never closes at column 0\n' \
            "$HELPER" "$start"
        printf '  without an end the exclusion would swallow the rest of the file.\n'
        return $rc_cannot
    fi

    # POSITIVE CONTROL. The region we are about to trust must itself contain
    # exactly one venv-creating line.
    body_sites="$(printf '%s\n' "$sites" \
        | awk -F: -v s="$start" -v e="$end" '$1 > s && $1 < e' | grep -c . || true)"
    if [ "${body_sites:-0}" -ne 1 ]; then
        printf 'CANNOT_RUN: %s() body (lines %s-%s) holds %s venv-creating lines, expected exactly 1\n' \
            "$HELPER" "$start" "$end" "${body_sites:-0}"
        if [ "${body_sites:-0}" -eq 0 ]; then
            printf '  zero: the helper no longer creates the venv, so excluding its\n'
            printf '  body proves nothing and may be hiding a real site.\n'
        else
            printf '  more than one: a second creation path sits inside the region\n'
            printf '  where this gate cannot see it.\n'
        fi
        return $rc_cannot
    fi

    bare="$(printf '%s\n' "$sites" \
        | awk -F: -v s="$start" -v e="$end" '$1 < s || $1 > e' | grep -c . || true)"
    printf 'examined %s venv-creating invocations; helper body is lines %s-%s; %s outside it\n' \
        "$total" "$start" "$end" "${bare:-0}"
    if [ "${bare:-0}" -gt 0 ]; then
        printf 'FAIL: a venv is created without the store-auth shim\n'
        printf '%s\n' "$sites" | awk -F: -v s="$start" -v e="$end" '$1 < s || $1 > e' | sed 's/^/  /'
        return $rc_fail
    fi
    printf 'PASS: every venv site routes through %s()\n' "$HELPER"
    return $rc_pass
}

self_test() {
    # No `trap ... RETURN` here. A RETURN trap fires in the CALLER's context,
    # by which time the local `d` is out of scope, so under `set -u` it aborted
    # with "d: unbound variable" the moment anything called self_test and then
    # carried on (ci_mode does). It was invisible while the only caller exited
    # immediately afterwards. Cleanup is explicit at the end instead.
    local d rc fails=0; d="$(mktemp -d)"
    # Fixtures are a handful of lines; the install.sh floor cannot apply to them.
    # The floor gets its own arm below, against a fixture built to trip it.
    local real_floor="$OSTLER_VENV_SITE_FLOOR"
    OSTLER_VENV_SITE_FLOOR=0
    OSTLER_VENV_FLOOR_UPGRADE=0
    OSTLER_VENV_FLOOR_MAIN=0

    : > "$d/empty"
    printf 'no venv here at all\n' > "$d/no_sites"

    # The REAL shape: multi-line helper. This is the arm whose absence let a
    # false-FAIL ship -- every earlier fixture put the helper on one line.
    cat > "$d/multiline_good" <<'FIXTURE'
_ostler_make_venv() {
    local _venv="$1"
    if [ ! -d "$_venv" ]; then
        "$PYTHON3_BIN" -m venv "$_venv" || return $?
    fi
    return 0
}
_ostler_make_venv "$DOCTOR_DIR/.venv"
FIXTURE

    cat > "$d/multiline_bare" <<'FIXTURE'
_ostler_make_venv() {
    local _venv="$1"
    "$PYTHON3_BIN" -m venv "$_venv" || return $?
}
"$PYTHON3_BIN" -m venv /somewhere/else
FIXTURE

    # Nested braces INSIDE the body must not close the region early. Without
    # the column-0 anchor the region would end at the inner `}` and the later
    # helper line would read as bare.
    cat > "$d/nested_braces" <<'FIXTURE'
_ostler_make_venv() {
    if [ -n "$1" ]; then
        :
    fi
    case "$1" in
        *) : ;;
    esac
    "$PYTHON3_BIN" -m venv "$1"
}
_ostler_make_venv /a
FIXTURE

    # POSITIVE-CONTROL arms: the region must earn the trust it is given.
    cat > "$d/body_zero" <<'FIXTURE'
_ostler_make_venv() {
    cp shim "$1"
}
"$PYTHON3_BIN" -m venv /a
FIXTURE

    cat > "$d/body_two" <<'FIXTURE'
_ostler_make_venv() {
    "$PYTHON3_BIN" -m venv "$1"
    "$PYTHON3_BIN" -m venv "$2"
}
FIXTURE

    cat > "$d/two_helpers" <<'FIXTURE'
_ostler_make_venv() {
    "$PYTHON3_BIN" -m venv "$1"
}
_ostler_make_venv() {
    "$PYTHON3_BIN" -m venv "$1"
}
FIXTURE

    cat > "$d/unterminated" <<'FIXTURE'
_ostler_make_venv() {
    "$PYTHON3_BIN" -m venv "$1"
FIXTURE

    # No helper at all -- origin/main's state. FAIL, not CANNOT_RUN.
    printf '"$PYTHON3_BIN" -m venv /a\n' > "$d/no_helper"

    # Regression arms carried over: each was a REAL false PASS once.
    cat > "$d/r1" <<'FIXTURE'
_ostler_make_venv() {
    "$PYTHON3_BIN" -m venv "$1"
}
"$PY" -m venv /o  # not via _ostler_make_venv
FIXTURE
    cat > "$d/r2" <<'FIXTURE'
_ostler_make_venv() {
    "$PYTHON3_BIN" -m venv "$1"
}
"$PY" -mvenv /o
FIXTURE
    cat > "$d/r3" <<'FIXTURE'
_ostler_make_venv() {
    "$PYTHON3_BIN" -m venv "$1"
}
virtualenv /o
FIXTURE
    cat > "$d/comment_only" <<'FIXTURE'
# "$PY" -m venv /commented
_ostler_make_venv() {
    "$PYTHON3_BIN" -m venv "$1"
}
FIXTURE

    check() { verify "$3" >/dev/null 2>&1; rc=$?
        if [ "$rc" -eq "$2" ]; then printf '  ok   %-38s rc=%s\n' "$1" "$rc"
        else printf '  FAIL %-38s rc=%s want=%s\n' "$1" "$rc" "$2"; fails=$((fails+1)); fi; }

    check "MULTI-LINE helper, compliant"     $rc_pass   "$d/multiline_good"
    check "MULTI-LINE helper, one bare site" $rc_fail   "$d/multiline_bare"
    check "nested braces do not close early" $rc_pass   "$d/nested_braces"
    check "CONTROL body has zero venv lines" $rc_cannot "$d/body_zero"
    check "CONTROL body has two venv lines"  $rc_cannot "$d/body_two"
    check "helper defined twice"             $rc_cannot "$d/two_helpers"
    check "helper never closes"              $rc_cannot "$d/unterminated"
    check "no helper at all (main today)"    $rc_fail   "$d/no_helper"
    check "commented-out site ignored"       $rc_pass   "$d/comment_only"
    check "absent file"                      $rc_cannot "$d/nonexistent"
    check "empty file"                       $rc_cannot "$d/empty"
    check "zero sites"                       $rc_cannot "$d/no_sites"
    check "REGRESSION helper named in comment" $rc_fail "$d/r1"
    check "REGRESSION -mvenv joined"         $rc_fail   "$d/r2"
    check "REGRESSION virtualenv idiom"      $rc_fail   "$d/r3"

    # FLOOR arm. @TNM's broken predicate scored 3 against a population of 15 and
    # 3 looks like an answer. This proves the floor catches an undercount that a
    # zero-check waves through. Compliant on purpose: without the floor it would
    # PASS, so any rc other than CANNOT_RUN means the floor is not firing.
    OSTLER_VENV_SITE_FLOOR="$real_floor"
    OSTLER_VENV_FLOOR_UPGRADE=3
    OSTLER_VENV_FLOOR_MAIN=12
    check "FLOOR trips on a plausible undercount" $rc_cannot "$d/multiline_good"

    # @TNM's catch, as an arm. 15 sites, ALL main leg, upgrade leg EMPTY.
    # The aggregate floor of 15 is satisfied. Only the per-compartment floor
    # sees that the population this gate exists for has vanished.
    {   printf '_ostler_make_venv() {\n    "$PYTHON3_BIN" -m venv "$1"\n}\n'
        i=0; while [ "$i" -lt 15 ]; do
            printf '"$PYTHON3_BIN" -m venv /main/%s\n' "$i"; i=$((i+1)); done
    } > "$d/aggregate_hides_empty_limb"
    check "SPLIT FLOOR sees an empty upgrade limb" $rc_cannot "$d/aggregate_hides_empty_limb"
    OSTLER_VENV_SITE_FLOOR=0; OSTLER_VENV_FLOOR_UPGRADE=0; OSTLER_VENV_FLOOR_MAIN=0

    printf '  self-test failures: %s\n' "$fails"
    rm -rf "$d"
    return $((fails > 0))
}

# ── CI MODE: the gate ENFORCES from the moment it merges ──────────────
#
# The hoist does not exist yet, so `verify` is legitimately RED on main. A gate
# that merges "to be wired later" gates NOTHING -- @TNM lost his own gate to
# exactly this today: scripts/verify_wired_paths_are_tracked.sh is 0 bytes on
# main because it lives on an unmerged PR, and he had to fetch refs/pull/.../head
# to read a file he wrote.
#
# So the expectation is PINNED and asserted. Today main must FAIL with 15 bare
# sites. That means:
#   - if someone adds a 16th bare site, CI goes red         (drift caught)
#   - if the hoist lands, CI goes red until this constant   (progress is a
#     is flipped to pass IN THAT SAME PR                     deliberate act)
#   - the gate can never sit dormant reading as protection  (#550's own class)
#
# ⚠️ FLIP TRIGGER: change to "pass" in the PR that lands _ostler_make_venv and
# hoists the sites. Not before, and never to silence a failure.
OSTLER_VENV_EXPECT="${OSTLER_VENV_EXPECT:-fail}"

ci_mode() {
    local rc want
    printf '== self-test ==\n'
    self_test || { printf 'CANNOT_RUN: the gate does not pass its own self-test\n' >&2; return 2; }
    printf '\n== %s ==\n' "$INSTALL"
    verify "$INSTALL"; rc=$?
    case "$OSTLER_VENV_EXPECT" in
        pass) want=$rc_pass ;;
        fail) want=$rc_fail ;;
        *) printf 'CANNOT_RUN: OSTLER_VENV_EXPECT=%s is not pass|fail\n' \
               "$OSTLER_VENV_EXPECT" >&2; return 2 ;;
    esac
    printf '\n'
    if [ "$rc" -eq "$want" ]; then
        printf 'GATE OK: verdict rc=%s matches the pinned expectation (%s).\n' \
            "$rc" "$OSTLER_VENV_EXPECT"
        [ "$OSTLER_VENV_EXPECT" = "fail" ] && printf \
'  This is a KNOWN-RED gate. install.sh still creates venvs with no store-auth
  shim. It is red ON PURPOSE and the redness is asserted, so it cannot be
  mistaken for protection. Flip OSTLER_VENV_EXPECT to "pass" in the PR that
  lands the hoist.\n'
        return 0
    fi
    printf 'GATE BROKEN: verdict rc=%s but the pinned expectation is %s (rc=%s).\n' \
        "$rc" "$OSTLER_VENV_EXPECT" "$want" >&2
    if [ "$rc" -eq "$rc_pass" ]; then
        printf '  install.sh now PASSES. If you landed the hoist, flip
  OSTLER_VENV_EXPECT to "pass" in this PR.\n' >&2
    else
        printf '  Read the verdict above. Either a new bare venv site was added,
  or the predicate broke. Do not flip the expectation to make this green.\n' >&2
    fi
    return 1
}

case "$MODE" in
    --self-test) self_test; exit $? ;;
    --ci)        ci_mode;   exit $? ;;
esac
verify "$INSTALL"; exit $?
