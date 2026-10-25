"""Consumption: rank candidates by derived affinities (Chunk 4).

The scorer is gated by the consume flag. With consume OFF it is a strict no-op
(returns base_relevance unchanged), so materialization and exposure roll out
independently and the negative control is structural, not incidental.

score(candidate) = base_relevance
                 + SUM over matched dimensions of (strength * confidence)
(only affinities at or above min_confidence contribute; a negative-strength
affinity such as disliked horror subtracts.)
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Sequence, Tuple

from .model import normalize_value
from .scoring import CONF_CONSUME_MIN


@dataclass(frozen=True)
class AffinityView:
    """A derived affinity as a consumer sees it."""

    dimension: str
    subject: str
    strength: float
    confidence: float
    intensity: str = "casual"
    because: Tuple[str, ...] = ()
    category: str = ""       # films / tv / music / ...; "" when the store did not say
    node: str = ""           # the derived node's URI, to resolve "because" later
    tier: str = ""           # "broad" | "specific"; "" for graphs written before tiers


@dataclass
class Candidate:
    """An item to be ranked. tags are (dimension, value) pairs to match on."""

    id: str
    base_relevance: float = 0.0
    tags: List[Tuple[str, str]] = field(default_factory=list)


class DerivedAffinityScorer:
    def __init__(
        self,
        affinities: Sequence[AffinityView],
        consume_enabled: bool,
        min_confidence: float = CONF_CONSUME_MIN,
    ):
        self.consume_enabled = consume_enabled
        self.min_confidence = min_confidence
        self._by_key: Dict[Tuple[str, str], AffinityView] = {}
        for a in affinities:
            if a.confidence >= min_confidence:
                self._by_key[(a.dimension, normalize_value(a.subject))] = a

    def contribution(self, candidate: Candidate) -> float:
        """The derived part of the score (0 when consume is off)."""
        if not self.consume_enabled:
            return 0.0
        total = 0.0
        for dim, val in candidate.tags:
            a = self._by_key.get((dim, normalize_value(val)))
            if a is not None:
                total += a.strength * a.confidence
        return total

    def score(self, candidate: Candidate) -> float:
        return candidate.base_relevance + self.contribution(candidate)

    def rank(self, candidates: Sequence[Candidate]) -> List[Candidate]:
        """Highest score first; stable for equal scores (preserves input order)."""
        return sorted(candidates, key=lambda c: -self.score(c))


def interleave_by_category(views: Sequence[AffinityView], limit: int) -> List[AffinityView]:
    """Round-robin a ranked list by category, so one category cannot own the top-N.

    Round 1 takes each category's best item, round 2 each category's second, and
    so on. Inside a round the items are ordered by confidence then strength, and
    within a category the input order is kept (the input is already ranked). A
    category that runs out simply drops out of later rounds, so when the others
    are empty the one left still fills the list.
    """
    by_cat: Dict[str, List[AffinityView]] = {}
    for v in views:
        by_cat.setdefault(v.category, []).append(v)
    # Types before things: inside a category a broad item leads a specific one
    # (the sort is stable, so confidence order is kept within each tier).
    for items in by_cat.values():
        items.sort(key=lambda v: v.tier != "broad")
    out: List[AffinityView] = []
    rnd = 0
    while len(out) < limit:
        this_round = [items[rnd] for items in by_cat.values() if len(items) > rnd]
        if not this_round:
            break
        # Types before things: inside a round a broad item leads a specific one.
        this_round.sort(key=lambda v: (v.tier != "broad", -v.confidence, -v.strength))
        out.extend(this_round[: limit - len(out)])
        rnd += 1
    return out
