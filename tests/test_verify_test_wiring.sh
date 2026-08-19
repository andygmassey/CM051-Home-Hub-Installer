#!/usr/bin/env bash
#
# tests/test_verify_test_wiring.sh
#
# Self-test for the test-wiring gate (v1018-D621g).
#
# The gate's whole job is to notice that a test runs nowhere. A gate with that
# job which itself runs nowhere, or which cannot tell "no unwired tests" from
# "I could not enumerate the tests", is the joke telling itself.
#
# So: fixture trees, not the real repo. Each control builds a tiny tests/ +
# .github/workflows/ pair and asserts the verdict AND the exit code.
#
# Exit 0 all controls pass / 1 a control failed / 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO_ROOT/scripts/verify_test_wiring.sh"

if [ ! -x "$GATE" ]; then
    echo "CANNOT RUN: gate not executable at $GATE" >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wiring-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

# fixture <name> -> sets T (tests dir), W (workflows dir), M (manifest path)
fixture() {
    local n="$1"
    T="$WORK/$n/tests"; W="$WORK/$n/.github/workflows"; M="$WORK/$n/TEST_WIRING.tsv"
    rm -rf "$WORK/$n"; mkdir -p "$T" "$W"
}

run_gate() { # -> OUT, RC
    OUT="$(TEST_WIRING_MANIFEST="$M" TEST_WIRING_TESTS_DIR="$T" \
           TEST_WIRING_WORKFLOWS_DIR="$W" /bin/bash "$GATE" "$@" 2>&1)"
    RC=$?
}

printf '== test_verify_test_wiring ==\n'

# --- 1. a wired test passes -------------------------------------------------
fixture wired
echo 'echo hi' > "$T/test_alpha.sh"
printf 'jobs:\n  x:\n    steps:\n      - run: bash tests/test_alpha.sh\n' > "$W/ci.yml"
run_gate --regenerate
run_gate
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "WIRED   : 1"; then
    ok "a test named in a workflow is WIRED -> exit 0"
else
    bad "wired test: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- 2. THE DEFECT: a new unwired test fails --------------------------------
# The manifest is generated while only test_alpha exists, then a second test
# appears with nothing to start it. This is the exact shape the gate exists to
# stop: the 128 growing to 129.
echo 'echo orphan' > "$T/test_beta.sh"
run_gate
if [ "$RC" -eq 1 ] \
   && printf '%s' "$OUT" | grep -q "THE UNWIRED SET GREW" \
   && printf '%s' "$OUT" | grep -q "test_beta.sh"; then
    ok "a NEW unwired test -> exit 1, named"
else
    bad "new unwired test: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- 3. the recorded backlog does NOT fail ---------------------------------
# Otherwise the gate is red on the day it lands and gets routed around, which
# is how the PR-age rule was nearly lost.
run_gate --regenerate
run_gate
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "UNWIRED : 1"; then
    ok "a RECORDED unwired test -> exit 0, but the count is printed"
else
    bad "recorded backlog: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- 4. transitive: a test invoked BY a wired test counts -------------------
fixture transitive
printf 'bash "$(dirname "$0")/test_helper_child.sh"\n' > "$T/test_parent.sh"
echo 'echo child' > "$T/test_helper_child.sh"
printf 'jobs:\n  x:\n    steps:\n      - run: bash tests/test_parent.sh\n' > "$W/ci.yml"
run_gate --regenerate
run_gate
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "WIRED   : 2"; then
    ok "a test invoked by a wired test is WIRED (transitive)"
else
    bad "transitive: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- 5. a Makefile / script counts as a starter too -------------------------
# Not every test is started by a workflow; some run from release.sh or a
# script. Scoring those UNWIRED would be a false accusation, and a gate that
# cries wolf gets switched off.
fixture viascript
echo 'echo hi' > "$T/test_gamma.sh"
printf 'jobs:\n  x:\n    steps:\n      - run: echo nothing\n' > "$W/ci.yml"
run_gate --regenerate
if grep -q 'test_gamma.sh	UNWIRED' "$M"; then
    ok "control: with no starter, test_gamma is UNWIRED (the probe works)"
else
    bad "test_gamma should have been UNWIRED with no starter"
    cat "$M" | sed 's/^/        /'
fi

# --- 6. CANNOT RUN is exit 2, never a pass ---------------------------------
fixture cannotrun
echo 'x' > "$T/test_delta.sh"
printf 'jobs: {}\n' > "$W/ci.yml"
T_SAVED="$T"; T="$WORK/cannotrun/does-not-exist"
run_gate
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "CANNOT RUN"; then
    ok "missing tests directory -> exit 2 CANNOT RUN"
else
    bad "missing tests dir: rc=$RC (expected 2)"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi
T="$T_SAVED"

fixture emptyscan
printf 'jobs: {}\n' > "$W/ci.yml"
run_gate
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "found NO test files"; then
    ok "no test files at all (empty scan) -> exit 2, NOT a clean report"
else
    bad "empty scan: rc=$RC (expected 2)"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

fixture nomanifest
echo 'x' > "$T/test_eps.sh"
printf 'jobs:\n  x:\n    steps:\n      - run: bash tests/test_eps.sh\n' > "$W/ci.yml"
run_gate    # no --regenerate, so no manifest exists
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "no manifest"; then
    ok "manifest absent -> exit 2 CANNOT RUN (not a silent pass)"
else
    bad "no manifest: rc=$RC (expected 2)"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

fixture malformed
echo 'x' > "$T/test_zeta.sh"
printf 'jobs:\n  x:\n    steps:\n      - run: bash tests/test_zeta.sh\n' > "$W/ci.yml"
printf 'this row has no tab at all\n' > "$M"
run_gate
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "malformed manifest row"; then
    ok "malformed manifest row -> exit 2, not a guessed verdict"
else
    bad "malformed manifest: rc=$RC (expected 2)"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

# --- 7. a file with no row at all is caught --------------------------------
# Distinct from "unwired": a test can be WIRED and still be missing from the
# manifest, which means the manifest has silently stopped describing reality.
fixture drift
echo 'x' > "$T/test_one.sh"
printf 'jobs:\n  x:\n    steps:\n      - run: bash tests/test_one.sh tests/test_two.sh\n' > "$W/ci.yml"
run_gate --regenerate
echo 'x' > "$T/test_two.sh"
run_gate
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "no row in the manifest"; then
    ok "a WIRED file missing from the manifest -> exit 1 (drift caught)"
else
    bad "manifest drift: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
