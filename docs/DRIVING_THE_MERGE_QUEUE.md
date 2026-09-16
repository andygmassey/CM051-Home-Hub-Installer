# Driving the merge queue on CM051

Written 2026-09-16, after two sessions hit the same two edges on the same day.
Both cost real time and neither is guessable from the outside.

## Why merging is serial whatever you do

Measured, `gh api repos/andygmassey/CM051-Home-Hub-Installer/rules/branches/main`:

    {"checks":["CI Required Gate"], "strict": true}

One required check, **strict up-to-date**. The instant a merge lands, every
other branch in the repo is BEHIND by construction.

**So only one PR can be up to date at a time.** Merging is inherently serial no
matter how many people drive it. Two drivers running at once does not halve the
time, it doubles the wasted updates: each invalidates the other's in-flight
branch before its gate can conclude. Measured on the day this was written, that
was most of a 334-run backlog.

**Drive alone, in a batch.** If two of you are clearing PRs, split the list,
then take turns with the whole pool. Sequential batches, never parallel drivers.

**Update ONE branch at a time and let its gate conclude.** The required gate
polls every other check on the head and finishes last, so it can take about 40
minutes on this repo. Updating three at once starts three 40-minute waits, two
of which you will invalidate yourself.

## `gh run rerun` replays the ORIGINAL event payload

This is the one that looks like a safe action and is not.

Any gate that reads the PULL REQUEST BODY reads it **from the event payload**,
not from the API. `enforce-ledger-write.yml` is one, and its own header says so.
So:

1. The gate fails because the body is wrong.
2. You fix the body. A fresh `edited` event fires and the gate PASSES.
3. You re-run the old failed job "to be sure".
4. **The re-run replays the pre-edit body and fails again**, overwriting the
   passing result.

Measured 2026-09-16: a green ledger-pr check was overwritten by a stale red
exactly that way, and the PR sat blocked on a body that had already been
corrected.

**The remedy for a body-reading gate is to edit the body**, which fires a fresh
event. Never re-run it. An aggregate that reads no body, such as `CI Required
Gate`, is safe to re-run, which is why the trap is easy to miss: the same
command is correct for one gate and destructive for another.

## `DIRTY` is terminal for an automated driver

`mergeStateStatus: DIRTY` means a merge conflict. It needs a human merge and it
will never clear on its own.

A driver that only checks for failures and staleness will poll it forever.
Measured: 32 polls, about 20 minutes, while every PR behind it waited.

**Skip DIRTY and report it.** Resolve conflicts by hand, separately, and give
generated files (`TEST_WIRING.tsv` and similar) to their generator rather than
hand-merging: taking either side of a conflict in a sorted, generated file
silently drops whichever row the other side registered, and the file still
parses afterwards, so nothing tells you.

## A checklist that avoids all three

1. `gh pr view N --json mergeStateStatus` first. DIRTY, skip and report.
2. Any failing check: read it, fix the cause, do NOT re-run a body-reading gate.
3. BEHIND: update ONE branch, then wait for `CI Required Gate` to conclude on
   the new head before touching another.
4. Merge, then expect every other branch to be BEHIND again. That is normal and
   not a symptom.


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
