"""The assistant's decisions tool and the wiki Decisions page read ONE store.

Wow gate item 2 (v1.0.108). The wiki Decisions page (CM044
compiler/pwg_data.py load_decision_facts -> compiler/pages/decision_pages.py)
reads the Qdrant ``conversations`` collection, keeping ``type == "decision"``.
The assistant's ``pwg_decisions`` tool hits GET /api/v1/decisions ->
``decisions_list``, which used to read only Oxigraph ``pwg:Decision`` nodes. So
a decision the owner could see in the wiki could not be found by the assistant.

Every name and sentence below is synthetic.
"""
from __future__ import annotations

import io
import json
from unittest.mock import patch

from .test_people_list_endpoint import server

WIKI_STORE_POINTS = [
    {"id": "d1", "payload": {"type": "decision", "text": "Switch the supplier to Acme freight",
                             "subject": "user", "conversation_id": "conv-a",
                             "ingested_at": "2026-09-01T10:00:00Z", "sensitivity_level": "L1",
                             "privacy_level": "L1", "domain": "work"}},
    {"id": "d2", "payload": {"type": "decision", "text": "Book the lake house for August",
                             "subject": "person:jane-doe", "conversation_id": "conv-b",
                             "ingested_at": "2026-09-05T10:00:00Z", "sensitivity_level": "L1",
                             "privacy_level": "L1", "domain": "family"}},
    {"id": "d3", "payload": {"type": "decision", "text": "A private matter",
                             "subject": "user", "conversation_id": "conv-c",
                             "ingested_at": "2026-09-06T10:00:00Z", "sensitivity_level": "L3",
                             "privacy_level": "L2"}},
    {"id": "f1", "payload": {"type": "commitment", "text": "Send the deck", "conversation_id": "conv-a"}},
]


def _wiki_loader(points):
    """CM044 load_decision_facts, reduced to its filter: type == decision."""
    return [p["payload"] for p in points
            if (p["payload"].get("type") or "").strip().lower() == "decision"]


class _Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _fake_urlopen(points):
    def _open(req, timeout=None):
        body = json.loads(req.data.decode())
        musts = (body.get("filter") or {}).get("must") or []
        out = points
        for m in musts:
            if m.get("key") == "type":
                out = [p for p in out if p["payload"].get("type") == m["match"]["value"]]
        return _Resp(json.dumps({"result": {"points": out, "next_page_offset": None}}).encode())
    return _open


def _call(graph_rows=None, points=WIKI_STORE_POINTS, **kw):
    def fake_select(q):
        if "a pwg:Decision" in q and "decisionSummary" in q:
            return list(graph_rows or [])
        if "pwg:decisionAbout ?p" in q:
            return []
        return []
    with patch.object(server, "_sparql_select", side_effect=fake_select), \
         patch.object(server.urllib.request, "urlopen", _fake_urlopen(points)):
        return server.decisions_list(**kw)


def test_every_decision_the_wiki_lists_is_found_by_the_tool():
    body, status = _call()
    assert status == 200
    found = {d["summary"] for d in body["decisions"]}
    wiki_visible = {p["text"] for p in _wiki_loader(WIKI_STORE_POINTS)
                    if str(p.get("sensitivity_level")).upper() != "L3"}
    assert wiki_visible, "denominator: the wiki must list at least one decision"
    assert wiki_visible <= found, "the owner sees decisions in the wiki that the assistant cannot find"


def test_a_private_decision_is_withheld_from_the_assistant():
    body, _ = _call()
    assert "A private matter" not in {d["summary"] for d in body["decisions"]}


def test_a_non_decision_fact_is_never_listed():
    body, _ = _call()
    assert "Send the deck" not in {d["summary"] for d in body["decisions"]}


def test_the_graph_only_decision_is_still_found_and_duplicates_collapse():
    graph = [{"d": "urn:d1", "summary": "Hire a second engineer", "date": "2026-08-01"},
             {"d": "urn:d2", "summary": "Switch the supplier to Acme freight", "date": "2026-09-01"}]
    body, _ = _call(graph_rows=graph)
    texts = [d["summary"] for d in body["decisions"]]
    assert "Hire a second engineer" in texts
    assert texts.count("Switch the supplier to Acme freight") == 1


def test_query_and_about_filters_apply_to_the_wiki_store():
    body, _ = _call(query="lake")
    assert [d["summary"] for d in body["decisions"]] == ["Book the lake house for August"]
    body, _ = _call(about="jane-doe")
    # the slug resolves through the graph in this module; with no person in the
    # fake graph the call short-circuits to an empty, non-error answer
    assert body["count"] == 0


def test_an_unreadable_conversations_store_is_reported_not_hidden():
    def boom(req, timeout=None):
        raise OSError("down")
    with patch.object(server, "_sparql_select", return_value=[]), \
         patch.object(server.urllib.request, "urlopen", boom):
        body, status = server.decisions_list()
    assert status == 200 and body["conversations_unreadable"]
