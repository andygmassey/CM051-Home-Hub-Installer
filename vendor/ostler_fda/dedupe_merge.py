"""Post-ingest exact-identifier dedup merge (RULE 1).

Enforces the ratified dedup rule: two Person nodes that share an exact
identifier VALUE (same email string or same phone string) are the same
person and MUST be merged -- regardless of source, regardless of display
name. Runs AFTER all ingest writers, as a graph-level sweep against
Oxigraph, so every consumer (the wiki, the iOS People view, the Doctor
API) sees merged people -- not just one renderer.

This catches the cross-source case the resolver misses: ``pwg_ingest``
(iMessage / WhatsApp) mints its own ``uuid5`` Person URIs and never
consults the identity resolver, so an iMessage Person and a Contacts
Person that share a phone number stay split until this sweep folds them
together.

Scope (deliberate): only the EXACT shared-identifier case (the metric
``dedupe_scorecard.py`` calls "shared value owned by >1 Person"). The
fuzzy no-shared-identifier case -- same person across sources with no
overlapping email/phone -- is BW-2 / #662 and is DEFERRED to v1.1; it is
risky to auto-merge and is not touched here.

Idempotent: a second run finds no collisions and is a no-op. Safe to run
on every install / recompile.
"""

from __future__ import annotations

import argparse
import logging
import os
from typing import Dict, List, Set, Tuple

import httpx

logger = logging.getLogger(__name__)

OXIGRAPH_URL = os.getenv("OXIGRAPH_URL", "http://localhost:7878")
PWG = "https://pwg.dev/ontology#"

# Identifier types treated as exact-identity keys (RULE 1). Instagram /
# twitter / facebook handles are intentionally NOT here -- they are
# name-fuzzy signals only, never an exact-merge key.
EXACT_KEY_TYPES: Tuple[str, ...] = ("email", "phone")


def _sparql_query(sparql: str) -> list:
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=60.0, transport=transport) as client:
        resp = client.post(
            f"{OXIGRAPH_URL}/query",
            content=sparql,
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
        )
        resp.raise_for_status()
        return resp.json().get("results", {}).get("bindings", [])


def _sparql_update(sparql: str) -> None:
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=60.0, transport=transport) as client:
        resp = client.post(
            f"{OXIGRAPH_URL}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()


def find_collisions() -> Dict[Tuple[str, str], List[str]]:
    """Return ``{(type, value): [person_uri, ...]}`` for every identifier
    value of an exact-key type owned by more than one distinct Person."""
    out: Dict[Tuple[str, str], List[str]] = {}
    for typ in EXACT_KEY_TYPES:
        rows = _sparql_query(
            f"PREFIX pwg:<{PWG}> "
            "SELECT ?v ?p WHERE { "
            "  ?p a pwg:Person ; pwg:hasIdentifier ?id . "
            f'  ?id pwg:identifierType "{typ}" ; pwg:identifierValue ?v . '
            "}"
        )
        groups: Dict[str, Set[str]] = {}
        for r in rows:
            groups.setdefault(r["v"]["value"], set()).add(r["p"]["value"])
        for value, persons in groups.items():
            if len(persons) > 1:
                out[(typ, value)] = sorted(persons)
    return out


def _components(collisions: Dict[Tuple[str, str], List[str]]) -> Dict[str, Set[str]]:
    """Union-find over all colliding persons. A person can collide with A
    on a phone and with B on an email; all three must fold into one node.
    The canonical URI of a component is its lexicographically-smallest
    member (deterministic, so re-runs are stable)."""
    parent: Dict[str, str] = {}

    def find(x: str) -> str:
        parent.setdefault(x, x)
        root = x
        while parent[root] != root:
            root = parent[root]
        while parent[x] != root:  # path-compress
            parent[x], x = root, parent[x]
        return root

    def union(a: str, b: str) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            # smaller URI becomes the canonical root
            lo, hi = sorted((ra, rb))
            parent[hi] = lo

    for persons in collisions.values():
        first = persons[0]
        for other in persons[1:]:
            union(first, other)

    comps: Dict[str, Set[str]] = {}
    for person in list(parent):
        comps.setdefault(find(person), set()).add(person)
    return comps


def _merge_pair(canonical: str, dupe: str) -> None:
    """Move every triple referencing ``dupe`` onto ``canonical``. After
    both rewrites, no triple references ``dupe`` and it ceases to exist."""
    # Outbound: <dupe> ?p ?o  ->  <canonical> ?p ?o
    _sparql_update(
        f"DELETE {{ <{dupe}> ?p ?o }} "
        f"INSERT {{ <{canonical}> ?p ?o }} "
        f"WHERE  {{ <{dupe}> ?p ?o }}"
    )
    # Inbound: ?s ?p <dupe>  ->  ?s ?p <canonical>
    _sparql_update(
        f"DELETE {{ ?s ?p <{dupe}> }} "
        f"INSERT {{ ?s ?p <{canonical}> }} "
        f"WHERE  {{ ?s ?p <{dupe}> }}"
    )


def run(dry_run: bool = False) -> Dict[str, int]:
    """Sweep the graph and merge all exact-identifier-colliding Persons.
    Returns ``{"collision_keys": N, "merged": M}`` (M = duplicate nodes
    folded away)."""
    collisions = find_collisions()
    comps = _components(collisions)
    merged = 0
    for canonical, members in comps.items():
        for dupe in sorted(members - {canonical}):
            if not dry_run:
                _merge_pair(canonical, dupe)
            merged += 1
    logger.info(
        "dedupe_merge: %d exact-id collision key(s); merged %d duplicate Person node(s)%s",
        len(collisions),
        merged,
        " (dry-run, no writes)" if dry_run else "",
    )
    return {"collision_keys": len(collisions), "merged": merged}


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    ap = argparse.ArgumentParser(description="Post-ingest exact-identifier dedup merge (RULE 1)")
    ap.add_argument("--dry-run", action="store_true", help="report collisions without merging")
    args = ap.parse_args()
    result = run(dry_run=args.dry_run)
    print(f"dedupe_merge: {result['collision_keys']} collision keys, {result['merged']} merged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
