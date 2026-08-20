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
TRIPLE_SPACED_LITERAL = '<https://pwg.dev/p/1> <https://pwg.dev/name> "Hello there world" .'
TRIPLE_IRI_OBJECT = "<https://pwg.dev/p/1> <https://pwg.dev/knows> <https://pwg.dev/p/2> ."
QUAD = ('<https://pwg.dev/p/1> <https://pwg.dev/name> "Ada" '
        "<urn:pwg:compartment> .")
QUAD_SPACED_LITERAL = ('<https://pwg.dev/p/1> <https://pwg.dev/note> "a b c d e" '
                       "<urn:pwg:compartment> .")


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
    typed = ('<https://pwg.dev/p/1> <https://pwg.dev/when> '
             '"2026-08-20"^^<http://www.w3.org/2001/XMLSchema#date> .')
    tagged = '<https://pwg.dev/p/1> <https://pwg.dev/name> "Ada"@en-GB .'
    assert _nquads_is_quad(typed) is False, "^^<datatype> is part of the term"
    assert _nquads_is_quad(tagged) is False, "@lang is part of the term"
    assert _nquads_terms(typed) == ["iri", "iri", "literal"]
    assert _nquads_terms(tagged) == ["iri", "iri", "literal"]


def test_a_blank_node_graph_name_counts():
    line = '_:b0 <https://pwg.dev/name> "Ada" _:g1 .'
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


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  ok   {name}")
            except AssertionError as exc:
                failed += 1
                print(f"  FAIL {name}: {exc}")
    print(f"\n{'FAILED' if failed else 'PASSED'}: {failed} failing")
    sys.exit(1 if failed else 0)
