# vendor/

Vendored copies of upstream packages that must be bundled inside the
Ostler Installer `.app`, so the installer is genuinely self-contained
once it has been signed, notarised and shipped to a customer.

## Why vendor at all?

The installer `.app` runs `install.sh` from inside its own
`Contents/Resources/` directory at install time. `install.sh` looks
for the security package on disk at `${SCRIPT_DIR}/ostler_security/`,
and if it is missing it silently degrades (passphrase prompt is
skipped, the database-encryption step then has no passphrase to
work with, and the install fails with a confusing error several
phases later).

Until 2026-05-21 the installer assumed that `ostler_security/` would
"already be there" at runtime, which was true for the developer
checkout layout (sibling clone of HR015) but never true for the
shipped `.app`. The Studio retest on 2026-05-21 caught this end to
end: passphrase question was silently skipped, then `encrypt_db`
demanded a passphrase that was never set.

Vendoring fixes this at the source. The package source files travel
with the CM051 repo, the Xcode post-build script copies them into
`Contents/Resources/ostler_security/`, and `install.sh` finds them
in the same place whether it is running from a developer tarball,
from a `curl | bash` bootstrap, or from inside the signed `.app`.

## What is vendored here

### `ostler_security/`

Source of truth: `HR015 - Gaming PC/ostler_security/`. Pure-Python
package (no native extensions). Pip-installed into the customer's
Hub venv at install time.

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

## How to sync

Until a `make vendor-sync` target is wired up (post-launch chore),
syncing is manual:

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

Open a PR with the diff. The PR title should make it obvious this is
a sync (e.g. `chore(vendor): sync ostler_security from HR015 @ <sha>`),
and the body should link the upstream commit so the audit trail is
clear.

## Rule

HR015 is read-only as the upstream. Bug fixes go upstream first,
land in HR015's `ostler_security/`, and only then flow into this
vendored copy via a sync PR. Never edit `vendor/ostler_security/`
in place to fix a bug -- you will lose the change on the next sync.
