# vendor/

Vendored copies of upstream packages that must be bundled inside the
Ostler Installer `.app`, so the installer is genuinely self-contained
once it has been signed, notarised and shipped to a customer.

## Why vendor at all?

The installer `.app` runs `install.sh` from inside its own
`Contents/Resources/` directory at install time. `install.sh` looks
for vendored sources on disk under `${SCRIPT_DIR}/`, and if they are
missing it either silently degrades (skipping a phase) or falls back
to a `git clone` of an upstream repo. The clone path is fine for
developer machines (where credentials and network access are reliable)
but it makes the customer install non-hermetic -- a private repo, a
network blip, or a credentials prompt can all silently turn the
install into a half-install.

The Studio retest on 2026-05-21 caught the silent-degrade variant end
to end: the passphrase question was skipped because `ostler_security/`
was missing, and the `encrypt_db` phase then demanded a passphrase
that was never set.

Vendoring fixes this at the source. Package source files travel with
the CM051 repo, the Xcode post-build script copies them into
`Contents/Resources/<vendor-name>/`, and `install.sh` finds them in
the same place whether it is running from a developer tarball, from
a `curl | bash` bootstrap, or from inside the signed `.app`.

## What is vendored here

### `ostler_security/`

See PR #115. Source of truth: `HR015 - Gaming PC/ostler_security/`.
Pure-Python package (no native extensions). Pip-installed into the
customer's Hub venv at install time.

What is included: every top-level `.py` source file, `pyproject.toml`,
`requirements.txt`, `bip39_english.txt` (BIP-39 wordlist used by
`passphrase.py` for recovery-phrase generation), `README.md`,
`SECURITY_MODEL.md`, `DAY_ZERO_AUDIT.md`, `DEPLOYMENT_NOTES.md`.

What is NOT included:

- `tests/` -- CI-only, never installed on a customer Mac.
- `bin/` -- SwiftPM source for `OstlerPasskeyHelper`, built and
  packaged separately.
- `__pycache__/`, `*.egg-info/`, `build/`, `.DS_Store`,
  `.pytest_cache/` -- developer / build artefacts.

### `ostler_fda/`

See PR #116. Source of truth: `HR015 - Gaming PC/ostler_fda/`.

### `cm024_knowledge/`

Source of truth: `andygmassey/evernote-knowledge` (the productised
v0.1 repo split out of `HR015/CM024 - Evernote Knowledge/`). Pure-
Python click CLI (no native extensions). Pip-installed into a
dedicated venv at `~/.ostler/services/knowledge/.venv/` at install
time; the venv-built `ostler-knowledge` binary is then symlinked
into `/usr/local/bin/ostler-knowledge` so the customer can invoke
it without activating the venv.

Customer surface: the Doctor "Import Evernote" UI page (feature-
flagged OFF at v1.0; flipped on for v1.1 per HR015 brief 3.x
launch-scope). The Knowledge service install path is NOT flag-gated
-- the CLI is always installed, the flag only controls UI visibility.

What is included:

- The complete `src/` package tree -- top-level CLI (`src/cli.py`),
  `src/api/` (backend adapter for CM023 synthesis layer), `src/ingestion/`
  (ENEX parser, markdown writer, chunker, classifier, embedder,
  importance scorer, incremental adapter), `src/ingestion/adapters/`
  (base + Evernote source adapter), `src/knowledge/` (email
  knowledge thread aggregator + summariser), `src/query/` (RAG
  retriever stub), `src/storage/` (Qdrant vector store + SQLite
  metadata DB).
- `pyproject.toml` declaring the `ostler-knowledge` console script.
- `requirements.txt` (mirror of pyproject dependencies).
- `README.md` (customer-facing overview).
- `config/settings.yaml` (default Qdrant collection name, embedding
  model, chunking knobs, privacy compartment heuristics).

What is NOT included:

- `tests/` -- CI-only, never installed on a customer Mac.
- `scripts/` -- developer ergonomics (overnight embed runners,
  watchdog, progress monitors). Customer-facing entry is
  `ostler-knowledge` only.
- `docs/` -- design documents (email-knowledge design, incremental-
  updates plan). Source-of-truth lives in the upstream repo.
- `__pycache__/`, `*.pyc`, `.DS_Store` -- developer artefacts.
- `data/`, `logs/`, `output/` -- runtime / dev fixtures, gitignored
  upstream anyway.

## How to sync

Until a `make vendor-sync` target is wired up (post-launch chore),
syncing is manual.

For `ostler_security/`:

```
SRC="$HOME/Documents/Projects/HR015 - Gaming PC/ostler_security"
DST="$(git rev-parse --show-toplevel)/vendor/ostler_security"

# Wipe and re-copy the top-level package only (no tests / bin / caches).
rm -rf "$DST"
mkdir -p "$DST"
for f in "$SRC"/*.py "$SRC"/*.toml "$SRC"/*.txt "$SRC"/*.md; do
  [ -f "$f" ] || continue
  cp "$f" "$DST/"
done
```

For `cm024_knowledge/`:

```
SRC="/tmp/evernote-knowledge"
git clone --depth 1 https://github.com/andygmassey/evernote-knowledge.git "$SRC"

DST="$(git rev-parse --show-toplevel)/vendor/cm024_knowledge"
rm -rf "$DST"
mkdir -p "$DST"

# Copy the src/ package tree + top-level packaging files + config.
cp -R "$SRC/src" "$DST/src"
cp -R "$SRC/config" "$DST/config"
cp "$SRC/pyproject.toml" "$DST/pyproject.toml"
cp "$SRC/requirements.txt" "$DST/requirements.txt"
cp "$SRC/README.md" "$DST/README.md"

# Sanity-strip pyc / cache that snuck in.
find "$DST" -name __pycache__ -type d -exec rm -rf {} +
find "$DST" -name "*.pyc" -delete

rm -rf "$SRC"
```

Open a PR with the diff. The PR title should make it obvious this is
a sync (e.g. `chore(vendor): sync ostler_security from HR015 @ <sha>`
or `chore(vendor): sync cm024_knowledge from evernote-knowledge @ <sha>`),
and the body should link the upstream commit so the audit trail is
clear.

## Rule

Upstream repos are read-only as the source of truth. Bug fixes go
upstream first, land in the upstream repo, and only then flow into
the vendored copy via a sync PR. Never edit `vendor/<name>/` in
place to fix a bug -- you will lose the change on the next sync.
