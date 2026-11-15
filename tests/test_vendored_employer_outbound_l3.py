"""``/api/v1/employer`` (read by the brief agent) withholds L3 career facts.

``_query_operator_career_facts(outbound=True)`` applies the fail-closed L3
filter (``pwg_privacy.is_l3``: fact level + operator level, most-restrictive
wins, no parseable level -> hidden), the same rule as the brief's
``_get_person_facts``. The default (``outbound=False``) is the on-box Hub
path (Memory tab, person_context) and must STILL see L3.

Runs the shipped query against a real SPARQL engine. Synthetic data only.
"""
from __future__ import annotations

import unittest
from unittest.mock import patch

import sys
from pathlib import Path

# VENDORED COPY of CM041 assistant_api/tests/test_employer_outbound_l3.py,
# loading the shipped ical-server through the repo's own loader.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm041" / "assistant_api" / "tests"))
from test_ical_server_wire_shape import ical_server as server  # noqa: E402

OPERATOR_URI = "https://schema.ostler.ai/ontology#user_testuser"

PWG = "https://schema.ostler.ai/ontology#"
RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"


def _engine(facts, operator_level=None):
    from rdflib import Dataset, Literal, URIRef

    ds = Dataset(default_union=False)
    g = getattr(ds, "default_graph", None) or ds.default_context
    op = URIRef(OPERATOR_URI)
    if operator_level:
        g.add((op, URIRef(PWG + "privacyLevel"), Literal(operator_level)))
    for i, (org, level) in enumerate(facts):
        f = URIRef(PWG + "fact_synth_%d" % i)
        g.add((f, URIRef(RDF_TYPE), URIRef(PWG + "PersonFact")))
        g.add((f, URIRef(PWG + "aboutPerson"), op))
        g.add((f, URIRef(PWG + "factType"), Literal("career_position")))
        g.add((f, URIRef(PWG + "organization"), Literal(org)))
        if level is not None:
            g.add((f, URIRef(PWG + "privacyLevel"), Literal(level)))

    def select(sparql):
        rows = ds.query(sparql)
        return [{str(v): str(r[v]) for v in rows.vars if r[v] is not None} for r in rows]

    return select


def _orgs(facts, outbound, operator_level=None):
    with patch.object(server, "USER_URI", OPERATOR_URI), \
            patch.object(server, "_sparql_select", side_effect=_engine(facts, operator_level)):
        return sorted(r["org"] for r in server._query_operator_career_facts(outbound=outbound))


class EmployerOutboundL3(unittest.TestCase):
    FACTS = [("SynthL1 Ltd", "L1"), ("SynthL3 Corp", "L3")]

    def test_outbound_drops_l3_keeps_l1(self):
        self.assertEqual(_orgs(self.FACTS, True), ["SynthL1 Ltd"])

    def test_on_box_default_still_sees_l3(self):
        self.assertEqual(_orgs(self.FACTS, False), ["SynthL1 Ltd", "SynthL3 Corp"])

    def test_unparseable_level_fails_closed(self):
        self.assertEqual(_orgs([("SynthBad", "banana")], True), [])

    def test_untagged_fact_fails_closed_unless_operator_level_clears_it(self):
        self.assertEqual(_orgs([("SynthUntagged", None)], True), [])
        self.assertEqual(_orgs([("SynthUntagged", None)], True, operator_level="L2"), ["SynthUntagged"])

    def test_operator_l3_hides_everything_outbound(self):
        self.assertEqual(_orgs([("SynthL1 Ltd", "L1")], True, operator_level="L3"), [])

    def test_employer_route_uses_outbound(self):
        with patch.object(server, "USER_URI", OPERATOR_URI), \
                patch.object(server, "_sparql_select", side_effect=_engine(self.FACTS)), \
                patch.object(server, "_hygiene_verdicts", return_value={}), \
                patch.object(server, "_operator_email_domains", return_value=[]):
            out = server._current_employer_safe(outbound=True)
            box = server._current_employer_safe()
        self.assertEqual(out.get("employer"), "SynthL1 Ltd")
        self.assertNotIn("SynthL3", repr(out))
        self.assertIn("SynthL3 Corp", repr(box) + repr(server._query_operator_career_facts()))

    def test_http_route_passes_outbound_true(self):
        src = server.__file__
        text = open(src).read()
        i = text.index('parsed.path == "/api/v1/employer"')
        self.assertIn("_current_employer_safe(outbound=True)", text[i:i + 400])


if __name__ == "__main__":
    unittest.main()
