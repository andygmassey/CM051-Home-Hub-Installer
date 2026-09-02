#!/usr/bin/env python3
"""Did we merge a PR while a gate was saying no?

WHY THIS EXISTS. CM051 main is NOT branch-protected (task #607): there are no
required status checks, so `mergeStateStatus` returns CLEAN whether the checks
passed, failed, or are still running, and NOTHING mechanically prevents merging
over a red. The discipline is entirely human. This measures whether it holds.

⚠️ THE PREDICATE IS THE WHOLE POINT, AND I GOT IT WRONG THE FIRST TIME.

My first version asked "does the head sha carry any non-success conclusion".
It reported 7 of 60 merged PRs as RED AT MERGE TIME, with `ledger-pr` failing in
every one -- the gate that enforces the shipping-ledger mandate. I was minutes
from posting that as a 🔴🔴🔴 finding accusing three colleagues of merging over
their own gate seven times.

It was FALSE. A commit sha accumulates EVERY check run it has ever had. When a
gate fails, someone pushes a fix, and the gate re-runs green, BOTH conclusions
live on that sha forever. All seven had a SUCCESSFUL ledger-pr completing before
the merge:

    #1344   failed 17:41:51   RE-PASSED 17:44:23   merged 17:45:30

That is the gate working, not the gate being ignored. The real answer was 0 of 60.

SO THE QUESTION IS NEVER "is there a failure". It is:
    for each (WORKFLOW, check name), what was the LAST conclusion completing at
    or before mergedAt?
Runs are an append-only history. Only the last one per check is a verdict.

AND THE KEY IS A PAIR, NOT A NAME. A job name is not unique across workflows:
measured on this repo, `predicate-self-test` is emitted by 4 different workflows
on a single sha, `gate` and `self-test` by 3 each. Keyed by name alone, a green
from one workflow masks a red from another -- this tool committing the exact
error it was built to find. See last_word_per_name() for why check_suite.id,
which is free and looks like the obvious fix, is the wrong key.

A positive control cannot catch this class. A control proves your predicate RUNS;
it never proves your predicate ASKS THE RIGHT QUESTION.

OUTCOMES, three states, never two:
    RED-AT-MERGE   a check's last word before the merge was failure/cancelled/timed_out
    GREEN          every check's last word was success/skipped/neutral
    CANNOT-RUN     the API refused, or the sha reports zero checks
NO-CHECKS is CANNOT-RUN, never GREEN: a sha with no runs is unmeasured, not clean.
"""
import json, re, subprocess, sys, collections

REPO = "andygmassey/CM051-Home-Hub-Installer"
BAD = {"failure", "cancelled", "timed_out", "action_required", "stale"}
OK = {"success", "skipped", "neutral"}


def gh(args, timeout=45):
    r = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=timeout)
    return (r.returncode, r.stdout, r.stderr)


# ── THE PREDICATE, FACTORED OUT SO IT CAN BE TESTED ────────────────────────────
# These two live at module scope for one reason: tests/test_audit_red_merges_
# predicate.py IMPORTS them. It used to carry its own copy under a docstring
# reading "Mirrors audit_red_merges.py", which meant breaking the code below
# could never turn that test red -- a green light with no bulb behind it, which
# is the exact thing this file exists to detect. Do not re-inline them.

def last_word_per_name(rows, merged):
    """(workflow, name) -> (conclusion, completed_at) for the LAST run completing
    at or before `merged`.

    Runs are an append-only history: a sha accumulates every run it ever had, so
    a failure that was later fixed still sits there forever. Only the last run
    per check is a verdict.

    THE KEY IS (workflow, name), NOT name. A JOB NAME IS NOT UNIQUE. Measured on
    sha 4d18745c of this repo: `predicate-self-test` appears 4 times from 4
    DIFFERENT workflows (scheduled-agent-failure-is-loud, fda-rerun-recurs,
    fda-rerun-ingests, calendar-backfill-multiyear), and one of the four was red
    while the others were green. Keyed by name alone, whichever completed last
    wins and a green from one workflow MASKS a red from another -- the precise
    failure this tool exists to detect, occurring inside the tool itself.
    `gate` and `self-test` collide the same way, 3 each.

    And the key must NOT be check_suite.id even though that is free and distinct
    per workflow: a RE-RUN gets a new suite too, so suite-keying would make the
    fixed run a separate entry from the failed one and resurrect the false
    7-of-60 reading this predicate was written to kill. Workflow identity is
    stable across re-runs; suite identity is not.
    """
    last = {}
    for workflow, name, concl, done in rows:
        if not done:
            continue                      # never completed: not a verdict at all
        if done > merged:
            continue                      # completed after the merge: not the merge-time verdict
        key = (workflow, name)
        prev = last.get(key)
        if prev is None or done >= prev[1]:
            last[key] = (concl, done)
    return last


