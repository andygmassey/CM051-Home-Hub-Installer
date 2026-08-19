#!/usr/bin/env bash
#
# tests/test_vendor_exclude_glob_depth.sh
#
# THE EXCLUDE PREDICATE MUST AGREE WITH THE MATERIALISER, AT EVERY DEPTH.
#
# WHY THIS EXISTS
#
#   `vlib_materialise` strips excluded paths with `find -name "<glob>"`, which
#   matches a BASENAME at ANY depth. `vlib_vendor_diff` then asks "is this
#   vendored file excluded?" to decide whether a file missing from the source
#   tree is a deliberate omission or a genuine vendor-only graft.
#
#   Those two have to answer the same question. They did not.
#
#   The old predicate wrote its any-depth alternative as `*"/$_g"`. A quoted
#   expansion inside a `case` pattern matches LITERALLY, so with
#   _g="test_*.py" the pattern was `*/test_*.py` containing an asterisk
#   CHARACTER, which no real path matches. The unquoted `$_g` arm did glob but
#   only against the whole relative path, i.e. only at the tree root.
#
#   Result: a LITERAL exclude (README.md) worked at any depth, a WILDCARD
#   exclude (test_*.py) worked only at the top level. The materialiser stripped
#   agent/test_*.py from source; the predicate did not call them excluded; so
#   they were emitted as /dev/null new-file hunks for files that exist at the
#   pin, and `git apply` aborted the ENTIRE patch with "already exists in
#   working directory". The tree reconstructed nothing.
#
#   Measured against the real doctor tree at pin b0b3831 before the fix:
#     error: agent/test_diagnostic_rules.py: already exists in working directory
#     error: agent/test_health_gate.py: already exists in working directory
#
#   It is the mirror of the bug that new-file support fixed. That one DROPPED
#   creations; this one MANUFACTURED them out of modifications. Both produce a
#   divergence patch that cannot rebuild the tree it claims to describe.
#
# WHAT IS ASSERTED, and why each one is here:
#   1. wildcard FILE glob excludes at top level and in a subdirectory
#   2. wildcard DIR glob excludes at top level and nested
#   3. literal excludes still work at any depth (no regression)
#   4. CONTROL: a genuinely vendor-only file is STILL emitted as a new file.
#      Over-excluding would silently restore the very bug new-file support
#      was written to fix, and every other assertion here would still pass.
#   5. the reconstruction actually applies when source carries the excluded
#      files -- the failure mode itself, not a proxy for it

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/_vendor_lib.sh"
set +e   # _vendor_lib.sh turns on -e; drift returns 1 and that is expected here
VLIB_REPO_ROOT="$REPO_ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL [$1]: $2" >&2; exit 1; }

SRC="$TMP/src"; VEN="$TMP/ven"
mkdir -p "$SRC/agent" "$VEN/agent" "$VEN/pkg/sub.egg-info" "$VEN/agent/nested"

# Shared file that genuinely diverges: proves ordinary hunks still work.
printf 'line one\n'          > "$SRC/agent/mod.py"
printf 'line one CHANGED\n'  > "$VEN/agent/mod.py"

# The subjects. Present in the VENDOR tree, stripped from the materialised
# source by the exclude globs, and present upstream at the pin.
printf 'top level test\n'    > "$VEN/test_top.py"
printf 'nested test\n'       > "$VEN/agent/test_nested.py"
printf 'deeper test\n'       > "$VEN/agent/nested/test_deep.py"
printf 'egg top\n'           > "$VEN/pkg/sub.egg-info/PKG-INFO"
printf 'readme\n'            > "$VEN/agent/README.md"

# CONTROL subject: vendor-only, matches NO exclude glob. Must still be created.
printf 'def grafted():\n\treturn "vendor only"\n' > "$VEN/agent/grafted.py"

