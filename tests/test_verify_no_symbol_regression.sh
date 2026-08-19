#!/usr/bin/env bash
#
# tests/test_verify_no_symbol_regression.sh
#
# Self-test for the re-vendor symbol-regression guard (v1018-D684).
#
# A gate nobody has watched go RED is not a gate. This proves the guard
# discriminates in BOTH directions -- it must stay quiet for the changes a
# re-vendor is supposed to make (additions, edits, renames of file CONTENT)
# and refuse only when a symbol actually disappears. A guard that fires on
# everything gets switched off within a week, which is the same outcome as
# not having one.
#
# Exit 0 all controls pass / 1 a control failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${REPO_ROOT}/scripts/verify_no_symbol_regression.sh"

if [[ ! -x "$GUARD" ]]; then
    echo "FAIL: guard not executable at $GUARD" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/symreg-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

# expect <label> <expected_rc> <current_dir> <incoming_dir>
expect() {
    local label="$1" want="$2" cur="$3" inc="$4" out rc
    out="$("$GUARD" "$cur" "$inc" 2>&1)"; rc=$?
    if [[ "$rc" == "$want" ]]; then
        ok "$label (exit $rc)"
    else
        bad "$label -- expected exit $want, got $rc"
        printf '%s\n' "$out" | sed 's/^/        /'
    fi
}

mk() { mkdir -p "$(dirname "$2")"; printf '%s\n' "$1" > "$2"; }

printf '== test_verify_no_symbol_regression ==\n'

# ── 1. baseline: identical trees pass ─────────────────────────────
mk 'def alpha():
    return 1


def beta():
    return 2
' "$TMP/a/pkg/m.py"
cp -R "$TMP/a" "$TMP/b"
expect "identical trees" 0 "$TMP/a" "$TMP/b"

# ── 2. ADDITION is fine -- this is what a re-vendor is FOR ────────
mk 'def alpha():
    return 1


def beta():
    return 2


def gamma():
    return 3
' "$TMP/b/pkg/m.py"
expect "incoming ADDS a function" 0 "$TMP/a" "$TMP/b"

# ── 3. body edits are fine -- not a diff tool ─────────────────────
mk 'def alpha():
    return 999  # rewritten entirely


def beta():
    """Docstring added, logic changed."""
    return 2
' "$TMP/b/pkg/m.py"
expect "incoming REWRITES bodies but keeps names" 0 "$TMP/a" "$TMP/b"

# ── 4. THE DEFECT: a function disappears ─────────────────────────
mk 'def alpha():
    return 1
' "$TMP/b/pkg/m.py"
expect "incoming DELETES beta()" 1 "$TMP/a" "$TMP/b"

# Capture FIRST, then grep the variable. Piping the guard straight into
# grep under `set -o pipefail` reports the GUARD's exit 1 as the pipeline
# status, not grep's 0 -- so this control inverted and claimed the symbol
# was unnamed while the guard was in fact naming it correctly. Caught by
# reproducing the guard in isolation instead of believing the control.
_named_out="$("$GUARD" "$TMP/a" "$TMP/b" 2>&1)"
if printf '%s\n' "$_named_out" | grep -q 'beta'; then
    ok "names the deleted symbol (beta)"
else
    bad "the deleted symbol is not NAMED in the output"
    printf '%s\n' "$_named_out" | sed 's/^/        /'
fi

# ── 5. a whole file disappearing is also a reduction ─────────────
rm -rf "$TMP/b"; mkdir -p "$TMP/b"
expect "incoming DROPS the file entirely" 1 "$TMP/a" "$TMP/b"

# ── 6. classes count too, not just defs ──────────────────────────
rm -rf "$TMP/c" "$TMP/d"
mk 'class Widget:
    pass
' "$TMP/c/m.py"
mk 'def unrelated():
    pass
' "$TMP/d/m.py"
expect "incoming DELETES a class" 1 "$TMP/c" "$TMP/d"

