#!/usr/bin/env bash
# The product-tree seed must actually seed the product tree.
#
# WHAT HAPPENED. sign-python-bundle.sh seeds the product tree with
#
#     compileall -q -f --invalidation-mode unchecked-hash -x '<REGEX>' "$PRODUCT_ROOT"
#
# and the regex was `(/python/|\.app/)`. compileall matches -x with
# rx.search(FULLNAME) -- the full path, not one relative to the root. Every path
# under the bundle contains `OstlerInstaller.app/`, so `\.app/` matched ALL of
# them and compileall compiled NOTHING while exiting 0.
#
# It failed CLOSED -- the bundle audit further down counts uncovered .py and
# refuses to sign -- so nothing shipped broken. But the cut stops dead, and the
# error it stops with ("353 of 1801 .py have NO .pyc") describes the SYMPTOM in
# a different compartment from the CAUSE, which is a bad place to start
# debugging from.
#
# WHY A TEST AND NOT JUST A FIX. The bug is invisible in the script: the flag is
# present, the mode is right, the exit code is 0. Only the COUNT of what got
# seeded gives it away, and nothing counted that.
#
# THIS TEST READS THE REGEX OUT OF THE SCRIPT rather than restating it, so it
# cannot drift into testing a copy while the script carries something else.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/gui/scripts/sign-python-bundle.sh"
FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL [script-missing]: $SCRIPT not found -- nothing was checked. NOT a pass." >&2
    exit 2
fi

PY="$(command -v python3 || true)"
if [[ -z "$PY" ]]; then
    echo "FAIL [no-python]: python3 not on PATH. CANNOT-RUN, which is not a pass." >&2
    exit 2
fi

# ---- lift the regex out of the script -------------------------------------
RX="$(grep -oE "^[[:space:]]*-x '[^']+'" "$SCRIPT" | head -1 | sed "s/.*-x '//; s/'$//")"
if [[ -z "$RX" ]]; then
    fail "no-regex" "could not lift the -x regex out of $SCRIPT; the test would otherwise pass while measuring nothing"
    exit 1
fi
echo "  regex under test: $RX"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- a faithful path shape -------------------------------------------------
# OUTER bundle, a NESTED bundle, and the stdlib compartment. The outer .app is
# the whole point: its name appears in every path beneath it.
ROOT="$WORK/dist/OstlerInstaller.app/Contents/Resources"
mkdir -p "$ROOT/assistant_api" "$ROOT/python/lib" "$ROOT/Ostler.app/Contents/Resources/svc"
printf 'a = 1\n' > "$ROOT/assistant_api/mod.py"
printf 'b = 2\n' > "$ROOT/python/lib/std.py"
printf 'c = 3\n' > "$ROOT/Ostler.app/Contents/Resources/svc/nested.py"

count_product() { find "$ROOT" -path '*Ostler.app*' -prune -o -name '*.pyc' -print 2>/dev/null | grep -vc '/python/' || true; }
count_stdlib()  { find "$ROOT/python" -name '*.pyc' 2>/dev/null | wc -l | tr -d ' '; }
count_nested()  { find "$ROOT/Ostler.app" -name '*.pyc' 2>/dev/null | wc -l | tr -d ' '; }
wipe()          { find "$ROOT" -name '*.pyc' -delete 2>/dev/null || true; }

# ---- 1. CONTROL FIRST: the tree must be compilable at all -----------------
# Without this, "0 seeded" could mean the sources are broken and the test would
# blame the regex for something else entirely.
wipe
env PYTHONDONTWRITEBYTECODE=1 "$PY" -m compileall -q -f --invalidation-mode unchecked-hash "$ROOT" >/dev/null 2>&1 || true
C_PROD=$(count_product); C_STD=$(count_stdlib); C_NEST=$(count_nested)
if [[ "$C_PROD" -lt 1 || "$C_STD" -lt 1 || "$C_NEST" -lt 1 ]]; then
    fail "control-dead" "with NO exclusion the tree seeded product=$C_PROD stdlib=$C_STD nested=$C_NEST; it must seed all three or this test proves nothing about the regex"
else
    pass "control: with no exclusion the tree is compilable (product=$C_PROD stdlib=$C_STD nested=$C_NEST)"
fi

# ---- 2. the real regex must seed the product tree -------------------------
wipe
env PYTHONDONTWRITEBYTECODE=1 "$PY" -m compileall -q -f --invalidation-mode unchecked-hash -x "$RX" "$ROOT" >/dev/null 2>&1 || true
PROD=$(count_product); STD=$(count_stdlib); NEST=$(count_nested)
echo "  with the script's regex: product=$PROD stdlib=$STD nested=$NEST"

if [[ "$PROD" -lt 1 ]]; then
    fail "seeds-nothing" "the exclusion swallowed the product tree: product=$PROD. compileall matches -x against the FULL path, so a bare '\\.app/' matches the OUTER bundle and excludes everything, silently, at rc=0"
else
    pass "the product tree IS seeded ($PROD)"
fi

# ---- 3. and it must still exclude the two compartments it means to --------
if [[ "$STD" -ne 0 ]]; then
    fail "stdlib-reseeded" "the stdlib was seeded again ($STD); it is seeded by the earlier pass and re-doing it here wastes the build and muddies the audit"
else
    pass "the stdlib compartment is excluded"
fi
if [[ "$NEST" -ne 0 ]]; then
    fail "nested-seeded" "the NESTED .app was seeded ($NEST); it carries its own signature, sealed later by sparkle-embed, and writing into it from here would break a bundle this script does not sign"
else
    pass "the nested .app compartment is excluded"
fi

if [[ "$FAILED" -ne 0 ]]; then exit 1; fi
echo
echo "ALL PRODUCT SEED REGEX TESTS PASSED"
