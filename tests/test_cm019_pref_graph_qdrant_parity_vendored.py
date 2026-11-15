#!/usr/bin/env python3
"""Every preference the SHIPPED ingest writes to the graph has its Qdrant point,
and a re-ingest REPLACES the graph node instead of adding a second value.

Upstream: personal-world-graph #471 (d9797d88), re-vendored into
vendor/cm019_preferences. Found on the v1.0.131 walk box (data_conservation):
preference nodes each carried two pwg:subject literals and two createdAt
values, while Qdrant held one payload per id. The writer is
IngestPipeline._process_batch: the Oxigraph mirror was an INSERT DATA (which
only adds), and it was written before the Qdrant upsert, so a failed upsert
left a typed node with no point.

Drives the VENDORED IngestPipeline._process_batch, the vendored loader's real
SPARQL update text, and a real SPARQL engine (pyoxigraph, the same Rust crate
as the Oxigraph server). The HTTP boundary is the only stub: every update the
loader POSTs is executed against an in-process store. Qdrant is a fake that
records payloads by id. The embedder is stubbed. Synthetic data only.

RED on the pre-graft vendored tree (pin 5af9f5b5): the re-ingest arm reads
two subjects on one node, and the failed-upsert arm leaves a typed node.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import httpx
import pyoxigraph
import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm019_preferences"))

from services.ingest.src import pipeline as pl  # noqa: E402
from services.ingest.src.parsers.base import ParsedPreference  # noqa: E402

PWG = "https://schema.ostler.ai/ontology#"
RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
TYPED = [PWG + "LikePreference", PWG + "DislikePreference", PWG + "NeutralPreference"]


class _Resp:
    status_code = 204
    text = ""


@pytest.fixture
def store(monkeypatch):
    s = pyoxigraph.Store()

    async def fake_post(self, url, content=None, headers=None, **kwargs):
        # The boundary: every SPARQL update the vendored loader sends runs in a
        # real engine. A Turtle body (the old INSERT path) would not parse as
        # an update, so the old code cannot pass by accident here.
        s.update(content)
        return _Resp()

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)
    return s


@pytest.fixture
def pipe(monkeypatch, tmp_path, store):
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("OSTLER_MINORS_FILE", str(tmp_path / "no-minors.json"))
    p = pl.IngestPipeline()
    p.qdrant_points = {}
    p.qdrant_ok = True

    async def upsert_vectors(vectors, payloads, ids=None):
        if not p.qdrant_ok:
            return False
        for pid, payload in zip(ids, payloads):
            p.qdrant_points[pid] = payload
        return True

    monkeypatch.setattr(p.qdrant, "upsert_vectors", upsert_vectors)
    monkeypatch.setattr(pl.vectorizer, "embed_batch", lambda texts, *a, **k: [[0.0] * 4 for _ in texts])
    return p


def _pref(subject, source_id="ORDER-1"):
    return ParsedPreference(
        subject=subject, preference_type="Like", source="amazon",
        source_id=source_id, category="books", compartment_level=2,
    )


def _graph_subjects(store, pid):
    return sorted(
        q.object.value
        for q in store.quads_for_pattern(pyoxigraph.NamedNode(PWG + "pref_" + pid),
                                         pyoxigraph.NamedNode(PWG + "subject"), None, None)
    )


def _typed_node_ids(store):
    ids = set()
    for cls in TYPED:
        for q in store.quads_for_pattern(None, pyoxigraph.NamedNode(RDF_TYPE),
                                         pyoxigraph.NamedNode(cls), None):
            ids.add(q.subject.value.rsplit("pref_", 1)[-1])
    return ids


def _assert_graph_matches_qdrant(store, points):
    assert _typed_node_ids(store) == set(points), "typed nodes and Qdrant points differ"
    for pid, payload in points.items():
        assert _graph_subjects(store, pid) == [payload["subject"]], pid


def _run(pipe, prefs):
    return asyncio.run(pipe._process_batch(prefs, "u"))


def test_control_one_preference_gets_one_node_and_one_point(pipe, store):
    r = _run(pipe, [_pref("Old Title")])
    assert r["vectors"] == 1 and r["triples"] == 1, r
    assert len(pipe.qdrant_points) == 1
    _assert_graph_matches_qdrant(store, pipe.qdrant_points)


def test_reingest_with_changed_subject_replaces_the_graph_value(pipe, store):
    _run(pipe, [_pref("Old Title")])
    r = _run(pipe, [_pref("New Title")])
    assert r["triples"] == 1, r
    pid = next(iter(pipe.qdrant_points))
    assert _graph_subjects(store, pid) == ["New Title"], "graph kept the old subject beside the new"
    _assert_graph_matches_qdrant(store, pipe.qdrant_points)


def test_failed_qdrant_write_leaves_no_typed_node_without_a_point(pipe, store):
    pipe.qdrant_ok = False
    r = _run(pipe, [_pref("Old Title")])
    assert r["triples"] == 0 and r["errors"], r
    assert _typed_node_ids(store) == set(), "a typed node was written with no Qdrant point"
    _assert_graph_matches_qdrant(store, pipe.qdrant_points)


def test_reingest_of_two_preferences_keeps_one_node_each(pipe, store):
    _run(pipe, [_pref("Book A", "ORDER-A"), _pref("Book B", "ORDER-B")])
    _run(pipe, [_pref("Book A", "ORDER-A"), _pref("Book B", "ORDER-B")])
    assert len(pipe.qdrant_points) == 2
    _assert_graph_matches_qdrant(store, pipe.qdrant_points)
