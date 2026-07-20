"""One-off backfill: tag untagged fact/signal nodes with pwg:privacyLevel.

Step 4 of the privacy reconciliation.

On the live graph ~4,208 fact-bearing nodes (most RelationshipSignal, many
PersonFact) carry no pwg:privacyLevel - the 85% coverage gap. Until they
are tagged, the wiki body default (absent -> "L2" publish) default-publishes
them. This script assigns each untagged node a level deterministically from
its rdf:type + provenance source, using the SAME canonical rule the writers
now use (contact_syncer.privacy_model.level_for), so the backfill and the
live writers can never drift.

Erring private
--------------
The rule ERRS PRIVATE: any node whose provenance is a private channel
(WhatsApp / iMessage / email / user-asserted / LinkedIn message content)
is tagged L1, NEVER L2. A node of unknown provenance also fails closed to
L1 (private, owner-pages only), not L2 (publishable). Public/social signals
(LinkedIn connection/career, Twitter, Facebook friend) become L2.

Safety
------
* DRY RUN BY DEFAULT. Nothing is written unless --apply is passed.
* IDEMPOTENT. The SELECT only matches nodes that have NO privacyLevel, so
  re-running after an --apply is a no-op.
* Deterministic. Given the same graph state it produces the same plan.

  *** REVIEW FLAG ***
  This backfill MUST be reviewed together with the CM044 wiki body-default
  flip (absent -> withhold). They are the leak / blank-wiki risk PAIR:
  - flip the wiki default BEFORE this backfill runs  -> wiki goes ~85% blank.
  - run a backfill that over-assigns L2 to private content -> private leak.
  Land the backfill first (verified), THEN flip the default. Do NOT run this
  against the live graph as part of merging the PR.

CLI:
    python -m contact_syncer.backfill_privacy                 # dry-run plan
    python -m contact_syncer.backfill_privacy --graph-endpoint http://h:7878
    python -m contact_syncer.backfill_privacy --apply         # writes
    python -m contact_syncer.backfill_privacy --limit 50      # cap per run
"""
from __future__ import annotations

import argparse
import logging
import sys
from typing import Dict, List, Optional

import httpx

from contact_syncer import config
from contact_syncer import privacy_model as pm

PWG_NS = "https://pwg.dev/ontology#"

# Node types whose untagged instances we backfill.
TARGET_TYPES = ("PersonFact", "RelationshipSignal")

# The set of provenance predicates we read to classify a node. A node may
# use any one of these; we coalesce them into a single source string.
SOURCE_PREDICATES = ("source", "factSource", "signalType", "factType")


def _select_untagged(oxigraph_url: str, rdf_type: str, limit: Optional[int]) -> List[Dict]:
    """Return untagged nodes of one type with their coalesced source string.

    Uses OPTIONAL on each provenance predicate and COALESCE so a node is
    returned with whatever provenance it has. FILTER NOT EXISTS privacyLevel
    is what makes the pass idempotent.
    """
    limit_clause = f"LIMIT {int(limit)}" if limit else ""
    sparql = f"""
PREFIX pwg: <{PWG_NS}>
SELECT ?node
       (COALESCE(?src, ?factSrc, ?sigType, ?factType, "") AS ?source)
WHERE {{
  ?node a pwg:{rdf_type} .
  FILTER NOT EXISTS {{ ?node pwg:privacyLevel ?existing }}
  OPTIONAL {{ ?node pwg:source ?src }}
  OPTIONAL {{ ?node pwg:factSource ?factSrc }}
  OPTIONAL {{ ?node pwg:signalType ?sigType }}
  OPTIONAL {{ ?node pwg:factType ?factType }}
}}
{limit_clause}
"""
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=60.0, transport=transport) as client:
        resp = client.post(
            f"{oxigraph_url}/query",
            content=sparql,
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
        )
        resp.raise_for_status()
        bindings = resp.json().get("results", {}).get("bindings", [])

    out = []
    for b in bindings:
        node = b.get("node", {}).get("value")
        source = b.get("source", {}).get("value", "")
        if node:
            out.append({"node": node, "type": rdf_type, "source": source})
    return out


def plan_backfill(oxigraph_url: str, limit: Optional[int] = None) -> List[Dict]:
    """Build the deterministic backfill plan: [{node, type, source, level}].

    Read-only - this is the dry-run output. The level for every row is
    computed by the canonical rule; private channels and unknown provenance
    resolve to L1 (never L2).
    """
    plan: List[Dict] = []
    for rdf_type in TARGET_TYPES:
        per_type_limit = limit
        rows = _select_untagged(oxigraph_url, rdf_type, per_type_limit)
        for row in rows:
            level = pm.level_for(rdf_type=row["type"], source=row["source"])
            plan.append({**row, "level": level})
    if limit:
        plan = plan[: int(limit)]
    return plan


