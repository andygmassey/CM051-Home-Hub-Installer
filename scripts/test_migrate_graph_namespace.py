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

import migrate_graph_namespace as mig  # noqa: E402
from migrate_graph_namespace import (  # noqa: E402
    _nquads_is_quad,
    _nquads_terms,
    graph_size,
    graph_transfer_stmts,
)

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


# ===========================================================================
# THE GRAPH TRANSFER. A DIFFERENT DEFECT, THE SAME SHAPE.
#
# The backup guard above could not go red. This one could not go red EITHER,
# and it was worse: `MOVE <old> TO <new>` is defined by SPARQL as *drop the
# destination*, insert the source, drop the source. Measured on the operator's
# box on 2026-08-21, AFTER the migration had already succeeded:
#
#     urn:ostler:user/Andy   16577   <- the migrated compartment
#     urn:pwg:user/Andy         20   <- rewritten since, by a live writer
#
# install.sh runs this script on EVERY install, including re-runs over an
# existing volume. The next one deletes 16,577 triples to make room for 20 --
# and every residue check afterwards reports CLEAN, because they only ask
# whether OLD-namespace triples remain. They would not. The data is gone.
#
# The guard shipped in fb4c096 with NO TESTS AT ALL, which is the exact thing
# the docstring at the top of this file exists to complain about.
# ===========================================================================

REAL_OLD = "urn:pwg:user/Andy"
REAL_NEW = "urn:ostler:user/Andy"
#: The two counts measured on the box. Not illustrative -- these are the
#: numbers that would have been destroyed.
MIGRATED_COMPARTMENT = 16577
REWRITTEN_SINCE = 20


def _old_transfer(old, new):
    """`move_graph_stmt` exactly as it shipped. Kept as the control.

    Without it these tests prove only that the new code agrees with itself --
    the same reason `_old_predicate` is still here.
    """
    return f"MOVE <{old}> TO <{new}>"


def test_the_control_the_shipped_code_really_did_issue_a_bare_MOVE():
    """THE CONTROL. If this ever stops reproducing, the bug was not this."""
    assert _old_transfer(REAL_OLD, REAL_NEW) == (
        "MOVE <urn:pwg:user/Andy> TO <urn:ostler:user/Andy>"
    ), "the control no longer reproduces the shipped statement"


def test_a_populated_destination_is_never_MOVEd_into():
    """THE DEFECT, asserted on the whole statement list rather than on one
    element, so an extra statement cannot smuggle a MOVE back in."""
    stmts = graph_transfer_stmts(REAL_OLD, REAL_NEW, MIGRATED_COMPARTMENT)
    for s in stmts:
        assert not s.startswith("MOVE"), (
            f"{s!r} would DROP <{REAL_NEW}> and its "
            f"{MIGRATED_COMPARTMENT} triples"
        )


def test_a_populated_destination_uses_ADD_then_DROP_IN_THAT_ORDER():
    """Order is load-bearing and it is the direction that loses data.

    DROP-then-ADD would delete the source before anything had copied it out,
    which is the same total loss by a different route.
    """
    stmts = graph_transfer_stmts(REAL_OLD, REAL_NEW, MIGRATED_COMPARTMENT)
    assert stmts == [
        f"ADD <{REAL_OLD}> TO <{REAL_NEW}>",
        f"DROP GRAPH <{REAL_OLD}>",
    ], stmts


def test_an_empty_destination_still_uses_MOVE():
    """THE CONTROL AGAINST OVERCORRECTING.

    MOVE is atomic and ADD+DROP is not, so the fix must not spend that
    atomicity on the ordinary rename -- a fresh install, where the
    destination does not exist. The trade is only worth making when the
    alternative is silent deletion.
    """
    assert graph_transfer_stmts(REAL_OLD, REAL_NEW, 0) == [
        f"MOVE <{REAL_OLD}> TO <{REAL_NEW}>"
    ]


def test_one_triple_in_the_destination_is_already_enough_to_switch():
    """The threshold is >0, not some tolerance. One triple is someone's fact."""
    assert graph_transfer_stmts(REAL_OLD, REAL_NEW, 1)[0].startswith("ADD ")


def test_the_measured_box_case_end_to_end():
    """THE CLOSING CONDITION: the exact numbers from the box, old vs new."""
    old = _old_transfer(REAL_OLD, REAL_NEW)
    new = graph_transfer_stmts(REAL_OLD, REAL_NEW, MIGRATED_COMPARTMENT)
    assert old.startswith("MOVE"), "control broken"
    assert new[0].startswith("ADD"), (
        f"the fix does not hold for the {MIGRATED_COMPARTMENT}-vs-"
        f"{REWRITTEN_SINCE} case that prompted it"
    )


# ----------------------------------------------------------- sizing the dest

class _StubRun:
    """Replaces `run` for the duration of one test. Records what was asked."""

    def __init__(self, out, err="", rc=0):
        self.out, self.err, self.rc, self.body = out, err, rc, None

    def __call__(self, host, path, body, ctype, *a, **k):
        self.body = body
        return self.out, self.err, self.rc


def _with_stub_run(stub, fn):
    real = mig.run
    mig.run = stub
    try:
        return fn()
    finally:
        mig.run = real


def _count_json(n):
    return ('{"results":{"bindings":[{"n":{"value":"%d"}}]}}' % n)


def test_graph_size_reads_a_real_count():
    stub = _StubRun(_count_json(MIGRATED_COMPARTMENT))
    n = _with_stub_run(stub, lambda: graph_size("local", REAL_NEW))
    assert n == MIGRATED_COMPARTMENT
    assert REAL_NEW in stub.body, "the query did not name the graph it sized"


def test_graph_size_reports_zero_for_a_graph_that_does_not_exist():
    """The fresh-install path. Oxigraph answers 0, not an error."""
    stub = _StubRun(_count_json(0))
    assert _with_stub_run(stub, lambda: graph_size("local", REAL_NEW)) == 0


def test_an_UNREADABLE_count_RAISES_rather_than_reading_as_empty():
    """🔴 THE ONE THAT MATTERS MOST, AND THE EASIEST TO GET WRONG.

    A `except: return 0` here would route an unreachable store, a 400, or a
    truncated body straight back into the MOVE arm -- reintroducing the exact
    deletion this whole change exists to prevent, while looking defensive.
    A count that cannot be read is not a count of zero.
    """
    for out, err, rc in (
        ("", "HTTP 400: b'parse error'", 400),   # rejected query
        ("", "URLError: refused", 1),            # store unreachable
        ('{"results":{"bindings":[]}}', "", 0),  # well-formed, no rows
        ("<html>proxy</html>", "", 0),           # something answered FOR it
    ):
        stub = _StubRun(out, err, rc)
        try:
            n = _with_stub_run(stub, lambda: graph_size("local", REAL_NEW))
        except RuntimeError:
            continue
        raise AssertionError(
            f"graph_size returned {n!r} for rc={rc} out={out[:40]!r}; a "
            "guessed 0 sends the caller back to MOVE and deletes the graph"
        )


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
