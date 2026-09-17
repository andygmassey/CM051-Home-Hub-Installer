
## The check count is a property of install.sh, not of the policy

Measured 2026-09-16, three PRs open at the same time on the same tree:

| PR | files touched | check-runs fired |
|---|---|---|
| #2039 | 1, `scripts/verify_pr_gate_aggregate.sh` | 41 |
| #2037 | 1, `gui/OstlerInstaller/Views/InstallCompleteView.swift` | 43 |
| #2038 | 3, including `install.sh` | **134** |

The floor is about 41: the 32 PR-triggered workflows that carry no path
filter at all. Everything above that floor is path-filtered work that MATCHED.
116 of the 148 PR-triggered workflows already have path filters, so "add path
filters" is not an available remedy -- it is already the dominant pattern.

**The load is install.sh.** It is 33,792 lines, it is the install, and roughly
ninety of those path-filtered gates name it. Any change to it, however small,
fires about 134 checks. A one-line comment fix in install.sh costs the same
runner time as a rewrite of it.

### What follows, and what does not

Row 1043 offered three remedies. Against this measurement:

- **Raise the aggregate timeout.** Treats the symptom. The job's own
  `timeout-minutes: 60` leaves only ~15 minutes of headroom over the current
  2700s window anyway, and a job GitHub kills reports no verdict at all --
  strictly worse than a CANNOT-RUN.
- **Reduce the check count per PR.** Not reachable without splitting
  install.sh, which is not a launch-week change.
- **Serialise the lane.** This one, and it is already in place: a driver that
  updates one branch, waits for its required gate, merges, and only then
  touches the next. Serial is not a throughput choice. With
  `strict_required_status_checks_policy: true` and ONE required context, every
  merge puts every other branch behind, so two drivers invalidate each other's
  in-flight gates.

**So the policy stays.** Strict-with-one-required-context is a deliberate
safety property; the measurement says its cost is not what row 1043 assumed,
and the cost that does exist is owned by install.sh's size rather than by the
ruleset.

### The discipline that actually saves runner time

One push per fix to install.sh costs 134 checks per fix. Batch install.sh
changes into as few pushes as the work allows. This is the same conclusion row
1043 reached from the other direction ("manifest findings are batched into one
push rather than one push per finding"), and it is worth restating because the
tempting move -- push the small fix now, it is only one line -- is the
expensive one.

And if the lane is already deep, the cheapest intervention is to CANCEL YOUR
OWN queued runs rather than wait. Measured the same day: 79 runs queued
repo-wide, 44 of them from a single push of mine, while the PR that unblocked
main sat behind them with two checks that had no runner. Cancelling 35 of my
own took the repo-wide queue to 0 and that PR merged within the minute. The
cancelled runs are re-run afterwards by editing the PR body -- NEVER with
`gh run rerun`, which replays the ORIGINAL event payload and restores the
stale result.

### The trap that cost the most: a driver that rewrites branches on a poll

**Measured 2026-09-18.** An automated merge loop called `gh pr update-branch` on
every BEHIND branch, every cycle. In one night it produced **33 merge-from-main
commits across 12 branches**:

```
#2116  9      #2128  4      #2131  2      #2136  2
#2123  7      #2130  2      #2132  2      #2137  1
#2133  1      #2134  1      #2052  1      #2065  1
```

At ~140 checks per push that is roughly **4,600 check-runs of pure churn**, and
the `CI Required Gate` on those same PRs then has to wait for all of them.

**The shape is worse than the total.** Merge one PR, main moves, eleven branches
go BEHIND, update eleven, 1,540 checks, merge one more. *The more it worked, the
more work it made.* A poll side effect that costs 140 checks is not a poll side
effect, it is a push.

The branches open longest take the worst of it, because they are BEHIND after
*every* merge. That is why #2116 and #2123 carried 9 and 7 while branches opened
an hour earlier carried 1.

**A BEHIND branch is not a problem until it is otherwise ready.** Update it once,
deliberately, at the moment it would otherwise merge. Never on a timer.

#### And the half that is a data-loss shape, not a cost

**Never let an automated driver rewrite a branch a human has checked out.**

The same loop twice pushed its own merge onto a branch while a person was
resolving that branch's conflict locally: once on a divergence record, once on
`install.sh` line citations. Both of GitHub's resolutions happened to be
correct. That is the luckiest available outcome, not evidence the design was
safe, and the next one lands silently on top of work nobody kept a copy of.

The recovery that worked, and the order matters: **verify the remote's
resolution against the gate that owns it BEFORE discarding your own.** For the
citation conflict that was
`tests/test_store_curl_config_survives_the_promote.sh` at 16 pass / 0 fail. The
tempting order -- discard the redundant local work first, because the remote
"obviously" already has it -- destroys the only thing that could have caught a
bad merge.

#### A citation conflict cannot be resolved by picking a side

When both sides of a conflict are the same comment with different line numbers,
**neither side is right after the merge**. The branch shifted the file; so did
main. Picking either leaves every number wrong.

Let the gate name the stale ones, then re-point each by **locating its
construct** in the merged file. Do not apply the offset, even when the offset is
uniform and correct: an offset holds until one hunk lands somewhere else, and
then it is silently wrong for every citation after that point. Locating the
construct cannot drift. It is a known cost paid to avoid an unbounded one.
