#!/usr/bin/env bash
#
# scripts/verify_test_wiring.sh [--regenerate]
#
# THE READER THIS REPO DID NOT HAVE.
#
# WHY (v1018-D621g, Andy 2026-08-13)
# ----------------------------------
# On 2026-08-13 the question "which tests actually run?" had no answer on main.
# There was no manifest, no glob-runner, no enumerating target: a test executed
# if and only if some workflow named it by hand. Measured that day:
#
#     174 test files in tests/
#      46 reachable from a workflow, Makefile, release.sh, or another
#         reachable test (transitive)
#     128 run NOWHERE
#
# 128 files that look like coverage, are counted as coverage by anyone reading
# the directory, and assert nothing. That is worse than having no tests: an
# empty tests/ directory is honest.
#
# WHAT THIS DOES
# --------------
# Computes reachability the same way the CI system does -- by name, from the
# things that can actually start a process -- and compares it to a checked-in
# manifest (tests/TEST_WIRING.tsv). Fails when the UNWIRED SET GROWS.
#
# WHY A RATCHET AND NOT "ALL 128 MUST BE FIXED NOW"
# ------------------------------------------------
# A gate that is red on the day it lands is a gate people route around, and
# this repo has the scar: the PR-age rule was deliberately made non-retroactive
# for exactly that reason (see gui/Makefile check-pr-age). So the 128 are
# recorded as an explicit, visible backlog with the count printed on EVERY run,
# and the gate fires the moment the set grows by one. New unwired tests are the
# thing that must stop; the existing 128 are a debt with a number on it, not a
# silence.
#
# THIS IS NOT A WARN BUCKET. Three things keep it honest:
#   1. the backlog is enumerated by name in a tracked file, not a count;
#   2. every run prints the total, so it cannot quietly grow into wallpaper;
#   3. a file that leaves the backlog can never re-enter it without editing
#      the manifest in a reviewed commit.
#
# EXIT CODES (the trichotomy this repo keeps re-learning)
#   0  every test file is wired, or is in the recorded backlog
#   1  a test file is wired to NOTHING and is not in the backlog -- the set grew
#   2  could not run (no tests dir, no workflows dir, no python3, empty scan,
#      unreadable manifest)
#
# Exit 2 matters. "No unwired tests" and "I could not enumerate the tests" print
# identically otherwise, and a wiring gate that passes on an empty scan
# manufactures exactly the confidence it exists to remove.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${TEST_WIRING_MANIFEST:-$REPO_ROOT/tests/TEST_WIRING.tsv}"
TESTS_DIR="${TEST_WIRING_TESTS_DIR:-$REPO_ROOT/tests}"
WORKFLOWS_DIR="${TEST_WIRING_WORKFLOWS_DIR:-$REPO_ROOT/.github/workflows}"

REGEN=0
[ "${1:-}" = "--regenerate" ] && REGEN=1

if ! command -v python3 >/dev/null 2>&1; then
    echo "verify_test_wiring: CANNOT RUN -- python3 unavailable; cannot walk the reachability graph." >&2
    exit 2
fi
for d in "$TESTS_DIR" "$WORKFLOWS_DIR"; do
    if [ ! -d "$d" ]; then
        echo "verify_test_wiring: CANNOT RUN -- not a directory: $d" >&2
        echo "                    Nothing was enumerated. This is not a pass." >&2
        exit 2
    fi
done

REPO_ROOT="$REPO_ROOT" MANIFEST="$MANIFEST" TESTS_DIR="$TESTS_DIR" \
WORKFLOWS_DIR="$WORKFLOWS_DIR" REGEN="$REGEN" python3 - <<'PYEOF'
import os
import sys
import glob

repo = os.environ["REPO_ROOT"]
manifest_path = os.environ["MANIFEST"]
tests_dir = os.environ["TESTS_DIR"]
workflows_dir = os.environ["WORKFLOWS_DIR"]
regen = os.environ["REGEN"] == "1"


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


