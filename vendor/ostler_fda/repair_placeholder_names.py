#!/usr/bin/env python3
"""Elect one displayName per person and DEMOTE the rest, losing nothing.

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

A LOSING NAME IS DEMOTED, NOT DELETED -- WITH ONE EXCEPTION
===========================================================
A losing name becomes ``pwg:alternateName``, so it stays useful for matching.
That makes this repair NON-DESTRUCTIVE, which is what takes the teeth out of
the tie question below: a wrong election is a one-line correction, not a lost
name.

**The exception is a kinship word, which is DELETED (v1018-D659).** An
``alternateName`` is offered to the assistant as another name this person goes
by, so demoting "Mum" still lets it answer *"your mum is <wife>"*. Andy,
2026-08-08: *"'Mum' for Alison is NOT - she is my WIFE and Connor's MUM, but
not MY MUM (who was Sylvia Massey)."* His mother has died. Demotion does not
solve the thing that made the name wrong; only removal does.

I got this backwards earlier today. CM041 #109's module HEADER says a losing
name is *"kept, because 'Mum' is genuinely useful for matching"* -- and its
CODE drops kinship words six lines below, for the reason above. I cited the
header. The predicate now lives in ``pwg_ingest`` and is shared with the
writer, so there is one rule rather than three descriptions of one.

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
  * only STRICTLY-lower-tier names are demoted -- a tie is never resolved
  * the ONLY name ever deleted is a kinship word, and never the last one
    the node has
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
        _NAME_TIER_PLACEHOLDER,
    )
except ImportError:  # running as a plain script, not a package member
    from pwg_ingest import (  # type: ignore
        _display_name_tier,
        _NAME_TIER_NAME,
        _NAME_TIER_PLACEHOLDER,
    )

NS = "https://pwg.dev/ontology#"
SKOS = "http://www.w3.org/2004/02/skos/core#"
OXIGRAPH = os.environ.get("OSTLER_OXIGRAPH_URL", "http://127.0.0.1:7878")


# ── the decision, as a pure function so it is testable without a graph ──


def _fold(value: str) -> str:
    """Case/punctuation/whitespace fold for equality only."""
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", value.lower())).strip()


def decide(
    names: Sequence[str],
) -> Tuple[str | None, List[str], List[str], bool, str]:
    """Pick the surviving name for one node.

    Returns ``(keep, demote, drop, clear_flag, verdict)``.

    ``demote`` becomes ``pwg:alternateName`` -- kept, still useful for
    matching. ``drop`` is DELETED outright, and the only thing that ever
    lands there is a kinship word (v1018-D659): "Mum" as an alternateName
    is still offered to the assistant as a name this person goes by, so
    demoting it does not solve the problem that made it wrong.

    ``verdict`` describes the ELECTION only -- ``"single"``, ``"auto"``,
    ``"review"``. It is deliberately independent of ``drop``: removing a
    kinship word is unambiguous whether or not the remaining names can be
    ranked, so a ``"review"`` node still returns its drops.

    The one exception is a node whose ONLY name is a kinship word.
    Dropping it would leave a person with no name at all, and no surface
    here has been measured against that. It goes to review untouched
    rather than trading a known wrong name for an unmeasured empty one.
    """
    distinct: Dict[str, str] = {}
    for n in names:
        f = _fold(n)
        if f and f not in distinct:
            distinct[f] = n
    values = list(distinct.values())

    drop = [v for v in values if _display_name_tier(v) < _NAME_TIER_PLACEHOLDER]
    values = [v for v in values if v not in drop]
    if drop and not values:
        # Refusing every name it has would leave the node nameless.
        return None, [], [], False, "review"

    if len(values) < 2:
        keep = values[0] if values else None
        clear = keep is not None and _display_name_tier(keep) >= _NAME_TIER_NAME
        return keep, [], drop, clear, "auto" if drop else "single"

    ranked = sorted(values, key=_display_name_tier, reverse=True)
    top = _display_name_tier(ranked[0])
    tied = [v for v in ranked if _display_name_tier(v) == top]
    if len(tied) > 1:
        # Two names of equal standing. The rule cannot choose and this
        # module will not guess -- Andy 2026-08-10, "review list".
        return None, [], drop, False, "review"

    keep = ranked[0]
    demote = [v for v in values if v != keep]
    return keep, demote, drop, top >= _NAME_TIER_NAME, "auto"


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

    auto: List[Tuple[str, str | None, List[str], List[str], bool]] = []
    review: List[Tuple[str, List[str]]] = []
    dropped_names = 0
    for uri, names in by_uri.items():
        keep, demote, drop, clear, verdict = decide(names)
        # A drop is unambiguous even when the election is not, so a
        # review node still gets its kinship word removed.
        if verdict == "auto" or drop:
            auto.append((uri, keep, demote, drop, clear))
            dropped_names += len(drop)
        if verdict == "review":
            review.append((uri, sorted(set(names))))

    print(f"person nodes            {len(by_uri)}")
    print(f"nodes to be written      {len(auto)}")
    print(f"needs a human            {len(review)}")
    if dropped_names:
        print(f"kinship names deleted    {dropped_names}  (v1018-D659)")

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
    for uri, keep, demote, drop, clear in auto:
        # Every losing name moves to alternateName in the SAME update, so at
        # no point does the graph hold fewer names than it started with.
        gone = [f'<{uri}> <{NS}displayName> "{_escape(d)}" .' for d in demote]
        gone += [f'<{uri}> <{SKOS}prefLabel> "{_escape(d)}" .' for d in demote]
        kept = [f'<{uri}> <{NS}alternateName> "{_escape(d)}" .' for d in demote]
        # v1018-D659: a kinship word is removed from EVERY name predicate,
        # alternateName included -- demoting it would leave the assistant
        # able to answer "your mum is <wife>", which is the whole defect.
        for d in drop:
            gone.append(f'<{uri}> <{NS}displayName> "{_escape(d)}" .')
            gone.append(f'<{uri}> <{SKOS}prefLabel> "{_escape(d)}" .')
            gone.append(f'<{uri}> <{NS}alternateName> "{_escape(d)}" .')
        if clear:
            gone.append(f"<{uri}> <{NS}displayNameProvisional> ?f .")
        where = (
            f"  OPTIONAL {{ <{uri}> <{NS}displayNameProvisional> ?f }}\n"
            if clear else "  BIND(1 AS ?ignore)\n"
        )
        if not gone:
            continue
        # Both halves in ONE update, so a reader never sees the node with
        # a name deleted and its replacement not yet inserted. The INSERT
        # is written inline rather than hoisted into a variable so that
        # the atomicity check in tests/test_name_repair.sh can still see
        # it -- and so can a person reading this.
        #
        # It is conditional because a node whose only change is a deleted
        # kinship word demotes nothing, and an empty INSERT template is
        # not a thing to rely on.
        _update(
            "DELETE {\n  " + "\n  ".join(gone) + "\n}\n"
            + (("INSERT {\n  " + "\n  ".join(kept) + "\n}\n") if kept else "")
            + "WHERE {\n" + where + "}"
        )
        written += 1
    print(f"\nwrote {written} node(s); {len(review)} left for review. "
          f"{dropped_names} kinship name(s) deleted; every other losing "
          f"name was demoted, not lost.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