def classify(rows, merged):
    """Three states, never two. Returns (verdict, detail).

    THE THIRD STATE IS NOT DECORATION. A check whose conclusion is `null` was
    STILL RUNNING when the merge happened. It did not pass. Bucketing it with
    the passes would make GREEN mean "nothing had failed YET", and absence of
    failure is not a pass -- so it lands in CANNOT-RUN with its name printed.
    Same for a check with no completed run before the merge at all.
    """
    if not rows:
        return ("CANNOT-RUN", "zero check runs -- unmeasured, NOT clean")
    last = last_word_per_name(rows, merged)
    if not last:
        return ("CANNOT-RUN", "no run completed at or before mergedAt")

    bad = {n: c for n, (c, _) in last.items() if c in BAD}
    if bad:
        return ("RED-AT-MERGE", bad)

    # Neither a pass nor a fail: `null` (in flight), or a conclusion string
    # GitHub added after this was written. Both are unmeasured, not clean.
    unknown = {n: c for n, (c, _) in last.items() if c not in OK}
    silent = sorted({(w, n) for w, n, _, _ in rows} - set(last))
    if unknown or silent:
        return ("CANNOT-RUN", {"not-a-conclusion": unknown,
                               "no-completed-run-before-merge": silent})
    return ("GREEN", len(last))


def main(limit=60):
    rc, out, err = gh(["pr", "list", "--repo", REPO, "--state", "merged",
                       "--limit", str(limit), "--json", "number,headRefOid,mergedAt"])
    if rc != 0:
        print(f"CANNOT-RUN: pr list failed rc={rc}: {err.strip()[:200]}")
        return 2
    prs = json.loads(out)
    print(f"denominator: {len(prs)} merged PRs")
    if prs:
        print(f"window: {prs[-1]['mergedAt']} -> {prs[0]['mergedAt']}")

    tally = collections.Counter()
    reds = []
    for p in prs:
        sha = p["headRefOid"]

        # ONE extra call per PR (not per check) to learn which WORKFLOW each run
        # belongs to. Per-check resolution would be ~30 calls per PR and reliably
        # earns a 504; this is 1, and it is what makes the (workflow, name) key
        # affordable. Failure here is CANNOT-RUN, never a silent fall back to
        # name-only keying, because name-only keying IS the masking bug.
        rc, out, err = gh(["api", f"repos/{REPO}/actions/runs?head_sha={sha}&per_page=100",
                           "--paginate", "--jq",
                           '.workflow_runs[] | [(.id|tostring), (.path // .name)] | @tsv'])
        if rc != 0:
            tally["CANNOT-RUN"] += 1
            print(f"  #{p['number']}  CANNOT-RUN (workflow-run list rc={rc}); without it, "
                  f"same-named jobs from different workflows would mask each other")
            continue
        run_wf = dict(l.split("\t", 1) for l in out.strip().split("\n") if "\t" in l)

        rc, out, err = gh(["api", f"repos/{REPO}/commits/{sha}/check-runs?per_page=100",
                           "--paginate", "--jq",
                           '.check_runs[] | [.name, (.conclusion // "null"), (.completed_at // ""), (.details_url // "")] | @tsv'])
        if rc != 0:
            tally["CANNOT-RUN"] += 1
            print(f"  #{p['number']}  CANNOT-RUN (api rc={rc})")
            continue

        rows = []
        for line in out.strip().split("\n"):
            if not line.strip():
                continue
            fld = line.split("\t")
            name, concl, done = fld[0], fld[1], fld[2]
            url = fld[3] if len(fld) > 3 else ""
            m = re.search(r"/actions/runs/(\d+)", url)
            # Unknown workflow keys as the run id: still distinct per workflow, so
            # it cannot mask, and it degrades toward over-reporting rather than
            # under-reporting. A masking default would be the wrong way to be wrong.
            wf = run_wf.get(m.group(1), f"run:{m.group(1)}") if m else "unknown-workflow"
            rows.append((wf, name, concl, done))

        # THE CORRECTED PREDICATE lives in classify(), which the test imports.
        # Calling it here is what makes that test load-bearing rather than a
        # study of a copy.
        merged = p["mergedAt"]
        verdict, detail = classify(rows, merged)
        tally[verdict] += 1
        if verdict == "RED-AT-MERGE":
            reds.append((p["number"], merged, detail, len(last_word_per_name(rows, merged))))
        elif verdict == "CANNOT-RUN":
            print(f"  #{p['number']}  CANNOT-RUN ({detail})")

    print("\n=== VERDICT HISTOGRAM ===")
    for k in ("GREEN", "RED-AT-MERGE", "CANNOT-RUN"):
        print(f"  {tally[k]:5d}  {k}")
    print(f"  ------ TOTAL: {sum(tally.values())} ------")
    if reds:
        print("\n=== RED AT MERGE, named ===")
        for n, m, bad, tot in reds:
            pretty = ", ".join(f"{w}:{nm}={c}" for (w, nm), c in sorted(bad.items()))
            print(f"  #{n}  merged={m}  checks={tot}  last-word-not-green=[{pretty}]")
    else:
        print("\n  No PR was merged while a check's last word was red.")
    return 1 if reds else 0


if __name__ == "__main__":
    sys.exit(main(int(sys.argv[1]) if len(sys.argv) > 1 else 60))
