#!/usr/bin/env python3
"""The cut's dry run must be REACHABLE on a workflow_dispatch, and the cut must not be.

WHY THIS EXISTS (CM051 row 1519).

The row said: "cut.yml: the dry-run job can never run, because it needs a
preflight that can only pass on a tag". Its own gate text said the evidence
suggested this was STALE, named the decisive test (fire a dispatch and watch it
reach the job), and deliberately did not fire it.

IT DID NOT NEED FIRING. The answer was already in the run history, and it is
measured rather than read. Over the last 30 workflow_dispatch runs of cut.yml:

    dry-run EXECUTED (success or failure)   11
    dry-run SKIPPED (preflight not green)   19
    cut     EXECUTED on a dispatch           0

So the job is not unreachable: it has run, most recently to SUCCESS on
2026-09-13 (run 34767764277, preflight success, dry-run success, cut skipped).
The row is stale.

AND THE 19 SKIPS ARE NOT THE ROW'S CLAIM EITHER. Today's two dispatches failed
preflight on "The cut record's CM051 pin is the tree being cut" (the OS003 pin
in cuts/v1.0.99/cut.env is 11 install.sh commits behind main) and on "The tagged
commit's own checks are not red". Both are CONTENT gates that would fail
identically on a tag push. Neither is "can only pass on a tag".

WHAT THIS FILE GATES, so the staleness cannot quietly stop being true.

A reading proved nothing before and would prove nothing now. What can regress is
the STRUCTURE, and it can regress in one of two directions, both silent:

  1. the dry run becomes unreachable, so the one gate that would catch a bad cut
     BEFORE a tag is not there, and nobody notices because a skipped job renders
     as a grey tick rather than a red one;
  2. the CUT becomes reachable on a dispatch, which is worse. Firing a dispatch
     is only safe because it cannot ship, and that safety is what makes the
     decisive test above cheap enough to run before every tag.

Arm 5 is the second one, and it is a control as much as an assertion: it is the
predicate that says this suite could notice if a dispatch became able to ship.

THE PERSON THIS IS ABOUT. Andy tags a version and that tag IS the ship. The dry
run is the only thing between a bad payload and a published DMG. A dry run that
cannot run is a ship gate that is not there, and it looks exactly like one that
is.

Exit 0 pass, 1 fail, 2 cannot-run.
"""
from __future__ import annotations

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

try:
    import yaml
except ImportError:  # pragma: no cover
    print("  CANNOT-RUN  PyYAML is not importable, so cut.yml could not be parsed")
    sys.exit(2)

REPO = pathlib.Path(__file__).resolve().parents[1]
WF = REPO / ".github" / "workflows" / "cut.yml"

DISPATCH = "workflow_dispatch"
PASS, FAIL = [], []


def ok(msg: str) -> None:
    PASS.append(msg)
    print(f"  PASS  {msg}")


def bad(msg: str, detail: str = "") -> None:
    FAIL.append(msg)
    print(f"  FAIL  {msg}")
    if detail:
        print(f"        {detail}")


def cannot(msg: str) -> None:
    print(f"  CANNOT-RUN  {msg}")
    print("VERDICT: CANNOT-RUN, nothing was measured")
    sys.exit(2)


def permits_dispatch(cond) -> bool:
    """Can a job with this `if:` run on a workflow_dispatch?

    No condition at all means every event, which is how preflight is written.
    A condition that names a DIFFERENT event and not this one cannot.
    """
    if cond is None:
        return True
    c = str(cond).replace(" ", "")
    if f"github.event_name=='{DISPATCH}'" in c or f'github.event_name=="{DISPATCH}"' in c:
        return True
    # Names some other event exclusively.
    if re.search(r"github\.event_name==['\"](?!%s)" % DISPATCH, c):
        return False
    return True


def code_lines(run: str):
    """The run block's CODE, with comment lines removed.

    🔴 A COMMENT IS NOT A USE. cut.yml's "Rollforward claims" step carries the
    line `# $CUT_VERSION, not $GITHUB_REF_NAME: on a dispatch the ref name is a
    ...`, which is prose EXPLAINING that it does not depend on the tag. A
    predicate that reads raw text flags that step as tag-dependent and reports a
    defect that is the opposite of what the code does. Same shape as the
    launchd probe this repo's own README records: v1 grepped raw XML and failed
    a healthy agent because a comment cited a /tmp/ path.
    """
    for ln in (run or "").splitlines():
        s = ln.strip()
        if s.startswith("#") or not s:
            continue
        yield s


