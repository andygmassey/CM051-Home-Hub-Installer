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
import re

repo = os.environ["REPO_ROOT"]
manifest_path = os.environ["MANIFEST"]
tests_dir = os.environ["TESTS_DIR"]
workflows_dir = os.environ["WORKFLOWS_DIR"]

# Directories whose *.swift files are test files. Listed rather than discovered
# so that adding a second test target is a VISIBLE edit here, not a silent
# widening -- the whole defect being fixed is a population nobody declared.
SWIFT_TEST_DIRS = ("gui/OstlerInstallerTests",)

# What it takes to START a Swift test. Xcode runs a TARGET, never a file, so
# searching starters for an individual .swift filename would be the wrong
# question and would score all 36 UNWIRED even after someone wired the target
# properly -- red-while-fixed, which is as bad as green-while-blind.
# THIS LIST WAS TOO LOOSE ON ITS FIRST DRAFT AND MANUFACTURED 36 FALSE WIRED.
#
# It included "xcodebuild -scheme", which matches every ordinary BUILD
# invocation in this repo -- `xcodebuild -scheme OstlerInstaller ... build`.
# Building a scheme compiles the test target and runs none of it. The gate
# promptly reported all 36 Swift files WIRED, which is precisely the
# green-while-blind result this whole exercise exists to stop, produced by the
# person writing the fix. Caught by the count, not by re-reading.
#
# So: only the TEST ACTION counts. If someone wires the target by a spelling
# not listed here, this reports UNWIRED -- noise a human clears in a minute.
# The opposite error blesses a dark suite silently and forever.
SWIFT_TEST_STARTERS = (
    "xcodebuild test",
    "test-without-building",
    "-testPlan",
    "swift test",
)
regen = os.environ["REGEN"] == "1"


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


# --- the test set -----------------------------------------------------------
#
# THE DEFECT THIS ENUMERATION USED TO HAVE WAS NOT IN THE WIRING. IT WAS HERE.
#
# Until 2026-08-16 this globbed tests/test_*.sh and tests/test_*.py and nothing
# else. gui/OstlerInstallerTests carries 36 Swift test files, in a different
# directory AND a different naming convention, and not one of them was ever
# scored. They were not reported UNWIRED. They were UNENUMERABLE, which prints
# as nothing at all and reads as a clean bill of health.
#
# That is the zero-denominator failure wearing a register's uniform: a register
# that cannot enumerate a population reports zero problems in it, forever, and
# a reader cannot tell that from "no problems". The header line below used to
# say "N test file(s) under tests/", which was true and still misled, because
# nobody reads a scope note as an exclusion.
#
# It surfaced the expensive way. The env-var licence bypass shipped past 13
# LicenseVerifier tests, and the three tests written to catch it would not have
# run either -- but "would not have run" was never the report, because the
# files were not in the report at all.
shell_py_tests = sorted(
    os.path.basename(p)
    for p in glob.glob(os.path.join(tests_dir, "test_*.sh"))
    + glob.glob(os.path.join(tests_dir, "test_*.py"))
)

# Swift tests are keyed by REPO-RELATIVE PATH, not basename. They live outside
# tests/ and a bare basename could collide with a shell test of the same name,
# which would silently merge two rows into one.
# FIXTURE HERMETICITY. The existing self-tests point TESTS_DIR at a temp fixture
# while REPO_ROOT still names the real checkout. Anchoring the Swift glob on
# REPO_ROOT therefore leaked 36 real files into every fixture run and broke two
# tests that had passed for weeks -- including the empty-scan CANNOT-RUN case,
# which could never be empty again.
#
# So: enumerate Swift only when this run is scoped to the REAL tests dir, or
# when a caller names the dirs explicitly. A fixture run stays hermetic, and a
# real run cannot silently skip the population, because the printed breakdown
# below would show the line missing.
_swift_env = os.environ.get("TEST_WIRING_SWIFT_DIRS", "")
if _swift_env:
    swift_dirs = tuple(d for d in _swift_env.split(":") if d)
elif os.path.realpath(tests_dir) == os.path.realpath(os.path.join(repo, "tests")):
    swift_dirs = SWIFT_TEST_DIRS
