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


def _orgs(facts, outbound, operator_level=None, destination="owner_own_brief"):
    # The outbound reads declare owner_own_brief (the brief agent's own-channel
    # view); tests of other destinations pass theirs.
    with patch.object(server, "USER_URI", OPERATOR_URI), \
            patch.object(server, "_sparql_select", side_effect=_engine(facts, operator_level)):
        return sorted(r["org"] for r in server._query_operator_career_facts(
            outbound=outbound, destination=destination))


class EmployerOutboundL3(unittest.TestCase):
    FACTS = [("SynthL1 Ltd", "L1"), ("SynthL3 Corp", "L3")]

    def test_outbound_drops_l3_keeps_l1(self):
        self.assertEqual(_orgs(self.FACTS, True), ["SynthL1 Ltd"])

    def test_on_box_default_still_sees_l3(self):
        self.assertEqual(_orgs(self.FACTS, False), ["SynthL1 Ltd", "SynthL3 Corp"])

    def test_unparseable_level_fails_closed(self):
        self.assertEqual(_orgs([("SynthBad", "banana")], True), [])

    def test_untagged_fact_fails_closed_even_beside_an_operator_level(self):
        # Canonical: a missing tag is L3, and beside the operator's L2 it is a
        # missing tag beside a present one (L3). Withheld at owner_own_brief;
        # served to owner_local only.
        self.assertEqual(_orgs([("SynthUntagged", None)], True), [])
        self.assertEqual(_orgs([("SynthUntagged", None)], True, operator_level="L2"), [])
        self.assertEqual(_orgs([("SynthUntagged", None)], True, operator_level="L2",
                               destination="owner_local"), ["SynthUntagged"])

    def test_undeclared_destination_is_unknown_and_withholds_l1(self):
        self.assertEqual(_orgs(self.FACTS, True, destination=None), [])

    def test_operator_l3_hides_everything_outbound(self):
        self.assertEqual(_orgs([("SynthL1 Ltd", "L1")], True, operator_level="L3"), [])

    def test_employer_route_uses_outbound(self):
        with patch.object(server, "USER_URI", OPERATOR_URI), \
                patch.object(server, "_sparql_select", side_effect=_engine(self.FACTS)), \
                patch.object(server, "_hygiene_verdicts", return_value={}), \
                patch.object(server, "_operator_email_domains", return_value=[]):
            out = server._current_employer_safe(outbound=True, destination="owner_own_brief")
            box = server._current_employer_safe()
        self.assertEqual(out.get("employer"), "SynthL1 Ltd")
        self.assertNotIn("SynthL3", repr(out))
        self.assertIn("SynthL3 Corp", repr(box) + repr(server._query_operator_career_facts()))

    def _get_employer(self, query=""):
        import http.client
        import json
        import threading
        from http.server import HTTPServer
        httpd = HTTPServer(("127.0.0.1", 0), server.Handler)
        t = threading.Thread(target=httpd.serve_forever, daemon=True)
        t.start()
        try:
            with patch.object(server, "USER_URI", OPERATOR_URI), \
                    patch.object(server, "_sparql_select", side_effect=_engine(self.FACTS)), \
                    patch.object(server, "_hygiene_verdicts", return_value={}), \
                    patch.object(server, "_operator_email_domains", return_value=[]), \
                    patch.object(server, "_expected_service_token", return_value="synthetic-test-token"):
                # CM051: the vendored Handler fails closed without a configured
                # token (CM041's conftest sets one in the environment).
                c = http.client.HTTPConnection("127.0.0.1", httpd.server_address[1], timeout=10)
                c.request("GET", "/api/v1/employer" + query, headers={
                    "X-Ostler-Service": "synthetic-test-token"})
                r = c.getresponse()
                return r.status, r.getheader("X-Ostler-Served-For"), json.loads(r.read())
        finally:
            httpd.shutdown()
            httpd.server_close()

    def test_http_route_gates_for_the_declared_destination(self):
        # Behavioural (replaces a source grep): the real Handler, the real
        # gate. owner_own_brief serves the L1 employer, never the L3 one.
        status, served_for, body = self._get_employer("?destination=owner_own_brief")
        self.assertEqual((200, "owner_own_brief"), (status, served_for))
        self.assertEqual("SynthL1 Ltd", body.get("employer"))
        self.assertNotIn("SynthL3", repr(body))

    def test_http_route_undeclared_is_unknown(self):
        status, served_for, body = self._get_employer()
        self.assertEqual((200, "unknown"), (status, served_for))
        self.assertNotIn("SynthL1", repr(body))
        self.assertNotIn("SynthL3", repr(body))


if __name__ == "__main__":
    unittest.main()
