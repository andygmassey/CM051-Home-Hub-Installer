# Folding CI into families – plan, inventory and proof

Owner lane: build speed / CI. Status: the tool and the inventory land first, with
nothing folded. Each family then lands as its own pull request, proven against
its base by `scripts/ci_fold.py check`.

## What was measured, and on which surface

**GitHub Actions is ON for this repository.** It is not off, and this plan
does not rely on a local runner. Measured on 2026-10-17 through the Actions API:
795 check-runs across eight open PRs (#2954, #2941, #2940, #2939, #2934, #2879,
#2878, #2781), with each job's runner label and its queue time (created to
started).

| | Ubuntu | macOS |
|---|---|---|
| jobs measured | 514 | 281 |
| queue, median | 13 s | 318 s |
| queue, p90 | 101 s | 2039 s |
| queue, max | 292 s | 5478 s |

| PR | check-runs | wall clock | CI Required Gate |
|---|---|---|---|
| #2941 | 178 | 9m16s | 525 s, success |
| #2939 | 191 | 14m09s | 847 s |
| #2940 | 98 | 13m21s | 799 s |
| #2879 | 56 | 91m28s | 2730 s, hit its 45 min idle cap waiting on macOS |
| #2878 | 54 | 65m29s | 2730 s, same |

Most jobs do 5 to 30 seconds of work. The wall clock is spent **waiting for
runners**, and macOS dominates: a macOS job waits a median of five minutes
before it starts, and the gate cannot conclude until the last one has. So the
lever is the number of jobs, and above all the number of macOS jobs.

A second surface, local, is used to prove that a folded family still goes
green. `scripts/ci_fold.py run-local` executes a family job on a Linux box in
a disposable worktree, with GitHub's step semantics (`GITHUB_ENV`,
`GITHUB_PATH`, `GITHUB_OUTPUT`, conditions, per-step timeouts). A step whose
condition it cannot evaluate is CANNOT-EMULATE and fails the run, so the
emulator cannot skip its way to a local green. It does not run macOS jobs.

## The estate

`docs/ci/CI_FOLD_INVENTORY.tsv` lists every step of every job in every
workflow (214 files, 266 jobs, about 1,670 steps). Each row records the
scripts and tests the step executes and the family the job is proposed to fold
into. Regenerate it with `python3 scripts/ci_fold.py inventory --out
docs/ci/CI_FOLD_INVENTORY.tsv`.

| family | files | jobs | check-runs (matrix expanded) | runner | unfiltered jobs |
|---|---|---|---|---|---|
| py-matrix | 27 | 31 | 93 | ubuntu-latest | 0 |
| installer | 62 | 70 | 70 | ubuntu-latest | 0 |
| macos-latest | 31 | 36 | 36 | macos-latest | 11 |
| macos-14 | 26 | 31 | 31 | macos-14 | 0 |
| always | 27 | 29 | 29 | ubuntu-latest | 29 |
| vendor | 25 | 25 | 25 | ubuntu-latest | 0 |
| release-walk | 14 | 17 | 17 | ubuntu-latest | 0 |
| misc | 12 | 12 | 12 | ubuntu-latest | 0 |
| macos-26 | 3 | 3 | 3 | macos-26 | 0 |
| standalone | 5 | 12 | 12 | mixed | 1 |
| **total** | 214 | 266 | 328 | | |

Standalone and never folded: `ci-required-gate.yml` (the aggregate),
`cut.yml` (the release cut: tags, dispatch, secrets), and the workflows that
express a dependency with `needs:` (`customer-download-path.yml`,
`hub-contract.yml`) or fire on schedule or issue events
(`red-main-opens-an-issue.yml`). A `needs:` chain is a real ordering, and
folding it would hide that ordering inside step order.

Fully folded, the estate is about 22 check-runs: 3 for py-matrix, one per other
family, and the 12 standalone jobs. Today it is 328.

