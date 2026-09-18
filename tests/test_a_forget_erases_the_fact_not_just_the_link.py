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

IT IS A CUT GATE, and as of 2026-09-18 the repair is GRAFTED rather than
awaited. The vendored copy is 1,151 lines ahead of CM041 main (board row 2218),
so a re-vendor would destroy shipped behaviour and no upstream fix can reach a
customer without a graft. vendor/VENDOR_MANIFEST.toml records
shipping_bugfixes_grafted for this tree with CM051 #1724 and #1726 as
precedent. The same fix is still owed upstream so the two converge. Outside a
cut this reports and exits 0; under OSTLER_CUT_IN_PROGRESS=1 it FAILS and the
cut stops.

AND THE OBVIOUS REPAIR IS WORSE THAN THE DEFECT, which is why the scoping below
is the whole design. Deleting every triple of any subject that links to the
person erases a meeting both people attended, with its other attendees, and a
bystander's entire record if it carries `spouseOf -> target`. Measured, not
reasoned. On a people graph a shared node is the normal case and not a corner:
RelationshipSignal 380, fromConversation 1353 on the box. The repair is
therefore keyed on the fact TYPE plus the fact-to-person PREDICATE, and the
broad form is kept below as a NEGATIVE CONTROL that must destroy what the
scoped one keeps. A MUST-MISS arm with nothing in the fixture that can fail it
is green by construction, and these were, for several hours.
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

# WHAT THIS CONTROL IS FOR: the function is lifted and executed ALONE, so if it
# reads any module-level name its output here is not the shipped output. It used
# to assert an exact list of locals, which quietly made it a version pin: any
# edit to the erasure failed it for the wrong reason. Compare against the names
# the function ITSELF binds instead -- arguments, assignments and loop targets.
_bound = set(a.arg for a in node.args.args)
for _n in ast.walk(node):
    if isinstance(_n, ast.Name) and isinstance(_n.ctx, ast.Store):
        _bound.add(_n.id)
    elif isinstance(_n, (ast.For, ast.comprehension)):
        for _t in ast.walk(_n.target):
            if isinstance(_t, ast.Name):
                _bound.add(_t.id)
free = sorted({x.id for x in ast.walk(node) if isinstance(x, ast.Name)} - _bound)
ns = {}
exec(compile(ast.Module(body=[node], type_ignores=[]), str(SERVER), "exec"), ns)
forget_update = ns["_forget_person_update"]

PERSON = "http://example.invalid/person/synthetic-subject"
GRAPH = "urn:ostler:user/synthetic"
OTHER = "http://example.invalid/person/synthetic-bystander"
USER_U = "http://example.invalid/user/synthetic-owner"

# THE REAL VOCABULARY, NOT A SYNTHETIC ONE. This fixture used to build facts
# from example.invalid predicates with NO rdf:type triple at all. That fixture
# can only ever validate a repair keyed on the SHAPE of a link, because there
# is no type to key on and no real predicate name to match. A correctly scoped
# erasure matches NOTHING in it and reads as a failure. The subjects are still
# synthetic; the PREDICATES and TYPES are the shipped ones, because they are
# what a repair has to hit.
RDF_T = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
PWG = "https://schema.ostler.ai/ontology#"
PWG_FACT, PWG_ABOUT = PWG + "PersonFact", PWG + "aboutPerson"
TEXT_P, OWNER_P = PWG + "factText", PWG + "belongsToUser"
MENTIONS_P, ATTENDED_P = PWG + "mentionsPerson", PWG + "attendedBy"
SPOUSE_P, NAME_P, TITLE_P = PWG + "spouseOf", PWG + "displayName", PWG + "title"
# CM048 writes its OWN vocabulary (ical-server.py:2751). On the box the pwg arm
# is 48 facts and this one is 1,274, so a repair covering only pwg leaves 96 per
# cent of the customer's facts in place.
OST_FACT, OST_ABOUT, OST_TEXT = "urn:ostler:Fact", "urn:ostler:about", "urn:ostler:text"

