# Cut gates — what each one proves, and what it cannot

**One command:**

```bash
CM044_DIR=~/Developer/cm044-wiki-remaining \
BOM="~/Documents/Projects/OS003 - Ostler Release/cuts/<ver>/MUST_CONTAIN.tsv" \
scripts/run_all_cut_gates.sh
```

Exit 0 = cut-clear on the mechanical checks. Exit 1 = do not assemble.
`--report` runs everything and always exits 0, for when you want the picture
rather than the verdict.

Both env vars are **required**. Neither has a default, on purpose — see
[Why no defaults](#why-no-defaults).

---

## The rule this document exists to enforce

> **Provenance is not content.**
> A valid digest of the wrong build is still a valid digest.

Every gate below sits in one of two columns. Read the second one before
trusting the first.

| gate | proves | does NOT prove |
|---|---|---|
| `check_install_sh_script_dir_coverage.py` | every `${SCRIPT_DIR}/X` probe has a bundler | that Xcode tracks the copy, or that the file is current |
| `test_bundle_phase_declares_every_copy.sh` | every copy is in `inputFiles` **and** `outputFiles`, so a rebuild can't ship a stale one | that the file's contents are correct |
| `test_wiki_image_namespace_matches_ci.sh` | CI publishes where `install.sh` reads | that the image at that address is current |
| `test_pinned_wiki_image_has_design_system.sh` | the pinned image's stylesheet is byte-identical to CM044 | that the rest of the image is current |
| `verify_cut_freshness.sh` | vendored inputs match live upstream HEAD | that the vendored code works |
| `verify_cut_provenance.sh` | components are the intended builds | that those builds contain the fixes |
| `provenance_gate.sh` | artefacts contain the required fixes | that they behave correctly on a box |
| `verify_must_contain.sh` | every capability we promised is marked landed **with evidence** | that it works — that is the box walk |

Nothing here replaces the box walk.

---

## Observed results — 2026-08-07, `main` @ `d863ed8`

Run in a clean worktree. These are actual exit codes, not expectations.

```
  PASS  SCRIPT_DIR/X coverage            38 probes all covered
  PASS  bundle-phase declarations        1 phase, 6 copies, control bites
  PASS  wiki image namespace             CI publishes where install.sh reads
  PASS  wiki image CONTENT               143,344 bytes / 370 rules, byte-identical
  RED   cut freshness                    2 inputs lag live upstream
  RED   cut provenance                   35 pass / 11 fail
  RED   content provenance               0 pass / 4 fail
  RED   MUST_CONTAIN BOM                 20 of 20 rows not landed

  4 green | 5 red   ->   DO NOT ASSEMBLE
```

The four green ones were built or repaired on 2026-08-07. The four red ones
are the honest state of the cut, and the BOM red is partly an artefact of the
BOM never having been maintained (see below).

---

## The four faults this tooling was built in response to

All four were live on 2026-08-07. Each is a different way for a green signal to
mean nothing.

### 1. A gate reading the wrong file

`cut_hygiene_gate.sh` defaults to `scripts/cut_manifest.v1010.tsv` — a
**v1.0.10** manifest. It parses cleanly, so the gate printed
**"GREEN. Cut-clear on the hygiene gate."** while validating a cut six versions
old. Its own orphan warnings cited *v1.0.13.1* PRs, which is the tell that
nobody read the output.

> A gate with a default input answers *"which cut am I gating?"* by accident.

**Status:** partially fixed. `verify_must_contain.sh` now reads the real BOM and
has no default. `cut_hygiene_gate.sh`'s stale default is **task #661, still
open** — treat any GREEN from it without an explicit manifest argument as
meaningless.

### 2. A manifest nobody reads is a manifest nobody updates

There were three manifest systems:

```
scripts/cut_manifest.v1010.tsv   ->  cut_hygiene_gate.sh   (v1.0.10, stale)
cut-manifests/*.yaml             ->  verify_cut_manifest.py
cuts/<ver>/MUST_CONTAIN.tsv      ->  NOTHING
```

The one with no reader is the one describing the cut being assembled. Because
nothing read it, nothing kept it true: on 2026-08-07 all 20 rows said
`landed=no`, **including three that had landed hours earlier** (the wiki
reskin, the image re-pin, the On-this-day fix).

> A BOM that costs nothing to leave stale becomes a wish list, and a wish list
> cannot gate anything.

**Status:** fixed — `verify_must_contain.sh`.

### 3. Provenance passing while content is stale

Three separate wiki-image checks — digest valid, namespace correct, pulls
anonymously — all passed for months while customers received a build from
before the design system existed. Nothing ever opened an image and looked
inside. The stale build was found by hand, on a real box, by diffing the served
stylesheet against git: **68,542 bytes, zero design-system rules**.

**Status:** fixed — `test_pinned_wiki_image_has_design_system.sh` opens the
image `install.sh` actually pins and compares byte for byte.

### 4. A build system silently shipping an old file

`lib/settling_progress.sh` was copied into the bundle but absent from the build
phase's `inputFiles`/`outputFiles`. Xcode uses those for incremental dependency
tracking — so editing the file did not dirty the phase, and a rebuild could
leave the **previous** copy in the `.app`. Green build, file present, content
old. The symptom is *"I changed that and nothing happened"*, which sends you
looking inside the file you edited rather than at the build system.

**Status:** fixed — `test_bundle_phase_declares_every_copy.sh`, which is
mechanical: it does not know which files matter, it just refuses to let `cp` and
the declarations disagree.

---

## Rules these gates are built to

### Why no defaults

`run_all_cut_gates.sh` and `verify_must_contain.sh` both **refuse to run**
without their inputs. That is fault 1 above: a default is the mechanism by
which a gate ends up validating the wrong cut and reporting success.

### A skip is not a pass

If a gate cannot run — no `CM044_DIR`, no docker, no BOM — that is **RED**.
A check that did not happen is indistinguishable from a check that passed, and
that confusion is what shipped stale images for three months. Gates that skip
legitimately (`test_wiki_image_namespace_matches_ci.sh` without a CM044
checkout) say so **loudly on stderr** and state that skipping is not a pass.

### Every gate needs a positive control

A gate that has silently stopped matching passes exactly like a clean tree.
Each gate built on 2026-08-07 proves it can still fail:

- `test_bundle_phase_declares_every_copy.sh` re-runs itself against a
  `project.yml` with a declaration deliberately removed
- `test_pinned_wiki_image_has_design_system.sh` appends a line to the extracted
  stylesheet and re-compares
- `verify_must_contain.sh` was proven across six cases by exit code, **including
  a synthetic all-landed manifest that returns 0** — a gate only ever seen
  failing has not been shown to pass for the right reason

> If a negative result would change what you do, run a known-good case through
> the same check first.

This is not theoretical. The anonymous-pull probe returned 404 for the new
digests; the control — the digest customers were pulling *at that moment* —
also 404'd, proving the probe was blind, not the image broken. The fix was a
missing `service=ghcr.io` parameter.

### Never edit a gate to pass a cut

And never re-point a gate at an input that happens to be greener. Fault 1 is
what that looks like six versions later.

### Unrecognised input is an error, not a failure

Point `cut_hygiene_gate.sh` at the real BOM and all 21 rows go red with
`class is unset/unknown` — not 21 problems with the cut, one problem with the
tool, wearing the costume of the first. `verify_must_contain.sh` hard-errors
(exit 2) on an unrecognised header, naming what it got, what it expected, and
which tool to use instead.

Exit code convention:

| code | meaning |
|---|---|
| `0` | pass |
| `1` | the thing being gated is wrong — **do not cut** |
| `2` | the gate could not run — usage, missing file, unknown schema |

Keeping 1 and 2 distinct is what stops a tool fault reading as a cut fault.

---

## Releasing wiki images

Separate flow, its own runbook: **CM044 `docs/RUNBOOK_wiki_image_release.md`**,
one command — `scripts/release_wiki_images.sh v0.1.N`.

The gotcha worth repeating here: the anonymous-pull probe **requires
`service=ghcr.io`**. Without it the token request returns a token that 404s
every digest, including ones that demonstrably work.

---

## Not automated, still required

- **The box walk on a real Mac.** No gate here proves behaviour.
- **`notarytool` exits 0 on `Invalid`.** Parse the status, not the exit code.
- **Staple the nested Hub `.app` before the outer installer seals it**, or you
  get "sealed resource missing or invalid".
- **Cut on the MBP**, not the Studio. Kill background jobs first.

---

## Open gaps in this tooling

| | |
|---|---|
| **#661** | `cut_hygiene_gate.sh` still defaults to the v1.0.10 manifest; its PR schema and the BOM schema are genuinely different documents and need reconciling |
| — | `run_all_cut_gates.sh` does not yet include `~/bin/ostler-acceptance-gate.sh` (runtime A1–A8, needs a running box) or `tests/test_wiki_tailnet_gate.sh` (needs docker + ~2 min) |
| — | no gate asserts a written field is ever **read** — `displayNameProvisional` ships written 4×, read 0× (task #658), the same shape as a probe with no bundler |
