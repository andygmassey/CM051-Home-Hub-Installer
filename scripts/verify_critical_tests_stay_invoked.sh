#!/usr/bin/env bash
# Critical tests must stay INVOKED, not merely mentioned
# =====================================================
#
# THE HOLE THIS CLOSES, demonstrated 2026-08-19 before it was written.
#
# A fix lands with a test. Weeks later someone comments out the invocation, or
# swaps `run: bash tests/foo.sh` for `run: echo "temporarily disabled"`, and the
# defect the test guards can walk straight back in. Measured on origin/main by
# doing exactly that to tests/test_no_data_is_not_success.sh:
#
#     verify_test_wiring.sh          -> "OK: no test file is newly unwired"
#     verify_test_wiring --regenerate -> file identical, no diff, CI green
#
# NOTHING CAUGHT IT. Both readers match a MENTION, and the filename still
# appeared in the workflow's `paths:` trigger list, so the register happily kept
# reporting WIRED for a test that no longer ran.
#
# #857 closed the NEW-test case (a test added by a change must be invoked by
# that change). It is diff-scoped by design, so it cannot see a test that was
# wired last month and quietly unwired today. And its predicate is a
# comment-stripped substring search, which a `paths:` entry also satisfies.
#
# So this file is deliberately NOT a generalisation of #857. It is the other
# half: a small, explicit, whole-tree register of tests that guard defects we
# have already paid for once, checked on every PR, using a STRICTER predicate.
#
# ---------------------------------------------------------------------------
# THE PREDICATE, and why it is not the same as #857's
# ---------------------------------------------------------------------------
#
# A test counts as INVOKED only if its path or basename appears, outside
# comments, on a line that also carries an EXECUTION VERB:
#
#     bash | sh | pytest | python3 -m | ./
#
# That is what separates
#
#     run: bash tests/test_no_data_is_not_success.sh     <- invocation
#     - 'tests/test_no_data_is_not_success.sh'           <- a paths: trigger
#
# The second is why the R6 un-wiring went unnoticed. A trigger says "re-run the
# workflow when this file changes"; it says nothing about whether anything in
# that workflow still executes it.
#
# ---------------------------------------------------------------------------
# WHAT GOES IN THE REGISTER
# ---------------------------------------------------------------------------
#
# Only tests that pin a defect which ALREADY REACHED A CUSTOMER or ALREADY
# BURNED A BUILD. This list is meant to stay short and to be added to
# deliberately. A long list nobody curates decays into noise, and noise is how
# the last register ended up with a 128-test grandfathered baseline.
#
# Adding a line here is a promise that the named test may never go dark again.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || { echo "CANNOT-RUN: cannot cd to repo root" >&2; exit 2; }

# ── THE REGISTER ────────────────────────────────────────────────────────────
# path                                            what it stops coming back
CRITICAL_TESTS="
tests/test_no_data_is_not_success.sh              a source that found no input claiming success, and --repair doing nothing
tests/test_hydrate_sentinel_not_on_error.sh       a FAILED hydrate step suppressing its own retry for 7 days
tests/test_aiconv_hydrate_honesty.sh              a timed-out or crashed drain recording itself as complete
scripts/tests/test_egress_probe_attribution.sh    an unattributable socket being silently counted as the operator's own
scripts/tests/test_new_tests_are_wired_predicate.sh  a newly added test never being invoked by anything
"

cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }

# ── APPARATUS CONTROL ───────────────────────────────────────────────────────
# An empty corpus would score every test DARK for want of anywhere to look,
# which is a broken probe, not a finding.
RUNNERS="$(git ls-files 2>/dev/null \
    | grep -E '^\.github/workflows/.*\.ya?ml$|\.sh$|\.py$|^Makefile$|/Makefile$' || true)"
RUNNER_N="$(printf '%s' "$RUNNERS" | grep -c . || true)"
[ "${RUNNER_N:-0}" -gt 0 ] || cannot_run "no runner files found; every test would score dark for want of anywhere to look"

CORPUS="$(mktemp -t criticalwiring_XXXXXX)"
trap 'rm -f "$CORPUS"' EXIT
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    sed 's/#.*$//' "$f"
done <<EOF >"$CORPUS"
$RUNNERS
EOF

# Is $1 invoked, rather than merely named, anywhere in the comment-stripped
# corpus? Requires an execution verb on the SAME line.
is_invoked() {
    local t="$1" base
    base="$(basename "$t")"
    grep -E "(bash|sh|pytest|python3 -m|\./)[^#]*($(printf '%s' "$t" | sed 's/[.[\*^$/]/\\&/g')|$(printf '%s' "$base" | sed 's/[.[\*^$/]/\\&/g'))" \
        "$CORPUS" >/dev/null 2>&1
}

echo "verify_critical_tests_stay_invoked"
echo "runner files searched (comments stripped): ${RUNNER_N}"
echo

DARK=""
CHECKED=0
MISSING=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    t="$(printf '%s' "$line" | awk '{print $1}')"
    why="$(printf '%s' "$line" | sed 's/^[^ ]* *//')"
    [ -n "$t" ] || continue
    CHECKED=$((CHECKED + 1))
    if [ ! -f "$t" ]; then
        printf '  ABSENT   %s\n             the file itself is gone: %s\n' "$t" "$why"
        MISSING="${MISSING}    ${t}  (file deleted)
"
        continue
    fi
    if is_invoked "$t"; then
        printf '  INVOKED  %s\n' "$t"
    else
        printf '  DARK     %s\n             would let this come back: %s\n' "$t" "$why"
        DARK="${DARK}    ${t}  -- ${why}
"
    fi
done <<EOF
$CRITICAL_TESTS
EOF

echo
echo "critical tests checked: ${CHECKED}"

# ── POSITIVE CONTROL ────────────────────────────────────────────────────────
# The register must not be empty. An empty register passes vacuously, and a
# gate over nothing is not a pass.
if [ "${CHECKED:-0}" -eq 0 ]; then
    cannot_run "the register is empty, so this gate examined nothing"
fi

# ── NEGATIVE CONTROL ────────────────────────────────────────────────────────
# A name that is invoked nowhere must NOT be reported as invoked. Without this,
# a predicate that matched everything would pass the whole register.
if is_invoked "tests/test_archie_negative_control_must_never_be_invoked.sh"; then
    cannot_run "the invocation predicate matched a test that does not exist. It is not discriminating, so its INVOKED verdicts mean nothing"
fi

if [ -n "$MISSING" ] || [ -n "$DARK" ]; then
    echo
    echo "FAIL: a test in the critical register is no longer invoked." >&2
    [ -n "$MISSING" ] && { echo "  DELETED:" >&2; printf '%s' "$MISSING" >&2; }
    [ -n "$DARK" ] && { echo "  NOT INVOKED:" >&2; printf '%s' "$DARK" >&2; }
    echo >&2
    echo "  Each of these pins a defect that already cost us a cut or reached a box." >&2
    echo "  Re-invoke it from a workflow or runner, or -- if it is genuinely obsolete --" >&2
    echo "  remove its line from CRITICAL_TESTS in this file, in the same change, with" >&2
    echo "  the reason in the commit message. Do not leave it listed and dark." >&2
    echo >&2
    echo "  NOTE: adding the path to a workflow's paths: trigger does NOT count." >&2
    echo "  A trigger re-runs the workflow when the file changes; it does not run" >&2
    echo "  the test. That exact confusion is why this gate exists." >&2
    exit 1
fi

echo "ALL CRITICAL TESTS STILL INVOKED"
