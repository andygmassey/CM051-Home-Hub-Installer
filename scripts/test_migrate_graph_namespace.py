"""The backup guard must be ABLE to fail, and these prove it can.

Archie's review of #888, 2026-08-20: he built a backup containing ZERO
named-graph quads and the guard PASSED it. The guard counted whitespace
tokens, and a default-graph triple whose literal contains spaces --

    <s> <p> "Hello there world" .

-- splits into four tokens and read as a quad. On the real dump that scored
43,399 "quads" when only 12,367 are real; on his named-graph-free backup it
still scored 31,032. The byte check was doing all the work, which the guard's
own comment says must not happen.

That matters more than a miscount. This backup is the ONLY artefact standing
between a customer's personal graph and a destructive rewrite that
install.sh:19546 runs unconditionally on every install. A guard nobody has
seen go red is indistinguishable from a guard that cannot go red.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from migrate_graph_namespace import _nquads_is_quad, _nquads_terms  # noqa: E402

# The literal contains spaces. This is a THREE-term default-graph triple.
TRIPLE_SPACED_LITERAL = '<https://example.org/p/1> <https://example.org/name> "Hello there world" .'
TRIPLE_IRI_OBJECT = "<https://example.org/p/1> <https://example.org/knows> <https://example.org/p/2> ."
QUAD = ('<https://example.org/p/1> <https://example.org/name> "Ada" '
        "<urn:example:compartment> .")
QUAD_SPACED_LITERAL = ('<https://example.org/p/1> <https://example.org/note> "a b c d e" '
                       "<urn:example:compartment> .")


def _old_predicate(line):
    """The predicate as shipped before this fix. Kept as the control.

    Without it these tests prove only that the new code agrees with itself.
    """
    return len(line.rstrip(" .").split()) >= 4 and line.endswith(".")


def test_the_old_predicate_really_did_misread_a_triple_as_a_quad():
    """THE CONTROL. If this ever fails, the bug was not what we thought."""
    assert _old_predicate(TRIPLE_SPACED_LITERAL) is True, (
        "the control does not reproduce the defect, so nothing below is "
        "evidence of a fix"
    )


def test_a_default_graph_triple_with_spaces_in_its_literal_is_not_a_quad():
    """F1. The exact line that let a named-graph-free backup pass."""
    assert _nquads_is_quad(TRIPLE_SPACED_LITERAL) is False
    assert _nquads_terms(TRIPLE_SPACED_LITERAL) == ["iri", "iri", "literal"]


def test_a_default_graph_triple_with_an_iri_object_is_not_a_quad():
    """Three IRIs is still three terms. Token count alone cannot see this."""
    assert _nquads_is_quad(TRIPLE_IRI_OBJECT) is False


def test_a_real_named_graph_quad_is_a_quad():
    assert _nquads_is_quad(QUAD) is True
    assert _nquads_terms(QUAD) == ["iri", "iri", "literal", "iri"]


def test_a_quad_whose_literal_has_spaces_is_still_a_quad():
    """The fix must not overcorrect into missing the thing it counts."""
    assert _nquads_is_quad(QUAD_SPACED_LITERAL) is True


def test_typed_and_tagged_literals_do_not_shift_the_arity():
    typed = ('<https://example.org/p/1> <https://example.org/when> '
             '"2026-08-20"^^<http://www.w3.org/2001/XMLSchema#date> .')
    tagged = '<https://example.org/p/1> <https://example.org/name> "Ada"@en-GB .'
    assert _nquads_is_quad(typed) is False, "^^<datatype> is part of the term"
    assert _nquads_is_quad(tagged) is False, "@lang is part of the term"
    assert _nquads_terms(typed) == ["iri", "iri", "literal"]
    assert _nquads_terms(tagged) == ["iri", "iri", "literal"]


def test_a_blank_node_graph_name_counts():
    line = '_:b0 <https://example.org/name> "Ada" _:g1 .'
    assert _nquads_is_quad(line) is True
    assert _nquads_terms(line) == ["bnode", "iri", "literal", "bnode"]


def test_blank_and_malformed_lines_are_not_quads():
    for line in ("", "   ", "# a comment", "<unterminated", '<s> <p> "open'):
        assert _nquads_is_quad(line) is False, line


def test_archies_control_a_backup_with_no_named_graphs_scores_zero():
    """THE CLOSING CONDITION, and the one the old guard failed.

    A whole-store dump that happens to contain no named graph must count ZERO
    quads, so the guard refuses. The old predicate scored 31,032 on exactly
    this shape and let the migration proceed.
    """
    dump = "\n".join([TRIPLE_SPACED_LITERAL, TRIPLE_IRI_OBJECT] * 500)
    new = sum(1 for ln in dump.splitlines() if _nquads_is_quad(ln))
    old = sum(1 for ln in dump.splitlines() if _old_predicate(ln))
    assert new == 0, f"{new} phantom quads in a dump with no named graphs"
    assert old == 500, (
        "the control should misread every spaced-literal line; if it does "
        "not, this fixture no longer reproduces the reported defect"
    )


def test_a_mixed_dump_counts_only_the_real_quads():
    dump = "\n".join([TRIPLE_SPACED_LITERAL] * 90 + [QUAD] * 10)
    assert sum(1 for ln in dump.splitlines() if _nquads_is_quad(ln)) == 10


# ---------------------------------------------------------------------------
# --preview MUST DESCRIBE THE SURFACE IT ACTUALLY COVERS.
#
# Archie's review of #888, finding F6, accepted and left open. --preview is the
# screen a human reads immediately before authorising a destructive whole-store
# rewrite, and it queried a DIFFERENT surface than the UPDATE it claims to
# preview: a bare `?s ?p ?o` with no UNION arm, and a FILTER with no `?o` arm.
#
# Measured on the live Hub store, READ ONLY, 2026-08-21 02:46Z. Both shapes,
# same store, same moment (the store had been migrated by another actor an hour
# earlier, so these are the post-migration namespaces -- the blindness is a
# property of the QUERY SHAPE, not of the needle, and reproduces identically):
#
#     needle                          preview saw   UPDATE touches   unseen
#     urn:ostler:                           3,762           20,339    81.5%
#     schema.ostler.ai/enrichment/          4,394            5,302    17.1%
#     schema.ostler.ai                    246,716          248,132     0.6%
#
# Each defect has its own witness, which is why both are fixed and both are
# tested rather than treated as one bug:
#   * schema.ostler.ai/enrichment/ is blind 908 of 908 in the DEFAULT graph --
#     rows whose only carrier is the object IRI. Purely the missing `?o` arm.
#   * urn:ostler: is blind 16,577 of 16,577 inside the NAMED graph. Purely the
#     missing UNION arm.
#
# And live on the box at the time of writing, the shipped preview printed
#     no rows matched -- the FILTER selected nothing, so an --apply here
#     would be a SILENT NO-OP
#     VERDICT: SOMETHING DID NOT MOVE -- do not --apply
# over a graph holding 20 real triples it simply could not see. Under-reporting
# does not only manufacture false confidence; here it manufactured a false
# BLOCKER, which teaches an operator to stop believing the verdict at all.
# ---------------------------------------------------------------------------

import migrate_graph_namespace as M  # noqa: E402

# THE CONTROL. The shipped preview's WHERE clause, copied verbatim from
# `git show origin/main:scripts/migrate_graph_namespace.py`. Without it these
# tests prove only that the new code agrees with itself.
_OLD_PREVIEW_WHERE = '''SELECT ?s ?ns ?p ?np WHERE {
  ?s ?p ?o .
  FILTER(CONTAINS(STR(?s),"{n}") || CONTAINS(STR(?p),"{n}"))
  BIND(IF(isIRI(?s), IRI(REPLACE(STR(?s), "{rx}", "{repl}")), ?s) AS ?ns)
  BIND(IRI(REPLACE(STR(?p), "{rx}", "{repl}")) AS ?np)
} LIMIT 6'''


def _filter_of(query):
    """The text inside the outermost FILTER(...), bracket-matched.

    Compared as a string on purpose. The claim being tested is not "these two
    predicates behave alike", which is untestable without an engine -- it is
    "these two predicates ARE the same text", which is the only property that
    actually stops them drifting apart again.
    """
    i = query.index("FILTER(")
    j, depth = i + len("FILTER("), 1
    while depth:
        depth += {"(": 1, ")": -1}.get(query[j], 0)
        j += 1
    return " ".join(query[i + len("FILTER("):j - 1].split())


def test_control_the_shipped_preview_was_default_graph_only():
    """F6, half one. If this passes, the reported defect was real."""
    assert "UNION" not in _OLD_PREVIEW_WHERE
    assert "GRAPH ?g" not in _OLD_PREVIEW_WHERE, (
        "the control does not reproduce the defect, so nothing below is "
        "evidence of a fix"
    )


def test_control_the_shipped_preview_filter_ignored_the_object():
    """F6, half two. The `?o` arm was absent, so object-only rows were unseen."""
    assert "STR(?o)" not in _filter_of(_OLD_PREVIEW_WHERE)


def test_control_the_shipped_preview_disagreed_with_the_update():
    """The two predicates were textually different. That IS the bug."""
    assert _filter_of(_OLD_PREVIEW_WHERE.replace("{n}", "urn:pwg:")) != _filter_of(
        M.rewrite_stmt(r"urn:pwg:", "urn:pwg:", "urn:ostler:")
    )


def test_the_preview_and_both_update_arms_share_one_filter_string():
    """The fix. One predicate, four callers, asserted character-identical.

    RED without the fix: preview_query does not exist on the shipped module.
    """
    needle, rx, repl = "urn:pwg:", r"urn:pwg:", "urn:ostler:"
    want = _filter_of(M.rewrite_stmt(rx, needle, repl))
    assert _filter_of(M.rewrite_named_stmt(rx, needle, repl)) == want
    for _label, pattern in M.SURFACES:
        assert _filter_of(M.preview_query(pattern, rx, needle, repl, 6)) == want
    assert _filter_of(f"FILTER({M.match_filter(needle)})") == want


def test_the_preview_filter_covers_the_object_position():
    """The 908 default-graph rows whose only carrier is the object IRI."""
    f = _filter_of(M.preview_query(M.SURFACES[0][1], r"urn:pwg:", "urn:pwg:",
                                   "urn:ostler:", 6))
    assert 'CONTAINS(STR(?o),"urn:pwg:")' in f
    assert "isIRI(?o)" in f, (
        "the guard must be kept: a literal object carrying the string is "
        "CONTENT the migration deliberately does not rewrite, and a preview "
        "that counts it is previewing something --apply will not do"
    )


def test_the_preview_samples_the_named_graph_surface_separately():
    """A LIMIT over a UNION is not a sample of the union.

    The engine may satisfy the limit entirely from the first arm, and on the
    live store it does -- 248,550 of 265,127 triples are in the default graph.
    81.5% of urn:ostler: candidates live in the named graph, so a unioned
    sample would show the operator that surface exactly never.
    """
    labels = [lab for lab, _p in M.SURFACES]
    patterns = [p for _lab, p in M.SURFACES]
    assert len(M.SURFACES) == 2, labels
    assert any("GRAPH ?g" in p for p in patterns), patterns
    assert any("GRAPH" not in p for p in patterns), patterns
    qs = [M.preview_query(p, r"urn:pwg:", "urn:pwg:", "urn:ostler:", 6)
          for p in patterns]
    assert "GRAPH ?g" in qs[1] and "GRAPH" not in qs[0]
    assert _filter_of(qs[0]) == _filter_of(qs[1]), "one predicate, two surfaces"


def test_the_preview_selects_the_object_it_now_matches_on():
    """Matching on ?o and not printing it counts a row as examined and shows
    the operator nothing at all."""
    q = M.preview_query(M.SURFACES[0][1], r"urn:pwg:", "urn:pwg:",
                        "urn:ostler:", 6)
    head = q[:q.index("WHERE")]
    assert "?o" in head and "?no" in head, head


def test_graph_names_are_previewed_not_just_triples():
    """A graph NAME is not a triple and no UPDATE can rewrite one."""
    ok = M.preview_graph_names({"urn:pwg:user/Andy": 20}, M.RULES)
    assert ok is True


def test_a_graph_name_with_no_rule_is_left_alone_and_does_not_fail_the_verdict():
    assert M.preview_graph_names({"urn:ostler:user/Andy": 16577}, M.RULES) is True


def test_the_preview_refuses_a_move_whose_destination_already_exists():
    """MOVE <a> TO <b> DROPS <b> FIRST. This is the live state of the box.

        <urn:ostler:user/Andy>  16,577 triples  (migrated 2026-08-21 ~01:40Z)
        <urn:pwg:user/Andy>         20 triples  (re-created since, by a writer
                                                 still running the old code)

    A second --apply destroys 16,577 triples to make room for 20, and every
    downstream check then reports clean: zero residue, no pwg graph name.
    """
    ok = M.preview_graph_names(
        {"urn:pwg:user/Andy": 20, "urn:ostler:user/Andy": 16577}, M.RULES)
    assert ok is False, (
        "the preview approved a MOVE that silently drops the destination, "
        "which on this store is the customer's entire compartment"
    )


def test_the_collision_check_does_not_fire_on_a_clean_two_graph_store():
    """It must refuse collisions without refusing every multi-graph store."""
    ok = M.preview_graph_names(
        {"urn:pwg:user/Andy": 20, "urn:ostler:user/Bea": 7}, M.RULES)
    assert ok is True


def _queries_issued_by_preview(rx, needle, repl):
    """Every SPARQL query the REAL preview() puts on the wire, captured at the
    transport and with nothing written.

    The tests above name functions the fix introduces, so against the shipped
    module they fail with AttributeError. That is red, but it is red about
    which names exist. This one calls `preview` itself -- a function BOTH
    versions have -- and asserts on the queries it actually sends, so the
    red is about behaviour: the shipped preview really does put a
    default-graph-only, object-blind query on the wire, and here is the string.

    ask() is stubbed to a non-zero count so the fixed preview believes there
    is something to sample; run() returns an empty result set so neither
    version can do anything but issue its queries.
    """
    import inspect
    sent = []
    real_run, real_ask = M.run, M.ask
    try:
        M.ask = lambda _h, _q: 1
        M.run = lambda _h, _path, body, *a, **k: (
            sent.append(body) or ('{"head":{"vars":[]},"results":'
                                  '{"bindings":[]}}', "", 0))
        kw = ({"touching_n": 1, "literal_n": 0}
              if "touching_n" in inspect.signature(M.preview).parameters else {})
        M.preview("local", rx, needle, repl, **kw)
    finally:
        M.run, M.ask = real_run, real_ask
    return sent


def test_preview_puts_a_named_graph_query_on_the_wire():
    """RED against the shipped module as a real assertion, not an import error.

    The shipped preview issues exactly one query and it is
    `SELECT ... WHERE { ?s ?p ?o . FILTER(...) }` -- default graph only. On
    the live store that is 248,550 of 265,127 triples, and it is the arm that
    left 16,577 of 20,339 urn:ostler: candidates unseen.
    """
    sent = _queries_issued_by_preview(r"urn:pwg:", "urn:pwg:", "urn:ostler:")
    assert sent, "preview issued no query at all"
    assert any("GRAPH ?g" in q for q in sent), (
        "preview never asks about a named graph, so its verdict is a "
        f"statement about the default graph only: {sent!r}"
    )


def test_every_preview_query_filters_on_the_object_too():
    """RED against the shipped module. The `?o` arm was simply absent."""
    sent = _queries_issued_by_preview(r"urn:pwg:", "urn:pwg:", "urn:ostler:")
    assert sent, "preview issued no query at all"
    for q in sent:
        f = _filter_of(q)
        assert 'CONTAINS(STR(?o),"urn:pwg:")' in f, (
            "a row whose only pwg-bearing term is the object IRI is invisible "
            f"to this preview and will still be rewritten by --apply: {f!r}"
        )


def test_candidates_uses_the_update_predicate_on_each_surface():
    """The denominator must be counted with the UPDATE's own predicate.

    `touching()` answers "mentions this string anywhere", which includes the
    literal content the migration deliberately leaves. A coverage fraction
    over that denominator is a fraction of the wrong population.
    """
    seen = []
    real_ask = M.ask
    try:
        M.ask = lambda _h, qy: seen.append(qy) or 0
        M.candidates("local", "urn:pwg:")
    finally:
        M.ask = real_ask
    assert len(seen) == 2, seen
    want = _filter_of(M.rewrite_stmt(r"urn:pwg:", "urn:pwg:", "urn:ostler:"))
    assert [_filter_of(q) for q in seen] == [want, want]
    assert "GRAPH ?g" in seen[1] and "GRAPH" not in seen[0]


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  ok   {name}")
            # Widened from AssertionError. A test that references a function
            # the module does not have raised straight through the runner and
            # aborted the whole file at the first one, so the RED demonstration
            # showed one error instead of the list. A test runner that cannot
            # survive its own failures cannot report them.
            except Exception as exc:  # noqa: BLE001
                failed += 1
                print(f"  FAIL {name}: {type(exc).__name__}: {exc}")
    print(f"\n{'FAILED' if failed else 'PASSED'}: {failed} failing")
    sys.exit(1 if failed else 0)
