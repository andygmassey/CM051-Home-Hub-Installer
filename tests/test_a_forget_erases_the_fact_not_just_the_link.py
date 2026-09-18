#!/usr/bin/env python3
"""A forget must erase the sentence, not merely the sentence's link to a person.

BOARD ROWS 960 AND 2217. The customer's one-click erasure reports success while
the text they asked to be erased is still in the graph and still returned by a
reader. Measured on the shipped box 2026-09-18: 48 PersonFacts carry a createdAt,
47 of them created within 100ms of a forget, against a control with the forget
times shifted by one hour matching 0 of 48.

THE MECHANISM. ``_forget_person_update`` emits two clause shapes:

    DELETE { <uri> ?p ?o }  WHERE { <uri> ?p ?o }     the person's own triples
    DELETE { ?s ?p <uri> }  WHERE { ?s ?p <uri> }     every link INTO the person

plus the same pair scoped into each named graph, which is a correct fix somebody
already made. The second shape removes the fact's LINK to the person. IT DOES NOT
REMOVE THE FACT NODE. factText, factSource, belongsToUser, privacyLevel,
factConfidence and createdAt all survive, and the reader lists facts by
belongsToUser, so the orphaned sentence is still returned.

🔴 WHY THE EXISTING GATES CANNOT SEE IT, WHICH IS THE WHOLE POINT OF THIS FILE.
tests/test_a_forget_must_reach_every_named_graph.py is correct and complete for
what it tests, and all five of its mutation arms mutate the GRAPH CLAUSE. It
takes the delete PATTERN as given and asks only whether that pattern reaches
every graph. The defect is IN the pattern. Instrument surface and defect surface
do not meet, so no amount of it passing could ever have caught this.

AND THE CONSUMER-SIDE PROOF WAS BLIND FOR THE SAME REASON. It counted triples
that MENTION the person. Once the second clause has run, NOTHING mentions the
person, so a person-keyed count reads 0 in the broken world and 0 in the fixed
one and cannot tell them apart. This file therefore keeps BOTH predicates and
asserts they disagree today: that disagreement IS the defect.

THREE STATES. 0 pass, 1 fail, 2 cannot-run.

IT IS A CUT GATE. The fix belongs UPSTREAM in CM041 (board row 2218: the vendored
copy is 1,151 lines ahead of CM041 main, so a re-vendor would destroy shipped
behaviour, and the hop is the register owner's to sequence). CM051 cannot patch
its way out, so what it owes is a REFUSAL: outside a cut this reports and exits
0, because the state is known and tracked; under OSTLER_CUT_IN_PROGRESS=1 it
FAILS and the cut stops. A cut must not carry an erasure that does not erase.
"""
import ast
import os
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SERVER = REPO / "vendor" / "cm041" / "assistant_api" / "ical-server.py"

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


try:
    from rdflib import Dataset, URIRef, Literal
except Exception as exc:  # noqa: BLE001
    cant("rdflib is absent (%s), so no store could be built and NOTHING was "
         "measured. This is not a pass." % exc)

# ---------------------------------------------------------------------------
# Lift the shipped function out of the server by AST, rather than importing the
# module: it is an 8,758-line web server whose import has side effects. The
# function has no module-global dependencies, which is checked here rather than
# assumed, so lifting it cannot silently lift something different.
# ---------------------------------------------------------------------------
if not SERVER.is_file():
    cant("%s is not a file" % SERVER)

src = SERVER.read_text(encoding="utf-8")
try:
    tree = ast.parse(src)
except SyntaxError as exc:
    cant("the shipped server does not parse (%s)" % exc)

node = None
for n in ast.walk(tree):
    if isinstance(n, ast.FunctionDef) and n.name == "_forget_person_update":
        node = n
        break
if node is None:
    cant("_forget_person_update is not defined in the shipped server. It may "
         "have been renamed, in which case this gate is measuring nothing.")

free = sorted({x.id for x in ast.walk(node) if isinstance(x, ast.Name)}
              - {a.arg for a in node.args.args})
ns = {}
exec(compile(ast.Module(body=[node], type_ignores=[]), str(SERVER), "exec"), ns)
forget_update = ns["_forget_person_update"]

PERSON = "http://example.invalid/person/synthetic-subject"
GRAPH = "urn:ostler:user/synthetic"
SENTENCE = "SYNTHETIC SENTENCE THE CUSTOMER ASKED TO HAVE ERASED"
OTHER_SENTENCE = "SYNTHETIC SENTENCE ABOUT SOMEBODY ELSE"
OTHER = "http://example.invalid/person/synthetic-bystander"
ABOUT = URIRef("http://example.invalid/ns#aboutPerson")
TEXT = URIRef("http://example.invalid/ns#factText")
OWNER = URIRef("http://example.invalid/ns#belongsToUser")
USER = URIRef("http://example.invalid/user/synthetic-owner")


