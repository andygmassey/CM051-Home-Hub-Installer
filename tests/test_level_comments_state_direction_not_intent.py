#!/usr/bin/env python3
"""A COMMENT ON A PRIVACY NUMBER MUST STATE THE DIRECTION, NOT THE INTENT.

=============================================================================
THE DEFECT THIS EXISTS FOR
=============================================================================

Shipped in vendor/cm019_preferences/services/ingest/src/parsers/apple.py, at
four sites, for Apple Notes and Apple Health:

    compartment_level=5,  # HIGHEST PRIVACY

compartment_level runs 0 to 6 with LOWER meaning more private, so 5 is
L5Commercial, which vendor/cm041/contact_syncer/privacy_model.py maps onto
privacy LEVEL_L2: publishable. A customer's health records and private notes
were labelled one step from Broadcast.

THE COMMENT IS WHY IT SURVIVED REVIEW. The prose stated the intent correctly
and the number said the opposite, so a reviewer checking intent found the right
words sitting next to the wrong value. Nothing on the line could be checked
against anything else on the line. Three docstrings taught the same inversion
to whoever read them next.

The required form says what the number IS:

    compartment_level=0,  # L0Personal, the most private level

Now the line carries its own control. A reader who knows 0 is L0Personal can
see agreement or disagreement without leaving the line, and a reader who does
not can look L0Personal up. See docs/PRIVACY_LEVELS.md for both scales.

=============================================================================
THE PREDICATE, IN FULL, BECAUSE A HEURISTIC NOBODY CAN RESTATE IS A HEURISTIC
NOBODY CAN ARGUE WITH
=============================================================================

A line is a VIOLATION when all four hold.

  1. ASSIGNMENT. It assigns a NUMERIC LITERAL to an identifier ending in
     `_level`. Covered: `compartment_level=5`, `privacy_level = 2`,
     `"compartment_level": 5`, `compartment_level: 5` (YAML),
     `compartment_level: int = 2` (annotated).
     NOT covered, deliberately: comparisons (`== 5`, `>= 5`, `!= 5`) and
     assignments from a variable (`compartment_level=level`). Neither writes a
     number a comment could mislabel, so neither is the defect class. An
     assignment sitting INSIDE a comment is prose, and is skipped and counted
     separately so the number examined is not quietly inflated.

  2. COMMENT. A `#` or `//` comment either TRAILING the assignment on the same
     line, or, when there is none, the contiguous comment block immediately
     ABOVE it. The block arm closes the obvious evasion of moving the words up
     one line. String literals are masked before the comment marker is looked
     for, so a `#` inside a quoted string is not mistaken for a comment.

  3. INTENT WORDS. The comment says `privacy`, `private`, `public`,
     `sensitive`, `confidential` or `secret`. This is what makes the line look
     reviewed. A comment with none of these makes no privacy claim at all and
     is out of scope here.

  4. AND IT DOES NOT RESTATE THE NUMBER IT IS LABELLING. Two exemptions, and
     BOTH require the comment to name the value actually assigned:

       NAMES THE LEVEL   the comment contains `L<n>` (`L0Personal`,
                         `L2Trusted`, a bare `L3`) for the n that was
                         assigned. `compartment_level=0, # L0Personal` is
                         exempt; `compartment_level=5, # L0Personal` is NOT,
                         because that pairing is the defect written out.

       STATES THE DIRECTION
                         the comment contains a direction word (`lower`,
                         `higher`, `lowest`, `highest`, `most`, `least`,
                         `more`, `less`, `max`, `min`, `top`, `bottom`,
                         `ascending`, `descending`, `increasing`,
                         `decreasing`, `counts up`, `counts down`) AND a
                         numeral equal to the assigned value. So
                         `# 0 = most private` is exempt and
                         `# HIGHEST PRIVACY` is not: it has the direction word
                         and no number, which is precisely how a claim about a
                         scale escapes ever being checked against the scale.

WHY THE EXEMPTION IS "RESTATE THE NUMBER" AND NOT "MENTION A LEVEL".
An exemption satisfied by any level name would have passed
`compartment_level=5, # HIGHEST PRIVACY (L0Personal)`, which is the same defect
with more words. Requiring the comment to name the number that was written is
the only version under which the line can be checked against itself.

KNOWN LIMITS, STATED RATHER THAN DISCOVERED LATER.
  * Docstrings are not comments here. apple.py carried the same inversion in
    four docstring lines; they are prose about the code, not a label on a
    number, and treating them as comments would put every module docstring
    that mentions privacy into the population.
  * `# highest number is least private` is refused despite being true, because
    it names no value. The remedy is to add the value. Over-refusal pushes
    toward the form that carries its own control, which is the point.
  * camelCase (`compartmentLevel`) is not matched. The field is snake_case in
    every writer measured; widening it without a measured instance would be
    guessing at a population.

=============================================================================
WHY A BASELINE AND NOT A MASS FIX
=============================================================================

The existing violations are in VENDORED parser code on the install path.
Rewriting a privacy label is a change to what a customer's data is labelled as,
not a comment tidy-up, and the two live sites are already being handled by the
pull request that fixed the four apple.py assignments. So the set is frozen
with a count per file, printed on every run, and the gate fires the moment it
grows. Unlike the crossing ratchet, the count here IS load-bearing: violations
accumulate inside a file, so a name-only row would let a listed file take on
new ones for ever under a green verdict.

=============================================================================
EXIT CODES
=============================================================================

  0  the violation set matches the baseline exactly
  1  it GREW (a new file, or a higher count), or SHRANK without the baseline
     being lowered (slack the next regression hides in)
  2  CANNOT-RUN: no baseline, an empty scan, or a baseline that does not parse.
     "No new violations" and "I could not look" print identically otherwise.

British English throughout. En dashes, never em dashes.
"""

