"""The general aggregation engine (Chunk 2, Layer 1).

Everything here operates ONLY on the universal EvidenceItem / DerivedPreference
records, so it is domain-agnostic: a new dimension is a Reader + a config row,
never an engine change. Pattern/trait derivers (Layers 2-3) are later chunks and
plug in at the same seam.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, Iterable, List, Optional, Sequence

from .model import DerivedPreference, EvidenceItem, max_privacy, normalize_value
from .scoring import score_group


@dataclass(frozen=True)
class DimensionConfig:
    dimension: str
    category: str
    min_evidence: int = 3
    # Keep only the strongest N nodes of this dimension. None = no cap. A
    # high-cardinality dimension (every artist, every site) would otherwise
    # write thousands of nodes and crowd the others out of any top-N read.
    max_items: Optional[int] = None
    # "broad" = a TYPE of thing (a genre, a cuisine, a topic); "specific" = a
    # single thing (an artist, a series, a restaurant). Consumers that lead with
    # types ask for the broad tier; the specific one follows once broad is settled.
    tier: str = "specific"


class Aggregator:
    """Group EvidenceItems by (dimension, normalized value) -> DerivedPreference."""

    def __init__(
        self,
        dimensions: Sequence[DimensionConfig],
        derivation_version: str = "derive-1.0.0+films",
    ):
        self._cfg: Dict[str, DimensionConfig] = {d.dimension: d for d in dimensions}
        self._version = derivation_version

    def _config_for(self, dimension: str) -> DimensionConfig:
        cfg = self._cfg.get(dimension)
        if cfg is not None:
            return cfg
        # Unknown dimension: accept-and-log into a counted bucket (never silently
        # drop), category = the dimension's domain leaf. min_evidence defaults.
        leaf = dimension.split(".")[0] if dimension else "unknown"
        return DimensionConfig(dimension=dimension, category=leaf, min_evidence=3)

    def aggregate(
        self, items: Iterable[EvidenceItem], now: Optional[datetime] = None
    ) -> List[DerivedPreference]:
        now = now or datetime.now(timezone.utc)
        groups: Dict[tuple, List[EvidenceItem]] = defaultdict(list)
        seen = set()
        for it in items:
            norm = normalize_value(it.value)
            # One literal preference is ONE observation of a value, however many
            # readers or tags report it (an artist named by both the payload
            # and the overlay, an actor listed twice).
            key = (it.dimension, norm, it.preference_id)
            if key in seen:
                continue
            seen.add(key)
            groups[(it.dimension, norm)].append(it)

        out: List[DerivedPreference] = []
        for (dimension, _norm), members in groups.items():
            cfg = self._config_for(dimension)
            # The anti-spurious gate stops a pile of weak behavioural signals
            # (one play, one visit) from becoming a preference. A STATED item is
            # the owner saying so in words, so one is enough to exist; its low
            # confidence is what keeps a single remark from steering anything,
            # and repetition across conversations is what raises it.
            stated = any(m.polarity_source == "stated" for m in members)
            if len(members) < cfg.min_evidence and not stated:
                continue  # anti-spurious gate (negative control covers this)

            score = score_group(members, now=now)
            user_id = members[0].user_id
            # display subject: the most common raw value spelling in the group
            subject = _modal_value(members)
            qid = next((m.value_qid for m in members if m.value_qid), None)
            evidence_from = sorted({m.provenance_uri for m in members})
            node = DerivedPreference(
                user_id=user_id,
                dimension=dimension,
                subject=subject,
                preference_strength=round(score.strength, 6),
                confidence=round(score.confidence, 6),
                category=cfg.category,
                evidence_from=evidence_from,
                evidence_count=score.evidence_count,
                evidence_source_count=score.source_count,
                intensity_tier=score.intensity_tier,
                value_qid=qid,
                first_observed_at=score.first_observed_at,
                last_observed_at=score.last_observed_at,
                derived_at=now,
                derivation_version=self._version,
                derivation_method="rollup",
                is_contested=score.is_contested,
                evidence_titles=_evidence_titles(members),
                tier=cfg.tier,
                privacy_level=max_privacy(m.privacy_level for m in members),
            )
            out.append(node)

        # Deterministic order: strongest-by-confidence first, then URI.
        out.sort(key=lambda n: (-abs(n.preference_strength), -n.confidence, n.uri))
        return self._apply_caps(out)

    def _apply_caps(self, nodes: List[DerivedPreference]) -> List[DerivedPreference]:
        kept: List[DerivedPreference] = []
        per_dim: Dict[str, int] = defaultdict(int)
        for n in nodes:  # already strongest-first
            cap = self._config_for(n.dimension).max_items
            if cap is not None and per_dim[n.dimension] >= cap:
                continue
            per_dim[n.dimension] += 1
            kept.append(n)
        return kept


def _evidence_titles(items: Sequence[EvidenceItem], limit: int = 3) -> List[str]:
    """Up to ``limit`` distinct literal titles behind a node, strongest first.

    These become the "because" line a consumer shows, so it works for evidence
    that has no enrichment title (a play count, a bookmark).
    """
    seen, out = set(), []
    for it in sorted(items, key=lambda i: (-i.item_strength, i.raw_subject)):
        t = (it.raw_subject or "").strip()[:120]
        k = t.lower()
        if t and k not in seen:
            seen.add(k)
            out.append(t)
            if len(out) >= limit:
                break
    return out


def _modal_value(items: Sequence[EvidenceItem]) -> str:
    counts: Dict[str, int] = defaultdict(int)
    for it in items:
        counts[it.value] += 1
    # most frequent spelling, ties broken alphabetically for determinism
    return sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]


@dataclass(frozen=True)
class RunResult:
    """Outcome of one derivation run.

    ``proven_empty`` is the load-bearing flag for the writer's non-destructive
    swap: a run yields an EMPTY node set for two very different reasons and they
    MUST NOT be conflated:

    - genuinely empty: every reader read successfully and found nothing to roll
      up (proven_empty=True) -> the derived graph may be cleared.
    - failed read: at least one reader raised (store down, auth shim not
      attached, broken predicate) (proven_empty=False) -> clearing the graph
      here would be the WIPE-ON-EMPTY data-loss bug, so the writer ABORTS and
      keeps the existing graph.
    """

    nodes: List[DerivedPreference]
    failed_readers: List[str] = field(default_factory=list)
    readers_total: int = 0

    @property
    def ok(self) -> bool:
        """True only when every reader read without raising."""
        return not self.failed_readers

    @property
    def proven_empty(self) -> bool:
        """Empty AND every reader succeeded -> a trustworthy empty result."""
        return self.ok and not self.nodes


@dataclass
class DerivationEngine:
    """Readers -> EvidenceItem stream -> Aggregator -> DerivedPreference list."""

    readers: list
    aggregator: Aggregator

    def run_result(self, user_id: str, now: Optional[datetime] = None) -> RunResult:
        """Run every reader, recording FAILURES rather than crashing the batch.

        A reader that raises no longer aborts the whole run (which would make a
        single flaky store take down the nightly batch); instead it is recorded
        in ``failed_readers`` so the writer can refuse to swap to an unsafe
        empty. This is the failed-vs-empty distinction the writer relies on.
        """
        items: List[EvidenceItem] = []
        failed: List[str] = []
        for reader in self.readers:
            name = getattr(reader, "dimension", reader.__class__.__name__)
            try:
                items.extend(reader.read(user_id))
            except Exception as exc:  # noqa: BLE001 - recorded, never silently dropped
                failed.append(f"{name}: {type(exc).__name__}: {exc}")
        nodes = self.aggregator.aggregate(items, now=now)
        return RunResult(nodes=nodes, failed_readers=failed, readers_total=len(self.readers))

    def run(self, user_id: str, now: Optional[datetime] = None) -> List[DerivedPreference]:
        """Backward-compatible: just the node list. Callers that must honour the
        non-destructive swap use ``run_result`` and pass proven_empty on."""
        return self.run_result(user_id, now=now).nodes
