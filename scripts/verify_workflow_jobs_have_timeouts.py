#!/usr/bin/env python3
"""Every workflow job must declare timeout-minutes (register #426).

WHY THIS EXISTS -- MEASURED, IN THE ACT, NOT REASONED ABOUT.

2026-09-03T20:46:57Z, CM051 #1400: the `shell-macos` job of
tests-unwired-sweep-mz wedged. It sat `in_progress` for 51 minutes producing
no output, and it would have sat there until someone noticed, because
GitHub's default job timeout is 360 minutes and the workflow declared none.

The denominator that makes it a wedge and not slowness: the previous 10
completed runs of that same workflow took 32 to 48 SECONDS. And it was not
the branch -- the same branch passed the same job in 41s one commit earlier,
the delta being a single added row in a TSV data file that no shell test
executes. A fresh runner then passed it in ~90s on a rerun of the identical
commit.

A wedged job is the worst failure shape we have: it is indistinguishable
from a slow job, it blocks the PR indefinitely, and it reports nothing but a
spinner. A timeout converts it into a red with a name.

WHAT THE TIERS ARE BUILT ON

Measured across every workflow's own last-30 runs, 2026-08-13 to 2026-09-03
(21 days, 3423 runs, 3353 success). 121 of 121 workflow files covered, ZERO
unmeasured -- that mattered, because an earlier attempt using a global
recent-runs listing hit a 500-row PAGE CAP whose window turned out to be 30
MINUTES, and cut.yml had no runs in it at all. A tier set from that would
have been derived from a burst of fast PR gates with the longest job we own
entirely absent.

    per-workflow slowest SUCCESS:  p50 1.0m | p90 7.6m | p99 9.7m | MAX 21.2m
    over 10m: 2 of 121    over 20m: 1    over 30m: 0    over 45m: 0

    60 minutes: cut.yml, keyless-store-probe-tests.yml  (the only two over 10m)
    30 minutes: everything else

⚠️ THOSE FIGURES ARE RUN-LEVEL WALL TIME, WHICH INCLUDES QUEUEING. Job
execution is strictly shorter, so every headroom ratio above is a LOWER
BOUND -- conservative in the safe direction for SETTING a timeout. It is the
wrong unit for judging whether an EXISTING tight timeout is too tight: this
gate first flagged 8 pre-existing 5-minute timeouts as "under 1.5x observed",
and job-level measurement then showed those jobs actually run in 8 to 11
SECONDS (~28x headroom). The run-level figure was overstating by ~50x
because queue time dominates. Right instrument, wrong question -- so this
file does NOT police the value, only its PRESENCE.

EXIT CODES
  0  every job declares timeout-minutes
  1  at least one job does not
  2  CANNOT-RUN -- no workflows found, or none parsed. NOT a pass.
"""
import os
import sys

try:
    import yaml
except ImportError:
    print("CANNOT-RUN [no-pyyaml]: cannot parse workflows without PyYAML. "
          "Nothing was examined; this is not a pass.", file=sys.stderr)
    sys.exit(2)

WF_DIR = ".github/workflows"


def main() -> int:
    root = os.environ.get("GITHUB_WORKSPACE") or "."
    d = os.path.join(root, WF_DIR)
    if not os.path.isdir(d):
        print(f"CANNOT-RUN [no-workflow-dir]: {d} is not a directory. "
              f"Nothing was examined.", file=sys.stderr)
        return 2

    files = sorted(f for f in os.listdir(d) if f.endswith((".yml", ".yaml")))
    if not files:
        print(f"CANNOT-RUN [no-workflows]: 0 workflow files in {d}. A zero here "
              f"means the scan is broken, not that the estate is clean.",
              file=sys.stderr)
        return 2

    missing = []
    parsed = 0
    jobs_seen = 0
    reusable = 0
    unparsed = []

    for f in files:
        try:
            doc = yaml.safe_load(open(os.path.join(d, f), encoding="utf-8"))
        except Exception as e:                       # noqa: BLE001
            unparsed.append((f, str(e)[:100]))
            continue
        parsed += 1
        if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict):
            continue
        for name, job in doc["jobs"].items():
            if not isinstance(job, dict):
                continue
            # A reusable-workflow call cannot carry timeout-minutes: the key is
            # invalid at a `uses:` job and GitHub rejects the file. Excluded on
            # purpose, and COUNTED so the exclusion is visible rather than a
            # silent hole in the denominator.
            if "uses" in job:
                reusable += 1
                continue
            jobs_seen += 1
            if job.get("timeout-minutes") is None:
                missing.append((f, name))

    # ANTI-VACUITY. A broken parse prints the same clean zero as a compliant
    # estate. Both of these must be non-zero or nothing was measured.
    if parsed == 0:
        print(f"CANNOT-RUN [none-parsed]: 0 of {len(files)} workflow files "
              f"parsed as YAML. Not a pass.", file=sys.stderr)
        for f, e in unparsed[:5]:
            print(f"    {f}: {e}", file=sys.stderr)
        return 2
    if jobs_seen == 0:
        print(f"CANNOT-RUN [no-jobs]: parsed {parsed} workflow file(s) and found "
              f"0 runnable jobs. This repo has always had jobs, so a zero here "
              f"is a broken predicate.", file=sys.stderr)
        return 2

    print(f"EXAMINED: {parsed} of {len(files)} workflow file(s), "
          f"{jobs_seen} runnable job(s) "
          f"({reusable} reusable-workflow call(s) excluded -- the key is "
          f"invalid there).")

    if unparsed:
        print(f"CANNOT-RUN [partial-parse]: {len(unparsed)} file(s) did not "
              f"parse. A verdict over the rest would understate the "
              f"population.", file=sys.stderr)
        for f, e in unparsed:
            print(f"    {f}: {e}", file=sys.stderr)
        return 2

    if missing:
        print(f"\nFAIL: {len(missing)} of {jobs_seen} job(s) declare no "
              f"timeout-minutes.\n", file=sys.stderr)
        for f, n in missing:
            print(f"    {f} :: {n}", file=sys.stderr)
        print("\nA job without a timeout inherits GitHub's 360-minute default. "
              "That is not\na bound, it is a whole working day of a wedged "
              "runner blocking a PR while\nlooking identical to a slow one -- "
              "measured live on #1400, 51 minutes into a\njob whose previous "
              "10 runs took 32 to 48 SECONDS.\n\n"
              "Add `timeout-minutes: 30` under the job's `runs-on:` (60 for "
              "cut.yml and\nkeyless-store-probe-tests.yml, the only two "
              "workflows measured over 10 min).",
              file=sys.stderr)
        return 1

    print(f"OK: all {jobs_seen} runnable job(s) declare timeout-minutes. "
          f"No job can wedge past its own bound.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