## How a fold works

`.github/ci-fold-families.tsv` names the jobs. `scripts/ci_fold.py generate
<family>` writes `.github/workflows/fold-<family>.yml` and
`.github/ci-fold-paths.tsv`, then removes the folded jobs from their source
files. A file is deleted only when every one of its jobs was folded. The
source text is copied verbatim, including its comments, and each source
file's header comment is carried above its block.

Each source job becomes a **block** inside one family job. A block gets back
what its own machine used to give it:

- a pristine checkout (`git reset --hard`, `git clean -ffdx`)
- a fresh venv from the hoisted interpreter, so a "stdlib only" test cannot
  pass because an earlier block installed something
- a fresh `HOME` and `TMPDIR`

**Step conditions are scoped to the block.** A step with no `if:` used to run
only when every earlier step in its job had succeeded. It now runs when every
earlier step in its **block** has succeeded. `success()` and `failure()` are
rewritten the same way, and `always()` and `cancelled()` are kept as written.
One block failing cannot skip another block's tests, so the folded family
still passes `verify_ci_steps_are_maskless.py`.

**Per-block path selection keeps the work equal to before.** GitHub's filter
fires the family on the union of the members' paths. A `select` step then asks
GitHub for the PR's changed-file list and runs a block only when one of those
files matches that block's **own** old patterns, as listed in
`.github/ci-fold-paths.tsv`. It fails open. The block runs on a push, an API
error, an empty or capped list, a glob form the matcher does not model, or a
change to the selector, its data or the family file. Skipping is the only
outcome that needs evidence. The matcher handles exactly the syntax this
repository uses (literal paths, `*` and `**`, measured over every workflow).
Anything else matches everything.

**Every step keeps its old job's timeout.** The family job's timeout is the
sum of the members' timeouts, capped at 70 minutes so the CI Required Gate
(75 minute hard cap) still sees a verdict.

## What `check` proves, and how it is proven to prove it

`python3 scripts/ci_fold.py check --base <base-sha>` runs on every PR, as a
step in `ci-maskless.yml`. On a PR that adds rows to the spec it refuses
unless all of the following hold:

1. Every job not being folded is **byte-identical** (parsed) at the base and
   at the head, in the same file. A fold PR may touch no other workflow.
2. Every folded step appears **verbatim**, in order, in its block. Only `id`,
   `if` and `timeout-minutes` may differ, and step-id renames are accounted
   for.
3. Each step's condition is block-scoped, `always()` is never lost, and its
   timeout is never wider than its old bound.
4. The runner and matrix are unchanged.
5. The `pull_request` and `push` triggers are supersets, the family watches
   itself, and each block's selection rows are a superset of its old paths.
6. Every block step is gated on its own selection, and the selector step
   exists and always runs.
7. The token is read-only (`contents: read`, `pull-requests: read`), which is
   no wider than any member's.
8. The set of **executed scripts** across all workflows is a superset of the
   base's.

`tests/test_ci_fold.sh` (38 cases) proves the checker by **mutation**: 17
ways a fold can lose a gate, each of which must be refused for the named
reason, plus the selector's glob table and fail-open paths. A guard makes a
mutation that changes nothing count as a test failure, because a no-op
mutation would read as "refused" while testing nothing. While this tool was
written, that guard caught three such mutations.

The wiring ratchet stays the control. `tests/TEST_WIRING.tsv` is regenerated
in each fold PR, and the PR body diffs the WIRED set: no test may leave it.

## What is not preserved

- **Check-run names change.** Nothing in this repository requires a check by
  name except "CI Required Gate", which is untouched. OS003 was read on
  2026-10-17: it names no check-run of the folded workflows, and its only
  mention of one, `people-projection-prune.yml`, is prose in a v1.0.68 BOM
  row and the rollforward register, which no OS003 code parses.