def _apply_chunk(oxigraph_url: str, rows: List[Dict]) -> None:
    """INSERT privacyLevel for a chunk of plan rows in one UPDATE."""
    triples = "\n".join(
        f'  <{r["node"]}> pwg:privacyLevel "{r["level"]}" .' for r in rows
    )
    sparql = (
        f"PREFIX pwg: <{PWG_NS}>\n"
        f"INSERT DATA {{\n{triples}\n}}"
    )
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=120.0, transport=transport) as client:
        resp = client.post(
            f"{oxigraph_url}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()


def apply_backfill(oxigraph_url: str, plan: List[Dict], chunk_size: int = 200) -> int:
    """Write the plan. Returns the number of nodes tagged. NOT dry-run."""
    written = 0
    for i in range(0, len(plan), chunk_size):
        chunk = plan[i : i + chunk_size]
        _apply_chunk(oxigraph_url, chunk)
        written += len(chunk)
    return written


def summarise(plan: List[Dict]) -> Dict[str, int]:
    counts: Dict[str, int] = {}
    for row in plan:
        counts[row["level"]] = counts.get(row["level"], 0) + 1
    counts["total"] = len(plan)
    return counts


# -- Observability: cheap coverage count (reader-side signal) -----------------


def _count_untagged(oxigraph_url: str, rdf_type: str) -> int:
    """COUNT untagged nodes of one type. Cheaper than pulling every row.

    Used by the reader-side observability surface (the /health coverage
    line) so a silent mass-hide -- the fail-closed reader dropping the
    whole historical coverage gap as unknown-privacy -- is visible.
    """
    sparql = f"""
PREFIX pwg: <{PWG_NS}>
SELECT (COUNT(?node) AS ?c)
WHERE {{
  ?node a pwg:{rdf_type} .
  FILTER NOT EXISTS {{ ?node pwg:privacyLevel ?existing }}
}}
"""
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=30.0, transport=transport) as client:
        resp = client.post(
            f"{oxigraph_url}/query",
            content=sparql,
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
        )
        resp.raise_for_status()
        bindings = resp.json().get("results", {}).get("bindings", [])
    if not bindings:
        return 0
    raw = bindings[0].get("c", {}).get("value", "0")
    try:
        return int(raw)
    except (TypeError, ValueError):
        return 0


def count_untagged(oxigraph_url: str) -> Dict[str, int]:
    """Per-type + total count of untagged PersonFact / RelationshipSignal.

    Returns e.g. ``{"PersonFact": 12, "RelationshipSignal": 4196,
    "total": 4208}``. A non-zero total is exactly the number of facts the
    fail-closed reader hides as unknown-privacy until the backfill runs.
    """
    counts: Dict[str, int] = {}
    total = 0
    for rdf_type in TARGET_TYPES:
        n = _count_untagged(oxigraph_url, rdf_type)
        counts[rdf_type] = n
        total += n
    counts["total"] = total
    return counts


# -- Startup / install entrypoint (idempotent, guarded, observable) -----------


