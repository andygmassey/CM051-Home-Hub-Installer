#!/usr/bin/env bash
#
# scripts/verify_no_symbol_regression.sh <current_tree> <incoming_tree>
#
# Refuse a re-vendor that would REDUCE the set of symbols defined in the
# vendored tree.
#
# WHY THIS EXISTS (v1018-D684, Andy 2026-08-13)
# --------------------------------------------
# Vendoring assumes upstream leads and vendor follows. On 2026-08-13 the
# reverse was measured:
#
#     doctor/agent/diagnostic_rules.py   HR015 996 lines / VENDORED 1329
#
# The vendored copy was a strict SUPERSET -- 8 functions existed only there
# (check_conversation_dispatch_failures, check_imessage_capture_stalled,
# check_last_upgrade + 5 helpers) and none existed only upstream. A re-vendor
# would have silently deleted three customer-facing Doctor cards.
#
# It had already happened once. HR015's most recent commit on that exact file:
#
#     12ac405 fix(doctor): restore iMessage chat.db FDA reminder card (CX-60)
#             dropped in re-vendor (#259)
#
# So this is the second occurrence pending, on the same file, with more at
# stake. Andy's ruling: make a third impossible, and build the guard BEFORE
# the next re-vendor rather than as part of one.
#
# WHAT IT CHECKS
# --------------
# For every Python file present in BOTH trees, the set of top-level `def` and
# `class` names must not shrink. Additions are fine -- that is what a
# re-vendor is for. Disappearances are refused, by name.
#
# A file that exists in the current tree and NOT in the incoming one is also
# a reduction (every symbol in it vanishes) and is reported as such.
#
# DELIBERATELY NOT A DIFF. Line counts, hashes and `diff` all go red on any
# legitimate change, so they would be turned off within a week. This asks the
# single question that distinguishes "upstream moved on" from "we are about
# to delete shipping code", and stays quiet for everything else.
#
# EXIT CODES (the trichotomy this repo keeps re-learning)
#   0  no symbol disappears -- safe to swap
#   1  at least one symbol would be deleted -- REFUSE the re-vendor
#   2  could not run (missing tree, no Python files found, no python3)
#
# Exit 2 matters. A run that finds nothing to compare must NOT report 0:
# "nothing looked at" and "nothing wrong" print identically otherwise, and a
# supply-chain guard that silently passes on an empty scan is worse than no
# guard, because it manufactures confidence.

set -uo pipefail

CURRENT="${1:-}"
INCOMING="${2:-}"

if [[ -z "$CURRENT" || -z "$INCOMING" ]]; then
    echo "usage: $0 <current_tree> <incoming_tree>" >&2
    exit 2
fi
for d in "$CURRENT" "$INCOMING"; do
    if [[ ! -d "$d" ]]; then
        echo "verify_no_symbol_regression: not a directory: $d" >&2
        exit 2
    fi
done
if ! command -v python3 >/dev/null 2>&1; then
    echo "verify_no_symbol_regression: python3 unavailable; cannot enumerate symbols" >&2
    exit 2
fi

CURRENT="$CURRENT" INCOMING="$INCOMING" python3 - <<'PYEOF'
import ast
import os
import sys

current = os.environ["CURRENT"]
incoming = os.environ["INCOMING"]


def symbols(path):
    """Top-level def/class names in a file.

    AST, not grep: a regex over `^def ` misses `async def`, and counts a
    `def` inside a string or a comment. Parsing is the honest instrument.

    A file that will not parse returns None, which the caller treats as
    could-not-run rather than as "no symbols" -- an unparseable file
    scoring zero would make every symbol in it look deleted, and an
    unparseable INCOMING file would look like a clean removal.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            tree = ast.parse(fh.read(), filename=path)
    except (OSError, SyntaxError, ValueError):
        return None
    out = set()
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            out.add(node.name)
    return out


def py_files(root):
    found = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            d for d in dirnames
            if d not in {"__pycache__", ".git", ".mypy_cache", ".pytest_cache"}
        ]
        for fn in filenames:
            if fn.endswith(".py"):
                abs_p = os.path.join(dirpath, fn)
                found[os.path.relpath(abs_p, root)] = abs_p
    return found


cur_files = py_files(current)
inc_files = py_files(incoming)

if not cur_files:
    print(
        "verify_no_symbol_regression: found NO Python files under "
        f"{current} -- nothing was compared. Refusing to report a pass on "
        "an empty scan.",
        file=sys.stderr,
    )
    sys.exit(2)

unparseable = []
losses = []       # (relpath, sorted names)
vanished = []     # whole files gone

for rel, cur_path in sorted(cur_files.items()):
    cur_syms = symbols(cur_path)
    if cur_syms is None:
        unparseable.append(f"{rel} (current)")
        continue
    if not cur_syms:
        continue

    inc_path = inc_files.get(rel)
    if inc_path is None:
        vanished.append((rel, sorted(cur_syms)))
        continue

    inc_syms = symbols(inc_path)
    if inc_syms is None:
        unparseable.append(f"{rel} (incoming)")
        continue

    missing = cur_syms - inc_syms
    if missing:
        losses.append((rel, sorted(missing)))

if unparseable:
    print(
        "verify_no_symbol_regression: could not parse these files, so the "
        "comparison is incomplete and no verdict is given:",
        file=sys.stderr,
    )
    for u in unparseable:
        print(f"    {u}", file=sys.stderr)
    sys.exit(2)

if not losses and not vanished:
    print(
        f"verify_no_symbol_regression: OK -- {len(cur_files)} file(s) "
        "compared, no symbol disappears."
    )
    sys.exit(0)

print("", file=sys.stderr)
print(
    "REFUSING RE-VENDOR: it would DELETE symbols that exist in the tree "
    "you are about to overwrite.",
    file=sys.stderr,
)
print("", file=sys.stderr)

for rel, names in vanished:
    print(f"  {rel}  -- FILE REMOVED ENTIRELY, taking with it:", file=sys.stderr)
    for n in names:
        print(f"      {n}", file=sys.stderr)

for rel, names in losses:
    print(f"  {rel}", file=sys.stderr)
    for n in names:
        print(f"      {n}", file=sys.stderr)

print("", file=sys.stderr)
print(
    "This is v1018-D684: the vendored tree can be AHEAD of upstream, and a\n"
    "re-vendor overwrites rather than merges. If these symbols are genuinely\n"
    "retired, delete them upstream FIRST so the removal is reviewed on a PR.\n"
    "If they are not, forward-port them into the source tree before vendoring.",
    file=sys.stderr,
)
sys.exit(1)
PYEOF