import os
import re
import sys
import tempfile

# CARRY OUR OWN sys.path. A test that only works because of what its invoker
# happened to export is not wired; it is borrowing. Nothing here imports from
# the repo today, and the insertion is here so that the first import added by
# the next author does not silently depend on PYTHONPATH.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

BASELINE_FILE = os.path.join(REPO_ROOT, "tests", "level_comment_intent_baseline.txt")

# --- the predicate ---------------------------------------------------------

ASSIGN = re.compile(
    r"\b(?P<name>[A-Za-z_][A-Za-z0-9_]*_level)"
    r"""(?:["']?\s*[:=](?!=)|\s*:\s*[A-Za-z_][\w\[\], .]*?\s*=)"""
    r"\s*(?P<val>-?\d+)"
)
INTENT = re.compile(
    r"\b(privacy|private|public|sensitive|confidential|secret)", re.IGNORECASE
)
LEVEL_TOKEN = re.compile(r"\bL(\d)[A-Za-z]*\b")
DIRECTION = re.compile(
    r"\b(lower|higher|lowest|highest|most|least|more|less|max|min|top|bottom"
    r"|ascending|descending|increasing|decreasing|counts? up|counts? down)\b",
    re.IGNORECASE,
)
NUMERAL = re.compile(r"-?\d+")
STRING_LITERAL = re.compile(r"\"[^\"\n]*\"|'[^'\n]*'")
COMMENT_LINE = re.compile(r"^\s*(#|//)")

# Exclusions, in ONE place, applied to the live tree and to every control. A
# rule applied to the tree but not to the controls is a rule nobody tested.
#   tests/, */tests/   a test that quotes the banned comment is the REMEDY, and
#                      this file quotes it repeatedly. Counting a test would
#                      mean the only route to green is to stop testing.
#   docs/, */docs/     prose cannot label a customer's data.
#                      docs/PRIVACY_LEVELS.md exists to quote this defect.
#   cut-manifests/     release-review registers that QUOTE the finding.
EXCLUDED_DIRS = ("tests", "docs")
EXCLUDED_TOP = ("cut-manifests",)


