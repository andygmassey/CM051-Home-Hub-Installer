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

## The 11 primitives

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

**Sidecar cross-check (v1.0.14, opt-in).** When the entry sets
`consume_build_info_sidecar: true`, the gate additionally cross-checks the
release's `.build-info.json` sidecar against the pin (see spec
`launch/BUILD_INFO_SIDECAR_SPEC_v1.0.14.md` and paired oa #259 Stream 1
emitter). Cross-checks: `sidecar.commit_sha == pin_sha`,
`sidecar.dirty_worktree != true`, and optionally
`sidecar.signed_by.tarball_sha256` (tamper detection, downloads the tarball;
only enabled when `verify_tarball_sha: true`). Sidecars marked
`reconstructed: true` (the four hub-v0.4.40-43 backfills at HR015
`launch/backfill-sidecars/`) are tolerated only when `allow_reconstructed: true`,
and they PASS with a "verified-with-caveat" note. Missing sidecar with
`consume_build_info_sidecar: true` -> FAIL closed. Backward-compat is
preserved: entries without the field behave exactly as before.

```yaml
proof:
  kind: pinned_artefact_freshness
  # ... existing fields ...
  consume_build_info_sidecar: true
  allow_reconstructed: true                                  # accept backfill
  local_sidecar_dir: "${HR015_DIR}/launch/backfill-sidecars" # local fallback
  verify_tarball_sha: false                                  # opt-in tamper check
```

### 11. `verify_build_info_sidecar_present`

Defensive backstop introduced in v1.0.14 (Stream 2 of the build-info sidecar
rollout, pairs with oa #259 Stream 1). Fires for every pinned binary artefact
that should ship with a `.build-info.json` sidecar. Fails closed if no sidecar
is present in either the local fallback directory (for Stream 3 backfills) or
as a `.build-info.json` release asset on the artefact's tag.

Sidecars marked `reconstructed: true` (the four hub-v0.4.40-43 backfills) pass
only when the entry sets `allow_reconstructed: true`, reporting
"verified-with-caveat". Non-reconstructed sidecars from a real Stream 1
daemon build pass as "sidecar present + fully-verified".

Belt-and-braces: if the sidecar declares its own `tag_name`, it must match the
tag the pin resolves to (misfile guard).

```yaml
proof:
  kind: verify_build_info_sidecar_present
  # Same pin-source shape as pinned_artefact_freshness.
  pinned_version_source:
    file: "gui/Makefile"
    pattern: 'DAEMON_VERSION\s*[?:]?=\s*(\d+\.\d+\.\d+)'
  tag_format: "hub-v{version}"
  source_repo: "ostler-ai/ostler-assistant"
  # Optional: accept Stream 3 backfill sidecars (reconstructed:true).
  allow_reconstructed: true
  # Optional: local fallback dir for backfill sidecars. Env-var expansion is
  # supported so a cut manifest need not carry a per-operator absolute path.
  local_sidecar_dir: "${HR015_DIR}/launch/backfill-sidecars"
```

Same `gh auth` rules apply as `pinned_artefact_freshness`. See
`launch/BUILD_INFO_SIDECAR_SPEC_v1.0.14.md` for the full spec including field
semantics and the Stream 1 emitter contract.

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
