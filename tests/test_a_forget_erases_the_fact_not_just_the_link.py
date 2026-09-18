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


# ---------------------------------------------------------------------------
# EVERY AVAILABLE ENGINE, AND THEY MUST AGREE. The product talks SPARQL to
# Oxigraph, not to rdflib, and those two have already disagreed once in this
# estate: rdflib returned 0 rows where pyoxigraph returned 1 on a FILTER inside
# GRAPH, a construct now used by six readers. A verdict about a customer's
# erasure taken from whichever library happened to be installed is a verdict
# about the library. So the measurement runs under each engine present and a
# DISAGREEMENT IS ITSELF A FINDING.
# ---------------------------------------------------------------------------
ENGINES = {}

try:
    import pyoxigraph as _ox
    ENGINES["pyoxigraph"] = "ox"
except Exception:  # noqa: BLE001
    pass
try:
    from rdflib import Dataset as _Dataset, URIRef as _U, Literal as _L
    ENGINES["rdflib"] = "rdf"
except Exception:  # noqa: BLE001
    pass

if not ENGINES:
    cant("neither pyoxigraph nor rdflib is importable, so no store could be "
         "built and NOTHING was measured. This is not a pass.")

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

RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
# THE TWO FACT VOCABULARIES, AND THE SECOND ONE IS THE POPULATION THAT MATTERS.
# ical-server.py:2741 measures it on the real box: `?s a pwg:PersonFact` is 0 in
# EVERY graph, `?s a <urn:ostler:Fact>` is 990 in the per-user named graph.
# CM048 -- the pipeline that produces essentially all of a customer's remembered
# facts -- writes urn:ostler:about / urn:ostler:text / urn:ostler:Fact, NOT the
# pwg names. A repair scoped to pwg:aboutPerson alone would leave every real
# fact orphaned while passing a test written in the pwg vocabulary.
FACT_TYPES = ("urn:ostler:Fact", "https://schema.ostler.ai/ontology#PersonFact")
PERSON = "http://example.invalid/person/synthetic-subject"
GRAPH = "urn:ostler:user/synthetic"
SENTENCE = "SYNTHETIC SENTENCE THE CUSTOMER ASKED TO HAVE ERASED"
OTHER_SENTENCE = "SYNTHETIC SENTENCE ABOUT SOMEBODY ELSE"
PWG_SENTENCE = "SYNTHETIC SENTENCE IN THE PWG VOCABULARY"
OTHER = "http://example.invalid/person/synthetic-bystander"
ABOUT_P = "http://example.invalid/ns#aboutPerson"
TEXT_P = "http://example.invalid/ns#factText"
OWNER_P = "http://example.invalid/ns#belongsToUser"
USER_U = "http://example.invalid/user/synthetic-owner"


def build_store(engine):
    """A dataset shaped like the one on the box.

    FOUR SHAPES, and the third is the one my first fixture lacked:

      1. a CM048-shaped fact ABOUT the subject   (the real population)
      2. a pwg-shaped fact ABOUT the subject     (the vocabulary the code writes)
      3. a BYSTANDER PERSON WHO REFERENCES THE SUBJECT -- the shape that
         exposes an over-deleting repair. A bystander whose fact is merely
         about themselves never matches the clause under test, so it can
         never catch the defect, which is why my first control did not.
      4. a fact about the bystander              (must survive untouched)
    """
    rows = []

    def person(uri, name):
        rows.append((uri, RDF_TYPE, "https://schema.ostler.ai/ontology#Person", False))
        rows.append((uri, "https://schema.ostler.ai/ontology#displayName", name, True))

    def fact(uri, ftype, link, about, textpred, text):
        rows.append((uri, RDF_TYPE, ftype, False))
        rows.append((uri, link, about, False))
        rows.append((uri, textpred, text, True))
        rows.append((uri, str(OWNER_P), str(USER_U), False))

    person(PERSON, "Subject")
    person(OTHER, "Bystander")
    fact("urn:ostler:fact/cm048-subject", "urn:ostler:Fact",
         "urn:ostler:about", PERSON, "urn:ostler:text", SENTENCE)
    fact("https://schema.ostler.ai/ontology#fact_pwg_subject",
         "https://schema.ostler.ai/ontology#PersonFact",
         str(ABOUT_P), PERSON, str(TEXT_P), PWG_SENTENCE)
    fact("urn:ostler:fact/cm048-bystander", "urn:ostler:Fact",
         "urn:ostler:about", OTHER, "urn:ostler:text", OTHER_SENTENCE)
    # 3. THE BYSTANDER REFERENCES THE SUBJECT.
    rows.append((OTHER, "https://schema.ostler.ai/ontology#knows", PERSON, False))

    if ENGINES[engine] == "ox":
        st = _ox.Store()
        for sub, pred, obj, is_lit in rows:
            o = _ox.Literal(obj) if is_lit else _ox.NamedNode(obj)
            st.add(_ox.Quad(_ox.NamedNode(sub), _ox.NamedNode(pred), o,
                            _ox.NamedNode(GRAPH)))
        return st
    ds = _Dataset()
    g = ds.graph(_U(GRAPH))
    for sub, pred, obj, is_lit in rows:
        g.add((_U(sub), _U(pred), _L(obj) if is_lit else _U(obj)))
    return ds


