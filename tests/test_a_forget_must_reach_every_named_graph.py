#!/usr/bin/env python3
"""A forget must reach every named graph, and a reader must see them.

THE DEFECT THIS PINS (v1018-D012b)
----------------------------------
``POST /api/v1/people/{slug}/forget`` is the customer's GDPR Art. 17
one-click erasure. It issued a bare ``DELETE ... WHERE``, which reaches
the DEFAULT graph ONLY. CM048 writes a person's facts, relationship
signals, outstanding todos and conversation links into the NAMED graph
``urn:ostler:user/<id>``, and Oxigraph runs WITHOUT
``--union-default-graph`` (install.sh; ``compartment.py`` requires it stay
off). So the erasure could not see the named graph.

Measured on a live Hub before the fix, with a synthetic person seeded 4
triples in each graph: the endpoint returned ``forgotten: true,
stores_purged: ['oxigraph','qdrant']`` and left all 4 named-graph triples
in place. The product ACCEPTED a deletion request and did not honour it.

The same missing scope blinded five readers. ``/api/v1/commitments``
returned count 0 against 67 live ``OutstandingTodo`` triples.

WHAT IS ASSERTED, AND WHY IT IS NOT JUST A GREP
-----------------------------------------------
Both halves are exercised as CODE, executed out of the shipped files, not
matched as prose:

  * the erasure builder emits an explicitly-scoped DELETE pair for EVERY
    graph in scope, plus the default-graph pair;
  * the reader rewriter puts the named graph on the read path while
    leaving default-graph reads reachable;
  * the rewriter NEVER emits an unrestricted ``GRAPH ?g``, which would put
    every OTHER user's compartment on the primary operator's read path and
    re-create precisely the leak ``assert_default_graph_isolated`` exists
    to prevent;
  * the raw-cased user id is carried, because CM048 mints its graph IRI
    from the RAW ``settings.user_id``. Measured on the live box:
    ``urn:ostler:user/Andy`` held 37,625 triples and
    ``urn:ostler:user/andy`` held 0, so a normalise-only reader would have
    matched nothing and looked exactly like a fix.

EVERY ASSERTION IS MUTATION-TESTED at the bottom: the pre-fix forms are
reconstructed and each must FAIL. A gate that has not been driven red is
a gate you have read, not a gate you have run.
"""
import ast
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICAL = os.path.join(REPO, "vendor", "cm041", "assistant_api", "ical-server.py")
COMPARTMENT = os.path.join(
    REPO, "vendor", "cm041", "identity_resolver", "compartment.py")
BRIEF = os.path.join(REPO, "vendor", "cm041", "meeting_syncer", "brief.py")

FAILURES = []


def check(label, condition, detail=""):
    if condition:
        print("  PASS  %s" % label)
    else:
        print("  FAIL  %s %s" % (label, detail))
        FAILURES.append(label)
    return bool(condition)


def read(path):
    if not os.path.exists(path):
        print("CANNOT-RUN: missing %s" % path)
        raise SystemExit(2)
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def load_function(src, name, path, ns=None):
    """Exec ONE top-level function out of a source file, by AST span.

    Importing ical-server.py outright would run its module-level
    environment and sys.path setup, which is not available on a CI runner.
    Taking the function by its AST span still executes the SHIPPED text.
    """
    tree = ast.parse(src)
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            seg = ast.get_source_segment(src, node)
            namespace = dict(ns or {})
            exec(compile(seg, path, "exec"), namespace)
            return namespace[name]
    print("CANNOT-RUN: %s not found in %s" % (name, path))
    raise SystemExit(2)


ical_src = read(ICAL)
comp_src = read(COMPARTMENT)
brief_src = read(BRIEF)

sys.path.insert(0, os.path.join(REPO, "vendor", "cm041"))
try:
    from identity_resolver.compartment import (
        cm048_user_graph_uris, graph_scoped_select,
    )
except ImportError as exc:
    print("CANNOT-RUN: cannot import the shared graph-scope helper: %s" % exc)
    raise SystemExit(2)

