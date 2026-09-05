"""The people sweep is a PROJECTION, so it must remove as well as add.

WHY THIS EXISTS. MEASURED on archie@192.168.1.240 with v1.0.67 installed,
2026-09-05: the Qdrant ``people`` collection held 1907 points while Oxigraph
held 1823 Person nodes, and the difference was exactly 84 points whose
``person_uri`` had NO presence anywhere in the graph -- not as a subject, not as
an object. All 84 were stamped ``source=fda_people_index`` and all 84 carried a
full contact payload (display name, organisation, job title, phones, emails).

``ingest_people_to_qdrant`` READS Oxigraph and WRITES Qdrant. It cannot create a
point without a Person node, so it could only ever ADD: a node that LEFT the
graph left its point behind permanently. The function contained no delete, and
the module contained no Qdrant delete at all.

The customer saw it twice: the People count the Doctor reports is the vector
store's (1907) while the graph said 1823, and a person removed from the graph
stayed searchable.

⚠️ THE DANGEROUS PART OF THIS FIX IS THE FIX, NOT THE BUG. A prune driven by a
failed read deletes the customer's entire people index. Arm 4 is the one that
matters most here; the others could all pass while arm 4 is broken, and the
result would be catastrophic rather than merely wrong.

Rule 0: every name below is synthetic.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor"))

from ostler_fda import pwg_ingest as mod  # noqa: E402

URI_KEPT = "https://schema.ostler.ai/person/kept0001"
URI_GONE = "https://schema.ostler.ai/person/gone0002"
URI_CONTACT = "https://schema.ostler.ai/person/contact0003"


def _person(uri: str, name: str) -> dict:
    return {
        "uri": uri, "display_name": name, "contact_type": "person",
        "organization": "", "job_title": "", "given_name": name,
        "family_name": "", "phones": [], "emails": [], "created_at": "",
    }


def _point(pid: str, uri: str, source: str) -> dict:
    return {"id": pid, "payload": {"person_uri": uri, "source": source}}


@pytest.fixture
def harness(monkeypatch):
    """Drive the REAL ingest_people_to_qdrant with its I/O stubbed.

    Returns a dict the test mutates to set up each scenario, and which
    collects what the function tried to delete.
    """
    state: dict = {"deleted": [], "scroll": [], "scroll_fails": False}

    # Oxigraph currently holds ONE person: URI_KEPT.
    monkeypatch.setattr(mod, "_load_people_from_oxigraph",
                        lambda: [_person(URI_KEPT, "Alder")])
    monkeypatch.setattr(mod, "_person_embed_doc", lambda p: "doc")
    monkeypatch.setattr(mod, "_ollama_embed_batch", lambda docs: [[0.1, 0.2]] * len(docs))
    monkeypatch.setattr(mod, "_qdrant_ensure_collection", lambda *a, **k: None)
    monkeypatch.setattr(mod, "_qdrant_upsert_points", lambda c, pts: len(pts))

    def _scroll(collection, limit=1000):
        if state["scroll_fails"]:
            return None
        return state["scroll"]

    def _delete(collection, ids):
        state["deleted"].extend(ids)
        return len(ids)

    monkeypatch.setattr(mod, "_qdrant_scroll_points", _scroll)
    monkeypatch.setattr(mod, "_qdrant_delete_points", _delete)
    return state


def test_a_point_whose_person_left_the_graph_is_pruned(harness):
    harness["scroll"] = [
        _point("p-kept", URI_KEPT, "fda_people_index"),
        _point("p-gone", URI_GONE, "fda_people_index"),
    ]
    res = mod.ingest_people_to_qdrant()
    assert res["status"] == "ok"
    assert harness["deleted"] == ["p-gone"], (
        "the orphaned projection point was not pruned; this is the measured "
        "84-orphan defect"
    )


def test_a_point_still_in_the_graph_is_never_pruned(harness):
    """MUST-MISS. A prune that also removes current people is worse than none."""
    harness["scroll"] = [_point("p-kept", URI_KEPT, "fda_people_index")]
    mod.ingest_people_to_qdrant()
    assert harness["deleted"] == [], "a CURRENT person was pruned"


def test_points_this_sweep_does_not_own_are_never_pruned(harness):
    """MUST-MISS, and the one with the widest blast radius.

    contact_syncer writes source='icloud_contacts' into the SAME collection.
    This sweep reads Oxigraph only and knows nothing about which contacts are
    current, so an icloud_contacts point absent from its projection is NOT
    evidence of anything. Measured on the box: 1610 of 1907 points are
    icloud_contacts, so a source-blind prune would delete most of the
    customer's address book from search.
    """
    harness["scroll"] = [
        _point("p-contact", URI_CONTACT, "icloud_contacts"),
        _point("p-gone", URI_GONE, "fda_people_index"),
    ]
    mod.ingest_people_to_qdrant()
    assert "p-contact" not in harness["deleted"], (
        "an icloud_contacts point was pruned by a sweep that does not own it"
    )
    assert harness["deleted"] == ["p-gone"]


def test_a_failed_read_prunes_nothing(harness):
    """THE ARM THAT MATTERS MOST.

    _qdrant_scroll_points returns None on any failure. An empty list from a
    broken read and a genuinely empty collection are indistinguishable by
    value, and treating the first as the second authorises deleting every
    point in the collection. A zero denominator must never authorise a delete.
    """
    harness["scroll_fails"] = True
    res = mod.ingest_people_to_qdrant()
    assert res["status"] == "ok", "a failed prune-read must not fail the ingest"
    assert harness["deleted"] == [], (
        "a FAILED READ authorised deletes -- this would wipe the customer's "
        "people index"
    )
    assert res.get("pruned") is None, (
        "a failed read must report pruned=None (could not look), not 0 "
        "(looked, found nothing)"
    )


def test_pruned_zero_and_pruned_none_are_different_answers(harness):
    """CANNOT-RUN is a third state here too.

    pruned=0 means the sweep looked and there was nothing stale.
    pruned=None means it could not look. Collapsing them would hide a
    permanently failing read behind a reassuring zero.
    """
    harness["scroll"] = [_point("p-kept", URI_KEPT, "fda_people_index")]
    assert mod.ingest_people_to_qdrant().get("pruned") == 0
    harness["scroll_fails"] = True
    assert mod.ingest_people_to_qdrant().get("pruned") is None