def subject_triples(engine, store, uri):
    """How many triples this node still has as a SUBJECT. A bystander losing
    all of them is the over-deletion this file exists to refuse."""
    return sum(1 for sub, _o, _l in _quads(engine, store) if sub == uri)


def _quads(engine, store):
    """(subject, object, object-is-literal, literal-value) for every quad."""
    if ENGINES[engine] == "ox":
        for q in store:
            lit = isinstance(q.object, _ox.Literal)
            # .value on BOTH sides. str() on a pyoxigraph NamedNode returns the
            # N-Triples form <http://...> with the angle brackets, so comparing a
            # str()-ed object against a bare URI silently never matches and the
            # person-keyed count reads one low. The cross-engine arm caught this.
            yield q.subject.value, q.object.value, lit
    else:
        for sub, _pred, obj, _g in store.quads((None, None, None, None)):
            lit = isinstance(obj, _L)
            yield str(sub), str(obj), lit


def apply_update(engine, store, sparql):
    store.update(sparql)


def mentions(engine, store, uri):
    """The PERSON-KEYED predicate: triples that mention the person."""
    n = 0
    for sub, obj, lit in _quads(engine, store):
        if sub == uri or (not lit and obj == uri):
            n += 1
    return n


def carries(engine, store, text):
    """The CONTENT-KEYED predicate: triples carrying the sentence itself."""
    return sum(1 for _s, obj, lit in _quads(engine, store) if lit and obj == text)


def corrected_update(person_uri, graph_uris):
    """The repair, proposed for CM041.

    🔴 SCOPED BY FACT TYPE, AND THE BROAD FORM I FIRST PROPOSED DESTROYS PEOPLE.
    The obvious clause is `?s ?p <uri> . ?s ?p2 ?o2` -- delete every triple of
    anything that references the person. Measured: that erases the sentence AND
    ERASES AN INNOCENT BYSTANDER ENTIRELY, because a second Person node that
    merely `knows` the forgotten one matches `?s ?p <uri>` and then loses every
    triple it has, name and email included. An erasure that takes other people's
    data with it is a worse defect than the one it fixes, and it would have been
    landed as the fix for a GDPR row.

    My first MUST-MISS control did not catch it because it had the wrong shape:
    the bystander's fact was ABOUT the bystander rather than REFERENCING the
    subject, so it never matched the clause under test. A control has to carry
    the shape the defect needs.

    So the wholesale delete is scoped to nodes explicitly TYPED as a fact, in
    BOTH vocabularies. A Person node is never a fact type, so a bystander keeps
    everything except their own link to the forgotten person, which the existing
    `?s ?p <uri>` clause correctly removes.

    The ordering still matters: the fact is collected while its link exists.
    """
    esc = person_uri.replace("\\", "\\\\").replace(">", "%3E")
    clauses = []
    for graph in graph_uris:
        for ftype in FACT_TYPES:
            clauses.append(
                "DELETE {{ GRAPH <" + graph + "> {{ ?f ?p2 ?o2 }} }} "
                "WHERE {{ GRAPH <" + graph + "> {{ ?f <" + RDF_TYPE + "> <" + ftype + "> . "
                "?f ?link <{uri}> . ?f ?p2 ?o2 }} }};")
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


def wrong_order(person_uri, graph_uris):
    """The same repair with the collecting clause moved AFTER the link delete."""
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


