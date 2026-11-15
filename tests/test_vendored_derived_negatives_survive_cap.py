"""A stated dislike must not fall off the route's cap (v1.0.121 walk, Mini16).

The route round-robins by category and THEN applies ``limit``; on a 312-node
graph the seeded dislike ranked 186th and a limit=8 consumer never saw it. The
route now appends every negative-strength item above min_confidence ALONGSIDE the
capped list, whatever the tier, bounded separately (NEGATIVES_LIMIT, strongest
|strength| x confidence first, not counted against ``limit``).

Real in-memory pyoxigraph store, so the SPARQL (filters, order) is exercised.
Synthetic data only.
"""

import sys
from pathlib import Path

import pytest

ox = pytest.importorskip("pyoxigraph")

# The VENDORED hub route module (vendor/cm041/assistant_api); canonical copy and
# the same test: CM041 assistant_api/tests/test_derived_preferences_negatives.py.
_AAPI = Path(__file__).resolve().parents[1] / "vendor" / "cm041" / "assistant_api"
if str(_AAPI) not in sys.path:
    sys.path.insert(0, str(_AAPI))

from derived_preferences import (  # noqa: E402
    DERIVED_GRAPH,
    NEGATIVES_LIMIT,
    PWG_NS,
    DerivedGraphReader,
    build_derived_preferences_response,
)

SYNTH_USER = "synthetic_owner_01"
_DBL = ox.NamedNode("http://www.w3.org/2001/XMLSchema#double")
_TYPE = ox.NamedNode("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")


def _add(store, nid, label, strength, conf, category, tier="specific", level=None):
    g = ox.NamedNode(DERIVED_GRAPH)
    s = ox.NamedNode(f"urn:synthetic:derived:{nid}")
    quads = [
        (_TYPE, ox.NamedNode(PWG_NS + "DerivedPreference")),
        (ox.NamedNode(PWG_NS + "dimension"), ox.Literal(f"dim.{category}")),
        (ox.NamedNode(PWG_NS + "subject"), ox.Literal(label)),
        (ox.NamedNode(PWG_NS + "preferenceStrength"), ox.Literal(str(strength), datatype=_DBL)),
        (ox.NamedNode(PWG_NS + "confidence"), ox.Literal(str(conf), datatype=_DBL)),
        (ox.NamedNode(PWG_NS + "category"), ox.Literal(category)),
        (ox.NamedNode(PWG_NS + "tier"), ox.Literal(tier)),
    ]
    if level:
        quads.append((ox.NamedNode(PWG_NS + "privacyLevel"), ox.Literal(level)))
    for p, o in quads:
        store.add(ox.Quad(s, p, o, g))


def _sparql(store):
    def run(q):
        res = store.query(q)
        names = [v.value for v in res.variables]
        return [{n: sol[i].value for i, n in enumerate(names) if sol[i] is not None}
                for sol in res]
    return run


def _route(store, **kw):
    return build_derived_preferences_response(
        DerivedGraphReader(_sparql(store)), SYNTH_USER, **kw)


def _labels(resp):
    return [i["label"] for i in resp["items"]]


def _big_store(n=320):
    """n likes across 20 categories at high confidence, one low-confidence dislike."""
    store = ox.Store()
    for k in range(n):
        _add(store, f"like{k}", f"synthetic like {k}", 0.9, round(0.95 - k * 0.0015, 4), f"cat{k % 20}")
    _add(store, "dislike", "synthetic coriander", -0.7, 0.62, "food", tier="specific")
    return store


def test_low_ranked_dislike_is_served_with_a_small_cap_and_no_tier():
    resp = _route(_big_store(), limit=8)  # tier=None: the consumers' shape
    assert "synthetic coriander" in _labels(resp)
    assert resp["degraded"] is False


def test_low_ranked_dislike_is_served_for_every_tier_filter():
    for tier in ("all", "specific", "broad"):
        assert "synthetic coriander" in _labels(_route(_big_store(), limit=8, tier=tier)), tier


def test_capped_list_is_still_capped_plus_the_negatives():
    resp = _route(_big_store(), limit=8, tier="all")
    assert len(resp["items"]) == 8 + 1


def test_negatives_are_bounded_at_100_strongest_first():
    store = ox.Store()
    _add(store, "like", "synthetic like", 0.9, 0.9, "films")
    for k in range(130):
        # |strength| x confidence grows with k, so the strongest are the last ones.
        _add(store, f"neg{k}", f"synthetic neg {k:03d}", -(0.3 + k * 0.004), 0.5 + k * 0.003, f"c{k % 7}")
    resp = _route(store, limit=1, tier="all")
    negs = [i for i in resp["items"] if i["strength"] < 0]
    assert NEGATIVES_LIMIT == 100 and len(negs) == 100
    assert len(resp["items"]) == 1 + 100  # not counted against limit
    scores = [abs(i["strength"]) * i["confidence"] for i in negs]
    assert scores == sorted(scores, reverse=True)
    assert negs[0]["label"] == "synthetic neg 129"
    assert "synthetic neg 029" not in _labels(resp) and "synthetic neg 030" in _labels(resp)


def test_sensitive_gated_negative_does_not_appear():
    store = ox.Store()
    _add(store, "like", "synthetic like", 0.9, 0.9, "films")
    _add(store, "ok", "synthetic visible dislike", -0.8, 0.8, "food", level="L1")
    _add(store, "l3", "synthetic sealed dislike", -0.9, 0.9, "health", level="L3")
    _add(store, "odd", "synthetic odd-level dislike", -0.9, 0.9, "health", level="secret")
    labels = _labels(_route(store, limit=8, tier="all"))
    assert "synthetic visible dislike" in labels
    assert "synthetic sealed dislike" not in labels
    assert "synthetic odd-level dislike" not in labels


def test_negatives_below_min_confidence_are_not_served():
    store = ox.Store()
    _add(store, "like", "synthetic like", 0.9, 0.9, "films")
    _add(store, "weak", "synthetic weak dislike", -0.9, 0.2, "food")
    assert "synthetic weak dislike" not in _labels(_route(store, limit=8, min_confidence=0.4))


def test_negative_already_in_the_capped_list_is_not_repeated():
    store = ox.Store()
    _add(store, "like", "synthetic like", 0.9, 0.5, "films")
    _add(store, "dislike", "synthetic top dislike", -0.9, 0.99, "food")  # ranks first by confidence
    labels = _labels(_route(store, limit=8, tier="all"))
    assert labels.count("synthetic top dislike") == 1
    assert len(labels) == 2


def test_dislike_in_capped_list_does_not_squeeze_out_other_negatives():
    store = ox.Store()
    _add(store, "like", "synthetic like", 0.9, 0.5, "films")
    _add(store, "d1", "synthetic dislike one", -0.9, 0.99, "food")
    _add(store, "d2", "synthetic dislike two", -0.5, 0.45, "music")
    labels = _labels(_route(store, limit=8, tier="all"))
    assert sorted(labels) == ["synthetic dislike one", "synthetic dislike two", "synthetic like"]
