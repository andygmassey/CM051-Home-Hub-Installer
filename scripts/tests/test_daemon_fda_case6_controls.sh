#!/usr/bin/env bash
#
# scripts/tests/test_daemon_fda_case6_controls.sh
#
# PROVES tests/test_daemon_fda_app_bundle_path.sh case-6 CAN FAIL, and fails on
# the defect rather than on the defect's formatting.
#
# WHY THIS EXISTS
# ---------------
# case-6 asserts that every TCC pre-probe SELECT covers both the daemon bundle
# ID and the legacy bare-binary client, so an upgrade from the v0.4.1 layout
# resolves its existing Full Disk Access grant instead of silently losing it.
#
# It used to assert that as an exact-literal grep for one rendering:
#     client IN ('ai.ostler.assistant', '${ASSISTANT_BINARY_LEGACY}')
# On 2026-07-26 install.sh hardened both sites to '${ASSISTANT_BINARY_LEGACY:-none}'
# and case-6 went red while the invariant it names was intact -- for three
# weeks, unnoticed, because the test file runs nowhere.
#
# A repaired predicate is worth nothing without evidence it can still go red.
# The controls below vary THE AXIS THE PREDICATE READS:
#
#   1  unmodified tree                          -> PASS   (not vacuous)
#   2  legacy client removed from ONE site      -> FAIL   (the real defect)
#   3  bundle ID removed from ONE site          -> FAIL   (the other half)
#   4  pre-1026-07-26 rendering restored        -> PASS   (formatting-blind)
#   5  every pre-probe deleted                  -> FAIL   (no vacuous green)
#
# Control 2 is the load-bearing one: it is the exact regression case-6 exists
# to catch, applied to only ONE of the two sites, which the original
# single-line grep would have passed.
# Control 4 is the one that distinguishes a repaired predicate from a merely
# re-pinned one: both renderings mean the same thing and both must pass.
# Control 5 refuses the shape where a loop over zero sites reports success.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_REL="tests/test_daemon_fda_app_bundle_path.sh"
fails=0

pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fixture tree holding only what the test reads. The test cd's to its own
# parent, so the fixture must carry the same relative layout.
build_fixture() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir/tests" "$dir/assistant-agent"
    cp "$REPO_ROOT/install.sh" "$dir/install.sh"
    cp "$REPO_ROOT/assistant-agent/INSTALL_SNIPPET.sh" "$dir/assistant-agent/INSTALL_SNIPPET.sh"
    cp "$REPO_ROOT/$TEST_REL" "$dir/tests/"
}

# Runs case-6 only, and reports its verdict. The other cases are irrelevant
# here and one of them failing would be read as case-6 failing.
run_case6() {
    local dir="$1" out rc
    out="$(bash "$dir/tests/$(basename "$TEST_REL")" 2>&1)"
    rc=$?
    printf '%s\n' "$out" | grep -qE '\[case-6\]' || {
        # No case-6 verdict at all means an earlier case aborted the run, and
        # a control that never reached the predicate proves nothing about it.
        echo "__NOVERDICT__"
        return 99
    }
    if printf '%s\n' "$out" | grep -q 'PASS \[case-6\]'; then
        echo "__PASS__"
    else
        echo "__FAIL__"
    fi
    return $rc
}

echo "case-6 controls: does the repaired predicate still go red?"

# --- 1: unmodified ----------------------------------------------------------
build_fixture "$WORK/c1"
v="$(run_case6 "$WORK/c1")"
if [ "$v" = "__PASS__" ]; then
    pass "control 1: unmodified tree -> case-6 PASSES"
else
    fail "control 1: unmodified tree -> case-6 did not pass ($v); every control below is meaningless"
fi

# --- 2: legacy client stripped from ONE site (THE defect) -------------------
build_fixture "$WORK/c2"
# Only the first occurrence, so the file keeps one correct site. The original
# grep would have matched that survivor and passed.
awk '!done && /ASSISTANT_BINARY_LEGACY:-none/ { sub(/, '\''\$\{ASSISTANT_BINARY_LEGACY:-none\}'\''/, ""); done=1 } { print }' \
    "$WORK/c2/install.sh" > "$WORK/c2/install.sh.new" && mv "$WORK/c2/install.sh.new" "$WORK/c2/install.sh"
