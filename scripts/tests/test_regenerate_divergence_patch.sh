#!/usr/bin/env bash
#
# scripts/tests/test_regenerate_divergence_patch.sh
#
# Self-test for scripts/regenerate_divergence_patch.sh -- the tool that RECORDS
# a vendored graft rather than deleting it.
#
# WHY THIS MATTERS MORE THAN A USUAL SELF-TEST
# -------------------------------------------
# This tool writes the only file that distinguishes a deliberate graft from
# accidental drift. Every refusal in it is load-bearing: if it can be talked
# into blessing upstream commits, or into running across trees in bulk, or into
# leaving a patch that cannot rebuild its own tree, it becomes a faster way to
# cause the damage it was built to prevent.
#
# So the controls are mostly REFUSALS. A tool whose safety is all in its guards
# needs its guards exercised, not its happy path.
#
#   1  fresh tree                          REFUSED, nothing to record
#   2  divergent tree, dry run             prints, writes NOTHING
#   3  --write without the confirm env     REFUSED
#   4  --write with the confirm env        writes, self-verifies, tree rebuilds
#   5  re-run after a successful write     REFUSED, patch already correct
#   6  source advanced past the pin        REFUSED as a RE-PIN
#   7  the vendored tree is never touched  across every control above
#
# Control 7 is the invariant the whole design rests on: this tool must change
# no shipped bytes. It is checked by hashing the vendored tree before and after
# every single control, not just at the end.
#
# Fixture shape mirrors tests/test_vendor_fresh_gate.sh so the two agree about
# what a vendored tree looks like.
#
# RUNTIME: SLOW BY DESIGN, roughly 20s per tool invocation and eight of them,
# so budget three minutes. Each control builds a real git repo and drives the
# real materialise path -- that is the point, a mocked materialiser would not
# exercise the guards that matter. Noted here because the first run of this
# file was killed by a 120s limit and the timeout read as a test failure. Slow
# is not hung, and a harness timeout is a CANNOT-RUN, not a red.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="scripts/regenerate_divergence_patch.sh"
fails=0

pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

