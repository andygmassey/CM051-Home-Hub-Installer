#!/usr/bin/env python3
"""A test that refuses only during a cut must be RUN during the cut.

THE DEFECT, COMMITTED TWICE IN ONE BATCH BY THE AGENT WHO KEEPS QUOTING ITEM 9.

A cut gate has two arms: it reports and exits 0 in ordinary CI, and it exits 1
under OSTLER_CUT_IN_PROGRESS=1 so the cut stops. The second arm is the entire
point. Both of tests/test_the_doctor_page_is_on_brand.py and
tests/test_a_forget_erases_the_fact_not_just_the_link.py were wired into a
subject workflow, recorded WIRED in tests/TEST_WIRING.tsv, ran green on every
PR, and named NOWHERE in .github/workflows/cut.yml. Measured on origin/main:

    test_the_doctor_page_is_on_brand                  0 occurrences in cut.yml
    test_a_forget_erases_the_fact_not_just_the_link   0
    CONTROL test_the_cut_checklist_is_complete        1

So the refusal ran nowhere, and both pull requests asserted in their own bodies
that the gate would stop a cut. The subject workflows never set the flag, so the
rc-1 branch was unreachable code that looked wired from every angle anyone
checked.

WHY TEST_WIRING.tsv CANNOT SEE THIS. It answers "does any workflow run this
file", which was true and stayed true. It does not ask "does the workflow that
runs it set the variable the file branches on". A register that records the
invocation cannot see a conditional arm inside the thing invoked.

THIS IS THE SAME SHAPE AS THE WORKFLOW-STEP GATE: a defect that deletes the
evidence of itself. An unreachable refusal produces no output, no failure and no
log line. The only way to see it is to compare the two files.

THREE STATES. 0 pass, 1 fail, 2 cannot-run.
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
TESTS = REPO / "tests"
CUT = REPO / ".github" / "workflows" / "cut.yml"

FLAG = "OSTLER_CUT_IN_PROGRESS"

#: Below this, the finder has gone blind: zero cut gates trivially all pass.
FLOOR = 2

PASS, FAIL = [], []


def ok(msg):
    PASS.append(msg)
    print("  [PASS] %s" % msg)


def bad(msg):
    FAIL.append(msg)
    print("  [FAIL] %s" % msg)


def cant(msg):
    print("CANNOT-RUN: %s" % msg, file=sys.stderr)
    sys.exit(2)


def branches_on_flag(text):
    """True when the file READS the flag, rather than merely naming it.

    A file that only mentions the variable in prose is documenting it, not
    branching on it. The read forms are what matter: os.environ, getenv, and
    the shell's ${VAR}/$VAR expansions.
    """
    return bool(re.search(
        r"(?:environ(?:\.get)?\s*[\(\[]\s*['\"]%s|getenv\s*\(\s*['\"]%s|\$\{?%s\b)" % (FLAG, FLAG, FLAG),
        text))


def named_in(haystack, stem):
    return stem in haystack


if not CUT.is_file():
    cant("%s is not a file, so nothing could be compared" % CUT)
if not TESTS.is_dir():
    cant("%s is not a directory" % TESTS)

cut_text = CUT.read_text(encoding="utf-8")

print("-- controls: the finder must see a gate and must ignore prose --")

# A file that BRANCHES must be recognised, and one that merely NAMES the flag in
# a comment must not. Without this, "no unreachable gates" could mean "the
# finder matched nothing".
if branches_on_flag('v = os.environ.get("%s", "")' % FLAG) and \
   branches_on_flag('[ -n "${%s:-}" ]' % FLAG):
    ok("CONTROL: the finder recognises both a Python read and a shell read")
else:
    bad("CONTROL: the finder missed a seeded read of the flag, so its silence "
        "below would prove nothing")

if not branches_on_flag("# set %s=1 and this refuses instead" % FLAG):
    ok("CONTROL: a prose mention of the flag is NOT counted as a branch")
else:
    bad("CONTROL: a comment naming the flag was counted as a branch. This gate "
        "would demand cut.yml entries for files that do not gate anything.")

# 🔴 MUST-MISS ON THE REAL TREE, NOT ON A FIXTURE. Two files in this repo SET
# the flag to drive another gate. They are harnesses, not gates with a dead arm,
# and naming them in cut.yml would be the wrong fix. A substring test gets both
# of them wrong, which is the same shape as the checklist predicate that has
# cost this estate six tools: the file that talks ABOUT a marker trips it.
#
# These are named rather than seeded because a fixture proves the regex handles
# a string I wrote, and these prove it handles the strings that actually exist.
HARNESSES = (
    "test_a_blocker_with_no_issue_still_blocks.py",   # dict(os.environ, FLAG="1")
    "test_a_blocking_row_stops_a_cut.sh",             # FLAG="$cutting"
)
for name in HARNESSES:
    candidate = TESTS / name
    if not candidate.is_file():
        bad("MUST-MISS: %s is not on disk, so this control measured nothing. It "
            "was renamed or removed, and the discriminator is now unproven "
            "against the shape it exists to separate." % name)
        continue
    if branches_on_flag(candidate.read_text(encoding="utf-8", errors="replace")):
        bad("MUST-MISS: %s SETS the flag to drive another gate and was counted as "
            "a gate with a dead arm. This gate would demand a cut.yml entry for a "
            "harness, which is the wrong fix." % name)
    else:
        ok("MUST-MISS: %s sets the flag rather than reading it, and is not counted" % name)

gates = []
for path in sorted(TESTS.rglob("*")):
    if not path.is_file() or path.suffix not in (".py", ".sh"):
        continue
    if path.name == pathlib.Path(__file__).name:
        continue          # this file documents the flag; it does not branch on it
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        continue
    if branches_on_flag(text):
        gates.append(path)

# THE SELF-EXCLUSION MUST BE NARROW. This file names the flag more often than
# any subject it examines, so it excludes itself. An exclusion that quietly
# widened would hide real gates behind the same clause.
_excluded = [p for p in TESTS.rglob("*")
             if p.is_file() and p.suffix in (".py", ".sh")
             and p.name == pathlib.Path(__file__).name]
if len(_excluded) == 1:
    ok("CONTROL: the self-exclusion covers exactly one file, this one")
else:
    bad("CONTROL: the self-exclusion matches %d file(s), so it is not narrow and "
        "may be hiding a real gate" % len(_excluded))

print("-- subject: every cut gate in tests/ --")
print("     EXAMINED: %d file(s) under tests/, %d of them branch on %s"
      % (sum(1 for p in TESTS.rglob("*") if p.is_file() and p.suffix in (".py", ".sh")),
         len(gates), FLAG))

if len(gates) < FLOOR:
    cant("found %d cut gate(s), below the floor of %d. The finder has gone blind "
         "or the gates were renamed; zero gates are trivially all reachable and "
         "that is not a pass." % (len(gates), FLOOR))

# POSITIVE CONTROL OF THE SAME SHAPE AS THE SUBJECT. A known-wired gate must be
# found in cut.yml, or "not named in cut.yml" means the reader is broken.
control = "test_the_cut_checklist_is_complete"
if named_in(cut_text, control):
    ok("CONTROL: %s IS named in cut.yml, so a miss below is real" % control)
else:
    bad("CONTROL: the known cut gate %s was not found in cut.yml. The reader is "
        "broken and every finding below is noise." % control)

unreachable = [p for p in gates if not named_in(cut_text, p.stem)]
for p in sorted(gates):
    print("       %-58s %s" % (p.name, "in cut.yml" if named_in(cut_text, p.stem) else "NOT IN cut.yml"))

if unreachable:
    bad("%d of %d cut gate(s) branch on %s and are named nowhere in cut.yml, so "
        "the arm that refuses a cut runs NOWHERE: %s. A gate whose refusal is "
        "unreachable produces no output and no failure, so nothing but this "
        "comparison can see it."
        % (len(unreachable), len(gates), FLAG, ", ".join(p.name for p in unreachable)))
else:
    ok("all %d cut gate(s) are named in cut.yml, so every refusal arm can fire" % len(gates))

print()
print("== %d pass / %d fail / %d total ==" % (len(PASS), len(FAIL), len(PASS) + len(FAIL)))
sys.exit(1 if FAIL else 0)
