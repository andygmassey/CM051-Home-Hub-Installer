# vendor/

Vendored Python packages that ship inside the signed Ostler Installer
`.app` bundle. The customer-install path needs every dependency to be
already present on disk by the time `install.sh` runs, so packages that
were historically pip-installed from a developer's sibling-clone of
HR015 are copied here and bundled into `Contents/Resources/` by the
`postBuildScript` blocks in `gui/project.yml`.

## What lives here

| Package | Source of truth (HR015) | Why vendored |
|---------|-------------------------|--------------|
| `ostler_fda/` | `HR015/ostler_fda/` | FDA extraction module (instant onboarding sweep – Safari, iMessage, Notes, Calendar, Photos metadata, Reminders, Apple Mail, Google Takeout). `install.sh` Phase 3.7 imports `ostler_fda.extract_all.run_all`. |

(`ostler_security/` is vendored on a sibling branch; see PR #115. The
two land independently.)

## What is deliberately out

For each vendored package the following are excluded:

- `tests/` – not customer-facing, would double the bundle size
- `fixtures/`, `fixtures_private/` – may contain real-person data;
  Rule zero of `PRODUCTISATION_CHECKLIST.md`
- `__pycache__/`, `*.pyc`, `*.egg-info/`, `build/`, `.pytest_cache/`
- `.DS_Store` – macOS Finder noise
- `xattrs` on copied files – `xcodebuild` `postBuildScript` runs
  `xattr -cr` recursively so `codesign` does not choke on FinderInfo
  / provenance / macl xattrs

## Sync recipe

Until a `make vendor-sync` target lands (post-launch), the manual
sync recipe is:

```bash
# From the CM051 repo root, with HR015 checked out as a sibling.
SRC="../HR015 - Gaming PC/ostler_fda"
DEST="vendor/ostler_fda"
rm -rf "$DEST"
mkdir -p "$DEST"
for f in "$SRC"/*.py "$SRC"/README.md; do
    cp "$f" "$DEST/$(basename "$f")"
done
```

Then `xcodegen generate` + `xcodebuild` and verify
`Contents/Resources/ostler_fda/` lands in the built `.app`.

## Why vendor (not pip install at install time)

1. **Offline install.** Customer Macs without a working `pip` toolchain
   (corporate locked-down, no Xcode CLT, intermittent network) still
   get a complete install. Pip-fetching from a developer's HR015
   working tree only works on the developer's machine.
2. **Reproducible signing.** The signed `.app` artefact is a fixed
   payload; vendoring lets us pin every Python file that ships and
   makes `codesign` deterministic.
3. **Audit trail.** Every byte that lands on a customer Mac is in this
   repo. Lester's audit can diff `vendor/` vs HR015's source-of-truth
   without chasing a `requirements.txt` to PyPI.

## Productisation rule

If you add or modify code in HR015 that the customer-install path
needs, vendor it here before the next signed build. The
`postBuildScript` hard-fails if the vendor dir is missing, so a
forgotten sync surfaces at build time, not at the customer's first
install.
