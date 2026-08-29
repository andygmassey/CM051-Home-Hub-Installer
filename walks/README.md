# Walk records

One file per released version: `walks/<version>.tsv`.

A walk record is the **only runtime proof** in the release pipeline. Everything
else measures the artefact — hashes, staple, signature, Gatekeeper — and all of
that passes on a DMG that installs to a broken machine, because none of it has
ever been installed.

## Who writes these

`scripts/post_walk_qa.sh <box-host> <version>`, automatically, after it has run
the box-walk probes against a real installed box. Do not hand-write one.

## Who reads them

`scripts/verify_walk_record.sh <version>`, which `scripts/publish_release.sh`
consults before promoting a release to `latest`. Until a **CLEAN** record for
that exact version is committed here, the release is published as a
**prerelease**: the assets are up and installable by version, but
`ostler.ai/install.dmg` resolves `/releases/latest/` and keeps serving the
previous release that *was* walked.

Nothing is blocked by this. The cut runs, the DMG is built, signed, notarised
and uploaded. What it costs to hand the build to customers is one piece of
evidence that somebody installed it.

## Format

Tab-separated `key<TAB>value`. Lines beginning `#` are comments.

| field | meaning |
|---|---|
| `version` | the version walked. Checked against the version being published — a record's filename is not evidence, its contents are. |
| `version_source` | how the version was obtained. `measured(...)` means it was read off the box; anything else means it is an assertion. **Read by the gate since #931** — before that it was written on every run and consumed by nothing, so a record that openly said the version was unverifiable cleared the gate identically to one that measured it. |
| `artefact_sha256` | sha256 of the DMG the box was walked with. **A version does not identify a build**: `CFBundleShortVersionString` read `1.0.50` for eleven distinct assemblies of that cut, so without this field a walk of any build of a version cleared the gate for every build of it. `publish_release.sh` passes the sha of the file it is about to upload and the gate compares the two — both sides are content hashes. |
| `artefact_sha256_source` | as `version_source`. `measured(...)` only when the DMG was found on the walked box and hashed **there**. That establishes *which build*, not that it was the one mounted — a DMG in `~/Downloads` may never have been opened. Two copies of the same version on the box is recorded as ambiguity, never resolved by guessing. An asserted hash is refused: a value checked against the file it was copied from always agrees. |
| `walked_at` | UTC timestamp |
| `box_fp` | first 16 hex of `sha256(ssh target)`. **A hash, never the host.** This repo is public and the box argument is routinely `user@address`. The hash still distinguishes two walks on one box from one walk on each of two. |
| `pass` / `fail` / `cannot_run` / `broken` | the four counts from `run_box_walk.sh` |
| `counts_scope` | **which population those four counts describe.** The writer emits `box_walk_probes_only(phase1); verdict+qa_exit cover all phases` — so the counts are NOT the whole suite, and reading them as a total understates what ran. `verdict` and `qa_exit` are the whole-suite result. This field was emitted by `post_walk_qa.sh` and undocumented here until 2026-08-29; a field table that omits a field the writer emits is worse than no table, because it reads as complete. |
| `verdict` | `CLEAN`, `FAILED` or `PARTIAL` |
| `qa_exit` | exit code of the QA run |
| `failed_probe_names_recorded` | `<n> of <count>`. Reconciles the named probes against the `fail` count IN THE FILE. If the parser that reads the names ever stops matching, this reads `0 of 5` instead of silently returning the record to counts-with-no-names. |
| `failed_probe` | one row per probe that FAILED, by name. Repeatable. |
| `not_measured_probe` | one row per probe that could not run. Repeatable. Coverage lost, not coverage passed. |
| `broken_probe` | one row per probe that failed its own negative control, so its result is not trusted. Repeatable. |

**Names only, never probe output.** A probe's stdout carries paths and
hostnames; this repo is public, which is why `box_fp` is a hash. Only bare
probe filenames are written, and anything else on those lines is dropped.