- **Blocks within a family run in series.** With selection, a PR runs the same
  blocks it used to, on 1 to 3 runners instead of up to 31.
- **A literal absolute path outside the checkout, `HOME` and `TMPDIR`** (for
  example `/tmp/foo`) can still see an earlier block's leftovers. Only a
  fresh machine isolates that.

## Rollout order, and the hazard each family carries

Every family carries one hazard. A ratchet that counts per **file** has its
rows keyed by workflow name, so a source's row must move to the family file in
the same PR. `tests/pipefail_shortcircuit_baseline.txt` is the one measured so
far, and it is why the generated isolate step uses `set -eu` without
`pipefail`.

1. **py-matrix** (31 jobs, 93 check-runs, 3 after). This is the pilot: the most
   uniform shape, all on Ubuntu, and no meta-gate names these files.
2. **macos-14 and macos-latest** (67 jobs). These are the biggest wall-clock win,
   because they cut macOS queueing directly. They need the generator extended
   for jobs without `setup-python`. Some blocks install with `pip --user`,
   which the per-block `HOME` isolates, or with `--break-system-packages`,
   which it does not, so those blocks need a venv or stay separate.
   macos-latest has 11 unfiltered jobs (`test-wiring.yml` among them), which
   select as "always".
3. **vendor, release-walk, misc** (54 jobs, Ubuntu, filtered). These are
   mechanical once 1 has merged.
4. **installer** (70 jobs). This is the largest group. 36 test files name a
   workflow file by path (for example
   `tests/test_download_currency_gate_is_wired.sh`); any that names a member
   must be repointed in the same PR.
   `scripts/cut_trigger_reachability_baseline.tsv` and
   `verify_declared_gates_ran_at_commit.sh` key on workflow file names, so any
   member named there needs its row moved in the same PR.
5. **always** (29 unconditional jobs). **Needs a human call** (see below).

## Slowest ten legs

Ranked by median job duration on Actions (the same eight PRs), excluding the
CI Required Gate itself, which only waits. The cause was measured locally
where the leg can run on Linux.

