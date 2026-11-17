"""Topic mentions inherit their CONVERSATION's level (CM041 #278, 134 red-team
CM041-01). Real pyoxigraph store, synthetic cast only.

CM048 writes TopicMention rows with no level of their own, and stamps the
conversation's level on the facts drawn from that conversation. The reader must
read those levels and serve a mention only when the strictest level it can see
allows it. Fixtures carry BOTH shapes: the L3 level on a fact (what CM048
writes) and on the conversation node (what a future writer may write).
"""
from __future__ import annotations

import importlib.util
import pathlib
import sys
import types
import unittest
from unittest.mock import patch

import pyoxigraph as ox

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SERVER = REPO_ROOT / "assistant_api" / "ical-server.py"
sys.path.append(str(REPO_ROOT / "assistant_api"))
sys.path.append(str(REPO_ROOT))


def _stub_security():
    try:
        import ostler_security  # noqa: F401
        return
    except Exception:
        pass
    import sqlite3
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    db = types.ModuleType("ostler_security.database")
    db.get_db_connection = lambda p, _k, *a, **k: sqlite3.connect(p)
    sys.modules["ostler_security.database"] = db
    po = types.ModuleType("ostler_security.posture")
    po.record_posture = lambda *a, **k: None
    sys.modules["ostler_security.posture"] = po


_stub_security()
_spec = importlib.util.spec_from_file_location("ical_topic_level_134", SERVER)
ICAL = importlib.util.module_from_spec(_spec)
# The server edits sys.path and can shadow the test package name ("tests") with its
# own assistant_api/tests: restore both so the rest of the suite imports as before.
_saved_path = list(sys.path)
_saved_mods = {k for k in sys.modules if k == "tests" or k.startswith("tests.")}
_spec.loader.exec_module(ICAL)
sys.path[:] = _saved_path
for _k in [k for k in sys.modules if (k == "tests" or k.startswith("tests.")) and k not in _saved_mods]:
    del sys.modules[_k]

PREFIX = (
    "@prefix pwg: <https://schema.ostler.ai/ontology#> .\n"
    "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .\n"
    "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .\n"
    "@prefix ostler: <urn:ostler:> .\n"
)
TOPIC = (
    "<https://schema.ostler.ai/ontology#topic_synthetic-subject> a pwg:ConversationTopic ;\n"
    '    pwg:topicSlug "synthetic-subject" ; rdfs:label "Synthetic subject" .\n'
)


def _case(mention_level=None, conv_node_level=None, fact_level=None):
    """One topic mention in one synthetic conversation, with the given levels."""
    lines = [PREFIX, TOPIC]
    m = (
        "<https://schema.ostler.ai/ontology#topicmention_1> a pwg:TopicMention ;\n"
        "    pwg:mentionsTopic <https://schema.ostler.ai/ontology#topic_synthetic-subject> ;\n"
        '    pwg:topicWeight "3"^^xsd:integer ;\n'
        "    pwg:inConversation <urn:ostler:conversation/synthetic-conv> ;\n"
        '    pwg:validFrom "2026-01-02T03:04:05Z" .\n'
    )
    if mention_level:
        m = m.replace("pwg:validFrom", f'pwg:privacyLevel "{mention_level}" ;\n    pwg:validFrom')
    lines.append(m)
    conv = "<urn:ostler:conversation/synthetic-conv> a <urn:ostler:Conversation> ;\n    <urn:ostler:userId> \"synthetic-owner\""
    if conv_node_level:
        conv += f' ;\n    pwg:privacyLevel "{conv_node_level}"'
    lines.append(conv + " .\n")
    if fact_level:
        lines.append(
            "<urn:ostler:fact/synthetic-fact> <urn:ostler:fromConversation> "
            "<urn:ostler:conversation/synthetic-conv> ;\n"
            f'    <urn:ostler:privacyLevel> "{fact_level}" .\n'
        )
    return "".join(lines)


