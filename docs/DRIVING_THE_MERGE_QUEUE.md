
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

### `gh pr diff <n> -- <path>` silently returns an empty diff

Measured 2026-09-18, comparing two pull requests suspected of overlapping:

    gh pr diff 2140 -- install.sh.strings.en-GB.sh | grep -c '^[-+]MSG_'   ->  0
    gh pr diff 2156 -- install.sh.strings.en-GB.sh | grep -c '^[-+]MSG_'   ->  0

Two zeros in a row, from a filter that looks like `git diff`'s. The control is
the same command with no path filter:

    gh pr diff 2140 | grep -c '^[-+]MSG_'   ->  22
    gh pr diff 2156 | grep -c '^[-+]MSG_'   ->  23

Both pull requests changed that file heavily. `gh pr diff` takes no pathspec,
so the argument is consumed and the output is empty rather than an error. Read
as written, it says the two pull requests do not touch the same file, which is
the exact opposite of the truth.

**The tell was the shape of the zero: two independent subjects returning
exactly 0 on the same predicate.** Real absence is ragged. The no-filter
control cost one command and inverted the verdict.

There is a second trap in the same line. `grep -c` **exits 1 when it counts
zero**, so under `&&` the false zero also killed the rest of the chain, and the
second measurement never ran at all. A count that can be zero belongs in a
command substitution, never in an `&&` chain.

### Two sessions built the same fix seven hours apart, in different words

Pull request 2140 (20:34) and pull request 2156 (03:46 the next morning) both
rewrite the same ELEVEN `MSG_` lines in `install.sh.strings.en-GB.sh`: the nine
that named the wrong product and the two that promised a platform. Same rule,
same lines, same file. Neither author knew about the other.

They are not textually identical, which is what makes it expensive rather than
merely wasteful. Three of the eleven are worded differently:

    2140  "Intel Macs are not supported. Ostler needs Apple Silicon (M1, M2, M3 or M4)."
    2156  "Intel Macs are not supported. Apple Silicon (M1, M2, M3 or M4) is required."

Identical changes merge clean. **Two correct answers to the same question
conflict**, and the conflict arrives at merge time, in a customer-facing string,
where resolving it by taking either side silently discards a decision somebody
made on purpose.

The board is the only place a claim exists. A claim made in a session, in a
branch name, or in a message to one peer is invisible to the next agent who
reads the board and sees an unclaimed row. **Claim before you BUILD.** The one
thing that must NEVER be claimed in advance is a MEASUREMENT: two independent
measurements of the same quantity is a control, and it is the cheapest one
there is.

### Three mechanisms in one night, and the third was the first

Row 2155 named a writer, withdrew it, named another, withdrew that, and ended
back on the original. Every step was measured. The corrections did not converge
on anything; the middle one was simply wrong.

    mechanism 1   the fda iMessage ingest re-CREATES the retired node     <- correct
    mechanism 2   repair_overmerged_contact_cards.py re-TYPES it          <- excluded
    mechanism 3   nobody can tell, there is no write provenance           <- premature
    back to 1     the pipeline's own people_created counter names it

**A trend in corrections carries no information about the next correction.**
Anyone reading the direction of travel rather than the evidence would have
treated the second withdrawal as progress. It was the one that was wrong.

What withdrew a correct mechanism was two errors of the same family, and both
are cheap to make again.

**A UTC instant compared against a local date.** Both hosts run at +0800. A
detect-only reading logged as `02:39` was LOCAL, which is `2026-09-17T18:39Z`.
The phantoms' newest `createdAt` is `19:04Z`, twenty five minutes AFTER that
reading. The falsifying question asked how many phantoms carried a `createdAt`
dated *today* in UTC. The answer, 0, was **true and irrelevant**, and the
arithmetic was allowed to choose a mechanism.

Quote every timestamp in UTC with the zone printed, or in epoch seconds. A `Z`
on a value that was never converted is worse than no suffix at all.

**A zero from the wrong tick.** The same investigation read `people_created: 0`
from the TAIL of a log, hours after the event, when the nodes already existed
and there was nothing left to create. Twelve lines further up, two consecutive
ticks each report `people_created: 32`.

> **A zero from the wrong tick is not a smaller measurement. It is a
> measurement of something else.**

The remedy is mechanical and belongs in any run that reads an append-only log
for the effect of an action it just took:

    record the log's line count BEFORE the action
    take the action
    read ONLY the lines appended after that mark, and say how many there were
    an empty slice is CANNOT-RUN, never 0

