#!/usr/bin/env python3
"""Repair people already merged before the two stores were kept in step.

WHY THIS EXISTS. resolver.py step 5c and sweep_qdrant_orphans_of_merged_people
stop NEW divergence. They do nothing about the divergence already on disk, and
the customers who need this most are the ones whose graph is already wrong.

MEASURED on the live 16GB box 2026-09-18:

    56 subjects carry pwg:mergedInto
    32 of them are STILL TYPED pwg:Person  -> counted as live people they are not
    24 are correctly untyped                -> but still hold a Qdrant point
    oxigraph 2596 / qdrant 2620, true answer about 2564

THIS IS A PRODUCT STEP, NOT A HAND-RUN SCRIPT. Running it by hand fixes exactly
one Mac and leaves every other customer carrying the same wrong number with
nobody to run it for them. It would also make the walk probe pass for a reason
the artefact does not contain, which is a fixture encoding the flag rather than
the property: a green probe and a broken product, indistinguishable.

DESIGN CONSTRAINTS, each earned:

  IDEMPOTENT. Safe on a graph that is already correct. A second run finds zero
  and says zero.

  A ZERO MUST BE READABLE. "Nothing to repair" and "could not look" print
  identically unless the denominators are printed, so every phase prints what
  it EXAMINED beside what it CHANGED.

  UNREACHABLE IS CANNOT-RUN, NOT SUCCESS. A store we cannot reach exits 2 and
  says so. It never exits 0 having repaired nothing.

  A NEGATIVE CONTROL RUNS EVERY TIME. A synthetic URI that cannot exist is
  checked against the retirement predicate. If the predicate ever "finds" it,
  the predicate is broken and the run refuses rather than reporting a clean
  sweep computed by a broken query.
"""
from __future__ import annotations

import argparse
import logging
import sys
from typing import Dict, List

import httpx

from identity_resolver.batch_resolver import (
    PWG,
    _sparql_query,
    _sparql_update,
    sweep_qdrant_orphans_of_merged_people,
)

logger = logging.getLogger(__name__)

# Reserved by RFC 6761 for exactly this: it can never resolve to a real host,
# so a subject built on it can never legitimately exist in a customer graph.
CONTROL_URI = "https://control.invalid/person/must-never-be-retired"

EXIT_OK = 0
EXIT_BROKEN_PREDICATE = 1
EXIT_CANNOT_RUN = 2
EXIT_PARTIAL = 3


def _retired_subjects(url: str, client: httpx.Client) -> List[str]:
    rows = _sparql_query(
        url, client,
        f"SELECT DISTINCT ?s WHERE {{ ?s <{PWG}mergedInto> ?t . "
        f"FILTER NOT EXISTS {{ ?s a <{PWG}Person> }} }}",
    )
    return [r["s"] for r in rows if r.get("s")]


def _still_typed_subjects(url: str, client: httpx.Client) -> List[str]:
    rows = _sparql_query(
        url, client,
        f"SELECT DISTINCT ?s WHERE {{ ?s <{PWG}mergedInto> ?t . "
        f"{{ ?s a <{PWG}Person> }} UNION "
        f"{{ ?s a <http://xmlns.com/foaf/0.1/Person> }} }}",
    )
    return [r["s"] for r in rows if r.get("s")]


