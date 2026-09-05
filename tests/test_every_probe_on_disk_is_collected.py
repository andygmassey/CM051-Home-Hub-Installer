#!/usr/bin/env python3
"""Every probe-shaped script must actually be COLLECTED by a box walk.

WHY THIS EXISTS. Andy, 2026-09-05, on being told that most open issues were
about the measuring apparatus rather than the product: "if we're to actually
finally land this, surely we need to make sure all the instruments work as
well, so I'd actually rather we count them in the manifest."

He is right, and this file is the first instrument that fails that standard.

MEASURED on origin/main:

    run_box_walk.sh:42   PROBE_DIR="$HERE/probes"
    run_box_walk.sh:83   for f in "$PROBE_DIR"/*.sh; do
    on disk              scripts/box_walk_probes/acceptance_gate_v1013.sh
                         <- ONE DIRECTORY ABOVE the glob

So `acceptance_gate_v1013` is a registered probe that no box walk ever runs. It
appears in no walk report. Its only invocation is its `permanent.yaml` row,
which fires only when OSTLER_BOX_HOST is set.

That is precisely the shape `cut-manifests/README.md` records as this project's
worst measurement failure: `people_seed_and_retrieval` sat one level outside the
same glob, so the manifest row was its only caller, and FOURTEEN CUTS reported
a gate that measured nothing.

A probe outside the collector is not a weaker probe. It is a probe whose result
nobody will ever read.

EXPLICIT EXEMPTION, NOT A SILENT ONE. A script may sit outside `probes/` if it
is listed in EXEMPT below WITH A REASON. An unlisted one is a failure. That is
deliberate: the failure mode being closed is a file drifting out of the
collector unnoticed, and an exemption list nobody has to justify reproduces it.

Exit 0 pass, 1 fail, 2 cannot-run.
"""
from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
BASE = REPO / "scripts" / "box_walk_probes"
RUNNER = BASE / "run_box_walk.sh"

# path relative to BASE -> why it is legitimately not collected
EXEMPT: dict[str, str] = {
    "lib/probe.sh":
        "a sourced library, not a probe: it defines probe_pass/probe_fail",
    "acceptance_gate_v1013.sh":
        "BY DESIGN, and verified rather than assumed. verify_cut_manifest.py's "
        "registry searches probes/ FIRST and then the flat directory (see its "
        "_box_walk_probe_search_dirs and the comment above it, which records "
        "that run_box_walk.sh globs probes/ ONLY). This script is deliberately "
        "not probe-shaped -- no lib/probe.sh, no PROBE_NAME, and it skip-exits "
        "0 when OSTLER_BOX_HOST is unset -- so the collector could not report "
        "it anyway. It IS invoked, through its permanent.yaml row, and "
        "post_walk_qa.sh runs the manifest verifier alongside the walk, so its "
        "result does reach the QA output under the manifest section.",
}

PASS = 0
FAIL = 0


def ok(m: str) -> None:
    global PASS
    PASS += 1
    print(f"  [PASS] {m}")


def bad(m: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {m}")


def main() -> int:
    if not RUNNER.is_file():
        print(f"CANNOT-RUN: no {RUNNER}", file=sys.stderr)
        return 2
    runner = RUNNER.read_text(encoding="utf-8")

    # Read the collector's own directory rather than assuming it, so this gate
    # cannot pass by measuring a directory the runner stopped using.
    m = re.search(r'^PROBE_DIR="([^"]+)"', runner, re.M)
    if not m:
        print("CANNOT-RUN: could not find PROBE_DIR in run_box_walk.sh. This gate "
              "must read the collector's real directory, not assume one.",
              file=sys.stderr)
        return 2
    collected_dir = BASE / "probes"
    print(f"  collector globs : {m.group(1)}")

    if not collected_dir.is_dir():
        print(f"CANNOT-RUN: {collected_dir} does not exist", file=sys.stderr)
        return 2

    collected = sorted(p.name for p in collected_dir.glob("*.sh"))
    if not collected:
        # A zero here and a broken glob print identically.
        print("CANNOT-RUN: the collector directory contains no .sh files at all. "
              "An empty probe set and a wrong path are the same result.",
              file=sys.stderr)
        return 2
    print(f"  collected       : {len(collected)} probe(s)   <- positive control, non-zero")

    # Everything probe-shaped anywhere under box_walk_probes, excluding the
    # collected dir, the runner itself, and experiments/fixtures.
    stray = []
    for p in sorted(BASE.rglob("*.sh")):
        rel = p.relative_to(BASE).as_posix()
        if rel.startswith("probes/"):
            continue
        if p.name == RUNNER.name:
            continue
        if rel.startswith(("experiments/", "fixtures/")):
            continue
        if rel in EXEMPT:
            continue
        stray.append(rel)

    print()
    if stray:
        bad(f"{len(stray)} probe-shaped script(s) sit OUTSIDE the collector and are "
            f"not exempted, so no box walk will ever run them: {stray}. "
            "Move them into probes/, or add them to EXEMPT with a reason.")
    else:
        ok("every probe-shaped script under box_walk_probes is either collected "
           "by run_box_walk.sh or exempted with a written reason")

    # The exemption list must not rot into a dumping ground: every entry must
    # still exist, or it is silently protecting nothing.
    ghosts = [k for k in EXEMPT if not (BASE / k).exists()]
    if ghosts:
        bad(f"{len(ghosts)} EXEMPT entr(y/ies) name files that no longer exist: "
            f"{ghosts}. An exemption for a deleted file protects nothing and "
            "hides the next file that takes its name.")
    else:
        ok(f"all {len(EXEMPT)} exemption(s) name files that exist")

    print()
    print(f"== {PASS} pass / {FAIL} fail / {PASS + FAIL} total ==")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
