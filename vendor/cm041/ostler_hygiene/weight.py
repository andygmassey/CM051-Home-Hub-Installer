"""Effective-weight product + archival tombstones (spec 3.3 / 3.4) -- Phase 2.

Pure, deterministic, clock-injected. Composes Phase 1 (supersession +
contradiction flagging) with Phase 2 (decay + trust + corroboration)
into one full pass::

    effectiveWeight = clamp(sourceTrust * recencyWeight * corroborationBoost, 0..1)
    corroborationBoost = min(1 + log1p(count - 1) * 0.3, 1.6)   # count 1 -> 1.0

(The boost rewards corroboration BEYOND the first mention, so a fresh
single-mention linkedin fact scores exactly its source trust 0.85, and a
thrice-corroborated conversation fact scores ~0.70 * 1.33 -- the spec
3.4 fixtures.)

**Archival** is the "graceful forgetting" of noise, and it is guarded
five ways -- a fact is tombstoned ``archived`` only when ALL hold:

1. ``effectiveWeight < archive_threshold`` (default 0.15), and
2. single-mention (``corroborationCount <= 1``), and
3. not ``authoritative``, and
4. not evergreen, and
5. it has a derivable decay clock (a fact of unknown age is never
   archived on staleness grounds).

``validTo`` expiry is the one separate archival path: an explicitly
expired fact ("in Tokyo this week") archives regardless of weight.

Nothing here mutates or deletes a source fact. An archival tombstone is
a ``HygieneVerdict`` row in the ``<urn:pwg:hygiene>`` named graph
carrying full provenance (reason, run id, timestamp, the weights that
justified it); un-archiving is deleting that row (``graph_io.
build_verdict_undo``), after which the untouched source fact is simply
active again. ``user_override`` verdicts are immovable: those facts are
skipped entirely -- a user "keep" pins a fact against decay, a user
"forget" is never second-guessed.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Dict, List, Optional

from ostler_hygiene.decay import (
    decay_clock,
    is_evergreen,
    is_expired,
    recency_weight,
)
from ostler_hygiene.model import (
    FactRecord,
    HygieneConfig,
    HygieneResult,
    HygieneVerdict,
    REASON_DECAY,
    REASON_EXPIRED,
    STATUS_ACTIVE,
    STATUS_ARCHIVED,
    derive_observed_at,
)
from ostler_hygiene.supersede import run_hygiene_pass


def corroboration_count(fact: FactRecord) -> int:
    """Independent-mention count for a fact.

    An explicit writer-supplied count wins. Otherwise it is derived from
    the CM048 Foundry candidate lifecycle (spec 3.4): a promoted
    (non-candidate) ``urn:pwg:`` fact was corroborated by a second
    independent source by construction, so counts 2; a still-candidate
    fact counts 1. CM041 ``pwg:PersonFact`` rows have no corroboration
    machinery, so they conservatively count 1.
    """
    if fact.corroboration_count is not None:
        return max(int(fact.corroboration_count), 0)
    if fact.uri.startswith("urn:pwg:") and not fact.candidate:
        return 2
    return 1


def corroboration_boost(
    count: int, config: Optional[HygieneConfig] = None,
) -> float:
    """Boost for corroboration beyond the first mention, capped."""
    config = config or HygieneConfig()
    extra = max(count - 1, 0)
    return min(
        1.0 + math.log1p(extra) * config.corroboration_boost_scale,
        config.corroboration_boost_cap,
    )


@dataclass(frozen=True)
class FactScore:
    """The derived weights for one fact (verdict-bound, never source)."""
    source_trust: float
    recency: float
    corroboration: int
    boost: float
    effective: float


def score_fact(
    fact: FactRecord,
    now: datetime,
    config: Optional[HygieneConfig] = None,
) -> FactScore:
    """Compute the spec 3.4 effective-weight product for one fact."""
    config = config or HygieneConfig()
    trust = fact.source_trust
    recency = recency_weight(fact, now, config)
    count = corroboration_count(fact)
    boost = corroboration_boost(count, config)
    effective = min(max(trust * recency * boost, 0.0), 1.0)
    return FactScore(
        source_trust=trust, recency=recency, corroboration=count,
        boost=boost, effective=effective,
    )


def archival_reason(
    fact: FactRecord,
    score: FactScore,
    now: datetime,
    config: Optional[HygieneConfig] = None,
) -> Optional[str]:
    """Decide archival for one fact; ``None`` = stays active.

    See the module docstring for the five decay-archival guards. Expiry
    (``validTo`` passed) is checked first and applies regardless of
    weight -- it is an explicit source statement, not a staleness guess.
    """
    config = config or HygieneConfig()
    if is_expired(fact, now):
        return REASON_EXPIRED
    if fact.authoritative or is_evergreen(fact):
        return None
    if score.corroboration > 1:
        return None  # corroboration guard: never archive a echoed fact
    if decay_clock(fact) is None:
        return None  # unknown age -> staleness can never be claimed
    if score.effective < config.archive_threshold:
        return REASON_DECAY
    return None


def run_full_pass(
    facts: List[FactRecord],
    existing_verdicts: Optional[Dict[str, HygieneVerdict]] = None,
    now: Optional[datetime] = None,
    run_id: Optional[str] = None,
    config: Optional[HygieneConfig] = None,
) -> HygieneResult:
    """Phase 1 + Phase 2 in one deterministic pass.

    Runs supersession + contradiction flagging (Phase 1), then scores
    every in-play fact with the effective-weight product and the
    archival decision (Phase 2). Emits ONE verdict per scored fact:

    - superseded facts keep their supersession verdict, enriched with
      the weight fields;
    - archived facts get a reversible tombstone verdict with reason +
      provenance;
    - every other fact gets an ``active`` verdict carrying its weights
      (consumers rank by ``effectiveWeight``; absence of a verdict still
      means active + full weight, so a partial overlay fails safe).

    Facts with a ``user_override`` verdict of ANY status are skipped
    entirely: the user's decision is immovable and is never re-emitted,
    re-scored, or clobbered. Idempotent: same facts + same overrides +
    same clock -> same output.
    """
    existing_verdicts = existing_verdicts or {}
    config = config or HygieneConfig()
    now = now or datetime.now(timezone.utc)
    run_id = run_id or f"hygiene-{now.date().isoformat()}"

    base = run_hygiene_pass(
        facts, existing_verdicts=existing_verdicts, now=now,
        run_id=run_id, config=config,
    )
    superseded = {v.fact_uri: v for v in base.verdicts}
    overridden = frozenset(
        uri for uri, v in existing_verdicts.items() if v.user_override
    )

    result = HygieneResult(flags=base.flags)
    for fact in sorted(facts, key=lambda f: f.uri):
        if fact.uri in overridden:
            continue  # user verdicts are immovable, never rewritten
        score = score_fact(fact, now, config)
        prior = superseded.get(fact.uri)
        if prior is not None:
            prior.recency_weight = score.recency
            prior.effective_weight = score.effective
            prior.corroboration_count = score.corroboration
            result.verdicts.append(prior)
            continue
        reason = archival_reason(fact, score, now, config)
        result.verdicts.append(HygieneVerdict(
            fact_uri=fact.uri,
            status=STATUS_ARCHIVED if reason else STATUS_ACTIVE,
            source_trust=score.source_trust,
            observed_at=derive_observed_at(fact),
            reason=reason,
            verdict_at=now,
            run_id=run_id,
            user_override=False,
            recency_weight=score.recency,
            effective_weight=score.effective,
            corroboration_count=score.corroboration,
        ))
    result.verdicts.sort(key=lambda v: v.fact_uri)
    return result
