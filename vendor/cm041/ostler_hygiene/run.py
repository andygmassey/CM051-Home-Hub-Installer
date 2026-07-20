"""The hygiene pass runner (MEMORY_HYGIENE_SPEC.md section 4) -- Phase 1+2.

A periodic, off-hot-path job. Safety posture copies CM048's discipline:

- **Opt-in, per mechanism:** writes require ``--apply`` on the command
  line AND the mechanism's env flag: ``OSTLER_HYGIENE_SUPERSEDE=1``
  gates supersession verdicts, ``OSTLER_HYGIENE_DECAY=1`` gates the
  Phase 2 weight/archival verdicts. Default is dry-run: print what
  would change, write nothing.
- **Fail-open:** any error logs and exits 0 with nothing written; a
  broken pass degrades to today's append-only behaviour, never to a
  blank graph.
- **Idempotent:** verdicts are keyed by uuid5 of the fact URI; re-running
  rewrites the same rows.
- **Override-safe:** verdicts with ``userOverride true`` are never
  written over (the engine excludes those facts; the writer double-checks).

Outputs:
- verdicts (supersession / archival tombstones / active-with-weight)
  into the ``<urn:pwg:hygiene>`` named graph;
- a contradiction-flags JSON artifact (the human-review proposal that
  feeds the wiki's contradictions surface and, later, the fortnightly
  clarification queue) into ``$OSTLER_HYGIENE_DIR``
  (default ``~/.ostler/hygiene/``). L3 fact text is redacted before it
  reaches this artifact.

Usage::

    python3 -m ostler_hygiene.run                # dry-run report
    OSTLER_HYGIENE_SUPERSEDE=1 OSTLER_HYGIENE_DECAY=1 \\
        python3 -m ostler_hygiene.run --apply    # write verdicts + flags
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import urllib.request
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from ostler_hygiene import graph_io
from ostler_hygiene.model import (
    HygieneConfig,
    STATUS_ARCHIVED,
    STATUS_SUPERSEDED,
)
from ostler_hygiene.weight import run_full_pass

log = logging.getLogger("ostler_hygiene")

OXIGRAPH_URL = os.environ.get("OXIGRAPH_URL", "http://localhost:7878")


def _sparql_select(sparql: str):
    """Same shape as assistant_api/ical-server.py:_sparql_select (that file
    is hyphenated and non-importable)."""
    req = urllib.request.Request(
        OXIGRAPH_URL.rstrip("/") + "/query",
        data=sparql.encode("utf-8"),
        headers={
            "Content-Type": "application/sparql-query",
            "Accept": "application/sparql-results+json",
        },
    )
    resp = urllib.request.urlopen(req, timeout=60)
    data = json.loads(resp.read())
    return [{k: v["value"] for k, v in b.items()}
            for b in data.get("results", {}).get("bindings", [])]


def _sparql_update(sparql: str) -> None:
    req = urllib.request.Request(
        OXIGRAPH_URL.rstrip("/") + "/update",
        data=sparql.encode("utf-8"),
        headers={"Content-Type": "application/sparql-update"},
        method="POST",
    )
    urllib.request.urlopen(req, timeout=60)


def _flags_artifact(flags, run_id: str, now: datetime) -> dict:
    return {
        "run_id": run_id,
        # The injected pass clock, not wall-clock: the artifact is
        # bit-reproducible for a fixed ``now`` (AUDIT_3 LOW).
        "generated_at": now.isoformat(),
        "note": (
            "Unresolved fact contradictions detected by the memory-hygiene "
            "pass. PROPOSAL ONLY: nothing here has been auto-applied. "
            "Foundational items are candidates for the (Phase 2) "
            "fortnightly clarification conversation; all items are "
            "candidates for the wiki contradictions surface."
        ),
        "flags": [asdict(f) for f in flags],
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true",
                        help="write verdicts (also needs "
                             "OSTLER_HYGIENE_SUPERSEDE=1)")
    parser.add_argument("--min-gap-days", type=int, default=int(
        os.environ.get("OSTLER_HYGIENE_MIN_GAP_DAYS", "30")))
    parser.add_argument("--run-id", default=None)
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    supersede_on = os.environ.get(
        "OSTLER_HYGIENE_SUPERSEDE", "") in ("1", "true")
    decay_on = os.environ.get("OSTLER_HYGIENE_DECAY", "") in ("1", "true")
    apply_writes = args.apply and (supersede_on or decay_on)
    if args.apply and not (supersede_on or decay_on):
        log.warning("--apply given but neither OSTLER_HYGIENE_SUPERSEDE "
                    "nor OSTLER_HYGIENE_DECAY is set; running dry-run "
                    "instead (opt-in safety).")

    try:
        now = datetime.now(timezone.utc)
        run_id = args.run_id or f"hygiene-{now.date().isoformat()}"

        facts = graph_io.parse_fact_bindings(
            _sparql_select(graph_io.build_facts_query()))
        existing = graph_io.parse_verdict_bindings(
            _sparql_select(graph_io.build_verdicts_query()))
        log.info("loaded %d facts, %d existing verdicts", len(facts),
                 len(existing))

        result = run_full_pass(
            facts, existing_verdicts=existing, now=now, run_id=run_id,
            config=HygieneConfig(min_supersede_age_gap_days=args.min_gap_days),
        )
        superseded = [v for v in result.verdicts
                      if v.status == STATUS_SUPERSEDED]
        archived = [v for v in result.verdicts
                    if v.status == STATUS_ARCHIVED]
        active = len(result.verdicts) - len(superseded) - len(archived)
        log.info("pass result: %d supersession verdicts, %d archival "
                 "tombstones, %d active-with-weight verdicts, %d "
                 "contradiction flags (%d foundational)", len(superseded),
                 len(archived), active, len(result.flags),
                 sum(1 for f in result.flags if f.foundational))
        prefix = "WRITE" if apply_writes else "WOULD"
        for v in superseded:
            log.info("  %s %s -> superseded by %s (%s)", prefix,
                     v.fact_uri, v.superseded_by, v.reason)
        for v in archived:
            log.info("  %s %s -> archived (%s, effectiveWeight=%s)",
                     prefix, v.fact_uri, v.reason, v.effective_weight)
        for f in result.flags:
            log.info("  FLAG %s %s: %s%s", f.person_uri, f.attribute,
                     " | ".join(f.fact_texts),
                     " [foundational]" if f.foundational else "")

        if not apply_writes:
            print(json.dumps(_flags_artifact(result.flags, run_id, now),
                             indent=2, default=str))
            return 0

        written = skipped_flag = 0
        for v in result.verdicts:
            # Per-mechanism gating: supersession verdicts need the
            # SUPERSEDE flag; weight/archival verdicts need DECAY.
            mechanism_on = (
                supersede_on if v.status == STATUS_SUPERSEDED else decay_on
            )
            if not mechanism_on:
                skipped_flag += 1
                continue
            prior = existing.get(v.fact_uri)
            if prior is not None and prior.user_override:
                # Belt-and-braces: the engine never emits these, but a
                # user override must be immovable even if it did.
                log.warning("skip %s: user_override verdict present",
                            v.fact_uri)
                continue
            _sparql_update(graph_io.build_verdict_upsert(v))
            written += 1
        if skipped_flag:
            log.info("skipped %d verdicts whose mechanism flag is off",
                     skipped_flag)
        hygiene_dir = Path(os.environ.get(
            "OSTLER_HYGIENE_DIR",
            str(Path.home() / ".ostler" / "hygiene")))
        hygiene_dir.mkdir(parents=True, exist_ok=True)
        out = hygiene_dir / f"flags-{run_id}.json"
        out.write_text(json.dumps(_flags_artifact(result.flags, run_id, now),
                                  indent=2, default=str))
        log.info("wrote %d verdicts to <%s>; flags artifact: %s",
                 written, graph_io.HYGIENE_GRAPH, out)
        return 0
    except Exception:  # noqa: BLE001 -- fail-open by design
        log.exception("hygiene pass failed; nothing (further) written "
                      "(fail-open: facts remain active + full weight)")
        return 0


if __name__ == "__main__":
    sys.exit(main())