| # | leg (workflow) | runner | median / max | queue median | measured cause | proposed speed-up |
|---|---|---|---|---|---|---|
| 1 | declared-gates-self-test (`declared-gates-reachable.yml`) | ubuntu | 302 / 329 s | 31 s | `verify_declared_gates_reachable.sh` takes 157 s locally, and two consecutive steps each run the **full** script just to grep a different marker in its output | run it once, `tee` the output to `$RUNNER_TEMP`, and grade both properties from the file (about −150 s). Then profile the fixpoint's per-file `while read` / `grep` forks and move the hot loop into a single Python pass |
| 2 | catchup-takeout | ubuntu | 256 / 259 s | 26 s | three tests account for 272 s of 280 s: `test_install_plus_catchup_reads_every_thread_once` 162 s, `test_sigkill_in_index_and_dispatch_never_duplicates_or_loses` 71 s, `test_bounded_cost_measured` 39 s | they drive real ticks against real time. Inject the clock (or the tick budget) so the same sequence runs at simulated speed, and keep one slow end-to-end run on `push` to main only |
| 3 | cold-box-truth (`cold-box-source-truth.yml`) | macos-14 | 212 / 223 s | 322 s | 59 serial bash 3.2 test steps, plus a venv build and pip install inside the job. The queue costs more than the run | fold into macos-14 (removes the queue). Then move steps that need neither `/bin/bash` 3.2 nor a macOS tool to the Ubuntu family, and keep the 3.2-parse checks on macOS |
| 4 | "A feed cannot be starved…" (`ingest-slot.yml` suite) | ubuntu | 201 / 203 s | 4 s | `tests/test_ingest_slot_fairness.sh` alone took 309 s locally (on a loaded 4-core box). It has 14 sections and 20 fixed `sleep N` calls. `test_a_hung_slot_holder_is_stopped.sh` took 36 s, and the pytest tick suite took 20 s | replace the fixed sleeps with poll-until-condition (the idiom `doctor_page_renders_for_a_customer.sh:259` already uses), and drive the slot timers through their env knobs at sub-second values in the test. Same assertions, less waiting |
| 5 | driver-not-box (`unreachable-not-absence.yml`) | macos-latest | 192 / 228 s | 500 s | **not reproducible on Linux**: both test steps take about 1 s here (4 of 4 and 5 of 5 arms pass). The 192 s is macOS-specific, and the 500 s queue costs more than the run | fold into macos-latest first, because the queue is the bigger cost. Then time each arm on the next macOS run (`date +%s` around each arm). The suspects are the `curl --max-time 12` arms against a server that never answers |
| 6 | cut-gate-wrappers | macos-latest | 140 / 156 s | 38 s | 45 serial steps, PyYAML installed three times by three different pip spellings | install once at the top. Fold the ten `bash -n` / grep-count checks into one step. Fold the job into macos-latest |
| 7 | catchup-messages | ubuntu | 99 / 102 s | 4 s | `tests/test_catchup_messages.py` takes 103 s: two hang-quarantine cases at 15 s each, then 10 s timeout cases. The vendored source suites take 9 s | the 15 s is the real per-item hang timeout. Pass the timeout in (env or argument), set it to about 1 s in all but one case, and keep a single full-length case so the real value is still exercised |
| 8 | catchup-machinery | ubuntu | 97 / 100 s | 29 s | `tests/test_catchup_core.py` takes 92 s, with its top three cases at 14 to 15 s each (the same per-item timeout). The other steps take 4 s | the same injected timeout as #7. And `test_catchup_core.py` is **run twice per PR**, here and in catchup-mail (#10). Run it once, from a block whose selection rows are the union of both workflows' paths |
| 9 | sweep-macos (`tests-unwired-sweep-al.yml`) | macos-latest | 92 / 96 s | 288 s | the queue (288 s) is three times the run | fold into macos-latest. That removes the queue, which is the cost here |
| 10 | catchup-mail | ubuntu | 82 / 84 s | 36 s | its own suite takes 13 s. The rest is the **same `test_catchup_core.py` run as #8** (92 s) | deduplicate with #8 (about −80 s per PR that fires both). Rows, not runs, decide coverage |

Two common causes sit under several rows. **pip resolution without a cache.**
The family's hoisted `setup-python` uses `cache: pip`, and per-block venvs
reuse the warm wheel cache. **Real-time sleeps in tests.** No speed-up here
removes a test or loosens an assertion. Each one either removes a duplicate
run or replaces wall-clock waiting with an injected clock, which the test
must still exercise.

## Needs a human call

1. **Folding the 29 unconditional Ubuntu jobs shrinks the CI Required Gate's
   anti-vacuity floor.** `verify_pr_gate_aggregate.sh` recomputes its floor as
   the number of unconditional workflow **files**, which is 34 today. If those
   files are folded into one family, the floor drops to about 6, and the
   aggregate will accept a far smaller enumeration before it refuses. The
   proposal is to have the floor count expected **check-runs** (jobs ×
   matrix legs) instead, and to land that change before the `always` family
   is folded. That changes the gate, so it is your call.
2. **Selection uses the PR files API** with `pull-requests: read`. The
   alternative is a `git diff` against the merge commit's first parent. That
   needs no token, but it can differ from GitHub's own three-dot diff when the
   base has independently made the same change, and in that case it would
   skip a block GitHub would have run. The API was chosen for that reason.
   Say if a token-less family is preferred.
3. **Stale prose references.** Historical cut manifests (`cut-manifests/
   v1.0.99`–`v1.0.108`) and OS003's v1.0.68 BOM mention folded workflow
   names. They are records, v1.0.108 is frozen, and they are left as written.
   `.github/ci-fold-families.tsv` is the map from an old name to its family.
