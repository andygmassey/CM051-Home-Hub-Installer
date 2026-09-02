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
    for each check NAME, what was the LAST conclusion completing at or before
    mergedAt?
Runs are an append-only history. Only the last one per name is a verdict.

A positive control cannot catch this class. A control proves your predicate RUNS;
it never proves your predicate ASKS THE RIGHT QUESTION.

OUTCOMES, three states, never two:
    RED-AT-MERGE   a check's last word before the merge was failure/cancelled/timed_out
    GREEN          every check's last word was success/skipped/neutral
    CANNOT-RUN     the API refused, or the sha reports zero checks
NO-CHECKS is CANNOT-RUN, never GREEN: a sha with no runs is unmeasured, not clean.
"""
import json, subprocess, sys, collections

REPO = "andygmassey/CM051-Home-Hub-Installer"
BAD = {"failure", "cancelled", "timed_out", "action_required", "stale"}
OK = {"success", "skipped", "neutral"}


def gh(args, timeout=45):
    r = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=timeout)
    return (r.returncode, r.stdout, r.stderr)


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
        rc, out, err = gh(["api", f"repos/{REPO}/commits/{p['headRefOid']}/check-runs?per_page=100",
                           "--paginate", "--jq",
                           '.check_runs[] | [.name, (.conclusion // "null"), (.completed_at // "")] | @tsv'])
        if rc != 0:
            tally["CANNOT-RUN"] += 1
            print(f"  #{p['number']}  CANNOT-RUN (api rc={rc})")
            continue
        rows = [l.split("\t") for l in out.strip().split("\n") if l.strip()]
        if not rows:
            tally["CANNOT-RUN"] += 1
            print(f"  #{p['number']}  CANNOT-RUN (zero check runs -- unmeasured, NOT clean)")
            continue

        # THE CORRECTED PREDICATE: last conclusion per NAME, at or before mergedAt.
        merged = p["mergedAt"]
        last = {}
        for name, concl, done in rows:
            if done and done > merged:
                continue                      # completed after the merge: not the merge-time verdict
            prev = last.get(name)
            if prev is None or done >= prev[1]:
                last[name] = (concl, done)
        if not last:
            tally["CANNOT-RUN"] += 1
            print(f"  #{p['number']}  CANNOT-RUN (no run completed before mergedAt)")
            continue
        bad = {n: c for n, (c, _) in last.items() if c in BAD}
        if bad:
            tally["RED-AT-MERGE"] += 1
            reds.append((p["number"], merged, bad, len(last)))
        else:
            tally["GREEN"] += 1

    print("\n=== VERDICT HISTOGRAM ===")
    for k in ("GREEN", "RED-AT-MERGE", "CANNOT-RUN"):
        print(f"  {tally[k]:5d}  {k}")
    print(f"  ------ TOTAL: {sum(tally.values())} ------")
    if reds:
        print("\n=== RED AT MERGE, named ===")
        for n, m, bad, tot in reds:
            print(f"  #{n}  merged={m}  checks={tot}  last-word-not-green={bad}")
    else:
        print("\n  No PR was merged while a check's last word was red.")
    return 1 if reds else 0


if __name__ == "__main__":
    sys.exit(main(int(sys.argv[1]) if len(sys.argv) > 1 else 60))