SENTENCE = "SYNTHETIC SENTENCE THE CUSTOMER ASKED TO HAVE ERASED"
CM048_SENTENCE = "SYNTHETIC CM048 SENTENCE ABOUT THE SAME PERSON"
OTHER_SENTENCE = "SYNTHETIC SENTENCE ABOUT SOMEBODY ELSE"
# A fact whose SUBJECT is the bystander and which merely MENTIONS the target.
# It separates a repair keyed on the fact-to-person predicate from one keyed on
# the type plus ANY predicate: the second destroys this and the first does not.
MENTION_SENTENCE = "SYNTHETIC FACT ABOUT THE BYSTANDER MENTIONING THE TARGET"
# Nodes SHARED between the two people. A people graph is full of them
# (RelationshipSignal 380, fromConversation 1353 on the box) and a fixture
# without one cannot see an erasure that takes the bystander with it.
MEETING_TITLE = "SYNTHETIC MEETING BOTH PEOPLE ATTENDED"
BYSTANDER_NAME = "SYNTHETIC BYSTANDER OWN NAME"


def build_store(engine):
    """A dataset shaped like the one on the box, in the SHIPPED vocabulary.

    Five things, and the last three are what a fixture without them cannot see:
      1. a pwg:PersonFact about the target            -- must be erased
      2. a urn:ostler:Fact about the target (CM048)   -- must be erased
      3. a pwg:PersonFact about the BYSTANDER         -- must survive
      4. a fact about the bystander that MENTIONS the target -- must survive
      5. a meeting BOTH attended, and a bystander node carrying spouseOf ->
         target -- both must survive, and both die under the obvious repair
    """
    rows = []
    for subject, fact, text in ((PERSON, "fact-subject", SENTENCE),
                                (OTHER, "fact-bystander", OTHER_SENTENCE)):
        f = "http://example.invalid/fact/" + fact
        rows.append((f, RDF_T, PWG_FACT, False))
        rows.append((f, str(PWG_ABOUT), subject, False))
        rows.append((f, str(TEXT_P), text, True))
        rows.append((f, str(OWNER_P), str(USER_U), False))
        rows.append((subject, str(NAME_P), "Synthetic", True))

    # 2. the CM048 vocabulary, about the target
    c = "http://example.invalid/fact/fact-cm048"
    rows.append((c, RDF_T, OST_FACT, False))
    rows.append((c, OST_ABOUT, PERSON, False))
    rows.append((c, OST_TEXT, CM048_SENTENCE, True))

    # 4. about the bystander, MENTIONING the target
    m = "http://example.invalid/fact/fact-mentions"
    rows.append((m, RDF_T, PWG_FACT, False))
    rows.append((m, str(PWG_ABOUT), OTHER, False))
    rows.append((m, str(MENTIONS_P), PERSON, False))
    rows.append((m, str(TEXT_P), MENTION_SENTENCE, True))

    # 5. the shared nodes
    mt = "http://example.invalid/meeting/synthetic"
    rows.append((mt, str(ATTENDED_P), PERSON, False))
    rows.append((mt, str(ATTENDED_P), OTHER, False))
    rows.append((mt, str(TITLE_P), MEETING_TITLE, True))
    rows.append((OTHER, str(SPOUSE_P), PERSON, False))
    rows.append((OTHER, str(NAME_P), BYSTANDER_NAME, True))
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


FACT_SHAPES = (("<" + PWG_FACT + ">", "<" + PWG_ABOUT + ">"),
               ("<" + OST_FACT + ">", "<" + OST_ABOUT + ">"))


def corrected_update(person_uri, graph_uris):
    """The repair, now GRAFTED into the vendored server. Collects the fact node
    WHILE ITS LINK STILL EXISTS, scoped by fact TYPE plus the fact-to-person
    PREDICATE, then does everything the shipped update already did."""
    esc = person_uri.replace("\\", "\\\\").replace(">", "%3E")
    clauses = []
    for graph in graph_uris:
        for fact_type, about in FACT_SHAPES:
            clauses.append(
                "DELETE {{ GRAPH <" + graph + "> {{ ?f ?fp ?fo }} }} "
                "WHERE {{ GRAPH <" + graph + "> {{ ?f a " + fact_type + " ; "
                + about + " <{uri}> ; ?fp ?fo }} }};")
    for fact_type, about in FACT_SHAPES:
        clauses.append(
            "DELETE {{ ?f ?fp ?fo }} WHERE {{ ?f a " + fact_type + " ; "
            + about + " <{uri}> ; ?fp ?fo }};")
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


