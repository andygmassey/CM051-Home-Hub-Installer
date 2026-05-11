# Cutting a CM051 release

This is the **canonical** release recipe for `ostler-ai/ostler-installer`.
If anything below disagrees with what's happening in the wild, this doc wins.
If you change the recipe, update this doc in the same commit.

> **Why this exists:** v0.1.0 was cut without documentation. v0.2.0 had to
> reconstruct the recipe from the v0.1.0 artefact's contents during launch
> crunch – slow, error-prone, and revealed a brand-leak (the
> `lifeline-import.sh` rename hack that didn't sweep content).
> See `memory/feedback_codify_walked_processes.md` for the rule.

## What ships in a release

A GitHub release at `ostler-ai/ostler-installer` attaches three artefacts:

| Asset | What it is | Source |
|---|---|---|
| `install.tar.gz` | The installer payload bundle (this repo's `release.sh` builds it) | This repo + HR015 (cross-repo bundle – see "Source map" below) |
| `ostler-assistant-aarch64-apple-darwin-vX.Y.Z.tar.gz` | The pre-built ZeroClaw assistant binary | `ostler-ai/ostler-assistant` repo (separate build, not in scope here) |
| `ostler-assistant-aarch64-apple-darwin-vX.Y.Z.tar.gz.sha256` | Checksum for the above | Generated alongside the binary build |

**This repo only owns `install.tar.gz`.** The assistant binary is built
separately in `ostler-ai/ostler-assistant` and attached to the same
release. If you're cutting a release and the assistant binary hasn't
changed, reuse the previous tag's binary by downloading + re-attaching it
(see "When the assistant binary is unchanged" below).

## Source map for `install.tar.gz`

The tarball stages everything under a single `install/` parent directory.
Sources span TWO repos (CM051 + HR015):

```
install/
├── install.sh              ← CM051: ./install.sh
├── lib/                    ← CM051: ./lib/
├── assistant-agent/        ← CM051: ./assistant-agent/
├── wiki-recompile/         ← CM051: ./wiki-recompile/
├── ostler-import.sh        ← HR015: ./ostler-import.sh   (was lifeline-import.sh; renamed at source 2026-05-08)
├── ostler_security/        ← HR015: ./ostler_security/
├── ostler_fda/             ← HR015: ./ostler_fda/
├── hub-power/              ← HR015: ./hub-power/
├── contact_syncer/         ← HR015: ./contact_syncer/    (canonical; CM041 has a divergent copy – DO NOT use)
├── email-ingest/           ← HR015: ./email-ingest/
├── doctor/                 ← HR015: ./doctor/
├── legal/                  ← HR015: ./legal/
├── LICENSES/               ← HR015: ./LICENSES/
├── THIRD_PARTY_NOTICES.md  ← HR015: ./THIRD_PARTY_NOTICES.md
└── requirements.txt        ← HR015: ./contact_syncer/requirements.txt  (copied to top-level)
```

**Forbidden patterns** in the staged content (sweep BEFORE tarballing):

- `lifeline` (case-insensitive) – residual rebrand leak
- `LIFELINE_DIR` – except where intentionally used as a backwards-compat
  alias (today: `hub-power/bin/hub-power-state.sh` only)
- `IT Guy`, `it-guy`, `/it-guy` – unreleased competitive IP, never ship to
  customers (see `memory/feedback_it_guy_never_public.md`)
- `Marvin` – assistant instance name, not a product noun
  (see `memory/feedback_naming_assistant_not_marvin.md`)
- `lifeline.dev` – defunct domain, never existed publicly
  (see `memory/feedback_lifeline_dev_never_existed.md`)

`release.sh --verify` runs these greps and refuses to seal the tarball if
any match. Do not bypass.

### Whitelisted exemptions

A small set of files legitimately mention `lifeline` and CANNOT be swept
without breaking installed users. Each exemption is documented in
`release.sh` (the `FORBIDDEN_EXEMPTIONS` array) with a one-line "why":

| File | Why exempt |
|---|---|
| `hub-power/bin/hub-power-state.sh` | Reads `$LIFELINE_DIR` as fallback for v0.1-era installs |
| `ostler_security/migrate_recovery_key_aad.py` | Migration script reads existing AAD-encrypted blobs that contain the literal `lifeline-recovery-key-v2:` byte string |
| `ostler_security/webauthn_client.py` | WebAuthn PRF salt is `lifeline/prf/v1` – historical name preserved as do-not-touch (changing it invalidates every paired user's encryption key) |
| `ostler_security/SECURITY_MODEL.md` | Doc explicitly contrasts the rebrand (mentions the old name to make the point) |

If you find yourself adding a new exemption, that's a strong signal you
should be doing a source-side rebrand instead – exemptions are for
load-bearing legacy crypto only.

### Exclusions (paths NEVER staged into the bundle)

`release.sh` excludes these from the rsync into the staging dir:

- `__pycache__`, `.pytest_cache`, `*.egg-info` – Python build artefacts
- `.DS_Store`, `.git*` – local cruft
- `build`, `*_AUDIT.md`, `TECH_DEBT_*.md`, `SESSION_HANDOFF_*.md` –
  internal-only docs and build outputs
- `tests` – internal test files. v0.1.0 SHIPPED these to disk and they
  contained internal naming (e.g. `test_payload_viewer.py` docstring
  referencing unreleased competitive IP). Customer installs do not need
  test files; if you ever do, reconsider why.
- `.env` – gitignored from git, but rsync does not honour `.gitignore`.
  v0.2.0 dry-run caught `contact_syncer/.env` containing a real CardDAV
  app-specific password. Without this exclude every customer download
  would have shipped the developer's iCloud credential. `.env.example`
  is allowed (template, not a secret).

### Credential scan (verify step, defence-in-depth)

`release.sh --verify` runs a second pass after the forbidden-pattern
grep. It greps the staged tree for known secret signatures:

- Apple app-specific password format (`xxxx-xxxx-xxxx-xxxx`)
- Any literal `.env` file that snuck through the rsync exclude
- Anthropic / OpenAI / GitHub PAT prefixes (`sk-ant-…`, `sk-…`, `ghp_…`,
  `github_pat_…`)

If a hit fires, fix at source – never add an exemption. Adding an
exemption is how secrets ship to customers.

## Cutting a new release – happy path

```bash
# 1. Make sure both source repos are on clean main and up to date
cd "$(dirname "$0")"
git checkout main && git pull --ff-only
( cd "../HR015 - Gaming PC" && git checkout main && git pull --ff-only )

# 2. Stage + verify + tarball (two-pass SHA injection happens automatically)
./release.sh --version v0.3.0 --hr015 "../HR015 - Gaming PC" --verify

# Output: dist/install.tar.gz (and dist/install.tar.gz.sha256)
# release.sh prints the pass-1 SHA (pinned inside the tarball) AND the
# final SHA (of dist/install.tar.gz). Read the output carefully.

# 3. SHA injection step (REQUIRED -- see "SHA injection" section below)
#    Copy the FINAL SHA printed by release.sh and patch standalone install.sh:
FINAL_SHA="<paste final SHA from release.sh output>"
sed -i '' "s/DEFAULT_INSTALLER_TARBALL_SHA256=\"REPLACE_AT_RELEASE_TIME\"/DEFAULT_INSTALLER_TARBALL_SHA256=\"${FINAL_SHA}\"/" install.sh

# Verify:
grep 'DEFAULT_INSTALLER_TARBALL_SHA256=' install.sh

# 4. Commit the patched install.sh to main (with the rest of the release bump)
git add install.sh
git commit -m "chore: bump installer SHA for v0.3.0 release"
git push origin main

# 5. Diff against the previous release tag (catches accidental drops)
./release.sh --version v0.3.0 --hr015 "../HR015 - Gaming PC" --diff-against-tag v0.2.0

# 6. When happy, cut the release
gh release create v0.3.0 \
    --repo ostler-ai/ostler-installer \
    --target main \
    --title "v0.3.0 – <short description>" \
    --notes-file dist/RELEASE_NOTES_v0.3.0.md \
    dist/install.tar.gz \
    dist/install.tar.gz.sha256

# 7. Attach the assistant binary
#    Either: rebuild from ostler-ai/ostler-assistant + upload
#    Or:   reuse previous binary if unchanged (see below)
gh release upload v0.3.0 \
    --repo ostler-ai/ostler-installer \
    "ostler-assistant-aarch64-apple-darwin-v0.3.0.tar.gz" \
    "ostler-assistant-aarch64-apple-darwin-v0.3.0.tar.gz.sha256"

# 8. Verify the live install.sh fetches the new release
curl -sI https://github.com/ostler-ai/ostler-installer/releases/latest/download/install.tar.gz | head -10

# 9. Smoke-test the SHA guard (cache-bust required)
curl -sL "https://ostler.ai/install.sh?cb=$(date +%s)" | grep 'DEFAULT_INSTALLER_TARBALL_SHA256'
# Should print the FINAL SHA from step 3 (not REPLACE_AT_RELEASE_TIME).
```

## SHA injection

The `DEFAULT_INSTALLER_TARBALL_SHA256` constant in `install.sh` pins the
SHA-256 of the release tarball. Customers who run `curl | bash` download the
tarball and verify it against this constant before extracting. This is the
supply-chain guard: an attacker must compromise BOTH the release tarball AND
the `install.sh` served by Cloudflare/GitHub to bypass it.

### Why a two-pass build is needed

The constant lives inside `install.sh`, which is also bundled inside the
tarball. If we naively pinned the tarball's SHA inside the bundled install.sh,
the tarball would have to contain a file that references its own SHA -- a
circular dependency.

`release.sh` resolves this with a two-pass build:

1. **Pass 1:** stage all files with the sentinel `REPLACE_AT_RELEASE_TIME`,
   tar, compute SHA (S1).
2. **Inject:** patch staged `install.sh`: replace sentinel with S1.
3. **Pass 2:** re-tar. Final tarball T2 contains install.sh with S1 pinned.
   T2 has SHA S2 (different from S1 because install.sh changed).

The **standalone `install.sh`** (in this repo, served at ostler.ai/install.sh
via GitHub raw) must be patched with **S2** before the release commits. This
is step 3 in the happy path above. The `release.sh` output prints both values
clearly:

```
   pass-1 SHA (pinned inside tarball's install.sh): <S1>
   FINAL  SHA (dist/install.tar.gz.sha256):         <S2>
```

Patch the standalone install.sh with **FINAL SHA (S2)**.

### What gets pinned where

| Location | SHA pinned | Matches |
|---|---|---|
| Standalone `install.sh` on GitHub raw (this repo) | S2 (FINAL) | `dist/install.tar.gz` |
| `install.sh` bundled inside `dist/install.tar.gz` | S1 (pass-1) | pass-1 tarball (no longer downloadable) |

The inner pinned SHA (S1) is harmless: it is only ever reached if someone
extracts the tarball and re-runs the inner install.sh via `curl|bash` from
inside the extracted tree, which is not a supported use-case. The security
property that matters is: the **outer** install.sh (what `curl | bash` fetches)
verifies the tarball before extraction.

### Release-gate CI

Set `OSTLER_CHECK_RELEASE_SHA=1` when running
`tests/test_bootstrap_prelude.sh` in release-gate CI. This makes the test
fail if the standalone install.sh still contains the sentinel, catching a
missed step-3 patch.

## When the assistant binary is unchanged

If `ostler-ai/ostler-assistant` has no commits since the previous release tag,
download the previous binary, rename, re-checksum, attach:

```bash
PREV=v0.1.0
NEW=v0.2.0
mkdir -p dist
gh release download "$PREV" \
    --repo ostler-ai/ostler-installer \
    --pattern "ostler-assistant-aarch64-apple-darwin-${PREV}.tar.gz" \
    --dir dist
mv "dist/ostler-assistant-aarch64-apple-darwin-${PREV}.tar.gz" \
   "dist/ostler-assistant-aarch64-apple-darwin-${NEW}.tar.gz"
shasum -a 256 "dist/ostler-assistant-aarch64-apple-darwin-${NEW}.tar.gz" \
    > "dist/ostler-assistant-aarch64-apple-darwin-${NEW}.tar.gz.sha256"
```

Note that the *content* of the binary tar is identical – only the filename
and checksum filename change. If install.sh pins to a specific binary
version, this approach still works because install.sh reads from the
release tag, not from the filename.

## What to put in RELEASE_NOTES_vX.Y.Z.md

- One-line summary
- Bullet list of merged PRs since the previous tag (`git log --oneline TAG..HEAD`)
- Any breaking changes (env-var renames, dependency bumps, etc.)
- Any "known issues" the user should be aware of

`release.sh --version vX.Y.Z --notes-skeleton > dist/RELEASE_NOTES_vX.Y.Z.md`
generates a skeleton with the PR list pre-filled. You write the prose.

## Quirks worth remembering

1. **The `install.sh` script in this repo is symlinked-by-copy into the
   tarball.** It's the same file. No mangling at packaging time.

2. **`requirements.txt` at the top level of the bundle is a verbatim copy
   of `HR015/contact_syncer/requirements.txt`.** If you change either,
   keep them in lockstep until/unless we untangle.

3. **`contact_syncer/` lives in BOTH HR015 and CM041.** The HR015 copy is
   canonical for the installer bundle. CM041's copy has drifted (different
   files). Resist the urge to merge them in the middle of a release cut –
   that's a separate post-launch ticket.

4. **`__pycache__/` and `.DS_Store` must be excluded from the tarball.**
   `release.sh` excludes them; verify in the dry-run output.

5. **The tarball is NOT signed or notarised.** macOS users pipe install.sh
   through bash directly; Gatekeeper does not gate it. The installer GUI
   (`OstlerInstaller.app`) IS notarised separately via `gui/Makefile`.

## When the recipe changes

Update this doc in the SAME commit. Then:

- If `release.sh` needs new flags, add them
- If new directories are bundled, update the source-map table above
- If new forbidden patterns are added, update the verify step + the
  feedback-memory list

The half-life of an undocumented recipe is roughly two weeks – by then
the next release is needed and somebody is reconstructing.