# --- the test set -----------------------------------------------------------
tests = sorted(
    os.path.basename(p)
    for p in glob.glob(os.path.join(tests_dir, "test_*.sh"))
    + glob.glob(os.path.join(tests_dir, "test_*.py"))
)
if not tests:
    print(
        "verify_test_wiring: CANNOT RUN -- found NO test files under "
        f"{tests_dir}. An empty scan is not a clean wiring report.",
        file=sys.stderr,
    )
    sys.exit(2)

# --- the things that can START a test ---------------------------------------
# A workflow step, a Makefile recipe, release.sh, or a script -- anything that
# can actually invoke a process. Reachability is BY NAME because that is
# precisely how the CI system resolves it: there is no registry to consult.
starters = {}
for p in sorted(glob.glob(os.path.join(workflows_dir, "*.yml"))
                + glob.glob(os.path.join(workflows_dir, "*.yaml"))):
    starters[os.path.relpath(p, repo)] = read(p)
for rel in ("Makefile", "gui/Makefile", "release.sh"):
    p = os.path.join(repo, rel)
    if os.path.exists(p):
        starters[rel] = read(p)
for p in sorted(glob.glob(os.path.join(repo, "scripts", "*.sh"))):
    starters[os.path.relpath(p, repo)] = read(p)

if not starters:
    print(
        "verify_test_wiring: CANNOT RUN -- no workflows, Makefiles or scripts "
        "were found to search. Every test would score UNWIRED for want of "
        "looking, which is a false accusation, not a finding.",
        file=sys.stderr,
    )
    sys.exit(2)

# test bodies, so a test invoked BY a wired test counts as wired
bodies = {}
for p in glob.glob(os.path.join(tests_dir, "*.sh")) + glob.glob(os.path.join(tests_dir, "*.py")):
    bodies[os.path.basename(p)] = read(p)

# --- reachability -----------------------------------------------------------
#
# A MENTION IS NOT AN INVOCATION, AND THIS USED TO TREAT THEM AS THE SAME.
#
# The check below is a substring search over the whole file, and a comment is
# part of the file. So a test scored WIRED if any workflow merely NAMED it.
#
# Found 2026-08-15 the only way this kind of thing gets found: it bit the commit
# that was fixing the backlog. .github/workflows/supply-chain-pins.yml carried a
# comment block listing the unwired supply-chain tests and their results, to
# document which ones do NOT run. Running this gate immediately reported two of
# them -- both red, both executing nowhere -- as newly WIRED. A note written to
# record that two tests are dark would have recorded them as live, and the next
# reader of TEST_WIRING.tsv would have seen WIRED against tests that never run.
#
# That matters more than a mislabelled row. The fix for the backlog IS wiring
# tests, and anyone doing that work writes workflow comments naming the tests
# they are triaging. The gate rewarded exactly that with false WIRED rows, so the
# burn-down effort would corrupt the manifest it is trying to drain.
#
# FULL-LINE COMMENTS ONLY, deliberately. Stripping everything after any '#'
# would truncate a real invocation whose arguments contain one -- a grep pattern,
# a URL fragment, a colour code. The defect is comment BLOCKS listing test names,
# and dropping lines whose first non-space character is '#' removes those with no
# risk to a line that actually runs something.
def strip_comment_lines(text):
    return "\n".join(
        l for l in text.splitlines() if not l.lstrip().startswith("#")
    )

starters = {k: strip_comment_lines(v) for k, v in starters.items()}
bodies = {k: strip_comment_lines(v) for k, v in bodies.items()}

runner = {}
for t in tests:
    for name, text in starters.items():
        if t in text:
            runner[t] = name
            break

changed = True
while changed:
    changed = False
    for w in sorted(runner):
        for t in tests:
            if t not in runner and t in bodies.get(w, ""):
                runner[t] = f"(via {w})"
                changed = True

unwired = [t for t in tests if t not in runner]

