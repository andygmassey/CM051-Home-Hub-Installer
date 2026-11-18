"""api_memory_list releases an L3 fact only to owner_local (3582 ruling 3).

GET /api/v1/memory answers for a request's declared destination. An L3 fact,
or an owner instruction with no level, must reach owner_local only. Any other
destination (cloud_model, owner_own_brief, unknown) must see it withheld and
counted in withheld_private. The about-others split must also hold for an
L2 neighbour fact that the owner is allowed to see on owner_local.

Runs the REAL query the reader builds against an rdflib Dataset, feeds the
rows through the real api_memory_list, and reads the response. Synthetic cast
names only.

STRAIGHT arm: test_l3_fact_is_withheld_from_a_non_owner_destination goes red
against a reader whose outbound gate is switched off (scratch mutant, see
the mutant arm below). Controls: the owner_local arm still serves the L3 fact.
"""
from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

import pytest

rdflib = pytest.importorskip("rdflib")

REPO = Path(__file__).resolve().parent.parent
OWNER_L3 = "Keeps the spare key under the blue pot"
OWNER_L2 = "Prefers window seats on trains"
NEIGHBOUR_L2 = "Sam Patel is speaking at the Harbourtown summit"

FIXTURE = f"""
@prefix pwg: <https://schema.ostler.ai/ontology#> .
<urn:ostler:user/Fixture> {{
    <urn:ostler:fact/l3> a <urn:ostler:Fact> ;
        <urn:ostler:text> "{OWNER_L3}" ;
        <urn:ostler:userId> "Fixture" ;
        <urn:ostler:about> <urn:ostler:user/Fixture> ;
        <urn:ostler:privacyLevel> "L3" ; <urn:ostler:signalStrength> "strong" .
    <urn:ostler:fact/l2> a <urn:ostler:Fact> ;
        <urn:ostler:text> "{OWNER_L2}" ;
        <urn:ostler:userId> "Fixture" ;
        <urn:ostler:about> <urn:ostler:user/Fixture> ;
        <urn:ostler:privacyLevel> "L2" ; <urn:ostler:signalStrength> "medium" .
    <urn:ostler:fact/neighbour> a <urn:ostler:Fact> ;
        <urn:ostler:text> "{NEIGHBOUR_L2}" ;
        <urn:ostler:userId> "Fixture" ;
        <urn:ostler:about> <urn:ostler:person/sam_patel> ;
        <urn:ostler:privacyLevel> "L2" ; <urn:ostler:signalStrength> "strong" .
}}
"""


def _load(source=None):
    os.environ["USER_ID"] = "Fixture"
    sys.path.insert(0, str(REPO / "vendor" / "cm041"))
    path = REPO / "vendor" / "cm041" / "assistant_api" / "ical-server.py"
    spec = importlib.util.spec_from_file_location("ical_server_l3_dest", path)
    mod = importlib.util.module_from_spec(spec)
    code = source if source is not None else path.read_text(encoding="utf-8")
    exec(compile(code, str(path), "exec"), mod.__dict__)
    return mod


def _response(mod, monkeypatch, destination):
    ds = rdflib.Dataset()
    ds.parse(data=FIXTURE, format="trig")

    def select(q):
        return [{str(k): str(v) for k, v in r.asdict().items() if v is not None}
                for r in ds.query(q)]

    monkeypatch.setattr(mod, "_sparql_select", select)
    monkeypatch.setattr(mod, "_memory_load_corrections", lambda: {})
    monkeypatch.setattr(mod, "_hygiene_overlay", lambda: (None, {}))
    monkeypatch.setattr(mod, "_current_employer_safe", lambda *a, **k: {})
    monkeypatch.setattr(mod, "_owner_instruction_facts",
                        lambda destination=None, withheld=None: [])
    return mod.api_memory_list(destination=destination)


def _texts(rows):
    return {r.get("object") for r in rows}


def test_l3_fact_is_withheld_from_a_non_owner_destination(monkeypatch):
    mod = _load()
    for dest in ("cloud_model", "owner_own_brief", "unknown"):
        out = _response(mod, monkeypatch, dest)
        assert OWNER_L3 not in _texts(out["facts"]), dest
        assert out["withheld_private"] >= 1, dest


def test_control_owner_local_serves_the_l3_fact(monkeypatch):
    mod = _load()
    out = _response(mod, monkeypatch, "owner_local")
    assert OWNER_L3 in _texts(out["facts"])


def test_control_l2_owner_fact_is_served_on_owner_local(monkeypatch):
    mod = _load()
    out = _response(mod, monkeypatch, "owner_local")
    assert OWNER_L2 in _texts(out["facts"])


def test_about_others_split_holds_on_owner_local(monkeypatch):
    mod = _load()
    out = _response(mod, monkeypatch, "owner_local")
    assert NEIGHBOUR_L2 not in _texts(out["facts"])
    assert NEIGHBOUR_L2 in _texts(out["about_others"])


def test_mutant_with_the_outbound_gate_off_is_caught(monkeypatch):
    # Scratch proof: a reader whose outbound gate never withholds must fail
    # the non-owner arm. The assertion below is the one that must fire.
    path = REPO / "vendor" / "cm041" / "assistant_api" / "ical-server.py"
    real = path.read_text(encoding="utf-8")
    needle = "if _pr.outbound_hidden(_rec, _owner_lvl, destination):"
    assert real.count(needle) == 1, "mutant anchor not found"
    mutant = real.replace(needle, "if False:")
    assert mutant != real, "mutation did not apply"
    mod = _load(source=mutant)
    with pytest.raises(AssertionError):
        test_l3_fact_is_withheld_from_a_non_owner_destination.__wrapped__(mod, monkeypatch) \
            if hasattr(test_l3_fact_is_withheld_from_a_non_owner_destination, "__wrapped__") \
            else _assert_non_owner_withheld(mod, monkeypatch)


def _assert_non_owner_withheld(mod, monkeypatch):
    for dest in ("cloud_model", "owner_own_brief", "unknown"):
        out = _response(mod, monkeypatch, dest)
        assert OWNER_L3 not in _texts(out["facts"]), dest
