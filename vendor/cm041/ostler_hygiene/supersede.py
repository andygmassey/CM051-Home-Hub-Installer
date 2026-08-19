"""Supersession + contradiction flagging (MEMORY_HYGIENE_SPEC.md 3.1 / 3.2).

Pure, deterministic, clock-injected. No I/O, no LLM, no globals. The
caller supplies fact records and existing verdicts; the engine returns
verdicts to upsert and flags to surface. Nothing here mutates or deletes
a source fact -- losers get a reversible ``superseded`` verdict in the
overlay, winners simply remain active (no verdict row is written for
them: absence of a verdict == active + full weight).

The auto-retire bar (spec 3.1 step 4) is deliberately high-precision:

- winner is authoritative and the loser is not, OR
- winner is strictly newer by MORE than ``min_supersede_age_gap_days``
  (default 30) AND the winner's source trust is not lower.

Everything else is handed to contradiction flagging (3.2): both facts
stay active and the conflict is emitted as a ``ContradictionFlag`` for
the human -- never silently resolved. Additional Phase 1 guards, all
conservative:

- A fact with no derivable observation time (legacy CM048 facts carry no
  timestamp) can lose only to an authoritative winner; recency can never
  be claimed against it.
- A still-``candidate`` fact (CM048 Foundry, uncorroborated) never
  supersedes anything (spec 3.7(4) states this for voice; we apply it to
  every candidate because a single unconfirmed mention should not retire
  an established fact).
- A ``user_override`` verdict is immovable: an override-hidden fact is
  out of play entirely; an override-pinned (kept) fact may win but can
  never be auto-retired -- a conflict against it is flagged instead.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

from ostler_hygiene.contradictions_detect import (
    _extract_attribute,
    _strip_negation,
)
from ostler_hygiene.model import (
    ContradictionFlag,
    FactRecord,
    HygieneConfig,
    HygieneResult,
    HygieneVerdict,
    L3_REDACTED,
    REASON_AUTHORITY,
    REASON_RECENCY,
    STATUS_ACTIVE,
    STATUS_SUPERSEDED,
    derive_observed_at,
    is_foundational,
    redacted_text,
)

_EPOCH_MIN = datetime.min.replace(tzinfo=timezone.utc)


def _as_comparable(dt: Optional[datetime]) -> datetime:
    """Timestamps for ordering: missing sorts oldest; naive treated as UTC."""
    if dt is None:
        return _EPOCH_MIN
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def _sort_key(fact: FactRecord):
    """Spec 3.1 step 2 ordering: authoritative desc, observedAt desc,
    sourceTrust desc; fact URI as the final deterministic tie-break."""
    return (
        not fact.authoritative,
        -_as_comparable(derive_observed_at(fact)).timestamp(),
        -fact.source_trust,
        fact.uri,
    )


def _pair_decision(
    winner: FactRecord,
    loser: FactRecord,
    pinned: frozenset,
    config: HygieneConfig,
) -> Tuple[Optional[str], str]:
    """Decide one (winner, loser) pair.

    Returns ``(reason, detail)``: ``reason`` is a supersession reason
    (auto-retire) or ``None`` (flag), with ``detail`` naming why it was
    left for the human when flagged.
    """
    if loser.uri in pinned:
        return None, "loser_pinned_by_user"
    if winner.candidate:
        return None, "winner_unconfirmed_candidate"
    if winner.authoritative and not loser.authoritative:
        return REASON_AUTHORITY, ""
    w_obs = derive_observed_at(winner)
    l_obs = derive_observed_at(loser)
    if w_obs is None or l_obs is None:
        return None, "no_observation_time"
    gap_days = (_as_comparable(w_obs) - _as_comparable(l_obs)).total_seconds() / 86400.0
    if gap_days > config.min_supersede_age_gap_days and (
        winner.source_trust >= loser.source_trust
    ):
        return REASON_RECENCY, ""
    if gap_days <= config.min_supersede_age_gap_days:
        return None, "age_gap_too_small"
    return None, "winner_trust_lower"


def _conflict_groups(facts: List[FactRecord]):
    """Yield ``(attribute, groups)`` where ``groups`` maps each distinct
    conflicting value to its facts. Mirrors the vendored detector's two
    detection classes exactly (single-valued attributes, affirm/negate)."""
    # 1. Single-valued attributes.
    by_attr: Dict[str, Dict[str, List[FactRecord]]] = {}
    for f in facts:
        extracted = _extract_attribute(f.text)
        if extracted is None:
            continue
        attr, value = extracted
        by_attr.setdefault(attr, {}).setdefault(value, []).append(f)
    for attr in sorted(by_attr):
        if len(by_attr[attr]) > 1:
            yield attr, by_attr[attr]

    # 2. Affirm/negate pairs.
    cores: Dict[str, Dict[bool, List[FactRecord]]] = {}
    for f in facts:
        if not (f.text or "").strip():
            continue
        was_neg, core = _strip_negation(f.text)
        if not core:
            continue
        cores.setdefault(core, {}).setdefault(was_neg, []).append(f)
    for core in sorted(cores):
        sides = cores[core]
        if True in sides and False in sides:
            # Distinct "values" are the two sides of the negation.
            yield f"negation:{core}", {
                core: sides[False],
                f"not {core}": sides[True],
            }


def run_hygiene_pass(
    facts: List[FactRecord],
    existing_verdicts: Optional[Dict[str, HygieneVerdict]] = None,
    now: Optional[datetime] = None,
    run_id: Optional[str] = None,
    config: Optional[HygieneConfig] = None,
) -> HygieneResult:
    """Run supersession + contradiction flagging over a set of facts.

    ``existing_verdicts`` maps fact URI -> current verdict. Only
    ``user_override=True`` verdicts influence the pass (they are
    immovable); everything else is recomputed from scratch, so the pass
    is idempotent: same facts + same overrides + same clock -> same
    output, run after run.
    """
    existing_verdicts = existing_verdicts or {}
    config = config or HygieneConfig()
    now = now or datetime.now(timezone.utc)
    run_id = run_id or f"hygiene-{now.date().isoformat()}"

    # User-override handling: hidden facts are out of play; pinned facts
    # can win but never lose.
    hidden = frozenset(
        uri for uri, v in existing_verdicts.items()
        if v.user_override and v.status != STATUS_ACTIVE
    )
    pinned = frozenset(
        uri for uri, v in existing_verdicts.items()
        if v.user_override and v.status == STATUS_ACTIVE
    )
    in_play = [f for f in facts if f.uri not in hidden]

    by_person: Dict[str, List[FactRecord]] = {}
    for f in in_play:
        by_person.setdefault(f.person_uri, []).append(f)

    result = HygieneResult()
    for person_uri in sorted(by_person):
        person_facts = by_person[person_uri]
        for attribute, groups in _conflict_groups(person_facts):
            ordered = sorted(
                (f for group in groups.values() for f in group),
                key=_sort_key,
            )
            winner = ordered[0]
            winner_key = next(
                k for k, group in groups.items() if winner in group
            )
            unresolved: List[Tuple[FactRecord, str]] = []
            for value_key in sorted(groups):
                if value_key == winner_key:
                    continue  # facts agreeing with the winner stay active
                for loser in sorted(groups[value_key], key=_sort_key):
                    reason, detail = _pair_decision(
                        winner, loser, pinned, config
                    )
                    if reason is not None:
                        result.verdicts.append(HygieneVerdict(
                            fact_uri=loser.uri,
                            status=STATUS_SUPERSEDED,
                            superseded_by=winner.uri,
                            source_trust=loser.source_trust,
                            observed_at=derive_observed_at(loser),
                            reason=reason,
                            verdict_at=now,
                            run_id=run_id,
                            user_override=False,
                        ))
                    else:
                        unresolved.append((loser, detail))
            if unresolved:
                involved = [winner] + [f for f, _ in unresolved]
                foundational = is_foundational(attribute, involved)
                # L3 privacy guard: flags leave the graph (JSON artifact,
                # wiki surface, logs), so an L3 fact's text -- and any
                # conflict value evidenced ONLY by L3 facts -- is
                # redacted. Verdicts carry no text, so need no guard.
                # A negation attribute key embeds the fact core
                # ("negation:<core>"), which is fact text too: it is
                # redacted when every fact evidencing the conflict is L3
                # (a core also carried by a non-L3 fact is already
                # public -- the same rule as values).
                flag_attribute = attribute
                if attribute.startswith("negation:") and all(
                    f.is_l3 for group in groups.values() for f in group
                ):
                    flag_attribute = f"negation:{L3_REDACTED}"
                result.flags.append(ContradictionFlag(
                    person_uri=person_uri,
                    attribute=flag_attribute,
                    fact_uris=[f.uri for f in involved],
                    fact_texts=[redacted_text(f) for f in involved],
                    values=[
                        L3_REDACTED
                        if all(f.is_l3 for f in groups[value])
                        else value
                        for value in sorted(groups)
                    ],
                    foundational=foundational,
                    clarification_queue=foundational,
                    classifier=(
                        "rule" if foundational
                        else "rule_default_nonfoundational"
                    ),
                    reason=unresolved[0][1],
                ))

    result.verdicts.sort(key=lambda v: v.fact_uri)
    result.flags.sort(key=lambda c: (c.person_uri, c.attribute))
    return result