# --- regenerate -------------------------------------------------------------
HEADER = """# TEST_WIRING.tsv -- which tests actually run, and what runs them.
#
# Generated by scripts/verify_test_wiring.sh --regenerate; verified on every PR
# by .github/workflows/test-wiring.yml. Do not hand-edit the WIRED rows.
#
# There is no test runner in this repo. A test executes if and only if
# something names it: a workflow step, a Makefile recipe, release.sh, a script,
# or another test that already runs. This file is the reader for that fact.
#
# STATUS  WIRED    something starts it; the runner is named.
#         UNWIRED  nothing starts it. It asserts nothing, for anyone, ever.
#
# The UNWIRED rows are a BACKLOG, not a blessing. The gate fails the moment the
# set GROWS -- a new test wired to nothing fails CI on the PR that adds it. The
# recorded ones are debt with a number on it, and that number prints on every
# run so it cannot become wallpaper. Wiring one is a one-line edit here plus
# the workflow that runs it.
#
# columns: test_file<TAB>status<TAB>runner
"""

if regen:
    with open(manifest_path, "w", encoding="utf-8") as fh:
        fh.write(HEADER)
        for t in tests:
            fh.write(f"{t}\t{'WIRED' if t in runner else 'UNWIRED'}\t{runner.get(t, '-')}\n")
    print(f"verify_test_wiring: wrote {manifest_path}")
    print(f"  {len(tests)} test file(s), {len(tests)-len(unwired)} wired, {len(unwired)} UNWIRED")
    sys.exit(0)

# --- compare against the manifest -------------------------------------------
if not os.path.exists(manifest_path):
    print(
        f"verify_test_wiring: CANNOT RUN -- no manifest at {manifest_path}. "
        "Run scripts/verify_test_wiring.sh --regenerate and commit it.",
        file=sys.stderr,
    )
    sys.exit(2)

recorded_unwired = set()
recorded_all = set()
for line in read(manifest_path).splitlines():
    if not line.strip() or line.startswith("#"):
        continue
    parts = line.split("\t")
    if len(parts) < 2:
        print(
            f"verify_test_wiring: CANNOT RUN -- malformed manifest row: {line!r}",
            file=sys.stderr,
        )
        sys.exit(2)
    recorded_all.add(parts[0])
    if parts[1] == "UNWIRED":
        recorded_unwired.add(parts[0])

print(f"verify_test_wiring: {len(tests)} test file(s) under tests/")
print(f"  WIRED   : {len(tests) - len(unwired)}")
print(f"  UNWIRED : {len(unwired)}   (recorded backlog: {len(recorded_unwired)})")

new_unwired = sorted(set(unwired) - recorded_unwired)
missing_rows = sorted(set(tests) - recorded_all)
fixed = sorted(recorded_unwired - set(unwired))

if fixed:
    print(f"  progress: {len(fixed)} test(s) newly WIRED since the manifest was written:")
    for f in fixed:
        print(f"      {f}")
    print("  re-run with --regenerate and commit, so the backlog can never grow back to include them.")

fail = False
if new_unwired:
    fail = True
    print("", file=sys.stderr)
    print(
        "THE UNWIRED SET GREW. These test files are started by nothing -- no "
        "workflow, no Makefile, no script, no other test:",
        file=sys.stderr,
    )
    for t in new_unwired:
        print(f"    {t}", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "A test that runs nowhere asserts nothing. Wire it (name it in a\n"
        "workflow), or delete it. Adding it to the UNWIRED backlog is NOT the\n"
        "fix -- the backlog is the 128 that already existed on 2026-08-13, and\n"
        "the whole point of this gate is that it stops there.",
        file=sys.stderr,
    )

if missing_rows:
    fail = True
    print("", file=sys.stderr)
    print("These test files have no row in the manifest at all:", file=sys.stderr)
    for t in missing_rows:
        print(f"    {t}", file=sys.stderr)
    print("Run scripts/verify_test_wiring.sh --regenerate and commit.", file=sys.stderr)

if fail:
    sys.exit(1)

print("OK: no test file is newly unwired.")
sys.exit(0)
PYEOF