else:
    swift_dirs = ()

swift_tests = sorted(
    os.path.relpath(p, repo)
    for d in swift_dirs
    for p in glob.glob(os.path.join(repo, d, "*.swift"))
)

tests = shell_py_tests + swift_tests
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
    rel = os.path.relpath(p, repo)
    # THE REGISTER IS NOT A STARTER. IT IS A READER.
    #
    # This exclusion is load-bearing and it was learned the hard way, inside
    # the commit that added Swift enumeration. scripts/*.sh is in the starter
    # set, this file is a scripts/*.sh, and this file now contains the literal
    # strings "xcodebuild test" and "swift test" in SWIFT_TEST_STARTERS. So the
    # gate matched its OWN PATTERN LIST, concluded the Swift test target was
    # invoked, and reported all 36 files WIRED.
    #
    # A guard compared to itself always agrees. The instrument's source is not
    # evidence about the tree, and any file that merely NAMES a runner spelling
    # is documentation, not a call site -- which is the same distinction this
    # script already draws for comments.
    if rel == "scripts/verify_test_wiring.sh":
        continue
    starters[rel] = read(p)

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

# SWIFT: reachability is asked ONCE, at the TARGET, and the answer applies to
# every file in that target. Xcode does not run files, it runs a scheme's test
# action, so "does anything invoke the test action" is the only question with a
# truthful answer. Asking it per-file would keep them all UNWIRED forever even
# after the target was wired.
swift_runner = None
for name, text in starters.items():
    if any(s in text for s in SWIFT_TEST_STARTERS):
        swift_runner = name
        break
if swift_runner:
    for t in swift_tests:
        runner[t] = swift_runner

# A .py TEST IS OFTEN INVOKED BY MODULE NAME, WHICH CARRIES NO ".py".
#
# `python3 -m unittest tests.test_tailnet_owner_resolution` starts a real test,
# but the substring the loop below hunts -- the filename WITH extension,
# `test_tailnet_owner_resolution.py` -- never appears in that invocation. The
# module form drops the extension and swaps the path separator for a dot, so a
# plain `t in text` scores a genuinely-wired unittest module UNWIRED.
#
# 🔻 THE ORIGINAL VERSION OF THIS PARAGRAPH WAS MEASURABLY FALSE AND IS
# CORRECTED HERE (2026-09-03). It said the sole victim was
# test_tailnet_owner_resolution.py, run by wiki-tailnet-gate.yml, and that
# 'the ".py" spelling appears nowhere for the substring to catch'. Measured:
# TWO workflows invoke that test, and only one uses the module form.
#
#   wiki-tailnet-gate.yml:47      python3 -m unittest tests.test_...  no ".py"
#   tests-unwired-sweep-mz.yml:165  python tests/test_....py          HAS ".py"
#
# The plain arm therefore already matches via the sweep, which is why the TSV
# credits tests-unwired-sweep-mz.yml as the runner rather than the purpose-built
# gate. ⇒ ON THIS TREE THE STEM ARM BELOW IS REDUNDANT, NOT LOAD-BEARING.
# Proved by mutation, not reasoned: deleting the stem arm and regenerating
# leaves tests/TEST_WIRING.tsv BYTE-IDENTICAL (git status clean), across all
# 416 rows -- so it currently changes no verdict anywhere.
#
# 🗿 IT IS RETAINED DELIBERATELY, and the distinction matters. A guard with no
# failing case today is not automatically dead weight -- it is dead weight only
# if the case can never return. Here it can and cheaply: delete the sweep line,
# or let the sweep drop this file, and wiki-tailnet-gate.yml's module-form
# invocation becomes the only starter, at which point the stem arm is the sole
# thing standing between a genuinely-wired test and a FALSE UNWIRED row.
# Keeping it is insurance. Keeping a FALSE STORY about it is not, which is the
# whole reason this paragraph was rewritten rather than the code touched.
#
# FIX: for a .py test, ALSO match the bare module STEM (filename minus ".py")
# on a word boundary, so `tests.test_tailnet_owner_resolution` and
# `tests/test_tailnet_owner_resolution` both count while a longer identifier
# that merely CONTAINS the stem does not. The stem arm is deliberately .py-ONLY:
# a .sh caller always carries the ".sh", so a .sh stem arm would only invite
# false WIRED.
def _started_by(t, text):
    if t in text:
        return True
    if t.endswith(".py") and re.search(r"(?<![\w])" + re.escape(t[:-3]) + r"(?![\w])", text):
        return True
    return False


