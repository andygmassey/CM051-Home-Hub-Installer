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
    kind: <one of the 5 below>
    # ... primitive-specific fields
```

## The 5 primitives

Every proof has `kind` and (for greps) `must_match: true|false` (default true).
`must_match: false` is an ABSENCE proof — the pattern MUST NOT appear. Absence
proofs are how you enforce "no legacy FDA URL survived any code path."

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

### 3. `grep_in_source_at_sha`

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

### 4. `file_exists_in_artefact`

Proves a specific file (asset, plist, script, chrome fragment) is present in
the artefact tree. Same `target:` semantics as `grep_in_artefact`.

```yaml
proof:
  kind: file_exists_in_artefact
  target: vendored-wiki-chrome
  path: "dup_decision.js"
```

### 5. `plist_key_equals`

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
