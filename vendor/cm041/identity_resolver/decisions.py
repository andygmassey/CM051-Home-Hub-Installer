"""BW-2 correction-loop decisions (task #662, pairs with CM044 review page).

The operator triages possible duplicates on the wiki's "Possible duplicate
contacts" page and records decisions in ``<corrections_dir>/duplicates.yaml``::

    decisions:
      - merge:    [7d33241d6e9e, 73053c07df44]   # these are the SAME person
      - distinct: [7d33241d6e9e, 94052f6a6fd0]   # these are DIFFERENT people

This module reads that file and applies it to the resolver's match lists:

- **distinct** is an absolute, permanent never-merge block (spec §3b: an
  explicit user "not the same person" mark vetoes the merge forever). It is
  removed from both the auto-merge and the review queues so the resolver
  never re-litigates a settled pair.
- **merge** forces the pair together (the user has confirmed they are one
  person) even if no detector found them.

IDs are the short hex tail of the person URI (``person_<hex>``), matching the
IDs the CM044 page renders in each row.
"""

from __future__ import annotations

import logging
import os
from itertools import combinations
from typing import Any, Dict, List, Optional, Set, Tuple

logger = logging.getLogger(__name__)


def short_id(uri: str) -> str:
    """Short hex id from a person/business URI (matches CM044's _short_id)."""
    if "person_" in uri:
        return uri.split("person_")[-1]
    if "business_" in uri:
        return uri.split("business_")[-1]
    return uri.rsplit("/", 1)[-1]


def load_duplicate_decisions(corrections_dir: str) -> Dict[str, Any]:
    """Load ``duplicates.yaml`` -> ``{merge_groups, distinct_pairs}``.

    Best-effort: a missing file or unreadable YAML yields empty decisions and
    never raises (this is an overlay, not a build-critical loader).
    """
    empty: Dict[str, Any] = {"merge_groups": [], "distinct_pairs": set()}
    if not corrections_dir:
        return empty
    path = os.path.join(corrections_dir, "duplicates.yaml")
    if not os.path.exists(path):
        return empty
    try:
        import yaml
        with open(path, "r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except Exception as e:  # pragma: no cover - defensive
        logger.warning("Could not load duplicate decisions from %s: %s", path, e)
        return empty

    merge_groups: List[Set[str]] = []
    distinct_pairs: Set[frozenset] = set()
    for entry in (data.get("decisions") or []):
        if not isinstance(entry, dict):
            continue
        merge = entry.get("merge")
        if isinstance(merge, list) and len(merge) >= 2:
            merge_groups.append({str(x).strip() for x in merge if str(x).strip()})
        distinct = entry.get("distinct")
        if isinstance(distinct, list) and len(distinct) >= 2:
            ids = [str(x).strip() for x in distinct if str(x).strip()]
            for a, b in combinations(ids, 2):
                distinct_pairs.add(frozenset((a, b)))
    return {"merge_groups": merge_groups, "distinct_pairs": distinct_pairs}


def is_blocked(uri_a: str, uri_b: str, decisions: Dict[str, Any]) -> bool:
    """True if the operator marked this pair ``distinct`` (never merge)."""
    pair = frozenset((short_id(uri_a), short_id(uri_b)))
    return pair in (decisions.get("distinct_pairs") or set())


def apply_user_decisions(
    auto: List[Any],
    review: List[Any],
    persons: Dict[str, Any],
    decisions: Dict[str, Any],
    *,
    match_factory=None,
) -> Tuple[List[Any], List[Any]]:
    """Apply operator decisions to the consolidated match lists.

    Returns ``(auto, review)`` with:
      - every pair the operator marked ``distinct`` removed from both lists,
      - every ``merge`` group materialised as forced auto-merge matches
        (using ``match_factory(uri_a, name_a, uri_b, name_b)``), unless the
        pair is also (contradictorily) blocked or already present.
    """
    distinct_pairs = decisions.get("distinct_pairs") or set()
    merge_groups = decisions.get("merge_groups") or []

    def _blocked(m) -> bool:
        return frozenset((short_id(m.uri_a), short_id(m.uri_b))) in distinct_pairs

    auto = [m for m in auto if not _blocked(m)]
    review = [m for m in review if not _blocked(m)]

    if merge_groups and match_factory is not None:
        # Map short_id -> uri for persons present in the graph this run.
        sid_to_uri: Dict[str, str] = {short_id(uri): uri for uri in persons}
        existing = {frozenset((m.uri_a, m.uri_b)) for m in auto}
        for group in merge_groups:
            present = [sid_to_uri[s] for s in group if s in sid_to_uri]
            for ua, ub in combinations(present, 2):
                if frozenset((short_id(ua), short_id(ub))) in distinct_pairs:
                    continue  # contradictory: distinct wins (safer)
                if frozenset((ua, ub)) in existing:
                    continue
                auto.append(match_factory(
                    ua, _name(persons, ua), ub, _name(persons, ub),
                ))
                existing.add(frozenset((ua, ub)))
    return auto, review


def _name(persons: Dict[str, Any], uri: str) -> str:
    rec = persons.get(uri)
    return getattr(rec, "display_name", "") if rec is not None else ""