def main() -> int:
    if not WF.is_file():
        cannot(f"no workflow at {WF}")
    try:
        doc = yaml.safe_load(WF.read_text())
    except yaml.YAMLError as exc:
        cannot(f"cut.yml did not parse: {exc}")

    # `on:` is YAML 1.1 true. Accept either spelling rather than assuming one.
    triggers = doc.get("on", doc.get(True))
    jobs = doc.get("jobs") or {}
    if not isinstance(triggers, dict):
        cannot(f"could not read the `on:` block (got {type(triggers).__name__}), so no trigger was measured")
    if not jobs:
        cannot("cut.yml declares no jobs, so this suite would be asserting over an empty set")

    print(f"DENOMINATORS: {len(jobs)} job(s) in cut.yml, triggers: {sorted(triggers)}")

    # ===== ARM 1: the dispatch trigger exists at all =========================
    if DISPATCH in triggers:
        ok(f"arm 1: cut.yml declares a `{DISPATCH}:` trigger")
    else:
        bad(f"arm 1: no `{DISPATCH}:` trigger", f"declared: {sorted(triggers)}. Nothing can be dry-run before a tag.")

    # ===== ARM 2: the dry-run job exists and admits a dispatch ===============
    dry = jobs.get("dry-run")
    if dry is None:
        bad("arm 2: there is no `dry-run` job", f"jobs present: {sorted(jobs)}")
        dry = {}
    elif permits_dispatch(dry.get("if")):
        ok(f"arm 2: the dry-run job's condition admits a dispatch (if: {dry.get('if')!r})")
    else:
        bad("arm 2: the dry-run job cannot run on a dispatch", f"if: {dry.get('if')!r}")

    # ===== ARM 3: THE ROW'S OWN CLAIM. Everything it needs admits a dispatch =
    needs = dry.get("needs") or []
    if isinstance(needs, str):
        needs = [needs]
    closure, queue = [], list(needs)
    while queue:
        n = queue.pop()
        if n in closure:
            continue
        closure.append(n)
        nxt = (jobs.get(n) or {}).get("needs") or []
        queue.extend([nxt] if isinstance(nxt, str) else list(nxt))
    print(f"              dry-run needs, transitively: {closure or '(nothing)'}")
    blocked = [n for n in closure if not permits_dispatch((jobs.get(n) or {}).get("if"))]
    if blocked:
        bad(f"arm 3: {len(blocked)} of {len(closure)} needed job(s) cannot run on a dispatch: {blocked}",
            "a needed job that is skipped makes the dry run unreachable, and a skipped job is a grey tick, not a red one")
    else:
        ok(f"arm 3: all {len(closure)} needed job(s) admit a dispatch, so the dry run is structurally reachable")

    # ===== ARM 4: no needed step consumes a tag unconditionally ==============
    # This is the mechanism the row NAMED: a preflight that can only pass on a
    # tag. A step is dispatch-safe if it is tag-guarded (so it skips), branches
    # on the event name itself, or reads the ref through a fallback.
    offenders, examined = [], 0
    for jn in closure:
        for step in (jobs.get(jn) or {}).get("steps", []) or []:
            run = step.get("run")
            if not isinstance(run, str):
                continue
            examined += 1
            code = "\n".join(code_lines(run))
            if "GITHUB_REF_NAME" not in code and "github.ref_name" not in code:
                continue
            guard = str(step.get("if") or "")
            safe = (
                "refs/tags" in guard
                or "GITHUB_EVENT_NAME" in code
                or re.search(r"\$\{CUT_VERSION:-\$\{GITHUB_REF_NAME", code) is not None
            )
            if not safe:
                offenders.append(f"{jn}:{step.get('name')!r}")
    print(f"              {examined} run-step(s) examined across the needed jobs")
    if examined == 0:
        cannot("zero run-steps were examined, so 'no step consumes a tag' is a statement about the parser")
    if offenders:
        bad(f"arm 4: {len(offenders)} step(s) read the tag with no guard, no event branch and no fallback: {offenders}",
            "on a dispatch the ref name is a branch, so such a step fails and takes the dry run down with it")
    else:
        ok(f"arm 4: no needed step reads the tag unconditionally (of {examined} run-steps)")

    # ===== ARM 5: THE SAFETY CONTROL, REWRITTEN, BECAUSE THE CONTRACT MOVED ==
    #
    # 🔴 THIS ARM USED TO ASSERT "the cut job cannot run on a dispatch", AND
    # THAT IS NOW DELIBERATELY FALSE. CM051 #2118 widened the cut job to
    # `push || workflow_dispatch` on purpose, so a real signed, notarised,
    # stapled CANDIDATE can be built and WALKED before any tag exists. The
    # v1.0.100 walk failed six probes that only an installed Ostler can
    # exercise, four of them introduced since v1.0.95, while CI had 80+ green
    # checks and had measured none of it.
    #
    # Landing the old assertion would have done real damage in the quiet
    # direction: it reds against a correct cut.yml, and the obvious way to
    # green it is to revert #2118 and lose the ability to walk a candidate.
    #
    # WHAT THE SAFETY PROPERTY IS NOW, and why this arm does not re-implement
    # it: a dispatch may PRODUCE and must never PUBLISH, and that is enforced
    # per step by scripts/verify_dispatch_cannot_ship.py, which grades
    # publishing capabilities against each step's own `if:` and refuses any
    # dispatch-reachable job holding `contents: write`. Duplicating that here
    # would give two gates one job and let them disagree.
    #
    # So this arm asserts the ONE thing that is this suite's own business and
    # is not covered there: that the enforcer is actually wired into the file
    # this suite is about. A dry run is only cheap to fire while something
    # checks that a dispatch cannot publish.
    enforcer = "test_cut_dispatch_is_dry.sh"
    raw = WF.read_text(encoding="utf-8")
    if enforcer in raw:
        ok(f"arm 5 (safety control): cut.yml invokes {enforcer}, so the "
           f"publish route is graded on every dispatch and every tag")
    else:
        bad(f"arm 5: cut.yml does not invoke {enforcer}",
            "Nothing then checks that a dispatch cannot publish, and firing a "
            "dry run stops being a cheap pre-tag step.")

    print()
    print(f"RESULT: {len(PASS)} pass / {len(FAIL)} fail (of {len(PASS) + len(FAIL)} assertions)")
    return 1 if FAIL else 0


if __name__ == "__main__":
    print("THE DRY RUN IS STRUCTURALLY REACHABLE ON A DISPATCH")
    print("==================================================")
    sys.exit(main())
