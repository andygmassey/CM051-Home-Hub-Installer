# Cut manifest gate

The cut manifest gate is a fail-closed pre-signing check that proves every
fix a cut is supposed to contain is actually baked into the shipped artefact.
It sits alongside the sibling gates (`check-provenance`, `check-freshness`,
`check-provenance-content`) and runs BEFORE `codesign`. Any RED fails the cut
before signing.

The point is to kill the class of bug where a fix has been merged, is in the
commit log, but does NOT ship in the DMG — because the daemon wasn't rebuilt,
the wrong vendored copy was shipped, a branch wasn't picked up, or the
maintainer forgot to add a marker to another gate's manifest.

## What it is not

- It is not a functional test. Tests prove logic; this proves the fix's
  fingerprint appears where it should appear in the shipped bytes.
- It does not run the artefact. `plist_key_equals` proves the plist file has
  the right key value; "does the daemon actually load at boot" belongs to the
  post-install box-walk gate.
- It does not replace `provenance_gate.sh`. That gate proves ancestry +
  vendored-image content via digest lookups; this gate is one YAML schema
  covering literal-provable + logic fixes across the whole cut.

## Manifest files

- **`permanent.yaml`** — never-regress backstop. Every entry converts a past
  incident into a permanent invariant proven at every cut. Add entries here
  after any incident where a slip caused customer pain. Do not remove.
- **`v<version>.yaml`** — per-cut contract. Entries can retire when the cut
  ships and the invariant is either promoted to `permanent.yaml` or the
  concern has passed.

Both files are consumed on every cut. A RED in either fails the cut.

## Entry schema

```yaml
- id: kebab-case-slug            # required, unique within the file
  title: One-line human title    # required
  incident: What slipped before  # optional; recommended for permanent.yaml
  source_pr: owner/repo#N        # optional; useful cross-reference
  source_sha: <sha>              # required for grep_in_source_at_sha
  proof:
    kind: <one of the 9 below>
    # ... primitive-specific fields
```

## The 10 primitives

Every proof has `kind` and (for greps) `must_match: true|false` (default true).
`must_match: false` is an ABSENCE proof — the pattern MUST NOT appear. Absence
proofs are how you enforce "no legacy FDA URL survived any code path" or "no
operator-PII rode into the DMG on any file."

### 1. `grep_in_installer`

Greps `install.sh` for a regex pattern. Simple, fast, covers all shell text.

```yaml
proof:
  kind: grep_in_installer
  pattern: "com\\.apple\\.settings\\.PrivacySecurity\\.extension"
  must_match: true
```

### 2. `grep_in_artefact`

Greps inside the built artefact tree. `target` names one of:

| target | Resolves to |
|---|---|
| `installer-app` | `${APP_PATH}` (the built `OstlerInstaller.app`) |
| `daemon-app` | `${APP_PATH}/Contents/Resources/Ostler.app` |
| `daemon-web-bundle` | `${APP_PATH}/Contents/Resources/Ostler.app/Contents/Resources` (web assets) |
| `daemon-binary` | `${APP_PATH}/Contents/Resources/Ostler.app/Contents/MacOS/ostler-assistant` |
| `vendored-context-refresh` | `${APP_PATH}/Contents/Resources/context-refresh` |
| `vendored-wiki-chrome` | `${APP_PATH}/Contents/Resources/wiki-chrome` (or discover) |

Add a `path:` sub-field to grep a specific file inside the target root. Without
`path:`, the whole target tree is greppable.

Note the compilation limit: `grep_in_artefact` only proves literals that
survive compilation. Swift/Rust logic edits like `?? ""` compile to nothing
greppable — use `grep_in_source_at_sha` for those.

```yaml
proof:
  kind: grep_in_artefact
  target: vendored-context-refresh
  path: "bin/generate_pwg_context.py"
  pattern: "Authorization"
  must_match: true
```

### 3. `grep_in_dmg_tree`

Proves a pattern's presence/absence across the **ENTIRE shipped DMG payload**,
not one named file or sub-target. The DMG's sole payload is
`OstlerInstaller.app`, so this scans the whole built installer-app tree — the
bundled `install.sh`, every vendored `.py`/`.md`/`.sh`, the daemon `Ostler.app`
and any nested helper apps and their text resources — plus a `strings(1)` pass
over the Mach-O binaries it finds. The source `install.sh` is scanned too, so an
absence proof still holds in a local no-build run. On a violation the detail
names the offending files.

