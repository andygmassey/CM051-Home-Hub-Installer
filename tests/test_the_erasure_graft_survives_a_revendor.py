#!/usr/bin/env python3
"""The erasure graft must still be in the vendored tree, not only in a record.

WHY THIS EXISTS, and it closes a gap the register owner named rather than hid.

Board rows 960 and 2217 stopped declaring themselves cut blockers because CM051
#2220 is MERGED: the one-click erasure now removes the fact NODE and not merely
its link to the person. That fix reaches customers as a GRAFT into
vendor/cm041/assistant_api/, because the same fix cannot currently land upstream
and come back down: the tree is over a thousand lines ahead of CM041 main, and
regenerating its divergence patch REFUSES because upstream still carries a
personal-contact-shaped value the vendored copy has scrubbed, so recording the
divergence would publish it into a PUBLIC repo.

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


def body_of(src, name):
    """The source text of one function, or None. Lifted by AST so a rename or a
    deletion is a clean absence rather than a substring that happens to match."""
    try:
        tree = ast.parse(src)
    except SyntaxError as exc:
        cant("the shipped server does not parse (%s)" % exc)
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return "\n".join(src.split("\n")[node.lineno - 1:node.end_lineno])
    return None


print("-- controls: the reader must see a graft and must miss its absence --")

_present = 'def f():\n    x = ("<urn:ostler:Fact>", "<urn:ostler:about>")\n'
if body_of(_present, "f") and all(s in body_of(_present, "f") for s in SHAPES[1]):
    ok("CONTROL: a seeded shape inside a lifted function is found")
else:
    bad("CONTROL: a seeded shape was not found, so the reader is broken and every "
        "absence below would be an artefact of it")

_absent = 'def f():\n    x = 1\n'
if body_of(_absent, "f") is not None and SHAPES[1][0] not in body_of(_absent, "f"):
    ok("CONTROL: a function without the shape reads as missing it, so this gate can fail")
else:
    bad("CONTROL: a function without the shape did not read as missing it")

if body_of('def g():\n    pass\n', FUNC) is None:
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
    print("     EXAMINED: %d line(s) of %s, %d line(s) in %s"
          % (src.count("\n"), SERVER.name, body.count("\n"), FUNC))
    missing = [ftype for ftype, about in SHAPES
               if ftype not in body or about not in body]
    if missing:
        bad("the erasure no longer scopes by %d of %d fact vocabularies (%s). The "
            "graft has been partly removed, so facts written in the missing "
            "vocabulary survive a forget as orphaned text."
            % (len(missing), len(SHAPES), ", ".join(missing)))
    else:
        ok("the erasure still scopes by BOTH fact vocabularies, so a forget reaches "
           "facts from CM041 and from CM048")

    # The type clause is what stops the repair destroying a bystander.
    unscoped = "?s ?p <{uri}> . ?s ?p2 ?o2"
    if unscoped in body:
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
