#!/usr/bin/env python3
"""Every workflow step carries a command, because one that does not voids the
whole workflow and NOTHING RUNS.

🔴 WHY THIS EXISTS. On 2026-09-18 CM051 #2182 inserted a new step INSIDE an
existing one. The result parsed as valid YAML and looked like this:

    - name: a verdict is not a mention
      if: always()
    # ...comment block introducing the new step...
    - name: a blocker with no tracker issue still blocks
      if: always()
      run: python3 tests/test_a_blocker_with_no_issue_still_blocks.py

      run: python3 tests/test_a_verdict_is_not_a_mention.py

The first step kept its name and its `if:` and lost its `run:`, which was
orphaned below the step that had been dropped on top of it.

WHAT THAT COSTS, AND IT IS NOT ONE STEP. GitHub refuses the ENTIRE workflow at
startup. The run is created, it is marked failed, and it contains ZERO JOBS, so
there is no job log to read and no failing step to name. Measured:

    gh api repos/<r>/actions/runs/<id>/jobs   ->   {"total_count": 0, "jobs": []}
    gh run view --log-failed                  ->   "log not found"

Main was red for an hour on six consecutive pushes, every branch inherited it,
and the one instrument anybody reaches for first, the job log, had nothing in
it. A defect that deletes the evidence of itself is worth a gate of its own.

AND YAML CANNOT CATCH IT. The file is well-formed YAML; the step is simply a
mapping with no command key. `yaml.safe_load` is happy. Only a schema check
sees it, which is why this asserts on the LOADED structure rather than on the
text.

THE DENOMINATOR IS ASSERTED. A sweep that silently stops finding workflows
would report zero offenders and read as a clean sheet, which is the exact shape
this repository has been burned by. Fewer than 50 steps examined is CANNOT-RUN.
"""
import pathlib
import sys

try:
    import yaml
except ImportError as exc:                                   # pragma: no cover
    print("CANNOT-RUN: pyyaml is not importable (%s). NOTHING was checked." % exc)
    raise SystemExit(2)

WORKFLOWS = pathlib.Path(__file__).resolve().parent.parent / ".github" / "workflows"
FLOOR = 50

FAILURES = []


def offenders(doc, where):
    """Steps carrying neither `run` nor `uses`, with a count of what was seen."""
    bad, seen = [], 0
    for job_name, job in (doc.get("jobs") or {}).items():
        for step in (job.get("steps") or []):
            seen += 1
            if not isinstance(step, dict):
                bad.append("%s :: %s :: step is %s, not a mapping"
                           % (where, job_name, type(step).__name__))
                continue
            if "run" not in step and "uses" not in step:
                bad.append("%s :: %s :: %r has neither run nor uses"
                           % (where, job_name, step.get("name", "<unnamed>")))
    return bad, seen


def main():
    if not WORKFLOWS.is_dir():
        print("CANNOT-RUN: %s is not a directory. NOTHING was checked." % WORKFLOWS)
        return 2

    files = sorted(WORKFLOWS.glob("*.yml")) + sorted(WORKFLOWS.glob("*.yaml"))
    total_steps = 0
    for f in files:
        try:
            doc = yaml.safe_load(f.read_text(encoding="utf-8"))
        except Exception as exc:
            FAILURES.append("%s :: UNPARSEABLE :: %s" % (f.name, exc))
            continue
        if not isinstance(doc, dict):
            FAILURES.append("%s :: top level is %s, not a mapping"
                            % (f.name, type(doc).__name__))
            continue
        bad, seen = offenders(doc, f.name)
        FAILURES.extend(bad)
        total_steps += seen

    print("EXAMINED: %d workflow file(s), %d step(s)" % (len(files), total_steps))

    # A zero denominator reads as success. Refuse instead.
    if total_steps < FLOOR:
        print("CANNOT-RUN: only %d step(s) were examined, below the floor of %d."
              " The sweep found nothing to check, which is not the same as"
              " finding nothing wrong. NOTHING was established."
              % (total_steps, FLOOR))
        return 2

    # CONTROLS. Both must behave or the negatives above are worthless.
    malformed = yaml.safe_load(
        "jobs:\n  j:\n    steps:\n      - name: no command here\n        if: always()\n")
    wellformed = yaml.safe_load(
        "jobs:\n  j:\n    steps:\n      - name: fine\n        run: true\n")
    c_bad, c_seen = offenders(malformed, "<control>")
    c_ok, _ = offenders(wellformed, "<control>")
    if len(c_bad) != 1 or c_seen != 1:
        print("CANNOT-RUN: the positive control did not fire (%d offender(s) in"
              " %d step(s), wanted 1 in 1), so a clean result above would mean"
              " nothing." % (len(c_bad), c_seen))
        return 2
    if c_ok:
        print("CANNOT-RUN: the negative control fired on a well-formed step, so"
              " this check flags correct workflows.")
        return 2
    print("  CONTROL: a step with neither run nor uses IS detected")
    print("  CONTROL: a step with run is NOT flagged")

    if FAILURES:
        print()
        print("FAILED (%d). A step with no command makes GitHub refuse the WHOLE"
              " workflow at startup: the run reports zero jobs, there is no job"
              " log, and every branch inherits the red." % len(FAILURES))
        for f in FAILURES:
            print("    %s" % f)
        return 1

    print("\nOK: every step in every workflow carries a command.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
