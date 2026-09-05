# SECRETS THIS REPO REFERENCES

Every `secrets.NAME` used by any workflow in this repo MUST have a row here.
`tests/test_secrets_are_documented.sh` refuses a workflow that references one
without a row, so this file cannot silently fall behind the workflows.

**NO VALUES. EVER.** Names, purpose, and what breaks without them.

Wider estate context, including scopes, expiries and who else holds a value,
lives in HR015 `launch/TOKEN_INVENTORY.md`. That file is private because it
maps the whole estate; this one is public because it only names what this
public repo already reveals by referencing it.

## WHY THIS EXISTS

Measured 2026-08-20: `CM051_RELEASES_READ` was wired at four sites and reading
FROM ostler-ai releases, while its publish counterpart was never connected to
anything. The read half worked, the write half did not exist, and nothing
anywhere compared the two. The result was 37 cut tags and ZERO release
objects: every cut produced a signed, notarised artefact that no customer
could obtain, and `ostler.ai/install.dmg` returned 404 to anyone who had paid.

A register nobody is forced to update rots. Hence the gate.

---

## LIVE

### CM051_INSTALLER_PUBLISH
Publishes the cut DMG as a release object on `ostler-ai/ostler-installer`, then
re-fetches the customer URL to prove it serves. Consumed by `cut.yml` via
`scripts/publish_release.sh`.
**Without it:** the publish step HARD-FAILS by design. It does not skip. A
silent skip is how 37 tags produced zero releases with nobody told. The
artefact is already uploaded by then, so a failure here costs nothing but a
red.

### CM051_RELEASES_READ
Reads release assets from `ostler-ai`. Four call sites in `cut.yml`
(`releases-token`, `OSTLER_RELEASES_TOKEN`).
**Without it:** the cut cannot fetch the daemon or the Hub app it pins.

### OSTLER_GH_TOKEN_ANDYGMASSEY
General `andygmassey` automation.
**NOT usable for publishing to `ostler-ai`:** measured refused 2026-08-20.

### OSTLER_SIGNING_CERT_P12 / OSTLER_SIGNING_CERT_PASSWORD
Developer ID Application identity, Team V95N2B8X7A. Imported by the `cut` job.
**Without them:** no signed artefact, so no notarisation and no ship.

### VENDOR_DRIFT_TOKEN
Cross-repo `Contents: Read` on every source repo listed in `.vendor-manifests/`.
Read by `vendor-drift-check.yml` as `GH_TOKEN`, with `secrets.GITHUB_TOKEN` as
the fallback. Read-only and cross-repo ONLY; the PR-open step deliberately uses
`GITHUB_TOKEN` instead, so this value never needs write scope anywhere.
**Without it:** the default `GITHUB_TOKEN` cannot read other repos, so every
cross-repo tree records a per-tree lookup error in the drift report. The
workflow does not open a PR on error, so the failure is loud in the report
rather than a silently empty "no drift" verdict.

### OSTLER_NOTARY_ISSUER / OSTLER_NOTARY_KEY / OSTLER_NOTARY_KEY_ID
App Store Connect API credentials for `notarytool`.
**Without them:** the DMG is signed but unnotarised, and Gatekeeper refuses it
on a customer machine that has never seen it before.

---

## DELIBERATELY ABSENT

Absence of these is CORRECT and has repeatedly been mis-reported as a blocker.
Do not "fix" either by adding it.

### OSTLER_SPARKLE_SIGNING_KEY
Referenced by `cut.yml`, deliberately NOT stored. **This repo is PUBLIC** and a
Sparkle EdDSA private key does not live in one. The key is held on the
OstlerSecrets volume and appcast signing is a local post-cut act.
`PUBLISH_APPCAST=onbox` is the mechanism, and the step prints the exact
on-box command then exits 0 without failing the cut. Settled by Andy
2026-08-19.

### OPERATOR_PII_INVENTORY
Referenced by `operator-pii-scan.yml`, deliberately NOT stored: the real
inventory contains the operator's own PII. The workflow falls back to a blank
committed template and prints "It is NOT a clean result: this denylist
examined nothing", which is honest rather than a false green. PR gating is
done by `ci-pii-shape-scan`, which always runs.
