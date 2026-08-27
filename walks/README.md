# Walk records

One file per released version: `walks/<version>.tsv`.

A walk record is the **only runtime proof** in the release pipeline. Everything
else measures the artefact — hashes, staple, signature, Gatekeeper — and all of
that passes on a DMG that installs to a broken machine, because none of it has
ever been installed.

## Who writes these

`scripts/post_walk_qa.sh <box-host> <version>`, automatically, after it has run
the 14 box-walk probes against a real installed box. Do not hand-write one.

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
| `walked_at` | UTC timestamp |
| `box_fp` | first 16 hex of `sha256(ssh target)`. **A hash, never the host.** This repo is public and the box argument is routinely `user@address`. The hash still distinguishes two walks on one box from one walk on each of two. |
| `pass` / `fail` / `cannot_run` / `broken` | the four counts from `run_box_walk.sh` |
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
`post_walk_qa.sh` deleted on exit. `walks/v1.0.44.tsv` is the only record that
has ever existed and that is exactly what it says.

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
