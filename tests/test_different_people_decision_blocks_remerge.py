""""No, different people" (#2876) is honoured by every merge path.

The decision is the `distinct` entry the wiki's "Not the same" answer writes
to duplicates.yaml (Doctor duplicate_decision.write_decision). The resolver's
detect() already drops such a pair, but two paths could still join it:

  1. batch execute(): a converge round PLANS first and EXECUTES later. A
     decision recorded in between (the customer answers while a converge
     runs) used to be ignored by the stale plan, which re-merged the pair
     through the exact-identifier override.
  2. ingest: IdentityResolver.resolve() collapses every node an incoming
     identity's exact identifiers point at (RULE 1). RULE 2 refuses two
     Contacts cards with different card uids, but a pair WITHOUT differing
     uids had nothing between it and merge_persons().

Real BatchResolver / IdentityResolver against in-memory rdflib stores.
SYNTHETIC DATA ONLY: approved cast, example.com, Ofcom drama range numbers.
"""
from __future__ import annotations

import os
import sys

import pytest

pytest.importorskip("qdrant_client")
pytest.importorskip("yaml")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import test_exact_identifier_merge as tx  # noqa: E402
from test_exact_identifier_merge import FakeStore, make, MOBILE_A  # noqa: E402
import test_nameless_records_sharing_a_number_are_one_person as tn  # noqa: E402

_no_qdrant = tx._no_qdrant   # autouse in-memory Qdrant for the batch tests
store = tn.store             # rdflib behind real loopback HTTP for the ingest tests

EMAIL = "jane.doe@example.com"
LANDLINE = "+442079460777"   # Ofcom drama range


def _distinct(corr, a, b):
    corr.mkdir(parents=True, exist_ok=True)
    (corr / "duplicates.yaml").write_text(
        "decisions:\n- distinct: [%s, %s]\n" % (a, b), encoding="utf-8")


# -- 1. batch execute() -------------------------------------------------------

def _planned_pair(tmp_path):
    s = FakeStore()
    s.person("cc33", "Jane Doe", phones=[MOBILE_A], uids=["uid-c"])
    s.person("dd44", "Jane Doe", phones=[MOBILE_A], uids=["uid-d"])
    r = make(s, tmp_path)
    report = r.detect()
    assert report.auto_merges, "precondition: the pair is planned"
    return s, r, report


def test_a_decision_between_plan_and_execute_is_honoured(tmp_path):
    s, r, report = _planned_pair(tmp_path)
    _distinct(tmp_path / "corr", "cc33", "dd44")      # lands after the plan
    r.execute(report, backup_dir=str(tmp_path / "bk"))
    assert len(s.live()) == 2


def test_control_without_a_decision_the_same_plan_merges(tmp_path):
    s, r, report = _planned_pair(tmp_path)
    r.execute(report, backup_dir=str(tmp_path / "bk"))
    assert len(s.live()) == 1


# -- 2. ingest (IdentityResolver.resolve, RULE 1 collapse) --------------------

def _split_pair(g):
    """Two nodes, same name, NO card uids (so RULE 2 has nothing to refuse):
    one holds the email, the other the landline."""
    a = tn.add_person(g, 1, "Jane Doe", email=EMAIL)
    b = tn.add_person(g, 2, "Jane Doe", phone=LANDLINE)
    return a, b


def _live(g):
    q = ("PREFIX pwg: <%s> SELECT ?p WHERE { ?p a pwg:Person . "
         "FILTER NOT EXISTS { ?p pwg:mergedInto ?m } }" % tn.PWG)
    return {str(r[0]) for r in g.query(q)}


def _ingest(g, monkeypatch, corr):
    from identity_resolver.models import PersonIdentity
    monkeypatch.setenv("WIKI_CORRECTIONS_DIR", str(corr))
    r = tn.resolver(g)
    return r.resolve(PersonIdentity(display_name="Jane Doe", emails=[EMAIL],
                                    phones=[LANDLINE]), use_fuzzy=False)


def test_ingest_honours_a_different_people_decision(store, monkeypatch, tmp_path):
    a, b = _split_pair(store)
    _distinct(tmp_path / "corr", "fixture1", "fixture2")
    _ingest(store, monkeypatch, tmp_path / "corr")
    assert len(_live(store)) == 2, "a recorded 'different people' pair was re-merged at ingest"


def test_control_ingest_without_a_decision_collapses_the_pair(store, monkeypatch, tmp_path):
    _split_pair(store)
    _ingest(store, monkeypatch, tmp_path / "corr")
    assert len(_live(store)) == 1
