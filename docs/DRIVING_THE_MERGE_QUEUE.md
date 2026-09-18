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
changes into as few pushes as the work allows.

**AND THAT ADVICE IS AIMED AT THE WRONG FILE, WHICH MADE IT READ AS PERMISSION
TO PUSH FREELY EVERYWHERE ELSE.** Measured 2026-09-18 on live heads, after one
agent pushed 22 one-row board commits and starved the lane for an hour:

| PR | touches | check-runs |
|---|---|---|
| #2132 | `cut-manifests/` only | 45 |
| #2148 | docs only | 40 |
| #2146 | board + a workflow + a test | 78 |
| #2030 | probe + tests | 82 |
| #2143 | `install.sh` | 141 |

**There is a FLOOR, and the floor is the number that matters.** Of 151
workflows, 116 are PR-triggered *with* a paths filter and **33 are PR-triggered
with no paths filter at all**, so those 33 fire on every push whatever it
touches. That is the ~40 you pay for a docs-only change.

So the marginal cost of touching `cut-manifests/` is about **5** checks, and
the cost of pushing *anything at all* is about **40**. A one-line board commit
and a one-line README commit cost nearly the same as each other, and nearly a
third of an `install.sh` one.

**Batch every push, not just install.sh ones.** And note that both agents who
read this paragraph tonight applied it correctly to install.sh and then pushed
freely elsewhere, because it names one file. A rule that names its example
gets read as a rule about that example. This is the same conclusion row
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
**AND THE BODY-EDIT HALF OF THAT IS WRONG FOR MOST WORKFLOWS IN THIS REPO.**
Measured 2026-09-18, after editing #2133's body to re-trigger its starved
aggregator and watching nothing happen: `on: pull_request:` with no `types:`
defaults to `opened, synchronize, reopened`, and **`edited` is not in that
list**. Only the workflows that name it explicitly respond:
`enforce-ledger-write`, `installer-version-consistency`,
`install-gui-contract`, `patch-new-files-visible`, `bash32-compat`. The
aggregator you most want to re-run, `ci-required-gate.yml`, is not one.

For everything else you need a `synchronize` event, which means a real push.
`gh pr update-branch` is the honest one: it produces a push AND clears
`BEHIND`, so it costs one CI cycle instead of two.

And the advice was generalised from the one workflow that had already been
fixed. `enforce-ledger-write` carries `edited` because its own printed remedy
was once unreachable for exactly this reason, with a comment saying so at
line 57. Somebody learned it there, wrote the remedy down, and it holds
nowhere else.

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

### A bare integer is not an address

Added the same night as the three above, because it cost more than all of
them and because three separate layers made the identical mistake on the same
field.

A cut-manifest row carries `issue:`, `repo:`, `title:` and `gate:` in one
record. The number is only meaningful in the repo the row names.

1. A board strike removed 41 rows asserting "the issue this row names is
   CLOSED on GitHub", resolving every number without reading `repo:`.
2. The audit of that strike resolved all 41 against CM051 and reported "41 of
   41 are pull requests". Ten of them declare `repo: HR015` and are OPEN
   issues there, every one titled `[LAUNCH]`.
3. A peer's five spot-checks confirmed the audit. Three of the five were
   `repo: none` and two were HR015; all five were resolved against CM051. The
   check was a COPY OF THE METHOD UNDER TEST, so it added confidence and no
   information, which is the worst thing a control can do, and it looked like
   a control, which made the wrong conclusion more credible.
4. The gate written to catch exactly this hard-coded CM051.

Nobody was careless. Everybody treated a number as self-locating.

**Before resolving an identifier, ask which register it belongs to, and read
the field that says so.**

#### Ask for the answer, not for the confirmation

The operational half, and the one that transfers furthest. The peer's
spot-checks failed because of how they were ASKED, not because the peer was
careless:

> "Confirm these five are pull requests" sends someone to check whether five
> numbers are pull requests. "Resolve these five row numbers and tell me what
> they are" forces them to open the row to find out WHERE to resolve it, and
> the `repo:` field is sitting right there.

A reviewer given the conclusion and the method can only agree or disagree
with the method. A reviewer given the question has to build their own, and
that is the only version that can fail independently. **Handing over the
method is how a second pair of eyes becomes a second copy of the first.**

The rule binds the asker, not the reviewer.

### Corrections do not converge, and a shrinking series is not evidence

The finding above was corrected five times: 29 rows, then 41 with 6
suppressed, then 41 with 2, then ten open `[LAUNCH]` issues, then those ten
triaged down to two with real outstanding work.

Four of the five shrank. Both parties had begun to treat "smaller" as the
direction of truth, which made the one correction that went the OTHER way the
hardest to receive and the only one that mattered.

**A trend in corrections carries no information about the next correction.**
Each is measured from scratch, from the artefact, or it is not measured.