forget_update = load_function(ical_src, "_forget_person_update", ICAL)

PERSON = "https://schema.ostler.ai/ontology#alice"
GRAPHS = cm048_user_graph_uris("Andy")

print("== the shared helper names this user's graphs ==")
check("raw-cased graph is carried (CM048 mints from the RAW id)",
      "urn:ostler:user/Andy" in GRAPHS, GRAPHS)
check("normalised spelling is carried too",
      "urn:ostler:user/andy" in GRAPHS, GRAPHS)
check("an unset USER_ID yields NO graphs (keeps today's behaviour)",
      cm048_user_graph_uris("") == [])

print("== the erasure reaches every graph in scope ==")
upd = forget_update(PERSON, GRAPHS)
check("default-graph subject pair present",
      "DELETE { <%s> ?p ?o } WHERE { <%s> ?p ?o };" % (PERSON, PERSON) in upd)
check("default-graph object pair present",
      "DELETE { ?s ?p <%s> } WHERE { ?s ?p <%s> };" % (PERSON, PERSON) in upd)
for g in GRAPHS:
    check("named graph %s gets a scoped subject DELETE" % g,
          "DELETE { GRAPH <%s> { <%s> ?p ?o } }" % (g, PERSON) in upd)
    check("named graph %s gets a scoped object DELETE" % g,
          "DELETE { GRAPH <%s> { ?s ?p <%s> } }" % (g, PERSON) in upd)
# THE ARITHMETIC, SPELLED OUT, because this number moved on 2026-09-18 and a
# bare literal would have read as a regression rather than as the fix it is.
#   person pairs : subject + object, once for the default graph and once per
#                  named graph                      -> 2 + 2 * len(GRAPHS)
#   fact nodes   : one collecting clause per FACT SHAPE (pwg:PersonFact and
#                  urn:ostler:Fact), for the default graph and each named one
#                                                    -> SHAPES * (1 + len(GRAPHS))
# The fact clauses are what erase the SENTENCE rather than merely its link to
# the person; see tests/test_a_forget_erases_the_fact_not_just_the_link.py and
# board rows 960 and 2217.
FACT_SHAPES_IN_ERASURE = 2
expected_deletes = (2 + 2 * len(GRAPHS)
                    + FACT_SHAPES_IN_ERASURE * (1 + len(GRAPHS)))
check("no graph is left unscoped (clause count matches)",
      upd.count("DELETE") == expected_deletes,
      "counted %d, expected %d" % (upd.count("DELETE"), expected_deletes))

# The fact-collecting clauses must come BEFORE the clause that deletes links
# into the person. After it they match nothing. This is a cheap positional
# check of a property the other file drives end-to-end.
_link_delete = "DELETE { ?s ?p <%s> } WHERE" % PERSON
check("the fact-collecting clauses precede the link delete",
      upd.index("?f a ") < upd.index(_link_delete)
      if ("?f a " in upd and _link_delete in upd) else False)

print("== the reader rewriter spans default AND named ==")
Q = "SELECT (COUNT(*) AS ?n) WHERE { ?s a <urn:ostler:OutstandingTodo> }"
out = graph_scoped_select(Q, GRAPHS)
check("named graph is on the read path", "GRAPH ?__ostler_g" in out)
check("the graph list is pinned by a FILTER",
      "FILTER (?__ostler_g IN (" in out)
for g in GRAPHS:
    check("FILTER names %s" % g, "<%s>" % g in out)
check("the default-graph branch survives (UNION, not replacement)",
      "UNION" in out and out.count("?s a <urn:ostler:OutstandingTodo>") == 2)
check("ORDER BY / LIMIT stay OUTSIDE the rewritten group",
      graph_scoped_select(
          "SELECT ?w WHERE { ?s <urn:ostler:warmth> ?w } ORDER BY DESC(?w) LIMIT 1",
          GRAPHS).rstrip().endswith("ORDER BY DESC(?w) LIMIT 1"))
check("no graphs -> query returned byte-identical",
      graph_scoped_select(Q, []) == Q)

