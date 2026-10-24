"""F12b (cut #17 iOS walk): GET /api/v1/memory "About you" must hold only the
owner's facts.

The walk showed facts about OTHER people (a contact speaking at an event, a
relative's job) listed as the owner's. The reader scopes by whose memory a
fact is in (CM048 urn:ostler:userId, pwg:belongsToUser), never by who it is
ABOUT (urn:ostler:about, pwg:aboutPerson). Same root as F12 (#2770), at the
iOS reader.

Runs the REAL query the shipped reader builds against a real SPARQL engine
(rdflib Dataset with the named graph), feeds the real rows through the real
api_memory_list, and reads the response body. Synthetic cast names only.

STRAIGHT arm: test_a_neighbours_fact_is_absent_from_about_you FAILS on the
pre-fix reader and passes with the fix. Controls: the owner's tagged and
untagged facts stay in "facts"; the neighbour facts are in the store and in
the query's rows, so their absence from "facts" is the split, not a blind query.
"""
from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

import pytest

rdflib = pytest.importorskip("rdflib")

REPO = Path(__file__).resolve().parent.parent

NEIGHBOUR_TALK = "Sam Patel is speaking at the Harbourtown summit"
NEIGHBOUR_JOB = "Liz Doe works as a creative technologist"
OWNER_TAGGED = "Prefers aisle seats on long flights"
OWNER_LEGACY = "Keeps a sketchbook"

FIXTURE = f"""
@prefix pwg: <https://schema.ostler.ai/ontology#> .
<urn:ostler:user/Fixture> {{
    <urn:ostler:fact/own> a <urn:ostler:Fact> ;
        <urn:ostler:text> "{OWNER_TAGGED}" ;
        <urn:ostler:userId> "Fixture" ;
        <urn:ostler:about> <urn:ostler:user/Fixture> ;
        <urn:ostler:privacyLevel> "L0" ; <urn:ostler:signalStrength> "strong" .
    <urn:ostler:fact/legacy> a <urn:ostler:Fact> ;
        <urn:ostler:text> "{OWNER_LEGACY}" ;
        <urn:ostler:userId> "Fixture" ;
        <urn:ostler:privacyLevel> "L0" ; <urn:ostler:signalStrength> "medium" .
    <urn:ostler:fact/talk> a <urn:ostler:Fact> ;
        <urn:ostler:text> "{NEIGHBOUR_TALK}" ;
        <urn:ostler:userId> "Fixture" ;
        <urn:ostler:about> <urn:ostler:person/sam_patel> ;
        <urn:ostler:privacyLevel> "L0" ; <urn:ostler:signalStrength> "strong" .
}}
{{
    <https://schema.ostler.ai/ontology#fact_job> a pwg:PersonFact ;
        pwg:factText "{NEIGHBOUR_JOB}" ;
        pwg:belongsToUser <https://schema.ostler.ai/ontology#user_fixture> ;
        pwg:aboutPerson <https://schema.ostler.ai/ontology#person_liz> ;
        pwg:confidence "0.8" .
    <https://schema.ostler.ai/ontology#person_liz> pwg:displayName "Liz Doe" .
}}
"""


def _load():
    os.environ["USER_ID"] = "Fixture"
    sys.path.insert(0, str(REPO / "vendor" / "cm041"))
    spec = importlib.util.spec_from_file_location(
        "ical_server_f12b", REPO / "vendor" / "cm041" / "assistant_api" / "ical-server.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture()
def body(monkeypatch):
    srv = _load()
    ds = rdflib.Dataset()
    ds.parse(data=FIXTURE, format="trig")
    seen = {}

    def select(q):
        rows = [{str(k): str(v) for k, v in r.asdict().items() if v is not None}
                for r in ds.query(q)]
        seen["rows"] = rows
        return rows

    monkeypatch.setattr(srv, "_sparql_select", select)
    monkeypatch.setattr(srv, "_memory_load_corrections", lambda: {})
    monkeypatch.setattr(srv, "_hygiene_overlay", lambda: (None, {}))
    monkeypatch.setattr(srv, "_current_employer_safe", lambda: {})
    out = srv.api_memory_list()
    out["_rows"] = seen.get("rows", [])
    return out


def _texts(facts):
    return [f.get("object") for f in facts]


def test_a_neighbours_fact_is_absent_from_about_you(body):
    about_you = _texts(body["facts"])
    print(f"\n[F12b] facts={about_you}")
    assert NEIGHBOUR_TALK not in about_you, f"a contact's fact is in About you: {about_you}"
    assert NEIGHBOUR_JOB not in about_you, f"a relative's job is in About you: {about_you}"
    assert body["count"] == len(body["facts"])


def test_control_the_query_returns_the_neighbour_rows(body):
    texts = [r.get("text") for r in body["_rows"]]
    assert NEIGHBOUR_TALK in texts and NEIGHBOUR_JOB in texts


def test_control_the_owners_own_facts_stay_in_about_you(body):
    about_you = _texts(body["facts"])
    assert OWNER_TAGGED in about_you and OWNER_LEGACY in about_you


def test_facts_about_others_are_kept_with_their_subject(body):
    others = {f["object"]: f.get("about_name") for f in body.get("about_others", [])}
    print(f"\n[F12b] about_others={others}")
    assert NEIGHBOUR_TALK in others and others.get(NEIGHBOUR_JOB) == "Liz Doe"