# The doctor tree's real exclude set, which is what exposed this.
vlib_excludes() { printf 'tests/\n__pycache__/\n*.egg-info/\ntest_*.py\nREADME.md\n'; }

OUT="$TMP/out.patch"
vlib_vendor_diff "fixture" "$SRC" "$VEN" "$OUT"
rc=$?
[ "$rc" = "1" ] || fail drift-rc "expected drift rc=1, got rc=$rc"
echo "PASS: divergence detected"

_hunk_for() { grep -q "^+++ b/$1\$" "$OUT"; }

# -- 1. wildcard FILE glob, top level AND subdirectory --------------------
for p in test_top.py agent/test_nested.py agent/nested/test_deep.py; do
    if _hunk_for "$p"; then
        fail wildcard-file \
"'$p' got a hunk despite the test_*.py exclude. A wildcard exclude must match a
 basename at ANY depth, exactly as the materialiser's find -name does. Emitting
 it means git apply aborts the whole patch on a file that exists at the pin."
    fi
done
echo "PASS: wildcard file glob excludes at top level and at depth"

# -- 2. wildcard DIR glob, nested ----------------------------------------
if _hunk_for "pkg/sub.egg-info/PKG-INFO"; then
    fail wildcard-dir "*.egg-info/ did not exclude a nested match"
fi
echo "PASS: wildcard dir glob excludes when nested"

# -- 3. literal exclude, at depth (regression guard) ---------------------
if _hunk_for "agent/README.md"; then
    fail literal-depth "literal exclude README.md stopped matching at depth"
fi
echo "PASS: literal exclude still matches at any depth"

# -- 4. CONTROL: real vendor-only file is STILL created ------------------
# Without this, "exclude everything" passes tests 1-3 and silently reintroduces
# the dropped-new-file bug that made a grafted file undeliverable.
if ! _hunk_for "agent/grafted.py"; then
    fail control-overexclude \
"a genuinely vendor-only file lost its new-file hunk. The fix has over-excluded
 and re-broken the case new-file support exists for: a graft ahead of the pin
 now has no durable home in the patch again."
fi
echo "PASS: CONTROL -- genuine vendor-only file still emitted as a creation"

# -- 4b. CONTROL: ordinary modification hunk survives ---------------------
grep -q '^--- a/agent/mod.py$' "$OUT" || fail control-modified \
    "the ordinary modified-file hunk regressed"
echo "PASS: CONTROL -- modified shared file still produces an ordinary hunk"

# -- 5. THE RECONSTRUCTION, against a source that HAS the excluded files --
# This is the actual failure: upstream at the pin carries agent/test_*.py, so a
# new-file hunk for one collides and git apply aborts the entire patch.
RECON="$TMP/recon"
cp -R "$SRC" "$RECON"
mkdir -p "$RECON/agent/nested"
printf 'top level test\n' > "$RECON/test_top.py"
printf 'nested test\n'    > "$RECON/agent/test_nested.py"
printf 'deeper test\n'    > "$RECON/agent/nested/test_deep.py"
printf 'readme\n'         > "$RECON/agent/README.md"

( cd "$RECON" && git init -q . && git apply --whitespace=nowarn "$OUT" ) \
    || fail apply \
"git apply failed against a source tree that carries the excluded files. This is
 the exact reported failure: 'already exists in working directory', whole patch
 aborted, nothing reconstructed."
echo "PASS: patch applies onto a source that carries the excluded files"

cmp -s "$RECON/agent/mod.py" "$VEN/agent/mod.py" \
    || fail recon-modified "reconstructed agent/mod.py differs from the vendored copy"
cmp -s "$RECON/agent/grafted.py" "$VEN/agent/grafted.py" \
    || fail recon-grafted "reconstructed agent/grafted.py differs from the vendored copy"
echo "PASS: reconstruction is byte-identical for both the modified and created file"

echo
echo "ALL EXCLUDE-GLOB DEPTH TESTS PASSED"
