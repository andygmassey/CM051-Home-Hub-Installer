#!/usr/bin/env python3
"""Collapse a person's stacked displayNames down to the best one.

WHY (v1018-D658, 2026-08-10)
============================
Ingest names an unknown person after their raw handle -- a phone number, a
JID -- and flags it ``pwg:displayNameProvisional``, meaning "replace me when
a real name arrives". A real name then arrives from another source and
NOTHING retracts anything, because every displayName write in
``pwg_ingest`` sits inside an ``if not _person_exists(uri)`` branch. No code
path ever updated an EXISTING person's name. The node keeps both.

CM051 #548 fixed the writer, so no NEW node accumulates names. It repairs
none of the existing ones. This does that.

Measured on a real box before writing: 6,325 Person nodes, 241 carrying 2+
distinct name strings, and 192 of those rendering a second name on the
built People page -- which is what a user actually sees.

THE RULE IS NOT INVENTED HERE
=============================
It is Andy's ranking of 2026-08-10, and this module imports it from
``pwg_ingest`` rather than restating it. A second copy of a predicate is
how two halves of a system come to disagree, and this cut produced several
of those.

    tier 0  "+852 1234 5678"       replaces nothing
    tier 1  "j.smith@company.com"  replaces tier 0, KEEPS the flag
    tier 2  "Jane Smith"           replaces either, CLEARS the flag

A tier-1 name is an improvement, not a resolution: the domain gives you the
company and the local-part usually gives surname-plus-initial, which beats a
bare number, but it is still not the person's name.

WHAT IT WILL NOT DO
===================
**It never breaks a tie.** If the two best names are the same tier -- two
things that both look like real human names -- the rule cannot choose, and
guessing would delete a correct name with no undo. Those nodes are written
to a review list and left untouched.

Andy's call, 2026-08-10, when asked whether near-duplicates ("Bob" vs "Bob
Chen") should auto-collapse on longer-wins: **review list.** Longer-wins is
right most of the time and wrong exactly when the shorter name is the real
person and the longer one belongs to somebody else.

On the founder box that splits 193 automatic / 48 for review.

SAFETY
======
Dry run by default; ``--apply`` is required to write. Per node, ALL of:

  * every name is ranked by the SHIPPED tier function, not a local copy
  * only STRICTLY-lower-tier names are deleted -- a tie is never resolved
  * the provisional flag is cleared ONLY when the surviving name is tier 2
  * nothing else on the node is touched: no identifier, edge or fact

The review list is written under ``~/.ostler/`` because it necessarily
contains real names. It is a local operator artefact and must never be
committed.

Usage:
    python3 -m ostler_fda.repair_placeholder_names             # dry run
    python3 -m ostler_fda.repair_placeholder_names --apply
    python3 -m ostler_fda.repair_placeholder_names --review-out PATH
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from typing import Dict, List, Sequence, Tuple

try:
    from .pwg_ingest import (
        _display_name_tier,
        _NAME_TIER_NAME,
    )
except ImportError:  # running as a plain script, not a package member
    from pwg_ingest import (  # type: ignore
        _display_name_tier,
        _NAME_TIER_NAME,
    )

NS = "https://pwg.dev/ontology#"
SKOS = "http://www.w3.org/2004/02/skos/core#"
OXIGRAPH = os.environ.get("OSTLER_OXIGRAPH_URL", "http://127.0.0.1:7878")


# ── the decision, as a pure function so it is testable without a graph ──


def _fold(value: str) -> str:
    """Case/punctuation/whitespace fold for equality only."""
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", value.lower())).strip()


def decide(names: Sequence[str]) -> Tuple[str | None, List[str], bool, str]:
    """Pick the surviving name for one node.

    Returns ``(keep, drop, clear_flag, verdict)``.

    ``verdict`` is one of ``"single"``, ``"auto"``, ``"review"``. A
    ``"review"`` verdict returns no drops at all -- the node is reported and
    left exactly as it is.
    """
    distinct: Dict[str, str] = {}
    for n in names:
        f = _fold(n)
        if f and f not in distinct:
            distinct[f] = n
    values = list(distinct.values())
    if len(values) < 2:
        keep = values[0] if values else None
        clear = keep is not None and _display_name_tier(keep) >= _NAME_TIER_NAME
        return keep, [], clear, "single"

    ranked = sorted(values, key=_display_name_tier, reverse=True)
    top = _display_name_tier(ranked[0])
    tied = [v for v in ranked if _display_name_tier(v) == top]
    if len(tied) > 1:
        # Two names of equal standing. The rule cannot choose and this
        # module will not guess -- Andy 2026-08-10, "review list".
        return None, [], False, "review"

    keep = ranked[0]
    drop = [v for v in values if v != keep]
    return keep, drop, top >= _NAME_TIER_NAME, "auto"


# ── graph I/O ──────────────────────────────────────────────────────────


def _query(sparql: str) -> list:
    url = OXIGRAPH + "/query?" + urllib.parse.urlencode({"query": sparql})
    req = urllib.request.Request(url, headers={"Accept": "application/sparql-results+json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["results"]["bindings"]


def _update(sparql: str) -> None:
    req = urllib.request.Request(
        OXIGRAPH + "/update",
        data=sparql.encode("utf-8"),
        headers={"Content-Type": "application/sparql-update"},
    )
    urllib.request.urlopen(req, timeout=120).read()


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true",
                    help="actually write (default is a dry run)")
    ap.add_argument("--review-out",
                    default=os.path.expanduser("~/.ostler/name-review.tsv"),
                    help="where to write the needs-a-human list")
    args = ap.parse_args(argv)

    rows = _query(
        f"SELECT ?s ?v WHERE {{ ?s a <{NS}Person> . "
        f"{{ ?s <{NS}displayName> ?v }} UNION {{ ?s <{SKOS}prefLabel> ?v }} }}"
    )
    by_uri: Dict[str, List[str]] = {}
    for r in rows:
        by_uri.setdefault(r["s"]["value"], []).append(r["v"]["value"])

    auto: List[Tuple[str, str, List[str], bool]] = []
    review: List[Tuple[str, List[str]]] = []
    for uri, names in by_uri.items():
        keep, drop, clear, verdict = decide(names)
        if verdict == "auto":
            auto.append((uri, keep, drop, clear))
        elif verdict == "review":
            review.append((uri, sorted(set(names))))

    print(f"person nodes            {len(by_uri)}")
    print(f"repairable automatically {len(auto)}")
    print(f"needs a human            {len(review)}")

    if review:
        os.makedirs(os.path.dirname(args.review_out), exist_ok=True)
        with open(args.review_out, "w", encoding="utf-8") as fh:
            fh.write("# v1018-D658 names the tier rule cannot choose between.\n")
            fh.write("# Real names: local operator artefact, never commit.\n")
            for uri, names in sorted(review):
                fh.write(uri + "\t" + "\t".join(names) + "\n")
        print(f"review list -> {args.review_out}")

    if not args.apply:
        print("\nDry run. Re-run with --apply to write.")
        return 0

    written = 0
    for uri, keep, drop, clear in auto:
        parts = [f'<{uri}> <{NS}displayName> "{_escape(d)}" .' for d in drop]
        parts += [f'<{uri}> <{SKOS}prefLabel> "{_escape(d)}" .' for d in drop]
        if clear:
            parts.append(f"<{uri}> <{NS}displayNameProvisional> ?f .")
        body = "\n  ".join(parts)
        where = (
            f"  OPTIONAL {{ <{uri}> <{NS}displayNameProvisional> ?f }}\n"
            if clear else "  BIND(1 AS ?ignore)\n"
        )
        _update(f"DELETE {{\n  {body}\n}}\nWHERE {{\n{where}}}")
        written += 1
    print(f"\napplied to {written} node(s); {len(review)} left for review.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