def run_startup_backfill(
    oxigraph_url: str,
    apply: bool = True,
    limit: Optional[int] = None,
    logger: Optional[logging.Logger] = None,
) -> Dict:
    """Tag untagged fact/signal nodes so the fail-closed reader hides only
    truly-private content, not the ~85% historical coverage gap.

    Safe to call unconditionally on every Hub startup / install hydrate:

    * IDEMPOTENT -- the plan only matches nodes with NO privacyLevel, so a
      re-run after a prior apply finds nothing and is a genuine no-op.
    * VISIBLE-DEFAULT -- every untagged node is stamped with the canonical
      provenance-derived level (``privacy_model.level_for``): private
      channels + unknown provenance -> L1, public/social -> L2, health/
      finance -> L0. It NEVER stamps L3, so a backfilled fact inherits a
      visible level rather than being body-suppressed.
    * FAIL-SAFE -- any graph error is caught and reported; the caller can
      still start serving because the reader stays fail-closed (a failed
      backfill hides facts, it never leaks them).
    * OBSERVABLE -- logs how many nodes would otherwise be silently hidden.

    Returns a status dict: ``{"status": ..., "total": n, "by_level": {...},
    "applied": n}``. ``status`` is one of ``clean`` / ``applied`` /
    ``planned`` / ``refused`` / ``error``.
    """
    log = logger or logging.getLogger(__name__)

    try:
        plan = plan_backfill(oxigraph_url, limit=limit)
    except Exception as exc:  # network / SPARQL failure -- fail safe.
        log.warning(
            "privacy backfill: graph query failed (%s); reader stays "
            "fail-closed so untagged facts remain hidden, not leaked", exc
        )
        return {"status": "error", "error": str(exc), "total": 0,
                "by_level": {}, "applied": 0}

    counts = summarise(plan)
    total = counts["total"]

    # Leak-safety: refuse to write if any private-channel node planned to a
    # publishable level (can only happen on a future rule bug).
    leaks = [
        r for r in plan
        if pm._matches_any((r["source"] or "").lower(),
                           pm.PRIVATE_CHANNEL_SOURCE_MARKERS)
        and r["level"] in pm.PUBLISHABLE_LEVELS
    ]
    if leaks:
        log.error(
            "privacy backfill REFUSED: %d private-channel node(s) planned "
            "as publishable -- a rule bug. Writing nothing.", len(leaks)
        )
        return {"status": "refused", "leaks": len(leaks), "total": total,
                "by_level": {}, "applied": 0}

    by_level = {lvl: counts[lvl] for lvl in pm.CANONICAL_LEVELS if counts.get(lvl)}

    if total == 0:
        log.info(
            "privacy backfill: 0 untagged PersonFact/RelationshipSignal "
            "nodes -- graph fully tagged, nothing to do."
        )
        return {"status": "clean", "total": 0, "by_level": {}, "applied": 0}

    # This is the reader-side observability signal: the count that would
    # otherwise be silently withheld by the fail-closed reader.
    log.warning(
        "privacy backfill: %d untagged PersonFact/RelationshipSignal node(s) "
        "would be HIDDEN as unknown-privacy by the fail-closed reader; "
        "tagging to visible provenance levels %s (never L3).", total, by_level
    )

    if not apply:
        return {"status": "planned", "total": total,
                "by_level": by_level, "applied": 0}

    try:
        written = apply_backfill(oxigraph_url, plan)
    except Exception as exc:  # partial write is safe: still idempotent.
        log.warning(
            "privacy backfill: write failed (%s); reader stays fail-closed. "
            "Re-run is safe (only untagged nodes are matched).", exc
        )
        return {"status": "error", "error": str(exc), "total": total,
                "by_level": by_level, "applied": 0}

    log.info(
        "privacy backfill: tagged %d node(s) -> %s. Re-runs are no-ops.",
        written, by_level
    )
    return {"status": "applied", "total": total,
            "by_level": by_level, "applied": written}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Backfill pwg:privacyLevel onto untagged PersonFact / "
            "RelationshipSignal nodes from type + source. DRY RUN BY "
            "DEFAULT. Idempotent (only matches untagged nodes). MUST be "
            "reviewed with the CM044 wiki body-default flip before either "
            "lands - the leak/blank-wiki risk pair."
        )
    )
    parser.add_argument(
        "--graph-endpoint",
        default=config.OXIGRAPH_URL,
        help="Oxigraph URL (default: OXIGRAPH_URL env var).",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write the plan. Without this flag the script is a dry run.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Cap the number of nodes considered/written (testing).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print every planned (node, source, level) row.",
    )
    args = parser.parse_args(argv)

    if not args.graph_endpoint:
        print("ERROR: no graph endpoint (set OXIGRAPH_URL or pass --graph-endpoint)",
              file=sys.stderr)
        return 2

    plan = plan_backfill(args.graph_endpoint, limit=args.limit)
    counts = summarise(plan)

    print(f"Backfill plan: {counts['total']} untagged nodes")
    for level in pm.CANONICAL_LEVELS:
        if counts.get(level):
            print(f"  -> {level}: {counts[level]}")
    if args.verbose:
        for row in plan:
            print(f"    {row['level']}  {row['source'] or '<no-source>'}  {row['node']}")

    # Safety assertion: surface (don't silently allow) any private-channel
    # node that somehow planned to a publishable level. With the canonical
    # rule this can never happen; the check guards future rule edits.
    leaks = [
        r for r in plan
        if pm._matches_any((r["source"] or "").lower(),
                           pm.PRIVATE_CHANNEL_SOURCE_MARKERS)
        and r["level"] in pm.PUBLISHABLE_LEVELS
    ]
    if leaks:
        print(f"REFUSING: {len(leaks)} private-channel nodes planned as "
              f"publishable. This is a rule bug.", file=sys.stderr)
        return 3

    if not args.apply:
        print("\nDRY RUN - nothing written. Re-run with --apply to write.")
        print("REVIEW FLAG: land+verify this backfill BEFORE the CM044 wiki "
              "body-default flip (leak / blank-wiki risk pair).")
        return 0

    written = apply_backfill(args.graph_endpoint, plan)
    print(f"\nApplied: tagged {written} nodes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
