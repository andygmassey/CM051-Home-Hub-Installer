
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

---

## Three things that are not about the queue, learned on 2026-09-18

The file is about driving merges, but these turned up while driving them and
they are cheaper to read here than to re-learn.

### A record only beats an inference while it cannot be forged

Given a fact that matters, prefer RECORDING it to RECONSTRUCTING it later from
a related value. That much is ordinary. The part that is not ordinary is that a
record has to be defended or it degrades into an inference with better manners.

The case: `IMPORT_DECLINED`. The customer answers no to the GDPR import at one
prompt. The first version of the fix reconstructed that answer downstream by
testing whether `EXPORTS_DIR` was empty, which is what the decline had emptied.
It was wrong, and not subtly: a later block refills `EXPORTS_DIR` for anybody
who has an `icloud-contacts.vcf`, so on the declined path the guard could not
fire at all. Its real firing condition had become "this customer has no iCloud
contacts file", which has no relationship to consent.

Recording the answer fixes that. What keeps it fixed is a test arm that pins
the number of WRITES to the variable at exactly two: the initialisation that
binds it under `set -u`, and the prompt. A third write means something other
than the person can answer for them, and the arm goes red. Without that arm the
record is just a variable anybody may set.

Generalises to: any consent flag, any "we already checked this" marker, any
provenance field. Ask who else can write it, then make the answer assertable.

### A gate that checks a structured field is bypassed by free text

CM051's checklist gate already prints, in capitals, `DO NOT STRIKE` when a row
declares `repo: CM051` but its number is not an issue there. That guard reads
the declared `repo:` FIELD.

On 2026-09-16, 41 rows were struck by writing the claim into the `gate:` TEXT
instead. Same claim, different surface, and the guard reads one of them. The
strike stood for two days and removed six rows from the cut's count, two of
them about consent and secrets.

Same family: the ledger gate checks pins while a shipping-behaviour change
rides in prose, and a vendor manifest asserts a pin while the content moved.

**When a guard exists, ask which surface it reads, then ask where else the same
claim can be made.**

### A mutant that did not apply reads exactly like one that was not caught

Known, written down, and it still happened five times in one shift between two
agents, with five different causes:

- a stale needle that no longer matched the code,
- a default nothing exercised, so changing it changed no observable,
- a `sed` range that ate the guard it was meant to mutate,
- a `grep` that counted its own pattern,
- and YAML folding a long scalar, so the parsed string was not a contiguous
  substring of the file and the locator found nothing.

Every one of them would have printed a clean run.

The only thing that caught them is that the mutation asserted its own
application FIRST and refused rather than reporting. Write the assertion before
the mutation, every time:

    assert s.count(old) == 1, "MUTANT DID NOT APPLY: %d matches" % s.count(old)

And restore with `cmp` afterwards, so "I put it back" is measured rather than
assumed.