def is_excluded(relpath):
    parts = relpath.split(os.sep)
    if parts[0] in EXCLUDED_TOP:
        return True
    return any(p in EXCLUDED_DIRS for p in parts[:-1])


def comment_start(line, frm=0):
    """Index of the comment marker at or after `frm`, or -1.

    String literals are masked first, so `{"tag": "#private"}` does not read as
    a comment. The mask preserves length so the index maps back to `line`.
    """
    masked = STRING_LITERAL.sub(lambda m: "x" * len(m.group(0)), line)
    found = [k for k in (masked.find("#", frm), masked.find("//", frm)) if k >= 0]
    return min(found) if found else -1


def comment_for(lines, idx, match):
    """The comment that labels this assignment, or None.

    Trailing comment first; failing that, the contiguous comment block directly
    above. Returns None when the assignment carries no comment at all.
    """
    line = lines[idx]
    k = comment_start(line, match.end())
    if k != -1:
        return line[k:]
    block = []
    j = idx - 1
    while j >= 0 and COMMENT_LINE.match(lines[j]):
        block.insert(0, lines[j])
        j -= 1
    return "\n".join(block) if block else None


def comment_violates(comment, value):
    if not INTENT.search(comment):
        return False
    if any(int(d) == value for d in LEVEL_TOKEN.findall(comment)):
        return False
    if DIRECTION.search(comment) and any(
        int(n) == value for n in NUMERAL.findall(comment)
    ):
        return False
    return True


class Scan(object):
    def __init__(self):
        self.files = 0
        self.binary = 0
        self.unreadable = []
        self.assignments = 0
        self.in_comment = 0
        self.commented = 0
        self.hits = {}


def scan(root):
    """Walk `root` and return a Scan. Counts every denominator it uses.

    THREE OUTCOMES PER FILE, NOT TWO. A PNG and a UTF-16 source file both fail
    a UTF-8 decode, and lumping them together is how a real blind spot hides in
    a list of eighteen icons: the reader learns to scroll past it. So a NUL byte
    in the first block classifies a file as BINARY, which is counted and not
    listed, and anything else that will not decode is UNREADABLE, which is
    listed by name because it is a file this gate cannot see into.
    """
    result = Scan()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            if is_excluded(rel):
                continue
            if os.path.islink(full):
                continue
            try:
                with open(full, "rb") as fh:
                    raw = fh.read()
            except OSError:
                result.unreadable.append(rel)
                continue
            if b"\x00" in raw[:8192]:
                result.binary += 1
                continue
            try:
                lines = raw.decode("utf-8").splitlines()
            except UnicodeDecodeError:
                # NOT silently skipped. A text file we could not read is not a
                # clean file, and a scanner that swallows them reports a zero
                # that is a statement about the scanner.
                result.unreadable.append(rel)
                continue
            result.files += 1
            for i, line in enumerate(lines):
                m = ASSIGN.search(line)
                if not m:
                    continue
                before = comment_start(line, 0)
                if before != -1 and before < m.start():
                    result.in_comment += 1
                    continue
                result.assignments += 1
                comment = comment_for(lines, i, m)
                if comment is None:
                    continue
                result.commented += 1
                if comment_violates(comment, int(m.group("val"))):
                    result.hits.setdefault(rel.replace(os.sep, "/"), []).append(
                        (i + 1, line.strip())
                    )
    return result


# --- baseline handling -----------------------------------------------------


def read_baseline(path):
    """Return {path: count}. Raises ValueError on a malformed row."""
    rows = {}
    with open(path, "r", encoding="utf-8") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 2:
                raise ValueError(
                    "line %d is not 'path<TAB>count': %r" % (n, line)
                )
            rows[parts[0]] = int(parts[1])
    return rows