### What survived all three, and it is the part that generalises

**A control has to come from the same population as the treatment.** The
obvious control for "does retiring by replacement stop the revival" was the 24
nodes already correctly retired. Measured, they carry no identifiers and no
source at all, so no ingest can ever match them. They had sat untyped through
dozens of ticks precisely because nothing could see them. A control that cannot
be acted on by the mechanism under test proves the mechanism is off, not that
the fix is on.

**NOT INSTRUMENTED is still the right word when it is true, and it was not
true here.** The store genuinely records no write provenance, and that is now a
registered launch item. But one pipeline happened to print a counter, and the
answer was in it. The lesson is not that the honest absence was wrong to say;
it is that saying it is a claim about where you looked, so it has to name the
places, and a log a product writes on every tick is one of them.

### A named writer on a row is read as a diagnosed writer

Prose hedging does not survive being skimmed the next day. Either name the
query or the counter that identified the writer, or name nothing. And keep the
dead mechanisms in the row, clearly marked dead, with the numbers that killed
them: they are the only thing stopping the next person spending an hour
re-excluding a module that has already been excluded.

### A probe run from the wrong directory exits 127, which reads as a missing tool

Measured 2026-09-18, checking another session's branch without asking them:

    bash /tmp/p2030.sh --self-test     ->  exit 127, no useful output
    cp into scripts/box_walk_probes/probes/ and run there
                                       ->  exit 1, EXAMINED: 41

The probe sources its helper library by a path relative to **its own location**,
so a copy run from anywhere else cannot find it. `127` is "command not found",
which every reader parses as a missing binary on the runner. It is not. It is a
correct probe in the wrong place.

The habit that costs nothing: when checking a branch's probe, put the file where
the probe expects to live, run it, and remove it in the same command. Verify the
removal in that command too, so a failed run cannot leave a stray probe that the
"every probe on disk is collected" gate then trips over.

### A capability proven against the tree is not a capability proven against the artefact

The release repo's capability matrix probes non-assistant repos on the **working
tree**, with a comment saying the working tree is the honest target because it
is what gets packaged. Measured: 171 of 178 rows use that method and 133 of them
are CM051.

That comment was falsified by one measurement:

    current install.sh in the tree     36,212 lines, 5 references to the repair
    shipped payload install.sh         35,510 lines, 0 references

Seven hundred lines apart. A working-tree grep reports the capability PRESENT
while a customer has none of it, and every gate stays green.

The subject of the assertion has to be the thing the customer receives. Where a
capability spans two halves that ship separately - a step in a script and the
module that step invokes - the two must be asserted **as a conjunction against a
single artefact identity**. Two rows that merely share a version string can be
satisfied by two different builds.

### The gate written for a failure had no consumer

Worse, and the reason this went unseen: the release repo already contains a gate
that reconciles a running box against the BOM the cut declared. It refuses when
nothing was checkable, and it treats an absent BOM on the box as RED rather than
as nothing to do. Its header records the decision it implements.

    SUBJECT  references outside the file itself
             0 in scripts, workflows, manifests and documents
             1 elsewhere, and it is a COMMENT
    CONTROL  the gate beside it        45
             the capability matrix     120

The controls are large, so the zero is a real absence. **A gate that is written,
reviewed, documented and never called is indistinguishable from a gate that was
never written**, except that its existence stops anyone writing it again.

When you find a missing check, search for it by name before building it, and
search for its CALLERS before trusting it.

### We are one GitHub identity, so a formal approval between us cannot arrive

Measured 2026-09-18, after one session told another that a pull request was
"waiting only on your review":

    gh pr review 166 --approve
    failed to create review: GraphQL: Review Can not approve your own pull request

Every token in this estate resolves to the same account, so three sessions
working in parallel are one author to GitHub. **A formal approval between any
two of us is impossible by construction, not by convention.** Waiting for one is
waiting for something that cannot happen, and it stalls the lane indefinitely
while looking like diligence.

Two consequences:

- Review between sessions goes in as a **comment**, and the **merge is the
  decision**. That is not a relaxation of the review rule; it is the only shape
  the rule can take here.
- Before saying a pull request "needs a review", check whether the branch is
  even protected:

      gh api repos/<owner>/<repo>/branches/main/protection
      -> 404 Branch not protected

  An empty `reviewDecision` on an unprotected branch means **none was ever
  requested**, not that one is outstanding. A pull request that reports CLEAN
  was already mergeable.