command -v git >/dev/null 2>&1 || { echo "CANNOT RUN: git unavailable" >&2; exit 2; }
[ -f "$REPO_ROOT/$TOOL" ] || { echo "CANNOT RUN: $TOOL missing" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build a hermetic fixture. Prints the pinned SHA.
make_fixture() {
    local root="$1" src="$1/synthetic-source"
    mkdir -p "$src/pkg"
    (
        cd "$src"
        git init --quiet
        git config user.email selftest@example.com
        git config user.name "regen self-test"
        printf 'def hello():\n    return "v1"\n' > pkg/mod.py
        git add pkg/mod.py
        git commit --quiet -m "v1: initial"
    )
    local sha; sha="$(git -C "$src" rev-parse HEAD)"
    mkdir -p "$root/scripts" "$root/vendor/synthtree/pkg" "$root/vendor/divergences"
    cp "$REPO_ROOT/scripts/_vendor_lib.sh" \
       "$REPO_ROOT/scripts/regenerate_divergence_patch.sh" "$root/scripts/"
    cp "$src/pkg/mod.py" "$root/vendor/synthtree/pkg/mod.py"
    cat > "$root/vendor/VENDOR_MANIFEST.toml" <<EOF
[[tree]]
name             = "synthtree"
vendor_path      = "vendor/synthtree"
source_repo      = "$src"
source_path      = "."
pinned_sha       = "$sha"
divergence_patch = "vendor/divergences/synthtree.patch"
exclude          = ["__pycache__/"]
verify           = "full"
EOF
    printf '%s\n' "$sha"
}

# Hash the vendored tree so control 7 can be checked after EVERY control.
vendor_hash() { ( cd "$1/vendor/synthtree" && find . -type f | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 ); }

run_tool() { ( cd "$1" && shift && bash scripts/regenerate_divergence_patch.sh "$@" 2>&1 ); }

echo "regenerate_divergence_patch: guards"

# --- 1: fresh tree -> REFUSED ------------------------------------------------
R1="$WORK/c1"; mkdir -p "$R1"; make_fixture "$R1" >/dev/null
H1="$(vendor_hash "$R1")"
out="$(run_tool "$R1" synthtree)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'not divergent'; then
    pass "control 1: fresh tree -> REFUSED (rc=1, 'not divergent')"
else
    fail "control 1: fresh tree -> rc=$rc, expected refusal"
fi
[ "$(vendor_hash "$R1")" = "$H1" ] || fail "control 1: THE VENDORED TREE CHANGED"

# --- 2: divergent, dry run -> prints, writes nothing -------------------------
R2="$WORK/c2"; mkdir -p "$R2"; make_fixture "$R2" >/dev/null
printf 'def hello():\n    return "v1"\n\ndef graft():\n    return "local"\n' \
    > "$R2/vendor/synthtree/pkg/mod.py"
H2="$(vendor_hash "$R2")"
out="$(run_tool "$R2" synthtree)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'DRY RUN. Nothing written.' \
   && printf '%s' "$out" | grep -q 'PROPOSED PATCH'; then
    pass "control 2: divergent, dry run -> prints proposal, rc=0"
else
    fail "control 2: dry run -> rc=$rc, missing proposal or DRY RUN banner"
fi
[ -f "$R2/vendor/divergences/synthtree.patch" ] \
    && fail "control 2: DRY RUN WROTE A PATCH FILE" \
    || pass "control 2: no patch file written"
[ "$(vendor_hash "$R2")" = "$H2" ] || fail "control 2: THE VENDORED TREE CHANGED"

# --- 3: --write without confirm -> REFUSED -----------------------------------
out="$(run_tool "$R2" synthtree --write)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'VENDOR_PATCH_REGEN_CONFIRM'; then
    pass "control 3: --write without the confirm env -> REFUSED"
else
    fail "control 3: --write without confirm -> rc=$rc, expected refusal"
fi
[ -f "$R2/vendor/divergences/synthtree.patch" ] \
    && fail "control 3: WROTE A PATCH WITHOUT CONFIRMATION" \
    || pass "control 3: still no patch file"
[ "$(vendor_hash "$R2")" = "$H2" ] || fail "control 3: THE VENDORED TREE CHANGED"

# --- 4: --write WITH confirm -> writes and self-verifies ---------------------
out="$( cd "$R2" && VENDOR_PATCH_REGEN_CONFIRM=synthtree \
        bash scripts/regenerate_divergence_patch.sh synthtree --write 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'The graft is now RECORDED'; then
    pass "control 4: --write with confirm -> wrote and self-verified"
else
    fail "control 4: --write with confirm -> rc=$rc"
    printf '%s\n' "$out" | tail -6 | sed 's/^/        /'
fi
[ -s "$R2/vendor/divergences/synthtree.patch" ] \
    && pass "control 4: patch file exists and is non-empty" \
    || fail "control 4: no patch written"
[ "$(vendor_hash "$R2")" = "$H2" ] || fail "control 4: THE VENDORED TREE CHANGED"

# --- 5: re-run after a good write -> REFUSED (already correct) ---------------
out="$(run_tool "$R2" synthtree)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qE 'already correct|nothing would change'; then
    pass "control 5: re-run after write -> REFUSED, patch already correct"
else
    fail "control 5: re-run -> rc=$rc, expected 'already correct' refusal"
fi
[ "$(vendor_hash "$R2")" = "$H2" ] || fail "control 5: THE VENDORED TREE CHANGED"

# --- 6: source advanced past the pin -> REFUSED as a RE-PIN ------------------
R6="$WORK/c6"; mkdir -p "$R6"; make_fixture "$R6" >/dev/null
printf 'def hello():\n    return "v1"\n\ndef graft():\n    return "local"\n' \
    > "$R6/vendor/synthtree/pkg/mod.py"
(
    cd "$R6/synthetic-source"
    printf 'def hello():\n    return "v2 upstream"\n' > pkg/mod.py
    git add pkg/mod.py
    git commit --quiet -m "v2: upstream moved on"
)
H6="$(vendor_hash "$R6")"
out="$(run_tool "$R6" synthtree)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'RE-PIN, not a graft'; then
    pass "control 6: source ahead of pin -> REFUSED as a RE-PIN"
else
    fail "control 6: source ahead -> rc=$rc, expected RE-PIN refusal"
    printf '%s\n' "$out" | tail -5 | sed 's/^/        /'
fi
[ -f "$R6/vendor/divergences/synthtree.patch" ] \
    && fail "control 6: WROTE A PATCH FOLDING IN UPSTREAM COMMITS" \
    || pass "control 6: no patch written"
[ "$(vendor_hash "$R6")" = "$H6" ] || fail "control 6: THE VENDORED TREE CHANGED"

echo ""
if [ "$fails" -gt 0 ]; then
    printf '\033[0;31mregenerate_divergence_patch: %d control(s) FAILED\033[0m\n' "$fails"
    exit 1
fi
printf '\033[0;32mregenerate_divergence_patch: all controls pass -- refuses correctly, and never touched a vendored byte\033[0m\n'