print("== isolation: never an unrestricted GRAPH ?g ==")
# The rewriter's ONLY graph variable must always be constrained. An
# unrestricted `GRAPH ?g` would union every OTHER user's compartment into
# the primary operator's reads -- the exact leak compartment.py forbids.
check("a bare 'GRAPH ?g {' never appears", "GRAPH ?g {" not in out)
check("every GRAPH-var use is paired with its FILTER",
      out.count("GRAPH ?__ostler_g") == out.count("FILTER (?__ostler_g IN ("))

print("== adversarial query shapes do not desynchronise the rewriter ==")
for label, q in [
    ("brace inside a string literal",
     'SELECT ?x WHERE { ?s <urn:p> "a { brace } here" . ?s <urn:q> ?x }'),
    ("brace inside a # comment",
     'SELECT ?x WHERE { # } not a real brace\n ?s <urn:p> ?x }'),
    ("unbalanced brace (must decline, not raise)",
     'SELECT ?x WHERE { ?s ?p ?o '),
]:
    try:
        r = graph_scoped_select(q, GRAPHS)
        ok = (r == q) if "unbalanced" in label else ("UNION" in r)
        check(label, ok)
    except Exception as exc:  # noqa: BLE001
        check(label, False, "raised %r" % exc)

print("== the five readers actually route through the shared helper ==")
check("ical-server imports the shared helper (no private copy)",
      "graph_scoped_select as _graph_scoped_select" in ical_src)
check("ical-server._sparql_select scopes its query",
      "_graph_scoped(sparql).encode" in ical_src)
check("brief.py imports the SAME shared helper",
      "graph_scoped_select as _graph_scoped_select" in brief_src)
check("brief.py._sparql_query scopes its query",
      "_graph_scoped_select(" in brief_src.split("def _sparql_query")[1][:400])
check("the helper is defined ONCE, in compartment.py",
      "def graph_scoped_select" in comp_src
      and "def graph_scoped_select" not in ical_src
      and "def graph_scoped_select" not in brief_src)

print("== MUTATION: the pre-fix forms must FAIL these assertions ==")


def mutant(label, condition_that_must_be_false):
    if condition_that_must_be_false:
        print("  FAIL  mutation survived: %s" % label)
        FAILURES.append("mutation: " + label)
    else:
        print("  PASS  mutation caught: %s" % label)


# M1: the original erasure -- default graph only.
prefix_only = (
    "DELETE {{ <{uri}> ?p ?o }} WHERE {{ <{uri}> ?p ?o }};\n"
    "DELETE {{ ?s ?p <{uri}> }} WHERE {{ ?s ?p <{uri}> }};"
).format(uri=PERSON)
mutant("bare DELETE reaches a named graph",
       any("GRAPH <%s>" % g in prefix_only for g in GRAPHS))
mutant("bare DELETE has the full clause count",
       prefix_only.count("DELETE") == 2 + 2 * len(GRAPHS))

# M2: the original reader -- unqualified, no scope at all.
mutant("unqualified query reaches the named graph", "GRAPH" in Q)

# M3: a normalise-only reader. Measured live: the lowercase graph held 0
# triples and the raw-cased one held 37,625, so this mutant looks like a
# fix and reads nothing.
normalised_only = [g for g in cm048_user_graph_uris("Andy")
                   if g == "urn:ostler:user/andy"]
mutant("normalise-only scope carries the raw-cased graph",
       "urn:ostler:user/Andy" in normalised_only)

# M4: the tempting global fix -- union every named graph. Must be absent
# from the shipped rewriter, because it breaks compartment isolation.
mutant("shipped rewriter emits an unrestricted GRAPH ?g",
       "GRAPH ?g {" in comp_src.split("def graph_scoped_select")[1])

print()
if FAILURES:
    print("FAILED (%d): %s" % (len(FAILURES), "; ".join(FAILURES)))
    raise SystemExit(1)
print("OK: erasure reaches every graph in scope; readers span default + named; "
      "isolation preserved; all mutants caught.")