### A check state is a timestamp, not a property

In the same exchange, one session read `2 of 2 SUCCESS` and reported the pull
request green. By the time the other session read it, a push had restarted the
suite and it was `scan completed / pytest in_progress`. The first reading was
true when it was taken and false when it was relayed.

This is the same shape as a pull request whose green was eleven days old: the
number is a fact about a moment, and relaying it turns it into a claim about
now. Re-read the state in the same turn you act on it, and when you hand a state
to someone else, hand them the query rather than the answer.

### BSD awk has no `\s`, and the zero it returns looks like a clean file

Re-measuring a known data-loss defect, the first reading said the swallow was
gone from all three files:

    awk '/except Exception/{getline; if ($0 ~ /^\s*pass\s*$/) n++} END{print n+0}'
      facebook_friends.py      0
      linkedin_connections.py  0
      instagram_social.py      0

Three zeros, one per file, on a pattern that reads correctly. The truth is 1, 2
and 1. **`\s` is a GNU extension and BSD awk does not implement it**, so the
alternation never matched and every file reported clean.

The control is one line and it is the only reason this was caught:

    echo "  pass" | awk '/^\s*pass\s*$/{print "matched"}'              -> nothing
    echo "  pass" | awk '/^[[:space:]]*pass[[:space:]]*$/{print "ok"}' -> ok

**Put a must-match line through the pattern before trusting what the pattern
says is absent.** Not through the subject - through the *pattern*. A predicate
that cannot match a line built to match it has not measured the subject at all.

This is the second false negative on the same defect category, in two different
tools, for two unrelated reasons: an earlier sweep reported it clean with a
single-line regex while the real code uses the standard two-line idiom. A
category that has produced a false negative twice should never be measured again
without a must-match control in the same command.

### The collision the owner warned about, caused by the person who was warned

The register owner said the specific risk in a shared repo is two sessions
appending a row for the same thing. Hours later, with a cut-blocking pull
request stalled on a missing register entry, the other session asked the owner
to write it, judged the block too important to wait, and wrote it anyway.

    feature_prs entries       186
    duplicate row for PR A      2
    duplicate row for PR B      2

Both sets in the working tree, neither pushed. No data lost, because the tip
SHAs were recorded and the owner had not committed - but the file briefly said
two different things about the same two changes.

**The reasoning that produced it is the reasoning that produces every
collision**: the person who breaks the rule always has a reason, and the reason
is usually true. The block was real. The correct move was to say the pull
request is blocked and work on something else, which is what the operating
instruction already says to do, and there was other work available.

A shared register is not a queue you can jump when your item is urgent. It is a
queue *because* items are urgent.

### A duplicate check keyed on a field that is in dispute cannot see the duplicate

Two sessions appended a row for the same two pull requests to the same register.
The owner's duplicate check was a `Counter` keyed on `(repo, pr)` and it reported
one row each.

It could not have reported anything else. The two sessions spelled the `repo`
field differently - one owner-qualified, one bare - so **the key built to detect
the collision contained the field the collision was in**. A plain textual count
of the identifying line said 2, with a control line that said 1.

    Counter keyed on (repo, pr)      ->  1 each   (wrong)
    grep -c '^  pr: 2160$'           ->  2        (right, control row 1)

> **A duplicate check must key on the field that IDENTIFIES the thing, never on
> a composite containing a field whose spelling is in dispute.**

That generalises past this register. Every composite key in this estate has a
field that two people could spell differently, and the check is silent in
exactly the case it exists for.

The convention question underneath it was settled by counting rather than by
argument: 107 rows owner-qualify the repo and 4 use the bare form, and the row
the owner had copied was one of the 4. **A sample of one is not a convention**,
and copying the last row you read reproduces whatever that row got wrong.

### A head SHA in a permanent register is a timestamp, not a property

One of the duplicate rows recorded `head_sha: 9b3f5a6e`. That was the head at
04:40:39Z; the branch moved at 05:17:20Z. Both SHAs exist, so it is staleness and
not a typo - the value was true when it was read and false by the time the row
was committed.

Same shape as relaying `2 of 2 SUCCESS` as "the PR is green" while a push was
restarting the suite. The answer is not to stop recording the SHA. It is that a
row recording a moving value must also record **the instant it was read**, or the
reader cannot tell a stale value from a wrong one.