Built for the **operator-PII backstop**: `grep_in_installer` only ever saw
`install.sh`, so v1.0.11 shipped 3 `gamingrig` occurrences in vendored trees
while the gate passed. Use this kind (with `must_match: false`) to prove Andy's
personal instance details never appear ANYWHERE in the cut.

```yaml
proof:
  kind: grep_in_dmg_tree
  pattern: "gamingrig"
  must_match: false
```

No `target:`/`path:` fields — the point is that it scans everything. The gate's
own pattern-definition files (`cut-manifests/`, `verify_cut_manifest*`) are
excluded so the scan never flags the manifest that bans the pattern.

Optional `exempt_paths:` accepts a list of glob patterns; hits whose file path
matches any glob are removed from the count BEFORE the presence/absence
decision. Mirrors the `[allow_paths].skip` pattern in `bin/operator-pii-scan.sh`
so a `must_match: false` entry can allowlist known-good references (for example
the F6.1 "Marvin" name-suggestion pool that lives in `ViewCopy.json` +
`install.sh.strings.en-GB.sh`). Detail line shows `hits=N (M exempted)` when
exemptions apply.

```yaml
proof:
  kind: grep_in_dmg_tree
  pattern: "Marvin"
  must_match: false
  exempt_paths:
    - "**/ViewCopy.json"
    - "**/install.sh.strings.en-GB.sh"
    - "**/permanent.yaml"
```

**Coverage limit (honest):** Tauri packs the daemon's `web/dist` COMPRESSED
inside its main binary, so operator-PII living ONLY in the compiled+compressed
web bundle is unreachable by both a text read and `strings(1)`. That residual
class must be guarded by `grep_in_source_at_sha` on `ostler-assistant` (see
`firstrun-popup-governor-source` in `permanent.yaml`). Everything
text-extractable in the DMG — where every operator-PII slip to date has landed —
is covered.

### 4. `grep_in_source_at_sha`

Greps the source repo at a pinned SHA. Use this for logic fixes that
compile away. Combines with a `test:` block that names the regression test
guarding the same path — the test is the runtime proof.

```yaml
proof:
  kind: grep_in_source_at_sha
  target: this-repo                # or: ostler-assistant, cm044, hr015
  path: "gui/OstlerInstaller/ProgressProtocol.swift"
  pattern: "kv\\[\"title\"\\]\\s*\\?\\?\\s*\"\""
  must_match: true
  test:
    command: "xcodebuild test ..."
    required: false                # true = block cut if the test fails locally
```

The `target` names a repo the verifier knows how to locate. `this-repo` is
CM051 itself (the worktree the verifier runs in). Others resolve via env
vars documented in `verify_cut_manifest.py`.

### 5. `file_exists_in_artefact`

Proves a specific file (asset, plist, script, chrome fragment) is present in
the artefact tree. Same `target:` semantics as `grep_in_artefact`.

```yaml
proof:
  kind: file_exists_in_artefact
  target: vendored-wiki-chrome
  path: "dup_decision.js"
```

### 6. `plist_key_equals`

Reads a plist and asserts a key's value. Static proxy for launchd behaviour;
box-walk verifies actual runtime.

```yaml
proof:
  kind: plist_key_equals
  target: installer                # 'installer' = CM051 tree, 'installer-app' = built .app
  path: "lib/plists/com.creativemachines.ostler-imessage-bundle.plist"
  key: "RunAtLoad"
  value: "false"                   # string; "true"/"false" for booleans
```

### 7. `plist_env_key_present`