def broad_update(person_uri, graph_uris):
    """NEGATIVE CONTROL, and it was this file's proposed repair until
    2026-09-18. Collects by ANY predicate instead of the fact-to-person one:

        DELETE { GRAPH g { ?s ?p2 ?o2 } }
        WHERE  { GRAPH g { ?s ?p <uri> . ?s ?p2 ?o2 } }

    It erases the sentence, and it also erases every node that so much as
    REFERENCES the person: a meeting they attended (with its other attendees)
    and a bystander whose record carries `spouseOf -> target`, whole. It is
    kept because a MUST-MISS arm with nothing that must miss is green by
    construction. This must DESTROY the bystander below or the arm proves
    nothing.
    """
    esc = person_uri.replace("\\", "\\\\").replace(">", "%3E")
    clauses = []
    for graph in graph_uris:
        clauses.append(
            "DELETE {{ GRAPH <" + graph + "> {{ ?s ?p2 ?o2 }} }} "
            "WHERE {{ GRAPH <" + graph + "> {{ ?s ?p <{uri}> . ?s ?p2 ?o2 }} }};")
    clauses.append("DELETE {{ <{uri}> ?p ?o }} WHERE {{ <{uri}> ?p ?o }};")
    clauses.append("DELETE {{ ?s ?p <{uri}> }} WHERE {{ ?s ?p <{uri}> }};")
    return "\n".join(clauses).format(uri=esc)


def wrong_order(person_uri, graph_uris):
    """The GRAFTED repair with its collecting clauses moved AFTER the link
    delete. They then match nothing, and the repair does nothing while looking
    correct. The ordering is a claim, so it is driven."""
    esc = person_uri.replace("\\", "\\\\").replace(">", "%3E")
    clauses = ["DELETE {{ ?s ?p <{uri}> }} WHERE {{ ?s ?p <{uri}> }};"]
    for graph in graph_uris:
        clauses.append(
            "DELETE {{ GRAPH <" + graph + "> {{ ?s ?p <{uri}> }} }} "
            "WHERE {{ GRAPH <" + graph + "> {{ ?s ?p <{uri}> }} }};")
        for fact_type, about in FACT_SHAPES:
            clauses.append(
                "DELETE {{ GRAPH <" + graph + "> {{ ?f ?fp ?fo }} }} "
                "WHERE {{ GRAPH <" + graph + "> {{ ?f a " + fact_type + " ; "
                + about + " <{uri}> ; ?fp ?fo }} }};")
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

    r["cm048_before"] = carries(engine, before, CM048_SENTENCE)

    shipped = build_store(engine)
    apply_update(engine, shipped, forget_update(PERSON, [GRAPH]))
    r["m_after"] = mentions(engine, shipped, PERSON)
    r["c_after"] = carries(engine, shipped, SENTENCE)
    r["cm048_after"] = carries(engine, shipped, CM048_SENTENCE)
    r["bystander_after"] = carries(engine, shipped, OTHER_SENTENCE)
    # the three surfaces a too-broad repair destroys
    r["mention_after"] = carries(engine, shipped, MENTION_SENTENCE)
    r["meeting_after"] = carries(engine, shipped, MEETING_TITLE)
    r["byname_after"] = carries(engine, shipped, BYSTANDER_NAME)

    fixed = build_store(engine)
    apply_update(engine, fixed, corrected_update(PERSON, [GRAPH]))
    r["fixed_content"] = carries(engine, fixed, SENTENCE)
    r["fixed_cm048"] = carries(engine, fixed, CM048_SENTENCE)
    r["fixed_bystander"] = carries(engine, fixed, OTHER_SENTENCE)
    r["fixed_mention"] = carries(engine, fixed, MENTION_SENTENCE)
    r["fixed_meeting"] = carries(engine, fixed, MEETING_TITLE)
    r["fixed_byname"] = carries(engine, fixed, BYSTANDER_NAME)

    # NEGATIVE CONTROL: the broad repair must destroy what the scoped one keeps.
    broad = build_store(engine)
    apply_update(engine, broad, broad_update(PERSON, [GRAPH]))
    r["broad_content"] = carries(engine, broad, SENTENCE)
    r["broad_meeting"] = carries(engine, broad, MEETING_TITLE)
    r["broad_byname"] = carries(engine, broad, BYSTANDER_NAME)

    mis = build_store(engine)
    apply_update(engine, mis, wrong_order(PERSON, [GRAPH]))
    r["wrong_order_content"] = carries(engine, mis, SENTENCE)
    return r