def build_store():
    """A dataset shaped like the one on the box: a person, a fact ABOUT them
    carrying the text, and a bystander's fact that a forget must NOT touch."""
    ds = Dataset()
    g = ds.graph(URIRef(GRAPH))
    for subject, fact, text in ((PERSON, "fact-subject", SENTENCE),
                                (OTHER, "fact-bystander", OTHER_SENTENCE)):
        f = URIRef("http://example.invalid/fact/" + fact)
        g.add((f, ABOUT, URIRef(subject)))
        g.add((f, TEXT, Literal(text)))
        g.add((f, OWNER, USER))
        g.add((URIRef(subject), URIRef("http://example.invalid/ns#name"), Literal("Synthetic")))
    return ds


def mentions(ds, uri):
    """The PERSON-KEYED predicate: triples that mention the person."""
    u = URIRef(uri)
    return sum(1 for _s, _p, _o, _g in ds.quads((None, None, None, None))
               if u in (_s, _o))


def carries(ds, text):
    """The CONTENT-KEYED predicate: triples carrying the sentence itself."""
    return sum(1 for _s, _p, o, _g in ds.quads((None, None, None, None))
               if isinstance(o, Literal) and str(o) == text)


print("-- controls: neither predicate may be always-zero --")
if free == ["clauses", "esc_uri", "graph"]:
    ok("CONTROL: the lifted function's free names are its own locals only (%s)" % ", ".join(free))
else:
    bad("CONTROL: the lifted function references %s, so it depends on module "
        "state this gate did not provide and its output may not be the shipped "
        "one" % ", ".join(free))

before = build_store()
m_before, c_before = mentions(before, PERSON), carries(before, SENTENCE)
if m_before > 0:
    ok("CONTROL: before any forget, the person-keyed predicate reads %d, not zero" % m_before)
else:
    bad("CONTROL: the person-keyed predicate reads 0 on an unmodified store, so it is broken")
if c_before > 0:
    ok("CONTROL: before any forget, the content-keyed predicate reads %d, not zero" % c_before)
else:
    bad("CONTROL: the content-keyed predicate reads 0 on an unmodified store, so it is broken")

# A DELETION THE HARNESS MUST BE ABLE TO SEE. If rdflib silently ignored the
# update, every count below would read unchanged and this gate would report the
# defect whether or not it exists. Prove the engine applies an update at all.
probe = build_store()
probe.update("DELETE { GRAPH <%s> { ?s <%s> ?o } } WHERE { GRAPH <%s> { ?s <%s> ?o } }"
             % (GRAPH, OWNER, GRAPH, OWNER))
if sum(1 for _ in probe.quads((None, OWNER, None, None))) == 0:
    ok("CONTROL: the engine applies a graph-scoped DELETE, so a survival below is real")
else:
    bad("CONTROL: a graph-scoped DELETE did not remove its triples. The engine is "
        "not applying updates, so nothing below is measured.")

print("-- subject: the shipped erasure --")

store = build_store()
update = forget_update(PERSON, [GRAPH])
try:
    store.update(update)
except Exception as exc:  # noqa: BLE001
    cant("the shipped update would not execute (%s: %s). It may use a construct "
         "this engine does not accept, in which case this gate has NOT measured "
         "the erasure." % (type(exc).__name__, exc))

m_after, c_after = mentions(store, PERSON), carries(store, SENTENCE)
print("     EXAMINED: %d clause(s) of shipped SPARQL against a %d-quad store"
      % (update.count(";"), len(list(before.quads((None, None, None, None))))))
print("     person-keyed  before %d -> after %d" % (m_before, m_after))
print("     content-keyed before %d -> after %d" % (c_before, c_after))

if m_after == 0:
    ok("the person-keyed predicate reads 0 after the forget, which is why this "
       "defect was reported closed: it reads 0 in the broken world too")
else:
    bad("the person-keyed predicate still reads %d, so the erasure did not even "
        "remove the links. That is a different and larger defect than rows "
        "960 and 2217 describe." % m_after)

if c_after == 0:
    ok("the sentence the customer asked to erase is GONE from the store")
else:
    bad("THE SENTENCE SURVIVES THE ERASURE. %d triple(s) still carry the text "
        "after a forget the endpoint reports as successful. The fact's LINK was "
        "deleted and the fact's CONTENT was not, so the fact is orphaned rather "
        "than erased and a reader listing by belongsToUser still returns it. "
        "GDPR Article 17 is the docstring's own citation." % c_after)

# MUST-MISS. An erasure that takes the bystander's fact with it would make the
# assertion above pass for the worst possible reason.
if carries(store, OTHER_SENTENCE) == c_before:
    ok("MUST-MISS: the bystander's fact is untouched, so a pass above would not "
       "be bought by over-deletion")
else:
    bad("MUST-MISS: forgetting one person removed another person's fact. Whatever "
        "else is true, this erasure is not correctly scoped.")

