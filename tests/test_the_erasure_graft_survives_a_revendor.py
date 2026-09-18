#!/usr/bin/env python3
"""The erasure graft must still be in the vendored tree, not only in a record.

WHY THIS EXISTS, and it closes a gap the register owner named rather than hid.

Board rows 960 and 2217 stopped declaring themselves cut blockers because CM051
#2220 is MERGED: the one-click erasure now removes the fact NODE and not merely
its link to the person. That fix reaches customers as a GRAFT into
vendor/cm041/assistant_api/, because the same fix cannot currently land upstream
and come back down: the tree is over a thousand lines ahead of CM041 main, and
regenerating its divergence patch REFUSES.

🔴 WHY IT REFUSES, CORRECTED. An earlier version of this docstring said upstream
carried a personal-contact-shaped value the vendored copy had scrubbed, so
recording the divergence would publish it into a public repo. THAT WAS WRONG AND
THERE WAS NEVER ANY SUCH VALUE. Upstream carries an ALL-ZEROS placeholder that
CM041's own fixture gate tolerates BY NAME as an obvious placeholder. The
vendored copy had changed it, so it landed on the MINUS side of the diff and the
regeneration tool refused. The tool was not detecting a leak; it was declining to
certify a shape its allowlist cannot certify, because that allowlist admits only
standards-reserved values and a convention is not a standard. The refusal is
real and its cause was misread. Board row 2207 records the same correction, and
CM041 #173 removes the shape, so the refusal retires on a RE-PIN.

So the only thing standing between that graft and a `sync_vendor.sh` that
deletes it was a PROSE RECORD. A record is not an instrument: nothing reads it,
it cannot be applied, and its whole job is to make a deletion noticeable by a
person who happens to look. That is thin protection for a GDPR Article 17
surface, and thin in the direction that looks finished.

THIS IS THE INSTRUMENT. If a re-vendor removes the graft, this goes RED.

WHAT IT ASSERTS, and the both-vocabularies part is the half that matters:
CM048 writes urn:ostler:Fact / urn:ostler:about and produces essentially all of
a customer's remembered facts; CM041 writes pwg:PersonFact / pwg:aboutPerson.
Measured on the box, the pwg arm is a few dozen facts and the CM048 arm is over
a thousand. A repair that covered only the vocabulary the writer emits would
leave nearly every real fact orphaned while passing a test written in the other
one, so BOTH shapes are required here.

It asserts the SHAPES ARE SCOPED BY TYPE, not merely present. An unscoped
`?s ?p <uri>` collecting clause erases every triple of anything that references
the person, which destroys a bystander who merely knows them. That was measured,
and it was nearly shipped as the fix.

THREE STATES. 0 pass, 1 fail, 2 cannot-run.
"""
import ast
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SERVER = REPO / "vendor" / "cm041" / "assistant_api" / "ical-server.py"
FUNC = "_forget_person_update"

#: (fact type IRI, fact-to-person predicate IRI). Both are required.
SHAPES = (
    ("<https://schema.ostler.ai/ontology#PersonFact>",
     "<https://schema.ostler.ai/ontology#aboutPerson>"),
    ("<urn:ostler:Fact>", "<urn:ostler:about>"),
)

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


def _func(src, name):
    """The AST node for one function, or None."""
    try:
        tree = ast.parse(src)
    except SyntaxError as exc:
        cant("the shipped server does not parse (%s)" % exc)
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    return None


def body_of(src, name):
    """The source TEXT of one function, or None. Used only for the line count."""
    node = _func(src, name)
    if node is None:
        return None
    return "\n".join(src.split("\n")[node.lineno - 1:node.end_lineno])


# ── 🔴 THE PREDICATE READS CODE, NEVER PROSE, AND THAT IS THIS GATE'S OWN BUG FIX
#
# The first version of this gate tested `ftype not in body`, where `body` was the
# function's SOURCE TEXT. The vocabulary appears in that function TWICE: once in
# the executable tuple and once in the comment above it. So deleting the graft
# from the CODE left the comment behind, the substring was still found, and THE
# GATE STAYED GREEN. The comment satisfied the gate that guards the code.
#
# It was caught by a mutation that was nearly written off as not-applied. Both
# look identical from the outside, which is why the counts below are printed:
# dropping the CM048 pair took `<urn:ostler:Fact>` from 2 occurrences to 1 in the
# raw text, and the survivor was the comment. Scrubbing the comment too took it
# to 0 and the gate went red. So the gate could fire; it fired on PROSE.
#
# A re-vendor replaces code wholesale and would carry exactly that shape.
#
# So the predicate now reads STRING CONSTANTS lifted from the AST, with the
# function's own docstring excluded, because a docstring is an ast.Constant too
# and would reopen the same hole one level down. A comment is not an AST node at
# all, so it cannot be read by construction rather than by a rule.
def code_strings(src, name):
    """Every string CONSTANT in a function, excluding its docstring.

    Returns None when the function is absent, so absence stays distinguishable
    from a function that is present and holds nothing.
    """
    node = _func(src, name)
    if node is None:
        return None
    skip = set()
    if (node.body and isinstance(node.body[0], ast.Expr)
            and isinstance(node.body[0].value, ast.Constant)
            and isinstance(node.body[0].value.value, str)):
        skip.add(id(node.body[0].value))
    return [c.value for c in ast.walk(node)
            if isinstance(c, ast.Constant) and isinstance(c.value, str)
            and id(c) not in skip]


