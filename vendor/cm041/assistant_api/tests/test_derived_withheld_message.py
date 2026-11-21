"""CB136-DERIVED-EMPTY-IS-WITHHELD: an empty /api/v1/preferences/derived answer
must say what is true. Nodes that exist but are held back by privacy level are
"held back", never "not materialized yet". "Not materialized yet" is only for a
graph with 0 nodes. Synthetic graph only: counts and level labels, no names.

Control: the mutant (old message, count ignored) turns test_withheld_is_not_
called_not_materialized red.
"""

import sys
from pathlib import Path

_AAPI = Path(__file__).resolve().parents[1]
if str(_AAPI) not in sys.path:
    sys.path.insert(0, str(_AAPI))

from derived_preferences import DerivedGraphReader, build_derived_preferences_response  # noqa: E402


def _fake_graph(level_counts):
    """A sparql stand-in: the COUNT query answers the level counts, every
    preference read answers no rows (the privacy gate serves nothing)."""
    def sparql(q):
        if "COUNT(DISTINCT ?s)" in q:
            return [{"privacy": lvl, "n": str(n)} for lvl, n in level_counts.items()]
        return []
    return sparql


def _build(level_counts, tier="all"):
    reader = DerivedGraphReader(_fake_graph(level_counts), destination="owner_own_brief")
    return build_derived_preferences_response(reader, "owner", limit=8, min_confidence=0.0, tier=tier)


def test_withheld_is_not_called_not_materialized():
    out = _build({"": 267, "L1": 2})
    reason = out["cannot_check"]
    assert "not materialized" not in reason, reason
    assert "269 derived preferences held back by privacy level" in reason, reason
    assert "267 with no level" in reason and "2 at L1" in reason, reason
    assert out["items"] == [] and out["degraded"] is True


def test_zero_nodes_still_says_not_materialized():
    out = _build({})
    assert out["cannot_check"] == "no derived preferences materialized yet", out


def test_unreadable_count_is_not_called_empty():
    def boom(q):
        if "COUNT(DISTINCT ?s)" in q:
            raise RuntimeError("store down")
        return []
    reader = DerivedGraphReader(boom, destination="owner_own_brief")
    out = build_derived_preferences_response(reader, "owner", limit=8, min_confidence=0.0)
    assert "materialized" not in out["cannot_check"], out
    assert "could not be counted" in out["cannot_check"], out


def test_broad_tier_withheld_names_the_tier_and_the_hold():
    out = _build({"": 5}, tier="broad")
    reason = out["cannot_check"]
    assert "not materialized" not in reason, reason
    assert "in the broad tier" in reason and "5 exist" in reason, reason