def _select(store):
    # CM051-LOCAL: this tree's _sparql_select graph-scopes every query (see
    # _graph_scoped in ical-server.py). The harness must do the same, or a
    # named-graph fact is never seen.
    def run(sparql):
        res = store.query(ICAL._graph_scoped(sparql))
        names = [v.value for v in res.variables]
        out = []
        for sol in res:
            out.append({n: (sol[n].value if sol[n] is not None else None) for n in names})
        return out
    return run


def _store(ttl):
    s = ox.Store()
    s.load(ttl.encode("utf-8"), format=ox.RdfFormat.TURTLE)
    return s


class TopicMentionInheritsConversationLevel(unittest.TestCase):

    def _topics(self, ttl):
        with patch.object(ICAL, "_sparql_select", _select(_store(ttl))):
            body, code = ICAL.topics_list()
        self.assertEqual(code, 200)
        return body

    def _mentions(self, ttl):
        with patch.object(ICAL, "_sparql_select", _select(_store(ttl))):
            body, code = ICAL.topic_mentions("synthetic-subject")
        self.assertEqual(code, 200)
        return body

    # --- the red case: CM048's real shape (no level on the mention, L3 on a fact)
    def test_l3_conversation_with_untagged_mention_is_withheld(self):
        ttl = _case(fact_level="L3")
        self.assertEqual(self._topics(ttl)["topics"], [], "L3 conversation topic served")
        self.assertEqual(self._mentions(ttl)["mentions"], [], "L3 conversation mention served")

    def test_l2_twin_with_untagged_mention_is_served(self):
        ttl = _case(fact_level="L2")
        self.assertEqual(len(self._topics(ttl)["topics"]), 1)
        self.assertEqual(len(self._mentions(ttl)["mentions"]), 1)

    def test_l3_on_the_conversation_node_withholds_an_untagged_mention(self):
        ttl = _case(conv_node_level="L3")
        self.assertEqual(self._topics(ttl)["topics"], [])

    def test_mention_level_never_overrides_a_stricter_conversation_level(self):
        ttl = _case(mention_level="L2", fact_level="L3")
        self.assertEqual(self._topics(ttl)["topics"], [])

    def test_l0_on_the_mention_withholds_it(self):
        ttl = _case(mention_level="L0", fact_level="L2")
        self.assertEqual(self._topics(ttl)["topics"], [])
        self.assertEqual(self._topics(ttl)["withheld"]["unknown"], 1)

    def test_an_unreadable_conversation_level_withholds_it(self):
        ttl = _case(fact_level="not-a-level")
        self.assertEqual(self._topics(ttl)["topics"], [])


if __name__ == "__main__":
    unittest.main()


class NamedGraphFactLevelIsRead(unittest.TestCase):
    """CM048's facts live in a named graph. The L3 fact must still withhold."""

    def test_l3_fact_in_a_named_graph_withholds_the_mention(self):
        ttl = _case()  # untagged mention, no conversation level in the default graph
        fact = (
            "GRAPH <urn:ostler:user/synthetic-owner> {\n"
            "  <urn:ostler:fact/synthetic-named> <urn:ostler:fromConversation> "
            "<urn:ostler:conversation/synthetic-conv> ;\n"
            '      <urn:ostler:privacyLevel> "L3" .\n'
            "}\n"
        )
        s = ox.Store()
        s.load(ttl.encode("utf-8"), format=ox.RdfFormat.TURTLE)
        s.load((PREFIX + fact).encode("utf-8"), format=ox.RdfFormat.TRIG)
        with patch.object(ICAL, "_sparql_select", _select(s)), \
                patch.object(ICAL, "_USER_GRAPH_URIS", ["urn:ostler:user/synthetic-owner"]):
            body, code = ICAL.topics_list()
        self.assertEqual(code, 200)
        self.assertEqual(body["topics"], [], "named-graph L3 fact did not withhold")
