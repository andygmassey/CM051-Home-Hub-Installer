#!/usr/bin/env python3
"""The one pre-cut checklist must stay complete, and must be EMPTY of ungated
rows before a cut.

WHY THIS EXISTS. Andy, 2026-09-05, on being shown the first honest count of
remaining work: "maintain this discipline. Do NOT let it slip."

A discipline that lives in an agent's memory is exactly the thing that has been
slipping. `cut-manifests/v1.0.72.yaml` registers every open issue and marks the
ones with no proof written as `gate: NONE YET`. Two ways that decays:

  1. A NEW issue is opened and nobody adds it, so the register silently stops
     being the register. The checklist still looks complete because you cannot
     see what is not in it.
  2. A cut happens while `NONE YET` rows remain, which is the whole failure
     this file exists to prevent: shipping with untracked known defects.

So this gate asserts both, and the second is the one that blocks a cut.

THREE STATES. 0 pass, 1 fail, 2 cannot-run. A cannot-run is NOT a pass: if the
open-issue list cannot be read, this says so and refuses rather than reporting
a clean register it never saw.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys

import yaml

REPO = pathlib.Path(__file__).resolve().parents[1]
MANIFEST_DIR = REPO / "cut-manifests"
SLUG = "andygmassey/CM051-Home-Hub-Installer"

PASS = 0
FAIL = 0
CANNOT_RUN = 0


def ok(m: str) -> None:
    global PASS
    PASS += 1
    print(f"  [PASS] {m}")


def bad(m: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {m}")


def cannot_run(m: str) -> int:
    print(f"CANNOT-RUN: {m}", file=sys.stderr)
    return 2


def newest_manifest() -> pathlib.Path | None:
    """The highest-versioned per-cut manifest. `permanent.yaml` is excluded:
    it is the never-regress backstop, not the working checklist."""
    best = None
    best_key = ()
    for p in MANIFEST_DIR.glob("v*.yaml"):
        m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", p.stem)
        if not m:
            continue
        key = tuple(int(x) for x in m.groups())
        if key > best_key:
            best_key, best = key, p
    return best


def main() -> int:
    if not MANIFEST_DIR.is_dir():
        return cannot_run(f"no {MANIFEST_DIR}")
    manifest = newest_manifest()
    if manifest is None:
        return cannot_run("no per-cut manifest (cut-manifests/vX.Y.Z.yaml) exists at all")

    try:
        doc = yaml.safe_load(manifest.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        return cannot_run(f"{manifest.name} does not parse as YAML: {exc}")
    if not isinstance(doc, dict):
        # A truncated or empty manifest loads as None or a scalar. Reaching
        # `.get` on that raises AttributeError and exits 1, which reads as a
        # FAILED ASSERTION about a checklist nobody ever looked at. An
        # unreadable manifest is CANNOT-RUN. Found by driving this gate's own
        # red paths rather than by trusting that it compiled.
        return cannot_run(
            f"{manifest.name} did not load as a mapping (got {type(doc).__name__}). "
            "The checklist could not be read, so nothing about it was verified."
        )
    rows = doc.get("open_issues")
    if rows is None:
        return cannot_run(
            f"{manifest.name} has no `open_issues:` key. That key IS the register; "
            "without it this gate would pass by measuring nothing."
        )

    registered = {int(r["issue"]) for r in rows if "issue" in r}
    ungated = [r for r in rows if str(r.get("gate", "")).startswith("NONE")]
    print(f"== checklist: {manifest.name} ==")
    print(f"  registered issues : {len(registered)}")
    print(f"  rows with a gate  : {len(rows) - len(ungated)}")
    print(f"  NONE YET          : {len(ungated)}")
    print()

    # ── PROPERTY 1: the register must cover every OPEN issue ────────────────
    # Needs the live list. Absence of `gh`, or an unauthenticated runner, is a
    # CANNOT-RUN and not a pass -- a register checked against nothing is not a
    # checked register.
    live = None
    try:
        out = subprocess.run(
            ["gh", "issue", "list", "--repo", SLUG, "--state", "open",
             "--limit", "500", "--json", "number"],
            capture_output=True, text=True, timeout=90,
        )
        if out.returncode == 0 and out.stdout.strip():
            live = {int(o["number"]) for o in json.loads(out.stdout)}
    except (FileNotFoundError, subprocess.TimeoutExpired, json.JSONDecodeError, ValueError):
        live = None

    if live is None:
        # RECORDED, not merely printed. TNM drove this and found both `gh`
        # branches PRINTED the refusal and then fell through to a summary that
        # exits 0 -- with the manifest branches exiting 2 as the control, so the
        # script plainly can. `gh` auth expiring in CI would have left the daily
        # cron GREEN while measuring nothing, which is the exact failure the
        # third state exists to prevent, in the gate that argues for it. And it
        # was a SILENT green: the words CANNOT-RUN appear in the log, so a reader
        # skimming for red sees nothing.
        global CANNOT_RUN
        CANNOT_RUN += 1
        print("  [CANNOT-RUN] the open-issue list could not be read (no gh, no auth,")
        print("               or the call failed). Registration completeness is")
        print("               UNMEASURED on this run. This is not a pass.")
        print("               Command that settles it:")
        print(f"                 gh issue list --repo {SLUG} --state open --json number")
    elif not live:
        # An empty list is indistinguishable from a broken query, so refuse it.
        CANNOT_RUN += 1
        print("  [CANNOT-RUN] the open-issue list came back EMPTY. A repository with")
        print("               genuinely zero open issues and a broken query print")
        print("               identically, so this refuses rather than passing.")
    else:
        missing = sorted(live - registered)
        if missing:
            bad(f"{len(missing)} OPEN issue(s) are not in the checklist: {missing}. "
                "The register has stopped being the register.")
        else:
            ok(f"every one of the {len(live)} open issues is registered in {manifest.name}")
        # Registered-but-closed is drift, not a defect: report it, do not fail.
        stale = sorted(registered - live)
        if stale:
            print(f"  [note] {len(stale)} registered issue(s) are now closed and can be "
                  f"struck: {stale[:12]}{' ...' if len(stale) > 12 else ''}")

    # ── PROPERTY 2: no ungated rows may survive to a cut ────────────────────
    # This is the one that blocks. It is deliberately advisory OUTSIDE a cut
    # (there is always work in progress) and blocking when a cut is being made,
    # signalled by OSTLER_CUT_IN_PROGRESS=1 from the cut workflow.
    cutting = os.environ.get("OSTLER_CUT_IN_PROGRESS") == "1"
    if ungated:
        ids = [r.get("issue") for r in ungated]
        msg = (f"{len(ungated)} row(s) still carry `gate: NONE YET` -- no proof has "
               f"been written for them: {ids[:14]}{' ...' if len(ids) > 14 else ''}")
        if cutting:
            bad("CUT IS BLOCKED. " + msg + ". Each needs either a proof authored "
                "or a written DEFER decision in its row.")
        else:
            print(f"  [note] {msg}")
            print("         Not a failure outside a cut. With OSTLER_CUT_IN_PROGRESS=1 "
                  "this is a FAIL and the cut stops.")
    else:
        ok("no `NONE YET` rows remain: every registered issue is either gated or "
           "carries a written decision")

    print()
    print(f"== {PASS} pass / {FAIL} fail / {CANNOT_RUN} cannot-run / "
          f"{PASS + FAIL} adjudicated ==")
    if FAIL:
        return 1
    if CANNOT_RUN:
        # AND A CUT MUST NOT PROCEED ON AN UNREADABLE REGISTER. TNM's judgement
        # call and I agree with the reasoning: a cut that cannot confirm the
        # checklist is complete is a cut shipping an unknown, which is what
        # OSTLER_CUT_IN_PROGRESS exists to stop. 2 rather than 1 so it stays
        # distinguishable from a real registration failure.
        print(f"  REFUSING: {CANNOT_RUN} check(s) could not run. That is not a pass.")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
