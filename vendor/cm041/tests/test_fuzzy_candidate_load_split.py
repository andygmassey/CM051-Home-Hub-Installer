"""Fast fuzzy-candidate load: two flat queries instead of a nested OPTIONAL
join (Fix A, next-cut).

The single-query ``_load_fuzzy_candidates`` joined linkedin_url via a
per-Person OPTIONAL chain (``?person hasIdentifier ?lid . ?lid
identifierType "linkedin_url" ; identifierValue ?linkedinUrl``). Oxigraph
evaluates that join poorly at scale -- on the live Studio install
(~4,700 persons / ~4,300 identifiers) it measured 53s, over the resolver's
own 30s HTTP timeout, so even this once-per-run load pegged Oxigraph and
stalled the LinkedIn-messages import. These tests pin the split: two FLAT
queries joined in Python, identical candidate output.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from identity_resolver.resolver import IdentityResolver  # noqa: E402


def _binding(**cols):
    return {k: {"value": v} for k, v in cols.items()}


def test_load_fuzzy_candidates_splits_into_two_flat_queries(monkeypatch):
    resolver = IdentityResolver(oxigraph_url="http://localhost:0")
    captured: list[str] = []

    def fake_query(sparql: str):
        captured.append(sparql)
        if "linkedin_url" in sparql:
            # Query 2: person -> linkedin_url (flat).
            return {"results": {"bindings": [
                _binding(person="uri:a", linkedinUrl="https://lnkd/alex"),
            ]}}
        # Query 1: person + name + (optional) org.
        return {"results": {"bindings": [
            _binding(person="uri:a", name="Alex Stone", org="Acme"),
            _binding(person="uri:b", name="Sam Reed"),  # no org, no linkedin
        ]}}

    monkeypatch.setattr(resolver, "_sparql_query", fake_query)
    resolver._load_fuzzy_candidates()

    cands = {c["person"]: c for c in resolver._fuzzy_candidates}

    # The Python join must reproduce the old single-query output exactly:
    # uri:a picks up its linkedin url from query 2; uri:b has none.
    assert cands["uri:a"]["name"] == "Alex Stone"
    assert cands["uri:a"]["org"] == "Acme"
    assert cands["uri:a"]["linkedinUrl"] == "https://lnkd/alex"
    assert cands["uri:b"]["name"] == "Sam Reed"
    assert cands["uri:b"]["org"] is None
    assert cands["uri:b"]["linkedinUrl"] is None

    # Exactly two queries, both FLAT.
    assert len(captured) == 2
    people_q = next(q for q in captured if "linkedin_url" not in q)
    assert "hasIdentifier" not in people_q, (
        "the people query must not join identifiers -- that join was the "
        "O(scale) cost that stalled the install"
    )
    linkedin_q = next(q for q in captured if "linkedin_url" in q)
    assert "OPTIONAL" not in linkedin_q, (
        "the linkedin query must be a flat SELECT, not an OPTIONAL join"
    )


def test_load_fuzzy_candidates_dedupes_multiple_linkedin_rows(monkeypatch):
    """If a person somehow has >1 linkedin_url identifier, keep the first --
    matches the LIMIT-free single-query behaviour (first binding wins)."""
    resolver = IdentityResolver(oxigraph_url="http://localhost:0")

    def fake_query(sparql: str):
        if "linkedin_url" in sparql:
            return {"results": {"bindings": [
                _binding(person="uri:a", linkedinUrl="https://lnkd/first"),
                _binding(person="uri:a", linkedinUrl="https://lnkd/second"),
            ]}}
        return {"results": {"bindings": [
            _binding(person="uri:a", name="Alex Stone"),
        ]}}

    monkeypatch.setattr(resolver, "_sparql_query", fake_query)
    resolver._load_fuzzy_candidates()

    assert resolver._fuzzy_candidates[0]["linkedinUrl"] == "https://lnkd/first"