if grep -c 'ASSISTANT_BINARY_LEGACY:-none' "$WORK/c2/install.sh" | grep -q '^1$'; then
    v="$(run_case6 "$WORK/c2")"
    if [ "$v" = "__FAIL__" ]; then
        pass "control 2: legacy client removed from ONE of two sites -> case-6 FAILS"
    else
        fail "control 2: the real regression did NOT trip case-6 ($v) -- the predicate is blind"
    fi
else
    fail "control 2: fixture mutation did not land; control did not exercise the predicate"
fi

# --- 3: bundle ID stripped from ONE site ------------------------------------
build_fixture "$WORK/c3"
awk '!done && /ai\.ostler\.assistant.*ASSISTANT_BINARY_LEGACY/ { sub(/'\''ai\.ostler\.assistant'\'', /, ""); done=1 } { print }' \
    "$WORK/c3/install.sh" > "$WORK/c3/install.sh.new" && mv "$WORK/c3/install.sh.new" "$WORK/c3/install.sh"
if [ "$(grep -c "client IN ('ai.ostler.assistant'" "$WORK/c3/install.sh")" = "1" ]; then
    v="$(run_case6 "$WORK/c3")"
    if [ "$v" = "__FAIL__" ]; then
        pass "control 3: bundle ID removed from ONE of two sites -> case-6 FAILS"
    else
        fail "control 3: missing bundle ID did NOT trip case-6 ($v)"
    fi
else
    fail "control 3: fixture mutation did not land; control did not exercise the predicate"
fi

# --- 4: the pre-hardening rendering (must still pass) -----------------------
build_fixture "$WORK/c4"
sed -i.bak 's/\${ASSISTANT_BINARY_LEGACY:-none}/${ASSISTANT_BINARY_LEGACY}/g' "$WORK/c4/install.sh"
rm -f "$WORK/c4/install.sh.bak"
if ! grep -q 'ASSISTANT_BINARY_LEGACY:-none' "$WORK/c4/install.sh" \
   && [ "$(grep -c 'ASSISTANT_BINARY_LEGACY}' "$WORK/c4/install.sh")" -ge 2 ]; then
    v="$(run_case6 "$WORK/c4")"
    if [ "$v" = "__PASS__" ]; then
        pass "control 4: pre-2026-07-26 rendering -> case-6 still PASSES (formatting-blind)"
    else
        fail "control 4: case-6 is still pinned to a rendering ($v) -- it would go red on the next harmless quoting change"
    fi
else
    fail "control 4: fixture mutation did not land; control did not exercise the predicate"
fi

# --- 5: no pre-probe at all (refuse the vacuous green) ----------------------
build_fixture "$WORK/c5"
grep -v 'kTCCServiceSystemPolicyAllFiles' "$WORK/c5/install.sh" > "$WORK/c5/install.sh.new" \
    && mv "$WORK/c5/install.sh.new" "$WORK/c5/install.sh"
if ! grep -q 'kTCCServiceSystemPolicyAllFiles' "$WORK/c5/install.sh"; then
    v="$(run_case6 "$WORK/c5")"
    if [ "$v" = "__FAIL__" ]; then
        pass "control 5: zero pre-probes -> case-6 FAILS rather than passing vacuously"
    else
        fail "control 5: an empty scan reported as a pass ($v) -- nothing looked at printed as nothing wrong"
    fi
else
    fail "control 5: fixture mutation did not land; control did not exercise the predicate"
fi

echo ""
if [ "$fails" -gt 0 ]; then
    printf '\033[0;31mcase-6 controls: %d FAILED\033[0m\n' "$fails"
    exit 1
fi
printf '\033[0;32mcase-6 controls: 5/5 -- the predicate fails on the defect and ignores its formatting\033[0m\n'
