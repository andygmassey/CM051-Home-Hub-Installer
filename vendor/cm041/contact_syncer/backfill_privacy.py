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