def compare(baseline, found):
    """Return (added, grew, shrank, delisted). Driven against a known answer
    in limb 4 before it is trusted with the real one."""
    added = sorted(p for p in found if p not in baseline)
    grew = sorted(
        (p, baseline[p], found[p]) for p in found
        if p in baseline and found[p] > baseline[p]
    )
    shrank = sorted(
        (p, baseline[p], found[p]) for p in found
        if p in baseline and found[p] < baseline[p]
    )
    delisted = sorted(p for p in baseline if p not in found)
    return added, grew, shrank, delisted


# --- harness ---------------------------------------------------------------

PASS = [0]
FAIL = [0]


def ok(msg):
    print("  ok    %s" % msg)
    PASS[0] += 1


def bad(msg):
    print("  FAIL  %s" % msg)
    FAIL[0] += 1


def cannot(msg):
    sys.stderr.write("\n  CANNOT-RUN  %s\n" % msg)
    sys.exit(2)


def finish():
    print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
    sys.exit(1 if FAIL[0] else 0)


def main():
    print("\n=== a privacy number's comment must name the number ===\n")

    # --- 1. THE PREDICATE, AGAINST CASES WHOSE ANSWER IS ALREADY KNOWN -------
    #
    # These run before anything touches the tree. A scanner can be pointed at
    # the right files and still be wrong about every one of them, and a
    # whole-tree "0 violations" from a predicate that refuses nothing looks
    # exactly like a clean tree.
    #
    # The positive control is the LITERAL TEXT THAT SHIPPED. If this file ever
    # stops refusing that line, it has stopped being able to catch the thing it
    # was written for, whatever else is green.
    must_refuse = [
        ("compartment_level=5,  # HIGHEST PRIVACY",
         "the exact line that shipped for Apple Notes and Health"),
        ("compartment_level=5,  # HIGHEST PRIVACY - notes contain personal info",
         "the same, with a justification appended"),
        ("        compartment_level=3,  # Medium privacy (contains location data)",
         "an intent word with no number at all"),
        ("compartment_level=5,  # max privacy",
         "max privacy: a direction word, no value"),
        ("compartment_level=5,  # most private",
         "most private: a direction word, no value"),
        ("compartment_level=5,  # privacy",
         "the bare word privacy"),
        ("compartment_level=5,  # L0Personal, the most private level",
         "names a level, but NOT the one assigned. This is the defect spelled out"),
        ("compartment_level=5,  # HIGHEST PRIVACY (L0Personal)",
         "an intent claim wearing a level name that contradicts the value"),
        ("privacy_level = 2  # the most private",
         "the other scale, same shape"),
        ('{"compartment_level": 5},  # highest privacy',
         "a dict literal rather than a keyword argument"),
        ("compartment_level: int = 5  # highest privacy",
         "an annotated assignment"),
        ("int compartment_level = 5;  // HIGHEST PRIVACY",
         "a // comment, so the predicate is not Python-only"),
    ]
    must_allow = [
        ("compartment_level=0,  # L0Personal, the most private level",
         "the required form"),
        ("compartment_level=5,  # L5Commercial, publishable",
         "names the level it actually assigned, even though that level is public"),
        ("compartment_level=0,  # 0 = most private on this scale",
         "states the direction AND restates the value"),
        ("compartment_level=2,  # L2Trusted, the default",
         "a bare level name with no direction claim"),
        ("compartment_level=0,  # L0Personal, not L5Commercial which is publishable",
         "names two levels, one of which is the value assigned"),
        ("compartment_level=5,  # keyed off the source, see base.py",
         "a comment that makes no privacy claim"),
        ("compartment_level = level  # HIGHEST PRIVACY",
         "no numeric literal, so there is no number to mislabel"),
        ("if compartment_level == 5:  # highest privacy",
         "a comparison, not an assignment"),
        ("if compartment_level >= 5:  # highest privacy",
         "a >= comparison, which must not read as an assignment"),
        ('tag = {"compartment_level": 5, "note": "#private"}',
         "a # inside a string literal is not a comment"),
        ("compartment_level=5,",
         "no comment at all"),
    ]

    def verdict(text):
        lines = text.split("\n")
        m = ASSIGN.search(lines[-1])
        if not m:
            return False
        before = comment_start(lines[-1], 0)
        if before != -1 and before < m.start():
            return False
        c = comment_for(lines, len(lines) - 1, m)
        if c is None:
            return False
        return comment_violates(c, int(m.group("val")))

    for text, why in must_refuse:
        if verdict(text):
            ok("REFUSED (%s)" % why)
        else:
            bad("MUST REFUSE and did not (%s): %s" % (why, text.strip()))
    for text, why in must_allow:
        if verdict(text):
            bad("MUST ALLOW and refused (%s): %s" % (why, text.strip()))
        else:
            ok("allowed (%s)" % why)

    # THE EVASION ARM. Trailing comment moved one line up.
    moved_up = "# HIGHEST PRIVACY\ncompartment_level=5,"
    if verdict(moved_up):
        ok("REFUSED: the same claim moved to the line above is still caught")
    else:
        bad("The comment moved one line above the assignment escaped. The block arm of comment_for is not working, and every violation below can be evaded with one newline.")

    # --- 2. THE SCANNER, AGAINST A SEEDED TREE ------------------------------
    #
    # Seeded in a temp dir, never pointed at a tracked file. A control whose
    # subject an open pull request is editing inverts on merge, and then reports
    # the scanner blind when what actually happened is that the defect was
    # fixed. Nobody will ever "fix" a fixture that exists to be found.
    ctl = tempfile.mkdtemp()
    seeded = "compartment_level=5,  # HIGHEST PRIVACY\n"
    plan = {
        "lib/parser.py": seeded,
        "lib/clean.py": "compartment_level=0,  # L0Personal, the most private level\n",
        "tests/parser_test.py": seeded,
        "vendor/pkg/tests/parser_test.py": seeded,
        "docs/PRIVACY_LEVELS.md": seeded,
        "vendor/pkg/docs/NOTES.md": seeded,
        "cut-manifests/v1.0.99.yaml": seeded,
    }
    for rel, body in plan.items():
        full = os.path.join(ctl, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(body)
    # TWO FIXTURES, BECAUSE THERE ARE TWO ANSWERS AND ONLY ONE IS ALARMING.
    # An icon is binary and always will be: counted, not named. A TEXT file that
    # will not decode is a file this gate cannot see into, and it is named.
    # Written as bytes with no NUL so it lands in the second bucket, which is
    # the whole point of the classifier.
    with open(os.path.join(ctl, "lib", "mojibake.py"), "wb") as fh:
        fh.write(b"compartment_level=5,  # HIGHEST PRIVACY \xff\xfe\n")
    with open(os.path.join(ctl, "lib", "icon.png"), "wb") as fh:
        fh.write(b"\x89PNG\x00\x00\x00compartment_level=5,  # HIGHEST PRIVACY")

    cs = scan(ctl)
    if "lib/parser.py" in cs.hits:
        ok("POSITIVE CONTROL: the scanner finds a seeded violation it MUST find")
    else:
        bad("POSITIVE CONTROL FAILED: the scanner did not find a file it was handed carrying the exact shipped line. It is blind and every count below is void.")
    if "lib/clean.py" not in cs.hits:
        ok("DISCRIMINATOR: the required form is not reported")
    else:
        bad("DISCRIMINATOR FAILED: the required form was reported as a violation. The gate would demand that a correct comment be removed.")
    for rel in ("tests/parser_test.py", "vendor/pkg/tests/parser_test.py",
                "docs/PRIVACY_LEVELS.md", "vendor/pkg/docs/NOTES.md",
                "cut-manifests/v1.0.99.yaml"):
        if rel not in cs.hits:
            ok("DISCRIMINATOR: %s is excluded by declared rule, not reported" % rel)
        else:
            bad("DISCRIMINATOR FAILED: %s was reported. The exclusion stated in this file's header does not hold." % rel)
    if "lib/mojibake.py" in cs.unreadable:
        ok("DISCRIMINATOR: an undecodable TEXT file is named as unreadable, not counted as clean")
    else:
        bad("DISCRIMINATOR FAILED: an undecodable text file was silently dropped. 'Found nothing' and 'could not look' would print identically.")
    if "lib/icon.png" not in cs.unreadable and cs.binary == 1:
        ok("DISCRIMINATOR: a binary file is counted as binary, not paraded as a blind spot")
    else:
        bad("DISCRIMINATOR FAILED: binary files and undecodable text are not being told apart (binary=%d, unreadable=%r). A list padded with icons is a list nobody reads."
            % (cs.binary, cs.unreadable))
    # THE FLOOR. Five exclusion fixtures and one positive: a scanner that
    # excluded everything would also return exactly the positive, so assert
    # the set SIZE as well as its members.
    if len(cs.hits) == 1:
        ok("CONTROL FLOOR: the seeded tree yields exactly 1 violating file, so the exclusions removed 5 and not 6")
    else:
        bad("CONTROL FLOOR: expected exactly 1 violating file in the seeded tree, got %d (%s). The controls above cannot be scored."
            % (len(cs.hits), ", ".join(sorted(cs.hits))))

    # --- 3. THE COMPARISON, DRIVEN AGAINST A KNOWN ANSWER -------------------
    base = {"a/one.py": 2, "a/two.py": 1}
    added, grew, shrank, delisted = compare(base, {"a/one.py": 2, "a/two.py": 1})
    if not (added or grew or shrank or delisted):
        ok("COMPARISON: an identical pair reports no difference")
    else:
        bad("COMPARISON: an identical pair reported a difference. The ratchet cannot tell agreement from disagreement.")
    added, grew, shrank, delisted = compare(
        base, {"a/one.py": 2, "a/two.py": 1, "a/three.py": 1})
    if added == ["a/three.py"] and not (grew or shrank or delisted):
        ok("COMPARISON: a new file is named, and only it")
    else:
        bad("COMPARISON: expected only a/three.py added, got %r/%r/%r/%r" % (added, grew, shrank, delisted))
    added, grew, shrank, delisted = compare(base, {"a/one.py": 3, "a/two.py": 1})
    if grew == [("a/one.py", 2, 3)] and not (added or shrank or delisted):
        ok("COMPARISON: a file already listed that GREW is caught, which a name-only row could never see")
    else:
        bad("COMPARISON: expected only a/one.py 2->3, got %r/%r/%r/%r" % (added, grew, shrank, delisted))
    added, grew, shrank, delisted = compare(base, {"a/one.py": 1, "a/two.py": 1})
    if shrank == [("a/one.py", 2, 1)] and not (added or grew or delisted):
        ok("COMPARISON: a file that SHRANK is caught, so a fix cannot leave slack behind")
    else:
        bad("COMPARISON: expected only a/one.py 2->1, got %r/%r/%r/%r" % (added, grew, shrank, delisted))
    added, grew, shrank, delisted = compare(base, {"a/one.py": 2})
    if delisted == ["a/two.py"] and not (added or grew or shrank):
        ok("COMPARISON: a baselined file the scan no longer finds is named")
    else:
        bad("COMPARISON: expected only a/two.py delisted, got %r/%r/%r/%r" % (added, grew, shrank, delisted))

    # --- 4. THE LIVE SCAN, WITH ITS DENOMINATORS ----------------------------
    live = scan(REPO_ROOT)
    if live.files < 100:
        cannot("the walk examined only %d files. An empty or near-empty scan is not a clean result, it is a missing instrument." % live.files)
    if live.assignments == 0:
        cannot("ZERO numeric *_level assignments were found in %d files. A uniform zero means a broken predicate, not a clean tree." % live.files)

    print("")
    print("        text files examined:                     %d" % live.files)
    print("        binary files skipped (NUL in block 1):   %d" % live.binary)
    print("        TEXT files that would not decode:        %d" % len(live.unreadable))
    print("        numeric *_level assignments:             %d" % live.assignments)
    print("        assignments skipped (inside a comment):  %d" % live.in_comment)
    print("        of the assignments, carrying a comment:  %d" % live.commented)
    print("        VIOLATIONS: %d in %d file(s)"
          % (sum(len(v) for v in live.hits.values()), len(live.hits)))
    print("")
    for path in sorted(live.hits):
        for lineno, text in live.hits[path]:
            print("          %s:%d  %s" % (path, lineno, text[:100]))
    if live.unreadable:
        print("")
        for rel in sorted(live.unreadable):
            print("          UNREADABLE (not scored clean): %s" % rel)
    print("")

    if live.commented == 0:
        cannot("not ONE of the %d assignments carried a comment. comment_for is returning None for everything, so 'no violations' would be a fact about the reader." % live.assignments)

    # --- 5. THE RATCHET -----------------------------------------------------
    if not os.path.exists(BASELINE_FILE):
        cannot("%s is absent. There is nothing to ratchet against, so 'no new violations' would be unfounded. A deleted baseline must never read as 'no limit'."
               % os.path.relpath(BASELINE_FILE, REPO_ROOT))
    try:
        baseline = read_baseline(BASELINE_FILE)
    except (ValueError, OSError) as exc:
        cannot("%s does not parse: %s" % (os.path.relpath(BASELINE_FILE, REPO_ROOT), exc))
    if not baseline:
        cannot("%s lists zero rows. An empty baseline reads as either 'everything is new' or 'everything is fine' depending on which way it is used, and neither is a measurement."
               % os.path.relpath(BASELINE_FILE, REPO_ROOT))

    found = dict((p, len(v)) for p, v in live.hits.items())
    added, grew, shrank, delisted = compare(baseline, found)

    total_base = sum(baseline.values())
    total_found = sum(found.values())

    if added or grew:
        if added:
            bad("RATCHET: NEW files carrying an intent comment on a privacy number (%d violations found, baseline %d):"
                % (total_found, total_base))
            for p in added:
                print("            %s  (%d)" % (p, found[p]))
        if grew:
            bad("RATCHET: files already baselined that took on MORE:")
            for p, was, now in grew:
                print("            %s  %d -> %d" % (p, was, now))
        print("          State the direction and the value, not the intent:")
        print("              compartment_level=0,  # L0Personal, the most private level")
        print("          not")
        print("              compartment_level=5,  # HIGHEST PRIVACY")
        print("          5 is L5Commercial, which privacy_model.py labels publishable.")
        print("          Read docs/PRIVACY_LEVELS.md before choosing the number.")
    else:
        ok("RATCHET: no new violations. All %d found are within the baselined %d."
           % (total_found, total_base))

    if shrank or delisted:
        bad("RATCHET: the baseline claims more than this scan found. That is slack the next regression hides in.")
        for p, was, now in shrank:
            print("            %s  baseline %d, found %d" % (p, was, now))
        for p in delisted:
            present = os.path.exists(os.path.join(REPO_ROOT, p))
            print("            %s  baseline %d, found 0  (%s)"
                  % (p, baseline[p], "file still present, so the comments were fixed"
                     if present else "file no longer exists"))
        print("          Lower the baseline in the same commit as the fix, or the slack")
        print("          just earned silently permits the count to grow back into it.")
    else:
        ok("NO BASELINE ROT: every baselined row was found at its recorded count")

    finish()


if __name__ == "__main__":
    main()