Asserts a named env-var KEY is declared inside a plist's `EnvironmentVariables`
dict. Existence check only; the value is NEVER read or validated so the
per-install secret never lands in the manifest. Used to prove fresh v1.0.12+
installs ship an assistant plist that declares `PWG_SERVICE_TOKEN` (per CM051
#464). `must_be_present: false` inverts to an absence proof.

Follows the same template-fallback pattern as `plist_key_equals`: when
plistlib cannot parse the file (unresolved template placeholders leave the
XML ill-formed) the primitive falls back to a regex probe on the
`EnvironmentVariables` block.

```yaml
proof:
  kind: plist_env_key_present
  target: installer-tree
  path: "assistant-agent/launchd/com.creativemachines.ostler.assistant.plist"
  key: "PWG_SERVICE_TOKEN"
  must_be_present: true
```

### 8. `box_walk_probe`

A **runtime** gate. Invokes a named shell probe against a real box; captures
the class of bug that static gates cannot see (seed-and-query round-trip
proof). The registry maps `probe: <name>` to `scripts/box_walk_probes/<name>.sh`.
See `scripts/box_walk_probes/README.md` for the per-probe contract.

The primitive SKIPs when `OSTLER_BOX_HOST` is not set — runtime probes require
a reachable box, and CI + offline dev pass cleanly without one. When
`OSTLER_BOX_HOST` IS set the probe MUST exit `0` to PASS; any non-zero exit is
FAIL, with the last stdout / stderr line captured in the Result detail.
Timeout is 180 seconds.

```yaml
proof:
  kind: box_walk_probe
  probe: "people_seed_and_retrieval"
```

Registered probes live in `scripts/box_walk_probes/`. The
`people_seed_and_retrieval` probe seeds a Person "Sofia Testperson" into the
graph on the box, asks the daemon via the iMessage tool-call path, and asserts
the reply contains the name and does NOT contain the confabulation-tell "I
don't have any information". The full body ships with the Studio matrix
runbook; the stub in this PR exits `0` so the primitive wiring can land first.

### 9. `payload_version_matches_daemon_version`

Cut-time integrity check that the (B-lite) embedded payload's `VERSION` file
matches the bundled daemon binary's `--version` output. Catches "VERSION file
right, wrong binary bundled" and the reverse.

Reads `<APP_PATH>/Contents/Resources/ostler-payload/VERSION`, then invokes
`<APP_PATH>/Contents/Resources/ostler-payload/assistant-agent/bin/ostler-assistant --version`.
Both values are normalised to a semver core before comparison. Three input
shapes are accepted (matching TNM's `upgrade_reconcile::SemVer::parse` from
oa #238):

- `hub-vX.Y.Z` (typical payload VERSION file)
- `zeroclaw X.Y.Z` (typical daemon --version output)
- bare `X.Y.Z`

Anything else is a parse error and FAILs the gate. SKIPs when the built app is
not present. FAILs on any read error, invocation error, or non-zero exit from
the daemon `--version` call. Result detail includes both raw values and both
normalised values.

```yaml
proof:
  kind: payload_version_matches_daemon_version
```

No `target:`/`path:` fields — the payload location is fixed by the (B-lite)
spec.

### 10. `pinned_artefact_freshness`

Closes the class of failure where CM051 downloads a pre-built artefact (daemon
tarball, RemoteCapture app) at cut time and merged-to-source fixes have already
moved past the pinned tag, so those fixes structurally cannot ship in the DMG.
The v1.0.13 near-miss (2026-07-30) was exactly this: `DAEMON_VERSION = 0.4.39`
resolved to `hub-v0.4.39`, tagged from `oa/main` at commit `16687ed6`, but
`oa/main` had since advanced by 5 commits including v1.0.13 launch-blockers in
`crates/*`. TNM caught it by manual inspection; this primitive catches it by
mechanism.

The primitive:

1. Reads the pinned version from a source file via a capture-group regex.
2. Formats it to a source-repo git tag via `tag_format`.
3. Resolves the tag to its target commit SHA on the source repo via GitHub API.
4. Fetches the source repo's default-branch HEAD SHA.
5. Compares `pin_sha...head_sha` and walks every intervening commit.
6. Skips commits whose first-line message matches any `ignore_commits_matching`
   regex (chore-only cleanups don't affect the shipped bytes).
7. Fails when any surviving commit touches a file matching `source_paths`;
   enumerates the diverging commits in the error detail.

Fails closed on network errors, missing tokens, missing tags, or malformed
responses. A transient outage that hides real divergence is a worse outcome
than a build that needs a re-run.

```yaml
proof:
  kind: pinned_artefact_freshness
  # Human-readable name of the artefact (for error messages).
  artefact: "daemon (ostler-assistant)"
  # Where the pinned version comes from. `pattern` must capture the semver
  # in group 1.
  pinned_version_source:
    file: "gui/Makefile"
    pattern: 'DAEMON_VERSION\s*[?:]?=\s*(\d+\.\d+\.\d+)'
  # How the version turns into a git tag on the source repo. `{version}` is
  # substituted verbatim.
  tag_format: "hub-v{version}"
  # Source repo to check for divergence, owner/name.
  source_repo: "ostler-ai/ostler-assistant"
  # The sub-tree that compiles into this artefact. Divergence in files matching
  # any of these globs is what fails the gate. `**` spans directory separators.
  source_paths:
    - "crates/**"
  # Optional first-line-of-message regexes; matching commits are skipped
  # (docs/formatting-only changes don't affect the shipped bytes).
  ignore_commits_matching:
    - "^chore\\(fmt\\)"
    - "^docs:"
    - "^chore\\(docs\\)"
```

Auth: `gh api` is invoked with `GH_TOKEN=$(gh auth token --user <owner>)`, where
`<owner>` is the slug before the `/` in `source_repo`. The account must have
`repo` scope on the source repo, so private repos work. Missing token -> FAIL.

Recovery when the gate fails: tag a new release from source HEAD (or cherry-pick
the diverging commits to a release branch), wait for the build to publish,
bump the pin in the file named by `pinned_version_source.file`, re-run the
gate. See `VERSIONING.md` for the runbook.

### 11. `pin_matches_latest_release_tag`

Cross-repo tag consistency. Sibling to `pinned_artefact_freshness` with a
DIFFERENT failure mode:

- `pinned_artefact_freshness`  -- did source HEAD advance past the pinned tag?
- `pin_matches_latest_release` -- did a NEW release tag land that the pin
                                  does not yet reflect?

A pin can be fresh vs source (nothing merged since the tag) yet still lag
behind a subsequent release rebuild triggered off the same source SHA (for
example a packaging fix rebuilt as `hub-vX.Y.Z+1` with identical source).
Both gates protect against distinct real-world drift shapes; both fail closed.

The primitive:

1. Reads the pinned version from a source file via a capture-group regex
   (same shape as `pinned_artefact_freshness`).
2. Fetches the release listing on `release_repo`, filtering to non-draft,
   non-prerelease tags starting with `tag_prefix`.
3. Picks the newest by `published_at`.
4. Strips `tag_prefix` and asserts the resulting version equals the pin.

```yaml
proof:
  kind: pin_matches_latest_release_tag
  release_repo: "ostler-ai/ostler-releases"
  pin_file: "gui/Makefile"
  pin_var_pattern: 'DAEMON_VERSION\s*[?:]?=\s*(\d+\.\d+\.\d+)'
  tag_prefix: "hub-v"
  # Optional: allow prerelease tags to count as `latest` (default false).
  allow_prerelease: false
```

Auth follows the same `gh auth token --user <owner>` convention as
`pinned_artefact_freshness`. Fail-closed on network / auth / empty-list.

### 12. `pr_branch_not_stale_vs_main`

Encodes `feedback_mergeable_api_state_isnt_semantic_safety` (filed
2026-07-31): `mergeable: MERGEABLE` from the GH API does NOT prove a branch
is semantically safe to merge -- a branch that predates a critical recent
commit would silently REVERT it. TNM caught this on PR #484 before merging;
this primitive turns "rebase-before-merge" into a mechanical gate.

The primitive:

1. Reads `PR_NUMBER` + `GITHUB_REPOSITORY` from env (populated by GitHub
   Actions in PR context). SKIPS cleanly when unset (local dev / non-PR CI).
2. Fetches the PR to resolve `base.sha` + `base.ref`.
3. Fetches the current HEAD of `base.ref`.
4. Compares `base.sha...head.sha`, counts non-ignored commits behind.
5. FAILs when the behind-by count exceeds `max_commits_behind` (default 10).

```yaml
proof:
  kind: pr_branch_not_stale_vs_main
  max_commits_behind: 10
  ignore_commits_matching:
    - "^chore\\(fmt\\)"
    - "^docs:"
    - "^chore\\(docs\\)"
```

Recovery: merge the target branch into the PR branch and push. Never rebase --
a rebase rewrites SHAs, after which `git merge-base --is-ancestor` can never
prove the work landed.

#### This row was unreachable for its entire life, and read green

Measured 2026-08-19. `grep -rn PR_NUMBER .github/workflows/` returned nothing.
Control: the same grep for `pull_request` matched 12 files, so the absence was
real rather than a broken predicate. No caller ever set the variable, so step 1
returned SKIP on every invocation, and `main()` collapses SKIP and PASS onto
exit 0. **A row that always skips is indistinguishable from a row that always
passes**, which is why it survived from 2026-07-31 untouched.

Two things changed:

* `.github/workflows/pr-branch-staleness.yml` runs the primitive in PR context
  with `PR_NUMBER` set. It carries **no `paths:` filter** on purpose: staleness
  is a property of the branch, not of the files it touches, so a filter would
  skip the gate on exactly the PRs it exists to catch, and a skipped job renders
  as a grey tick that reads like a pass.
* `--require-kind KIND` demands the kind actually ran. If every entry of that
  kind ended SKIP, or the manifests hold none, the run exits **3
  (CANNOT-RUN)** -- a distinct, still-non-zero code. The workflow's first step
  is a positive control that deliberately unsets `PR_NUMBER` and asserts exit 3,
  so the gate cannot become unfalsifiable again without CI saying so.

Live proof, real PRs, real API, 2026-08-19:

| PR | base.sha behind `main` | verdict | exit |
|----|------------------------|---------|------|
| #509 | 393 | FAIL, `max_commits_behind=10 exceeded` | 1 |
| #493 | 10 | PASS, within bound | 0 |
| (none) `PR_NUMBER` unset | n/a | CANNOT-RUN | 3 |

#### The compare endpoint caps `.commits` at 250

`.ahead_by` reports the true total; `.commits` returns at most 250 entries with
no error and no flag. Measured on PR #509: `ahead_by=393`, `len(commits)=250`.
Applying `ignore_commits_matching` to the returned page alone understates the
gap and can **falsely PASS**: a branch 393 behind whose first 250 commits all
match an ignore pattern would count as 0 behind. Un-inspected commits are
counted as non-ignored and the split is printed in the detail line.

## Vendor drift check (sibling workflow, not a manifest primitive)

`scripts/check_vendor_drift.py` + `.github/workflows/vendor-drift-check.yml`
implement scheduled vendor drift detection. Runs daily; reads
`.vendor-manifests/*.yaml` (per-tree GitHub source resolvers) + the
pinned SHAs from `vendor/VENDOR_MANIFEST.toml`; opens a draft PR when
drift is detected on any tree with a KNOWN GitHub source. Trees with
`<UNKNOWN -- retrofit needed>` in their manifest are surfaced in the
report but do not auto-open PRs. See `.vendor-manifests/README.md` for
the resolver schema.

## Wiring

`gui/Makefile` gains a `check-manifest` target added to the `ship:` prereq
chain, right after `check-provenance-content`. `scripts/verify_cut_manifest.sh`
is the entry point (bash wrapper); the real logic is in
`scripts/verify_cut_manifest.py`.

## Manual usage

```bash
# From CM051 repo root
./scripts/verify_cut_manifest.sh                       # verifies against defaults
APP_PATH=/tmp/my.app ./scripts/verify_cut_manifest.sh  # override artefact path
./scripts/verify_cut_manifest.sh --verbose             # print each match
```

Exit codes:

- `0` — all entries GREEN
- `1` — one or more RED (fail-closed default)
- `2` — invocation error (missing manifest file, bad YAML, missing dependency)

## When to add an entry

- After any incident where a fix silently slipped or a customer-visible
  defect regressed, add a `permanent.yaml` entry as part of the fix commit.
- When opening a PR that changes `install.sh` or bumps a vendored SHA, add a
  matching entry in `cut-manifests/v<current-version>.yaml` if the fix isn't
  already covered by a permanent invariant.
- When a v<X>.yaml entry has proven itself worth enforcing forever, promote
  it into `permanent.yaml` and delete from the per-cut file.
