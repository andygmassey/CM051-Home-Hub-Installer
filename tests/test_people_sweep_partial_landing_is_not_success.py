"""A PARTIAL people sweep must report an error, not a success.

WHY THIS EXISTS. MEASURED on a real customer install, ten hours after the
install completed: the graph held 8679 Person nodes, the Qdrant ``people``
collection held 8643 points, a gap of 36 that stayed exactly 36 for ten
hours of a catch-up agent running on a DIFFERENT job (duplicate merging,
not vector delivery). Two walk probes went red on it:
``people_stores_reconcile`` (the two stores hold different SETS of people)
and ``people_count_agreement`` (the two TOTALS disagree).

THE MECHANISM. ``ingest_people_to_qdrant``'s only failure guard used to be
``sent == 0``. ``_qdrant_upsert_points`` drops any point carrying an empty
vector and logs-and-continues on a chunk failure, returning only the count
that landed -- so a run that sent 8643 of 8679 came back ``sent=8643``,
which is neither zero nor equal to what was asked for, and fell straight
through the only guard that existed into the "ok" return at the bottom of
the function. install.sh then wrote a success sentinel for the step, and
the sentinel's own freshness window (several days) suppressed the retry
that would otherwise have picked the 36 back up.

This suite drives the REAL ``ingest_people_to_qdrant`` with its network I/O
stubbed, so it cannot pass against a copy of the logic.

Rule 0: every name and URI below is synthetic.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor"))

from ostler_fda import pwg_ingest as mod  # noqa: E402


def _person(n: int) -> dict:
    uri = f"https://schema.ostler.ai/person/synthetic{n:04d}"
    return {
        "uri": uri, "display_name": f"Synthetic Person {n:04d}",
        "contact_type": "person", "organization": "", "job_title": "",
        "given_name": f"Synthetic{n:04d}", "family_name": "", "phones": [],
        "emails": [], "created_at": "",
    }


@pytest.fixture
def harness(monkeypatch):
    """Drive the REAL ingest_people_to_qdrant with its I/O stubbed.

    ``state["upsert_returns"]`` is the count ``_qdrant_upsert_points``
    hands back to the function under test -- the one number a chunk
    failure or an empty-vector drop actually changes in production. Every
    other stage is a clean pass-through so the arms below isolate that one
    variable.
    """
    state: dict = {"people": [], "upsert_returns": None}

    monkeypatch.setattr(mod, "_load_people_from_oxigraph",
                         lambda: state["people"])
    monkeypatch.setattr(mod, "_person_embed_doc", lambda p: "doc")
    monkeypatch.setattr(mod, "_ollama_embed_batch",
                         lambda docs: [[0.1, 0.2]] * len(docs))
    monkeypatch.setattr(mod, "_qdrant_ensure_collection", lambda *a, **k: None)

    def _upsert(collection, points):
        # ``upsert_returns`` is how many of the ASKED points land in the whole
        # sweep. The sweep lands in chunks (PEOPLE_INDEX_CHUNK, v1.0.126), so
        # it is a budget spent across calls, never a per-call constant.
        n = state["upsert_returns"]
        if n is None:
            return len(points)
        take = min(n, len(points))
        state["upsert_returns"] = n - take
        return take

    monkeypatch.setattr(mod, "_qdrant_upsert_points", _upsert)
    # Prune stage: only reachable on a full landing in the fixed code, but
    # stubbed regardless so an unfixed run that reaches it does not explode
    # this suite with an unrelated network error.
    monkeypatch.setattr(mod, "_qdrant_scroll_points", lambda *a, **k: [])
    monkeypatch.setattr(mod, "_qdrant_delete_points", lambda *a, **k: 0)
    return state


def test_a_full_landing_is_still_ok(harness):
    """CONTROL. The fix must not turn a genuinely complete sweep red."""
    harness["people"] = [_person(i) for i in range(10)]
    harness["upsert_returns"] = 10
    res = mod.ingest_people_to_qdrant()
    assert res["status"] == "ok"
    assert res["sent"] == 10
    assert res["total"] == 10


def test_a_zero_landing_is_still_error(harness):
    """CONTROL. The pre-existing all-or-nothing guard must survive untouched."""
    harness["people"] = [_person(i) for i in range(10)]
    harness["upsert_returns"] = 0
    res = mod.ingest_people_to_qdrant()
    assert res["status"] == "error"
    assert res["sent"] == 0
    assert res["total"] == 10


def test_a_partial_landing_is_an_error_not_an_ok(harness):
    """THE ARM THAT MATTERS. This is the exact measured shape: some points
    landed, most did not reach zero, and the old code called that "ok".
    """
    harness["people"] = [_person(i) for i in range(8679)]
    harness["upsert_returns"] = 8643
    res = mod.ingest_people_to_qdrant()
    assert res["status"] != "ok", (
        "a partial landing (8643 of 8679) was reported as a status other "
        "than 'ok' -- OK, this reads as UNFIXED: a partial landing was "
        "reported as success"
    )


def test_a_partial_landing_carries_both_numbers(harness):
    """The report must let a caller compare what was sent to what was
    asked, not merely say something was wrong. install.sh's own comparison
    (sent vs total) depends on both being present and correct even on the
    error path -- a caller cannot suppress a retry it cannot measure.
    """
    harness["people"] = [_person(i) for i in range(8679)]
    harness["upsert_returns"] = 8643
    res = mod.ingest_people_to_qdrant()
    assert res.get("sent") == 8643, "the count that DID land must survive onto the error report"
    assert res.get("total") == 8679, "the count that was ASKED for must survive onto the error report"


def test_a_partial_landing_still_prunes_what_left_the_graph(harness):
    """REVERSED in v1.0.126 (Archie on CM051 #3367). This arm used to require
    that a partial landing never prune, on the grounds that an unreliable
    delivery is no basis for deciding what is stale. The prune does not read
    the delivery: it deletes only points whose person is absent from the graph
    (the snapshot AND a fresh read), so a person whose embed failed is never
    stale. Holding the prune back kept deleted and merged-away people
    searchable for as long as any backlog persisted. It still deletes only
    this sweep's own points.
    """
    deletes: list = []
    harness["people"] = [_person(i) for i in range(20)]
    harness["upsert_returns"] = 15

    def _tracked_delete(collection, ids):
        deletes.extend(ids)
        return len(ids)

    import unittest.mock as mock
    with mock.patch.object(mod, "_qdrant_delete_points", _tracked_delete), \
         mock.patch.object(mod, "_current_person_uris", lambda: None), \
         mock.patch.object(mod, "_qdrant_scroll_points",
                            lambda *a, **k: [
                                {"id": "x", "payload": {
                                    "person_uri": "https://schema.ostler.ai/person/gone",
                                    "source": "fda_people_index"}},
                                {"id": "y", "payload": {
                                    "person_uri": "https://schema.ostler.ai/person/gone2",
                                    "source": "icloud_contacts"}}]):
        res = mod.ingest_people_to_qdrant()
    assert res["status"] == "error" and res.get("reason") == "partial_landing", res
    assert deletes == ["x"], (
        "a partial landing must still prune this sweep's point for a person "
        "who left the graph, and never another writer's: %r" % deletes)
    assert res.get("pruned") == 1, res


def test_a_partial_landing_is_distinguishable_from_a_zero_landing(harness):
    """CANNOT-RUN is a third state here too, in spirit: a partial landing
    and a total failure are different facts and a caller (install.sh)
    must be able to tell them apart, not just see 'error' twice.
    """
    harness["people"] = [_person(i) for i in range(10)]
    harness["upsert_returns"] = 0
    zero_res = mod.ingest_people_to_qdrant()

    harness["upsert_returns"] = 4
    partial_res = mod.ingest_people_to_qdrant()

    assert zero_res["status"] == "error"
    assert partial_res["status"] == "error"
    assert zero_res.get("reason") != partial_res.get("reason"), (
        "a total failure (sent=0) and a partial failure (sent=4 of 10) "
        "reported the identical reason -- a caller cannot tell a fully "
        "dead sweep from one that is nearly complete"
    )