for t in tests:
    if t in runner:
        continue
    for name, text in starters.items():
        if _started_by(t, text):
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

# THE BREAKDOWN IS PRINTED PER POPULATION, ALWAYS.
#
# A single total is what let 36 files hide: "174 test files" was true of the
# population it enumerated and silent about the one it did not. Naming each
# population and its count means a future language arriving with no row here is
# visible as a missing LINE, not as an unchanged number.
swift_unwired = [t for t in unwired if t in set(swift_tests)]
# Built outside the f-string on purpose. Nesting a same-type quote inside an
# f-string is PEP 701, i.e. Python 3.12 or newer. ubuntu-latest has 3.12 and the
# CUT MACHINE IS A MAC, where system python3 can be 3.9 -- so the 3.12-only form
# would parse in CI and SyntaxError on the box that ships the product, which is
# the worst place for a gate to discover its own portability.
_swift_label = "+".join(swift_dirs) if swift_dirs else "swift (not in scope)"
_swift_note = "" if swift_runner else ", target invoked by NOTHING"
print(f"verify_test_wiring: {len(tests)} test file(s) enumerated")
print(f"  tests/*.sh + *.py      : {len(shell_py_tests)}")
print(f"  {_swift_label}/*.swift : {len(swift_tests)}"
      f"   ({len(swift_unwired)} UNWIRED{_swift_note})")
print(f"  WIRED   : {len(tests) - len(unwired)}")
print(f"  UNWIRED : {len(unwired)}   (recorded backlog: {len(recorded_unwired)})")
if swift_tests and not swift_runner:
    print("  NOTE: no starter invokes the Swift test action, so every file in")
    print("        that target asserts nothing for anyone. Counting them is not")
    print("        wiring them; see task #704 for why wiring is post-tag.")

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
    # The backlog size is MEASURED from the manifest, never remembered. The
    # previous wording said "the backlog is the 128 that already existed on
    # 2026-08-13". 128 was the WIRED count, not the backlog, so the sentence
    # named the wrong population -- and by 2026-08-19 two readers measuring the
    # same manifest got 128/113 and 130/111, so the literal matched NEITHER.
    # A number in a refusal is an assertion; assert the one you just computed.
    print(
        "A test that runs nowhere asserts nothing. Wire it (name it in a\n"
        "workflow), or delete it. Adding it to the UNWIRED backlog is NOT the\n"
        f"fix. The backlog is the {len(recorded_unwired)} entries already recorded in\n"
        "tests/TEST_WIRING.tsv, and the whole point of this gate is that it\n"
        "stops there.",
        file=sys.stderr,
    )

if missing_rows:
    fail = True
    print("", file=sys.stderr)
    print("These test files have no row in the manifest at all:", file=sys.stderr)
    for t in missing_rows:
        print(f"    {t}", file=sys.stderr)
    print("Run scripts/verify_test_wiring.sh --regenerate and commit.", file=sys.stderr)

