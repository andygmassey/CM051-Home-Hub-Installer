
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