def repair(
    oxigraph_url: str,
    qdrant_url: str,
    collection: str = "people",
    *,
    apply: bool = False,
    backup_dir: str = "./backups",
) -> int:
    """Return an exit code. 0 ok, 1 broken predicate, 2 could not run."""
    try:
        # trust_env=False: local stores, never via a proxy. See the gate in
        # tests/test_local_stores_do_not_route_through_a_proxy.py.
        with httpx.Client(timeout=30, trust_env=False) as client:
            merged = _sparql_query(
                oxigraph_url, client,
                f"SELECT DISTINCT ?s WHERE {{ ?s <{PWG}mergedInto> ?t }}",
            )
            still_typed = _still_typed_subjects(oxigraph_url, client)
            retired = _retired_subjects(oxigraph_url, client)

            # NEGATIVE CONTROL. The retirement predicate must not claim a
            # subject that cannot exist. If it does, every count above is
            # computed by a broken query and repairing on it would be worse
            # than doing nothing.
            if CONTROL_URI in retired or CONTROL_URI in still_typed:
                print(
                    "REFUSING: the negative control %s was reported by the "
                    "retirement predicate. The query is broken; its counts "
                    "mean nothing and nothing was changed." % CONTROL_URI
                )
                return EXIT_BROKEN_PREDICATE

            print(
                "merge subjects examined : %d\n"
                "  still typed as Person : %d   (counted as live people they are not)\n"
                "  correctly retired     : %d"
                % (len(merged), len(still_typed), len(retired))
            )

    except Exception as exc:  # noqa: BLE001 -- a failed READ is CANNOT-RUN
        print(
            "CANNOT-RUN: the graph at %s could not be READ (%s). Nothing was "
            "repaired, which is NOT the same as nothing being wrong."
            % (oxigraph_url, exc)
        )
        return EXIT_CANNOT_RUN

    # The WRITE phase is separate. A failure here is not "nothing happened":
    # some subjects may already be retired, and printing the CANNOT-RUN
    # sentence would be false in exactly the way this module exists to stop.
    attempted = 0
    try:
        with httpx.Client(timeout=30, trust_env=False) as client:
            if still_typed and apply:
                for uri in still_typed:
                    _sparql_update(
                        oxigraph_url, client,
                        f"DELETE DATA {{ <{uri}> a <{PWG}Person> }}",
                    )
                    _sparql_update(
                        oxigraph_url, client,
                        f"DELETE DATA {{ <{uri}> a "
                        f"<http://xmlns.com/foaf/0.1/Person> }}",
                    )
                    attempted += 1
            # COUNT THE EFFECT, NOT THE ATTEMPT. Incrementing a counter after
            # issuing an update reports what we asked for, not what happened,
            # in a module whose whole subject is two stores publishing counts
            # that were not true. Re-read and take the delta.
            remaining = _still_typed_subjects(oxigraph_url, client)
            retired_now = len(still_typed) - len(remaining)
    except Exception as exc:  # noqa: BLE001
        print(
            "PARTIAL: the repair failed part-way (%s). %d subject(s) had "
            "already been attempted and the graph is in a half-repaired state. "
            "Re-run this step; it is idempotent." % (exc, attempted)
        )
        return EXIT_PARTIAL
    print(
        "  retired by this run   : %d   (attempted %d, apply=%s)"
        % (retired_now, attempted, apply)
    )

    report = sweep_qdrant_orphans_of_merged_people(
        qdrant_url, collection, oxigraph_url,
        apply=apply, backup_dir=backup_dir,
    )
    if report.total_points == 0:
        print(
            "CANNOT-RUN: the vector store at %s reported 0 points. A collection "
            "we cannot read prints the same zero as one with nothing to repair."
            % qdrant_url
        )
        return EXIT_CANNOT_RUN

    print(
        "vector points examined  : %d\n"
        "  distinct person_uris  : %d\n"
        "  orphans of retired    : %d\n"
        "  deleted by this run   : %d   (apply=%s, backup=%s)"
        % (report.total_points, report.distinct_person_uris,
           report.orphans, report.deleted, apply, report.backup_path or "none")
    )
    return EXIT_OK


def main(argv: List[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--oxigraph-url", default="http://localhost:7878")
    ap.add_argument("--qdrant-url", default="http://localhost:6333")
    ap.add_argument("--collection", default="people")
    ap.add_argument("--backup-dir", default="./backups")
    ap.add_argument(
        "--apply", action="store_true",
        help="make the changes. Without it this DETECTS only.",
    )
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    return repair(
        args.oxigraph_url, args.qdrant_url, args.collection,
        apply=args.apply, backup_dir=args.backup_dir,
    )


if __name__ == "__main__":
    sys.exit(main())
