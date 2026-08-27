#!/usr/bin/env bash
# test_grep_c_arith_safety.sh
#
# Regression net for the v1.0.15 box-walk defect: install.sh printed
#
#   install.sh: line 18193: [[: 0
#   0: syntax error in expression (error token is "0")
#
# into the customer-visible log on EVERY clean install.
#
# Cause: `grep -c PATTERN || echo 0`. When nothing matches, grep prints
# "0" to stdout AND exits 1, so the `|| echo 0` fallback fires as well.
# The command substitution captures BOTH lines, the variable becomes the
# two-line string "0\n0", and any `[[ "$var" -gt 0 ]]` on it is a syntax
# error. Zero matches is the HAPPY path for a doctor-error count, so this
# fired on every good install.
#
# Two independent checks:
#   1. BEHAVIOURAL -- reproduce both idioms in a subshell and assert the
#      broken one really does yield two lines and really does break the
#      arithmetic test. Without this the static check below is just a
#      style rule with no evidence behind it.
#   2. STATIC -- assert install.sh contains no `grep -c ... || echo N`
#      anywhere, so the pattern cannot creep back in at a new call site.
#
# Usage: bash tests/test_grep_c_arith_safety.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

pass=0
fail=0

ok()   { printf '  [PASS] %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1)); }

printf '== test_grep_c_arith_safety ==\n'

# ---------------------------------------------------------------------
# 1. BEHAVIOURAL -- prove the broken idiom is genuinely broken, and the
#    replacement genuinely is not. Guards against "fixed" a non-problem.
# ---------------------------------------------------------------------
broken="$(printf 'nothing here\n' | grep -c 'NO_SUCH_MARKER' 2>/dev/null || echo 0)"
broken_lines="$(printf '%s' "$broken" | wc -l | tr -d ' ')"

# printf of "0\n0" gives 1 newline -> wc -l == 1. A single "0" gives 0.
if [[ "$broken_lines" == "1" ]]; then
    ok "broken idiom 'grep -c ... || echo 0' yields TWO values on no-match"
else
    bad "broken idiom did not reproduce (got ${broken_lines} newline(s), want 1) -- the premise of this test no longer holds, investigate before deleting"
fi

if ( [[ "$broken" -gt 0 ]] ) 2>/dev/null; then
    bad "broken idiom's value did NOT break the arithmetic test -- premise gone"
else
    ok "broken idiom's value breaks '[[ -gt 0 ]]' as observed on the box"
fi

fixed="$(printf 'nothing here\n' | grep -c 'NO_SUCH_MARKER' 2>/dev/null || true)"
fixed="${fixed:-0}"
if [[ "$fixed" == "0" ]]; then
    ok "fixed idiom yields exactly '0' on no-match"
else
    bad "fixed idiom yielded '${fixed}', want '0'"
fi

if ( [[ "$fixed" -gt 0 ]] ) 2>/dev/null || [[ "$fixed" -eq 0 ]] 2>/dev/null; then
    ok "fixed idiom's value is arithmetic-safe"
else
    bad "fixed idiom's value is NOT arithmetic-safe"
fi

# Match case: the fixed idiom must still count correctly, not just be safe.
counted="$(printf 'x\nx\nx\n' | grep -c 'x' 2>/dev/null || true)"
counted="${counted:-0}"
if [[ "$counted" == "3" ]]; then
    ok "fixed idiom still counts matches correctly (3)"
else
    bad "fixed idiom counted '${counted}', want '3'"
fi

# ---------------------------------------------------------------------
# 2. STATIC -- no `grep -c ... || echo N` left anywhere in install.sh.
#    Comments are excluded so the explanatory notes at the fixed call
#    sites do not trip their own gate.
# ---------------------------------------------------------------------
if [[ ! -f "$INSTALL_SH" ]]; then
    bad "install.sh not found at ${INSTALL_SH}"
else
    offenders="$(grep -nE 'grep -c[^|]*\|\| *echo' "$INSTALL_SH" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    if [[ -z "$offenders" ]]; then
        ok "install.sh has no 'grep -c ... || echo N' call sites"
    else
        bad "install.sh still contains the broken idiom:"
        printf '%s\n' "$offenders" | sed 's/^/         /'
    fi
fi

# The two known call sites must both still be present and both safe.
# The assignments differ in quoting -- DOCTOR_ERRORS=$( ... ) is bare,
# TOTAL_STEPS="$( ... )" is quoted -- so the matcher allows an optional
# double quote before the command substitution. The first version of this
# test hard-coded the bare form and reported the quoted call site as
# "renamed", which would have read as a false alarm.
for marker in 'DOCTOR_ERRORS=' 'TOTAL_STEPS='; do
    line="$(grep -nE "^[[:space:]]*${marker}\"?\\\$\(" "$INSTALL_SH" | head -1 || true)"
    if [[ -z "$line" ]]; then
        bad "could not find the ${marker} assignment -- renamed? re-point this test"
    elif printf '%s' "$line" | grep -q '|| *echo'; then
        bad "${marker} assignment still uses '|| echo'"
    else
        ok "${marker} assignment is free of the broken fallback"
    fi
done

# ---------------------------------------------------------------------
# 4. THE GATE COULD ONLY SEE install.sh, SO THE DEFECT LIVED NEXT DOOR.
#
#    Measured on the live box 2026-08-27, from a probe this test never read:
#
#      ./install_error_honesty.sh: line 88: [: 0
#      0: integer expected
#      VERDICT: PASS
#
#    `grep -c` prints the count AND exits 1 on zero matches, so
#    `grep -c ... || echo 0` emits "0\n0". `[ "$errs" -gt 0 ]` then exits 2,
#    the comparison is SKIPPED, and the probe falls through to probe_pass.
#
#    install.sh was clean the whole time. The idiom had simply moved to a
#    surface the gate was not scoped to, which is the failure this repo keeps
#    paying for: a predicate scoped to where the bug WAS cannot see where it IS.
#
#    Scope now covers the box-walk probes as well. NOT widened to tests/ --
#    several tests carry this idiom deliberately, as fixtures, including this
#    one. A gate that flags its own positive control is not a wider gate, it is
#    a broken one.
# ---------------------------------------------------------------------
PROBE_DIR="${REPO_ROOT}/scripts/box_walk_probes"
if [[ ! -d "$PROBE_DIR" ]]; then
    bad "box-walk probe directory not found at ${PROBE_DIR} -- this section could not run, which is not a pass"
else
    probe_files=0
    probe_offenders=""
    while IFS= read -r _pf; do
        probe_files=$((probe_files + 1))
        _hits="$(grep -nE 'grep -c[^|]*\|\| *echo' "$_pf" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
        if [[ -n "$_hits" ]]; then
            probe_offenders="${probe_offenders}${_pf}
${_hits}
"
        fi
    done < <(find "$PROBE_DIR" -name '*.sh' -type f | sort)

    if [[ "$probe_files" -eq 0 ]]; then
        bad "zero probe files examined -- an empty scan is not a clean scan"
    elif [[ -z "$probe_offenders" ]]; then
        ok "no 'grep -c ... || echo N' call sites in ${probe_files} box-walk probe file(s)"
    else
        bad "box-walk probes still contain the broken idiom:"
        printf '%s\n' "$probe_offenders" | sed 's/^/         /'
    fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