# ── 7. async def is a def ────────────────────────────────────────
# A `^def ` grep would miss this. AST does not, which is why the guard
# parses instead of grepping.
rm -rf "$TMP/e" "$TMP/f"
mk 'async def fetch():
    pass
' "$TMP/e/m.py"
mk 'def something_else():
    pass
' "$TMP/f/m.py"
expect "incoming DELETES an async def" 1 "$TMP/e" "$TMP/f"

# ── 8. a `def` inside a STRING is not a definition ───────────────
# The false-positive direction. A grep-based guard would see this as a
# symbol and then report it "deleted" when the string changed.
rm -rf "$TMP/g" "$TMP/h"
mk 'TEMPLATE = """
def not_a_real_function():
    pass
"""


def real():
    pass
' "$TMP/g/m.py"
mk 'TEMPLATE = "changed entirely"


def real():
    pass
' "$TMP/h/m.py"
expect "a def inside a string is NOT counted" 0 "$TMP/g" "$TMP/h"

# ── 9. CANNOT-RUN is exit 2, never a pass ────────────────────────
expect "missing directory" 2 "$TMP/does-not-exist" "$TMP/a"
rm -rf "$TMP/empty"; mkdir -p "$TMP/empty"
expect "no Python files to compare (empty scan)" 2 "$TMP/empty" "$TMP/a"

# ── 10. an unparseable file yields NO VERDICT, not a pass ────────
# If a syntax error scored as "no symbols", every symbol in that file
# would look deleted -- or worse, an unparseable INCOMING file would look
# like a clean removal. Both are wrong; refuse to answer instead.
rm -rf "$TMP/i" "$TMP/j"
mk 'def fine():
    pass
' "$TMP/i/m.py"
mk 'def broken(:
' "$TMP/j/m.py"
expect "unparseable incoming file" 2 "$TMP/i" "$TMP/j"

# ── 11. THE ORDERING INVARIANT in sync_vendor.sh ─────────────────
# The guard is only useful if a missing guard is refused BEFORE the tree is
# destroyed. sync_vendor.sh swaps with `rm -rf "$abs_vendor"` + untar, so a
# refusal placed after that point would be refusing on top of an
# already-overwritten tree -- a caught defect turned into a worse one.
#
# The original wiring was worse than mis-ordered: an absent guard printed a
# WARNING and vendored anyway. A warning nobody blocks on is indistinguishable
# from no guard, which is how the doctor tree lost three shipping cards the
# first time (HR015 12ac405).
#
# This is a STRUCTURAL control, not an end-to-end one, and deliberately so: a
# real sync needs a manifest, a source checkout and a network, none of which
# belong in this suite. It asserts the ORDER -- the invariant -- by line
# position computed at runtime, never a hardcoded line number.
SYNC="${REPO_ROOT}/scripts/sync_vendor.sh"
if [[ -f "$SYNC" ]]; then
    _refuse_ln="$(grep -n 'REFUSING TO VENDOR: the symbol-regression guard' "$SYNC" | head -1 | cut -d: -f1)"
    _rmrf_ln="$(grep -n '^rm -rf "\$abs_vendor"' "$SYNC" | head -1 | cut -d: -f1)"
    if [[ -n "$_refuse_ln" && -n "$_rmrf_ln" && "$_refuse_ln" -lt "$_rmrf_ln" ]]; then
        ok "sync_vendor refuses a missing guard BEFORE the rm -rf (line $_refuse_ln < $_rmrf_ln)"
    else
        bad "sync_vendor guard-refusal is missing or comes AFTER the swap (refuse=${_refuse_ln:-none} rm-rf=${_rmrf_ln:-none})"
    fi
    # And it must be a refusal, not a warning that continues.
    if grep -q 'this re-vendor was NOT symbol-guarded' "$SYNC"; then
        bad "sync_vendor still WARNS about an unguarded re-vendor instead of refusing"
    else
        ok "an absent guard is a refusal, not a warning that vendors anyway"
    fi
else
    bad "scripts/sync_vendor.sh not found -- cannot check the ordering invariant"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