# ---------------------------------------------------------------------------
# THE GATE MUST BE SATISFIABLE. A test that can only ever fail is worth as
# little as one that can only ever pass: it proves the defect exists and gives
# nobody a target. So the corrected pattern is run here too, and it must close
# the finding above WITHOUT taking the bystander's fact. That makes this file an
# acceptance test for the upstream CM041 fix rather than only an accusation.
#
# THE ORDER IS LOAD-BEARING and it is the part that is easy to get wrong: the
# fact must be collected while its link still exists. Run after the existing
# `?s ?p <uri>` clause, the link is already gone, nothing matches, and the
# repair silently does nothing while looking correct.
print("-- the corrected pattern, proving this gate can be satisfied --")


def corrected_update(person_uri, graph_uris):
    esc = person_uri.replace("\\", "\\\\").replace(">", "%3E")
    clauses = []
    for graph in graph_uris:
        clauses.append(
            "DELETE {{ GRAPH <" + graph + "> {{ ?s ?p2 ?o2 }} }} "
            "WHERE {{ GRAPH <" + graph + "> {{ ?s ?p <{uri}> . ?s ?p2 ?o2 }} }};")
    clauses.append("DELETE {{ <{uri}> ?p ?o }} WHERE {{ <{uri}> ?p ?o }};")
    clauses.append("DELETE {{ ?s ?p <{uri}> }} WHERE {{ ?s ?p <{uri}> }};")
    for graph in graph_uris:
        clauses.append(
            "DELETE {{ GRAPH <" + graph + "> {{ <{uri}> ?p ?o }} }} "
            "WHERE {{ GRAPH <" + graph + "> {{ <{uri}> ?p ?o }} }};")
        clauses.append(
            "DELETE {{ GRAPH <" + graph + "> {{ ?s ?p <{uri}> }} }} "
            "WHERE {{ GRAPH <" + graph + "> {{ ?s ?p <{uri}> }} }};")
    return "\n".join(clauses).format(uri=esc)


fixed = build_store()
fixed.update(corrected_update(PERSON, [GRAPH]))
f_content, f_other = carries(fixed, SENTENCE), carries(fixed, OTHER_SENTENCE)
if f_content == 0 and f_other == c_before:
    ok("the corrected pattern erases the sentence (content %d -> 0) and leaves "
       "the bystander's fact intact, so this gate is satisfiable and the arm "
       "above is a target rather than a verdict" % c_before)
elif f_content != 0:
    bad("the corrected pattern ALSO leaves %d triple(s) carrying the text, so "
        "the repair proposed here does not work and must not be handed upstream "
        "as though it does" % f_content)
else:
    bad("the corrected pattern erased the bystander's fact too (%d -> %d). It "
        "over-deletes, and an erasure that takes other people's data with it is "
        "a worse defect than the one it fixes." % (c_before, f_other))

# AND THE ORDERING CLAIM IS CHECKED, not asserted. Put the collecting clause
# last and the repair must stop working, or the comment above is folklore.
def wrong_order(person_uri, graph_uris):
    esc = person_uri.replace("\\", "\\\\").replace(">", "%3E")
    clauses = ["DELETE {{ ?s ?p <{uri}> }} WHERE {{ ?s ?p <{uri}> }};"]
    for graph in graph_uris:
        clauses.append(
            "DELETE {{ GRAPH <" + graph + "> {{ ?s ?p <{uri}> }} }} "
            "WHERE {{ GRAPH <" + graph + "> {{ ?s ?p <{uri}> }} }};")
        clauses.append(
            "DELETE {{ GRAPH <" + graph + "> {{ ?s ?p2 ?o2 }} }} "
            "WHERE {{ GRAPH <" + graph + "> {{ ?s ?p <{uri}> . ?s ?p2 ?o2 }} }};")
    return "\n".join(clauses).format(uri=esc)


mis = build_store()
mis.update(wrong_order(PERSON, [GRAPH]))
if carries(mis, SENTENCE) == c_before:
    ok("CONTROL: with the collecting clause moved after the link delete, the "
       "repair does nothing. The ordering is load-bearing, as claimed.")
else:
    bad("CONTROL: the repair still worked with the clauses reordered, so the "
        "ordering claim in this file is wrong and the comment misleads the next "
        "reader.")

print()
print("== %d pass / %d fail / %d total ==" % (len(PASS), len(FAIL), len(PASS) + len(FAIL)))

IN_CUT = os.environ.get("OSTLER_CUT_IN_PROGRESS", "") not in ("", "0")
if not FAIL:
    sys.exit(0)
if IN_CUT:
    print()
    print("CUT BLOCKED: the one-click erasure does not erase. The fix belongs")
    print("UPSTREAM in CM041 and the vendor hop is the register owner's to")
    print("sequence (board row 2218); it must NOT be grafted into vendor/ here.")
    sys.exit(1)
print()
print("NOT A CUT: reporting %d finding(s) and exiting 0. This is the KNOWN state" % len(FAIL))
print("of the shipped erasure, tracked as board rows 960 and 2217. Run with")
print("OSTLER_CUT_IN_PROGRESS=1 and this refuses instead.")
sys.exit(0)