def in_code(strings, needle):
    return any(needle in s for s in strings)


print("-- controls: the reader must see a graft in CODE and must miss it in PROSE --")

_present = 'def f():\n    x = ("<urn:ostler:Fact>", "<urn:ostler:about>")\n'
_c = code_strings(_present, "f")
if _c is not None and all(in_code(_c, s) for s in SHAPES[1]):
    ok("MUST-HIT CONTROL: a shape in executable code is found (%d code string(s))" % len(_c))
else:
    bad("MUST-HIT CONTROL: a seeded shape was not found, so the reader is broken and "
        "every absence below would be an artefact of it")

_absent = 'def f():\n    x = 1\n'
_c = code_strings(_absent, "f")
if _c is not None and not in_code(_c, SHAPES[1][0]):
    ok("CONTROL: a function without the shape reads as missing it, so this gate can fail")
else:
    bad("CONTROL: a function without the shape did not read as missing it")

# 🔴 THE ARM THAT WOULD HAVE CAUGHT THIS GATE'S OWN BUG. The mutation that found
# it deleted the vocabulary from the code and left the comment, which is the
# exact shape a re-vendor produces. The old predicate read that comment and
# passed. Both arms below are MUST-MISS: the vocabulary is PRESENT in the text
# and must read as ABSENT, because neither a comment nor a docstring erases
# anything.
_comment_only = ('def f():\n'
                 '    # the erasure also covers <urn:ostler:Fact> / <urn:ostler:about>\n'
                 '    x = 1\n')
_c = code_strings(_comment_only, "f")
if _c is not None and not any(in_code(_c, s) for s in SHAPES[1]):
    ok("MUST-MISS CONTROL: a vocabulary present ONLY IN A COMMENT reads as ABSENT, "
       "which is the hole that made this gate green against a real mutation")
else:
    bad("MUST-MISS CONTROL: a vocabulary present only in a comment read as PRESENT. "
        "The gate is guarding prose again and cannot see a re-vendor that drops the "
        "code while keeping the commentary around it.")

_docstring_only = ('def f():\n'
                   '    """covers <urn:ostler:Fact> and <urn:ostler:about>."""\n'
                   '    x = 1\n')
_c = code_strings(_docstring_only, "f")
if _c is not None and not any(in_code(_c, s) for s in SHAPES[1]):
    ok("MUST-MISS CONTROL: a vocabulary present ONLY IN A DOCSTRING reads as ABSENT, "
       "so excluding comments did not merely move the hole one level down")
else:
    bad("MUST-MISS CONTROL: a vocabulary present only in a docstring read as PRESENT")

if code_strings('def g():\n    pass\n', FUNC) is None:
    ok("CONTROL: a tree where the function is absent returns absence, not a false match")
else:
    bad("CONTROL: a missing function did not read as missing")

print("-- subject: the vendored erasure --")

if not SERVER.is_file():
    cant("%s is not a file. The vendored tree is gone, which is a larger problem "
         "than this gate measures." % SERVER)

src = SERVER.read_text(encoding="utf-8")
body = body_of(src, FUNC)

if body is None:
    bad("%s is GONE from the vendored server. A re-vendor has removed the erasure "
        "entirely, and rows 960 and 2217 stopped blocking the cut on the strength "
        "of it being there." % FUNC)
else:
    strings = code_strings(src, FUNC)
    print("     EXAMINED: %d line(s) of %s, %d line(s) in %s, %d code string(s) "
          "(comments and the docstring are NOT read)"
          % (src.count("\n"), SERVER.name, body.count("\n"), FUNC, len(strings)))
    missing = [ftype for ftype, about in SHAPES
               if not in_code(strings, ftype) or not in_code(strings, about)]
    if missing:
        bad("the erasure no longer scopes by %d of %d fact vocabularies (%s). The "
            "graft has been partly removed, so facts written in the missing "
            "vocabulary survive a forget as orphaned text."
            % (len(missing), len(SHAPES), ", ".join(missing)))
    else:
        ok("the erasure still scopes by BOTH fact vocabularies, so a forget reaches "
           "facts from CM041 and from CM048")

    # The type clause is what stops the repair destroying a bystander.
    # Read from code strings for the same reason: a comment WARNING against the
    # unscoped clause must not turn this arm red, or the gate teaches people to
    # delete the warning.
    unscoped = "?s ?p <{uri}> . ?s ?p2 ?o2"
    if in_code(strings, unscoped):
        bad("the erasure contains the UNSCOPED collecting clause %r, which deletes "
            "every triple of anything referencing the person and destroys a "
            "bystander who merely knows them. That shape was measured and must not "
            "return." % unscoped)
    else:
        ok("the unscoped collecting clause is absent, so a bystander who references "
           "the forgotten person keeps everything but that reference")

print()
print("== %d pass / %d fail / %d total ==" % (len(PASS), len(FAIL), len(PASS) + len(FAIL)))
sys.exit(1 if FAIL else 0)
