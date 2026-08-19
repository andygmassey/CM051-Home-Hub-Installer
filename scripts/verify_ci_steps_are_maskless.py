#!/usr/bin/env python3
"""No test in CI may be silenced by an earlier test in the same job (#683).

THE DEFECT. A GitHub Actions job stops at its first failing step. Every later
step is reported as "skipped" -- grey in the UI, not red. So a job listing
eleven test steps proves eleven things only on a run where nothing fails. On the
run where a test breaks, which is the only run whose coverage anyone cares
about, it proves ONE thing and says nothing at all about the other ten.

WHY THE WIRING MANIFEST CANNOT SEE THIS. tests/TEST_WIRING.tsv records a test as
WIRED when a starter names it. That is a statement about the FILE, and it stays
true when the step never executes. So "WIRED" and "ran" diverge exactly when a
run goes red, and the manifest keeps reporting the reassuring one. #648 measured
which tests run nowhere; this measures which of the remainder stop running the
moment anything is wrong.

WHY IT MATTERS BEYOND TIDINESS. Two independent breakages in one job surface one
at a time: fix the first, push, discover the second, fix, push. Serial discovery
of parallel facts, at one CI round-trip each. And a reviewer reading a red run
sees ten grey ticks that look like "not reached", not "unknown".

THE RULE. Every test-running step that has ANOTHER TEST STEP before it in the
same job must carry `if: always()`.

The FIRST test step in a job is deliberately exempt. What precedes it is
checkout and setup; if those fail there is nothing to test, and forcing the run
prints a file-not-found on top of the real failure. The defect being gated is
narrower and worse: one test silencing another.

NO EXEMPTION LIST, ON PURPOSE. If a step genuinely must not run after an earlier
one fails, it does not have a scheduling problem, it has a DEPENDENCY -- and a
dependency belongs in a separate job with `needs:`, where GitHub expresses it
honestly, rather than as an accident of step order.

Exit 0 no step is maskable / 1 at least one is / 2 could not run.
"""
import sys
import pathlib

USAGE = "usage: verify_ci_steps_are_maskless.py [WORKFLOWS_DIR]"

EXIT_OK = 0
EXIT_VIOLATION = 1
EXIT_CANNOT_RUN = 2


def is_test_step(step):
    """Does this step actually invoke a test?

    Deliberately generous: a step that runs a test under any of these spellings
    counts. A miss here is a silent hole in the gate, which is the failure mode
    this whole file exists to prevent, so the patterns err towards including.
    """
    run = step.get("run")
    if not isinstance(run, str):
        return False
    return ("tests/test_" in run
            or "-m unittest tests." in run
            or "test_vendor_browser_history" in run)


def is_always(step):
    """Does this step run even after an earlier failure?"""
    cond = step.get("if")
    if cond is None:
        return False
    c = str(cond).replace(" ", "").lower()
    # always() is the canonical form. !cancelled() is the newer spelling and
    # success()||failure() the long-hand; all three keep the step running after
    # an earlier failure, which is the property being gated -- not the wording.
    return ("always()" in c
            or "!cancelled()" in c
            or "success()||failure()" in c
            or "failure()||success()" in c)


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("-")]
    if len(args) > 1:
        print(USAGE, file=sys.stderr)
        return EXIT_CANNOT_RUN

    wf_dir = pathlib.Path(args[0]) if args else pathlib.Path(".github/workflows")

    if not wf_dir.is_dir():
        print(f"COULD NOT RUN: {wf_dir} is not a directory (exit 2)",
              file=sys.stderr)
        return EXIT_CANNOT_RUN

    try:
        import yaml
    except ImportError:
        print("COULD NOT RUN: PyYAML is not installed, so no workflow could be "
              "parsed. This is a cannot-run, NOT a pass (exit 2)",
              file=sys.stderr)
        return EXIT_CANNOT_RUN

    files = sorted(wf_dir.glob("*.yml")) + sorted(wf_dir.glob("*.yaml"))
    if not files:
        print(f"COULD NOT RUN: no workflow files under {wf_dir}. An empty scan "
              f"scores identically to a clean one, so it is not a pass (exit 2)",
              file=sys.stderr)
        return EXIT_CANNOT_RUN

    violations = []
    n_test_steps = 0
    n_jobs_with_tests = 0

    for f in files:
        try:
            doc = yaml.safe_load(f.read_text())
        except Exception as e:  # noqa: BLE001 -- any parse failure is cannot-run
            print(f"COULD NOT RUN: {f.name} did not parse: {e} (exit 2)",
                  file=sys.stderr)
            return EXIT_CANNOT_RUN

        if not isinstance(doc, dict):
            continue

        jobs = doc.get("jobs")
        if not isinstance(jobs, dict):
            continue

        for job_name, job in jobs.items():
            if not isinstance(job, dict):
                continue
            steps = job.get("steps")
            if not isinstance(steps, list):
                continue

            test_positions = [i for i, s in enumerate(steps)
                              if isinstance(s, dict) and is_test_step(s)]
            if not test_positions:
                continue

            n_jobs_with_tests += 1
            n_test_steps += len(test_positions)

            first = test_positions[0]
            for i in test_positions:
                if i == first:
                    continue
                if is_always(steps[i]):
                    continue
                name = steps[i].get("name") or (steps[i].get("run") or "")[:60]
                violations.append((f.name, job_name, str(name).strip()))

    print(f"verify_ci_steps_are_maskless: {len(files)} workflow file(s), "
          f"{n_jobs_with_tests} job(s) running tests, {n_test_steps} test step(s)")

    if violations:
        print()
        print(f"MASKABLE: {len(violations)} test step(s) are skipped when an "
              f"earlier test in the same job fails:")
        for wf, job, name in violations:
            print(f"  {wf} :: {job} :: {name}")
        print()
        print("Each needs `if: always()` so a red run still reports it, or the "
              "step belongs in its own job with `needs:` if it genuinely "
              "depends on an earlier one.")
        return EXIT_VIOLATION

    print("OK: no test step can be silenced by an earlier test in its job.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv))