def measure(engine):
    """Every number this file reports, taken under ONE engine. Returns a dict,
    or raises so the caller can report the engine that could not run."""
    before = build_store(engine)
    r = {"m_before": mentions(engine, before, PERSON),
         "c_before": carries(engine, before, SENTENCE),
         "quads": sum(1 for _ in _quads(engine, before))}

    probe = build_store(engine)
    apply_update(engine, probe,
                 "DELETE { GRAPH <%s> { ?s <%s> ?o } } WHERE { GRAPH <%s> { ?s <%s> ?o } }"
                 % (GRAPH, OWNER_P, GRAPH, OWNER_P))
    r["engine_applies_delete"] = sum(
        1 for sub, obj, lit in _quads(engine, probe) if not lit and obj == USER_U) == 0

    shipped = build_store(engine)
    apply_update(engine, shipped, forget_update(PERSON, [GRAPH]))
    r["m_after"] = mentions(engine, shipped, PERSON)
    r["c_after"] = carries(engine, shipped, SENTENCE)
    r["bystander_after"] = carries(engine, shipped, OTHER_SENTENCE)

    r["bystander_triples_before"] = subject_triples(engine, before, OTHER)
    r["shipped_bystander_triples"] = subject_triples(engine, shipped, OTHER)

    fixed = build_store(engine)
    apply_update(engine, fixed, corrected_update(PERSON, [GRAPH]))
    r["fixed_content"] = carries(engine, fixed, SENTENCE)
    r["fixed_pwg_content"] = carries(engine, fixed, PWG_SENTENCE)
    r["fixed_bystander"] = carries(engine, fixed, OTHER_SENTENCE)
    r["fixed_bystander_triples"] = subject_triples(engine, fixed, OTHER)

    # THE BROAD REPAIR I FIRST PROPOSED, kept as a NEGATIVE CONTROL so the arm
    # below is proved to discriminate rather than merely to pass.
    broad = build_store(engine)
    clause = ("DELETE { GRAPH <%s> { ?s ?p2 ?o2 } } WHERE { GRAPH <%s> { ?s ?p <%s> . ?s ?p2 ?o2 } };"
              % (GRAPH, GRAPH, PERSON))
    apply_update(engine, broad, clause)
    r["broad_bystander_triples"] = subject_triples(engine, broad, OTHER)

    mis = build_store(engine)
    apply_update(engine, mis, wrong_order(PERSON, [GRAPH]))
    r["wrong_order_content"] = carries(engine, mis, SENTENCE)
    return r


print("-- controls: the lift, the predicates, and the engines --")

if free == ["clauses", "esc_uri", "graph"]:
    ok("CONTROL: the lifted function's free names are its own locals only (%s)"
       % ", ".join(free))
else:
    bad("CONTROL: the lifted function references %s, so it depends on module "
        "state this gate did not provide and its output may not be the shipped "
        "one" % ", ".join(free))

results, broken = {}, {}
for name in sorted(ENGINES):
    try:
        results[name] = measure(name)
    except Exception as exc:  # noqa: BLE001
        broken[name] = "%s: %s" % (type(exc).__name__, exc)

for name, why in broken.items():
    bad("the %s engine could not run the shipped update (%s). That is a result "
        "about the engine, and it means this gate did not measure under it."
        % (name, why))
if not results:
    cant("no engine completed the measurement, so NOTHING was measured.")

print("     EXAMINED: engines %s; shipped update has %d clause(s) against an %d-quad store"
      % (", ".join(sorted(results)), forget_update(PERSON, [GRAPH]).count(";"),
         list(results.values())[0]["quads"]))

# THE ENGINES MUST AGREE. If they do not, every verdict below is a verdict about
# a library rather than about the customer's erasure, and that is the finding.
if len(results) > 1:
    keys = sorted(next(iter(results.values())))
    diffs = [k for k in keys if len({results[e][k] for e in results}) > 1]
    if diffs:
        bad("the engines DISAGREE on %s: %s. A verdict taken from one of them is "
            "a verdict about the library, not about the erasure."
            % (", ".join(diffs),
               "; ".join("%s=%s" % (e, {k: results[e][k] for k in diffs}) for e in sorted(results))))
    else:
        ok("CONTROL: %s agree on every figure, so the verdict is about the "
           "erasure rather than about a library" % " and ".join(sorted(results)))
else:
    print("     [note] only one engine present (%s), so cross-engine agreement was "
          "NOT checked. The product speaks to Oxigraph." % list(results)[0])

r = results[sorted(results)[0]]

if r["m_before"] > 0:
    ok("CONTROL: before any forget, the person-keyed predicate reads %d, not zero" % r["m_before"])
else:
    bad("CONTROL: the person-keyed predicate reads 0 on an unmodified store, so it is broken")
if r["c_before"] > 0:
    ok("CONTROL: before any forget, the content-keyed predicate reads %d, not zero" % r["c_before"])
else:
    bad("CONTROL: the content-keyed predicate reads 0 on an unmodified store, so it is broken")