print("-- controls: the lift, the predicates, and the engines --")

if not free:
    ok("CONTROL: the lifted function binds every name it uses, so executing it "
       "alone gives the shipped output and not a stub's")
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

if r["cm048_after"] == 0:
    ok("the CM048-vocabulary fact about the same person is GONE too (1,274 of "
       "the box's 1,322 facts are this shape, not pwg:PersonFact)")
else:
    bad("THE CM048 SENTENCE SURVIVES. %d triple(s) still carry it. CM048 writes "
        "`a <urn:ostler:Fact> ; <urn:ostler:about>` and is 1,274 of the 1,322 "
        "facts on the box, so an erasure covering only pwg:PersonFact leaves 96 "
        "per cent of the customer's facts in place." % r["cm048_after"])

print("-- MUST-MISS: what an erasure must NOT take with it --")
for key, label in (("bystander_after", "the bystander's own fact"),
                   ("mention_after", "a fact ABOUT the bystander that merely "
                                     "MENTIONS the forgotten person"),
                   ("meeting_after", "a meeting BOTH people attended"),
                   ("byname_after", "the bystander's own name, on a node "
                                    "carrying spouseOf -> the forgotten person")):
    if r[key] == 1:
        ok("MUST-MISS: %s survives" % label)
    else:
        bad("MUST-MISS: forgetting one person destroyed %s. An erasure that "
            "takes other people's data with it is a worse defect than the one "
            "it fixes." % label)

print("-- the scoped repair, stated independently of the shipped function --")
_kept = (r["fixed_bystander"], r["fixed_mention"], r["fixed_meeting"],
         r["fixed_byname"])
if r["fixed_content"] == 0 and r["fixed_cm048"] == 0 and _kept == (1, 1, 1, 1):
    ok("the scoped repair erases BOTH vocabularies and keeps all four "
       "must-miss surfaces, so the arms above are a target and not a verdict")
elif r["fixed_content"] or r["fixed_cm048"]:
    bad("the scoped repair leaves content behind (pwg %d, cm048 %d), so it does "
        "not work and must not be handed upstream as though it does"
        % (r["fixed_content"], r["fixed_cm048"]))
else:
    bad("the scoped repair destroyed a must-miss surface "
        "(bystander %d, mention %d, meeting %d, name %d of 1 each)" % _kept)

# WITHOUT THIS THE MUST-MISS ARMS ARE GREEN BY CONSTRUCTION. They passed for
# hours against a fixture holding nothing that could fail them.
if r["broad_content"] == 0 and r["broad_meeting"] == 0 and r["broad_byname"] == 0:
    ok("NEGATIVE CONTROL: the broad repair erases the sentence AND destroys the "
       "meeting and the bystander's name, so the must-miss arms above "
       "discriminate rather than merely pass")
else:
    bad("NEGATIVE CONTROL FAILED: the broad repair left meeting=%d name=%d "
        "standing, so this fixture cannot exhibit over-deletion and every "
        "MUST-MISS arm above is green by construction."
        % (r["broad_meeting"], r["broad_byname"]))

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
    print("CUT BLOCKED: the one-click erasure does not erase, or it erases too")
    print("much. The repair is GRAFTED into vendor/cm041/assistant_api/ -- the")
    print("vendored copy is 1,151 lines ahead of CM041 main (board row 2218), so")
    print("a re-vendor would destroy shipped behaviour and a graft is the only")
    print("route to a customer. vendor/VENDOR_MANIFEST.toml records")
    print("shipping_bugfixes_grafted for this tree, with CM051 #1724 and #1726")
    print("as precedent. The same fix is still owed UPSTREAM so the two")
    print("converge; until then this file is what holds the behaviour.")
    sys.exit(1)
print()
print("NOT A CUT: reporting %d finding(s) and exiting 0. Run with" % len(FAIL))
print("OSTLER_CUT_IN_PROGRESS=1 and this refuses instead.")
sys.exit(0)