# ── THE BACKLOG MUST SHRINK, NOT MERELY NOT-GROW ──────────────────────────
#
# ANDY, 2026-09-02: "The bigger question is WHY there continue to be 'unwired'
# things at all??? I keep asking, yet you keep finding and/or delivering more."
#
# THE ANSWER IS THIS GATE, AND IT IS WORTH STATING PLAINLY BECAUSE IT IS MINE.
# Until this block existed the gate exited 0 whenever a test was "wired, OR IS
# IN THE RECORDED BACKLOG". It stopped the set GROWING and nothing ever forced
# it DOWN. So 91 tests sat dark and the gate printed
#
#     "OK: no test file is newly unwired."
#
# on every run, for months, truthfully. A green that means "still 91 dark" is
# how "unwired" survives being asked about repeatedly.
#
# 🔴 IT COST US A LIVE LAUNCH BLOCKER. tests/TEST_WIRING.tsv recorded
# test_walkaway_no_phase2_input_leak.sh as UNWIRED with runner "-". That test
# guards a BLOCKING gui_read at install.sh:11176, inside the phase install.sh
# itself declares unattended at :9757. A GUI walk-away install stalls on a
# consent sheet with nobody at the keyboard. The test existed. It was in the
# permitted backlog. Nothing ran it. It was found by hand, not by CI.
#
# THE FIX IS A ONE-WAY RATCHET. The ceiling in tests/TEST_WIRING_CEILING may
# only ever DECREASE. Wiring tests lowers it; nothing can raise it. The backlog
# therefore has to drain, and it can never be re-inflated to hide a new dark
# test behind an old number.
# FIXTURE HERMETICITY, SECOND OCCURRENCE -- see the Swift-glob note above.
# I anchored this on REPO_ROOT and the self-test suite went red on three arms:
# each fixture scans a temp tests dir holding 1-2 files, so its backlog is 0 or
# 1, but the ceiling it read was the REAL repo's 91. "THE BACKLOG SHRANK TO 0"
# was the gate comparing one repo's population against another repo's pin.
#
# The ceiling therefore anchors on TESTS_DIR -- the population actually being
# scanned -- so a number can never be checked against a set it does not
# describe. A fixture that wants the ratchet evaluated writes its own ceiling.
ceiling_path = os.path.join(tests_dir, "TEST_WIRING_CEILING")
_is_real_run = os.path.realpath(tests_dir) == os.path.realpath(
    os.path.join(repo, "tests")
)
if not os.path.exists(ceiling_path):
    if _is_real_run:
        # An ABSENT ceiling is CANNOT-RUN, never a pass. A deleted ceiling file
        # must not read as "no limit"; that is how a ratchet gets quietly
        # removed.
        print(
            "verify_test_wiring: CANNOT RUN -- tests/TEST_WIRING_CEILING is absent.\n"
            "The unwired backlog has no upper bound to check against. That is not a\n"
            "clean result, it is a missing instrument.",
            file=sys.stderr,
        )
        sys.exit(2)
    # A fixture run that declares no ceiling is not making a claim about the
    # backlog, so there is nothing to ratchet. SAY SO on stdout: a skipped
    # check that prints nothing is indistinguishable from one that passed,
    # which is the defect this whole file exists to prevent.
    print("  UNWIRED backlog: not evaluated (fixture run declares no ceiling)")
    if fail:
        sys.exit(1)
    print("OK: no test file is newly unwired.")
    sys.exit(0)
try:
    ceiling = int(read(ceiling_path).strip())
except ValueError:
    print(
        "verify_test_wiring: CANNOT RUN -- TEST_WIRING_CEILING is not an integer.",
        file=sys.stderr,
    )
    sys.exit(2)

actual = len(recorded_unwired)
print(f"  UNWIRED backlog: {actual}  (ceiling {ceiling}, may only DECREASE)")
if actual > ceiling:
    fail = True
    print("", file=sys.stderr)
    print(
        f"THE UNWIRED BACKLOG GREW: {actual} > ceiling {ceiling}.\n"
        "Wire the test, or delete it. Raising the ceiling is not a fix and the\n"
        "companion test refuses a raised ceiling on its own.",
        file=sys.stderr,
    )
elif actual < ceiling:
    # Shrinking is the POINT, but a stale ceiling lets the backlog creep back
    # up to the old number unnoticed. Force the ratchet to be re-pinned.
    fail = True
    print("", file=sys.stderr)
    print(
        f"THE BACKLOG SHRANK TO {actual} BUT THE CEILING STILL SAYS {ceiling}.\n"
        "Good news, unfinished: lower the ceiling to match, or the slack you\n"
        "just earned silently permits the backlog to grow back into it.\n"
        f"    printf '{actual}\\n' > tests/TEST_WIRING_CEILING",
        file=sys.stderr,
    )

if fail:
    sys.exit(1)

print(f"OK: no test file is newly unwired, and the backlog is pinned at {actual}.")
sys.exit(0)
PYEOF