Before this, the record kept the four counts and nothing else. The gate that
decides whether customers get a build said `fail 5` and could not say which
five: `run_box_walk.sh` printed the names into a `mktemp` log that
`post_walk_qa.sh` deleted on exit. `walks/v1.0.44.tsv` is exactly what that
looks like.

## What is actually in here, as of v1.0.50

Two records, and **both are `FAILED`**:

| record | pass | fail | cannot_run | verdict | `artefact_sha256` |
|---|---|---|---|---|---|
| `v1.0.44.tsv` | 5 | 5 | 3 | FAILED | absent |
| `v1.0.47.tsv` | 7 | 4 | 4 | FAILED | absent |

Both predate #931, so neither names the build it was taken on. That is not a
problem for the gate: it refuses them at the **verdict** check, before it ever
reaches the artefact fields. The artefact checks are deliberately scoped to
`CLEAN` records for exactly this reason — run unscoped, the absent-field check
would fire first and these two would be reported as CANNOT-RUN when they are in
fact a measured, legible FAILED. Losing that distinction would be signal loss.

**There has never been a `CLEAN` record for any version.** Every release since
v1.0.41 is therefore a prerelease, which is the walk gate working as designed
rather than publishing being broken: no clean walk → `PROMOTE=0` → the customer
keeps the last build that *was* walked.

## What the record cannot tell you: how DEEP the walk went

No field here records the walk's **depth**, and there is a real difference. A
*thin* walk runs on an empty account — no Address Book, no messages, no mail. It
proves `install.sh` completes. It proves nothing about the data paths. A *full*
walk runs against a populated box.

**Both produce a record with the same shape, and a `CLEAN` from either is
identical to the gate and to whoever reads the file next month.** `counts_scope`
says which *probes* the counts cover; nothing says which *box* they ran against.

This matters most for the probes that need data to mean anything. Measured
2026-08-29, CANNOT-RUN vocabulary per probe:

| probe | has a "could not look" path |
|---|---|
| `ingest_coverage` | yes |
| `people_seed_and_retrieval` | yes |
| `no_person_holds_two_contact_cards` | yes |
| `people_count_agreement` | yes |
| `assistant_answers_grounded` | **no** |

`assistant_answers_grounded` is the probe whose own header says it is the one
that *would have caught v1.0.38* — the release where every layer was green and
the assistant still answered "I don't know" to all four opening questions. On an
empty account it has no way to report that it could not look. Its result on a
thin walk is therefore uninformative in **both** directions: a pass is not
evidence the assistant works, and a failure is not evidence of a defect.

Until the record carries depth, **a walk's scope lives only in whatever the
operator wrote down elsewhere** — and that is exactly the kind of caveat that
does not survive into the artefact.

⚠️ **"Walked" is used for two different things and only one of them is this
file.** A DMG can be *artefact-verified* — hashed, signature checked, stapled,
contents mounted and read — with none of it ever having been installed. That is
not a walk and it does not produce a record here. A **box walk** means the thing
was installed on a real machine and the probes ran against it. `#844` exists
because everything between "gates green" and "customer download" is the first
kind. When a report says a build is "walked N/N", check which kind it means, and
check `walks/` before believing it is this one.

## Why four counts and not one

`PARTIAL` — nothing failed, but not everything ran — is refused just as firmly
as `FAILED`. Coverage lost is not coverage passed, and the two look identical
in any summary that reports a single number. The gate also refuses a record
whose verdict disagrees with its own counts, and one with `pass=0`: a suite
that never started reports the same "no failures" as a suite that passed.

## Bypass

`PUBLISH_RELEASE_ALLOW_UNWALKED="<reason>"` promotes without a record. It
requires a sentence, not a boolean, and the sentence is written into the
release notes — so a deliberate bypass is visible from the artefact itself and
not only from a CI log that expires.