if r["engine_applies_delete"]:
    ok("CONTROL: the engine applies a graph-scoped DELETE, so a survival below is real")
else:
    bad("CONTROL: a graph-scoped DELETE did not remove its triples, so nothing below is measured")

print("-- subject: the shipped erasure --")
print("     person-keyed  before %d -> after %d" % (r["m_before"], r["m_after"]))
print("     content-keyed before %d -> after %d" % (r["c_before"], r["c_after"]))

if r["m_after"] == 0:
    ok("the person-keyed predicate reads 0 after the forget, which is why this "
       "defect was reported closed: it reads 0 in the broken world too")
else:
    bad("the person-keyed predicate still reads %d, so the erasure did not even "
        "remove the links. That is a different and larger defect than rows 960 "
        "and 2217 describe." % r["m_after"])

if r["c_after"] == 0:
    ok("the sentence the customer asked to erase is GONE from the store")
else:
    bad("THE SENTENCE SURVIVES THE ERASURE. %d triple(s) still carry the text "
        "after a forget the endpoint reports as successful. The fact's LINK was "
        "deleted and the fact's CONTENT was not, so the fact is orphaned rather "
        "than erased and a reader listing by belongsToUser still returns it. "
        "GDPR Article 17 is the docstring's own citation." % r["c_after"])

if r["bystander_after"] == r["c_before"]:
    ok("MUST-MISS: the bystander's fact is untouched, so a pass above would not "
       "be bought by over-deletion")
else:
    bad("MUST-MISS: forgetting one person removed another person's fact. Whatever "
        "else is true, this erasure is not correctly scoped.")

print("-- the corrected pattern, proving this gate can be satisfied --")
if r["fixed_content"] == 0 and r["fixed_bystander"] == r["c_before"]:
    ok("the corrected pattern erases the sentence (content %d -> 0) and leaves "
       "the bystander's fact intact, so this gate is satisfiable and the arm "
       "above is a target rather than a verdict" % r["c_before"])
elif r["fixed_content"] != 0:
    bad("the corrected pattern ALSO leaves %d triple(s) carrying the text, so the "
        "repair proposed here does not work and must not be handed upstream as "
        "though it does" % r["fixed_content"])
else:
    bad("the corrected pattern erased the bystander's fact too (%d -> %d). An "
        "erasure that takes other people's data with it is a worse defect than "
        "the one it fixes." % (r["c_before"], r["fixed_bystander"]))

# 🔴 THE ARM THAT WOULD HAVE CAUGHT MY OWN REPAIR. A bystander who REFERENCES
# the forgotten person must keep everything except that reference.
if r["broad_bystander_triples"] == 0 and r["fixed_bystander_triples"] > 0:
    ok("MUST-MISS, DISCRIMINATING: the broad clause `?s ?p <uri>` destroys the "
       "bystander entirely (%d triples to 0) and the type-scoped repair leaves "
       "them %d of %d, losing only their own link to the forgotten person. So "
       "this arm can tell a correct erasure from one that takes other people's "
       "data with it."
       % (r["bystander_triples_before"], r["fixed_bystander_triples"],
          r["bystander_triples_before"]))
elif r["broad_bystander_triples"] != 0:
    bad("the broad clause did NOT destroy the bystander in this fixture, so this "
        "arm cannot discriminate and its pass proves nothing. The fixture has "
        "lost the shape the defect needs: a bystander who REFERENCES the subject.")
else:
    bad("THE PROPOSED REPAIR DESTROYS AN INNOCENT BYSTANDER: %d subject triples "
        "to %d. An erasure that takes other people's data with it is a worse "
        "defect than the one it fixes, and it must not be handed upstream."
        % (r["bystander_triples_before"], r["fixed_bystander_triples"]))

# BOTH VOCABULARIES, because the one the code writes is not the one the data uses.
if r["fixed_pwg_content"] == 0:
    ok("the repair erases the pwg-shaped fact as well as the CM048-shaped one, "
       "so it does not close only the vocabulary the writer happens to emit")
else:
    bad("the repair left %d pwg-shaped fact triple(s). ical-server.py:2741 "
        "measures pwg:PersonFact at 0 and urn:ostler:Fact at 990 on the real "
        "box, so covering one vocabulary is covering the smaller half."
        % r["fixed_pwg_content"])

if r["wrong_order_content"] == r["c_before"]:
    ok("CONTROL: with the collecting clause moved after the link delete, the "
       "repair does nothing. The ordering is load-bearing, as claimed.")
else:
    bad("CONTROL: the repair still worked with the clauses reordered, so the "
        "ordering claim in this file is wrong and misleads the next reader.")

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
