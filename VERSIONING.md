# Versioning the OstlerInstaller.app (CM051 #171)

This doc covers the **installer GUI app** version — the `CFBundleShortVersionString`
that the DMG's `OstlerInstaller.app` stamps. This is a **separate** concern from
the `install.tar.gz` release recipe (see `RELEASE.md`); the GUI app is built and
notarised on its own via `gui/Makefile`.

## The bug this codifies (#171)

The v1.0.11 **and** v1.0.12 DMGs shipped `OstlerInstaller.app` stamped
`CFBundleShortVersionString = 1.0.10`. The value was **hardcoded** and never
bumped, because `gui/Makefile` **derives** the app version + DMG name by *reading*
`gui/OstlerInstaller/Info.plist` (`gui/Makefile` `VERSION := $(shell PlistBuddy …)`)
rather than from the cut tag. Studio, support, and Sparkle all read that string,
so a stale stamp is genuine version confusion. The cut mechanism
(`HR015/scripts/cut_ostler_dmg.sh`) only forwards a `VERSION` to `make -C gui … ship`
when `--version` is passed, and even then `$(VERSION)` only names the DMG file —
it never flows into the app's embedded version. So the app version comes purely
from the checked-in source below.

## Where the installer app version lives (three tracked sources of truth)

A bump must touch **all three**, and they must agree:

| File | Field(s) | Notes |
|---|---|---|
| `gui/project.yml` | `settings.base.MARKETING_VERSION`, `settings.base.CURRENT_PROJECT_VERSION`, `targets…info.properties.CFBundleShortVersionString`, `…CFBundleVersion` | The xcodegen source |
| `gui/OstlerInstaller/Info.plist` | `CFBundleShortVersionString`, `CFBundleVersion` | What the built `.app` actually stamps (the literal, not `$(MARKETING_VERSION)`) — `xcodegen generate` does **not** overwrite this file, so it must be edited by hand |
| `gui/OstlerInstaller.xcodeproj/project.pbxproj` | `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` (Debug + Release) | Generated from `project.yml` by `xcodegen generate` — regenerate, don't hand-edit |

- **Short/marketing version** (e.g. `1.0.13`): `CFBundleShortVersionString` + `MARKETING_VERSION`.
- **Build number** (e.g. `13`): `CFBundleVersion` + `CURRENT_PROJECT_VERSION`.

## Bump checklist (the residual manual step)

Version derivation from the cut tag is **not yet wired** (see proposals below), so
bumping the installer app is still a deliberate manual step:

1. Edit `gui/project.yml`: set `MARKETING_VERSION` + `CFBundleShortVersionString`
   to the new marketing version, and `CURRENT_PROJECT_VERSION` + `CFBundleVersion`
   to the new build number.
2. Edit `gui/OstlerInstaller/Info.plist`: set `CFBundleShortVersionString` +
   `CFBundleVersion` to match.
3. `cd gui && xcodegen generate` — refreshes the tracked `project.pbxproj`.
4. Commit **all three** files together (`project.yml`, `Info.plist`, `project.pbxproj`).
5. Verify: `bash tests/test_installer_version_consistency.sh` (or `cd gui && make check-version`).

## The gate that now enforces this

`tests/test_installer_version_consistency.sh` asserts the short/marketing version
**and** the build number are identical across the three files above. It fails
closed on a **half-bump** — e.g. `project.yml` edited but `xcodegen generate` not
re-run so `project.pbxproj` lags, or `Info.plist` forgotten. Wiring:

- **Local cut:** `gui/Makefile` `check-version` target runs it, and it is a
  fail-closed prerequisite of both `release` and `package` (which `ship` depends
  on), so a drifted source tree aborts the cut before signing.
- **CI:** `.github/workflows/installer-version-consistency.yml` runs it on any PR
  touching the three version files (portable — stdlib `plistlib` + `grep`, no
  PlistBuddy, so it works on `ubuntu-latest`).

### What this gate does NOT catch (known residual)

The source-consistency gate proves the three files **agree with each other**. It
does **not** derive the version from the cut tag, so it cannot catch a
"nobody bumped anything" cut where all three are *consistently* stale versus the
release version — which is the **literal #171 shape** (source was internally
consistent at `1.0.10` while the cut shipped as v1.0.12). Two proposals close
that remaining gap at the built-artefact boundary; both are noted for ORM/TNM
because they touch cut-owned surfaces:

#### Proposal A (recommended, low-risk) — cut-manifest version gate on the built app

The cut-manifest gate (`gui/Makefile` `check-manifest`, already a `ship`
prerequisite; `scripts/verify_cut_manifest.py`) already ships a `plist_key_equals`
proof kind that reads a key from the **built** `OstlerInstaller.app`. Adding one
entry per cut asserts the shipped app stamps *this cut's* version, catching the
no-bump shape fail-closed right before `codesign`. Because per-cut manifests are
owned by ORM (they are created/retired per cut — see `cut-manifests/README.md`),
this should be added when the `cut-manifests/v<version>.yaml` for the cut is
created, so it does not reduce that cut's existing gate coverage. Concrete entry
for **v1.0.13** (`target: installer-app` resolves to the built `.app`;
`plist_key_equals` is already a registered kind in `verify_cut_manifest.py` and in
`.github/workflows/cut-manifest.yml`):

```yaml
- id: installer-app-version-stamp
  title: OstlerInstaller.app stamps the cut's marketing version (not a stale 1.0.10)
  incident: "#171 -- v1.0.11/v1.0.12 DMGs shipped CFBundleShortVersionString=1.0.10 (never bumped)"
  source_pr: ostler-ai/ostler-installer#171
  proof:
    kind: plist_key_equals
    target: installer-app
    path: Contents/Info.plist
    key: CFBundleShortVersionString
    value: "1.0.13"          # bump to the cut's marketing version each cut
```

#### Proposal B (airtight, larger change) — derive the app version from the cut tag

Make the cut tag the single source of truth so the manual bump disappears:

1. **`gui/Makefile`:** change `VERSION := …` to `VERSION ?= $(shell PlistBuddy …)`
   (command-line `VERSION=` already overrides it) **and** add a stamping step in
   the `release` target that sets the built app's `Contents/Info.plist`
   `CFBundleShortVersionString` (and `CFBundleVersion`) from `$(VERSION)` via
   `PlistBuddy -c "Set …"`, so the passed cut version wins over the checked-in
   literal.
2. **`HR015/scripts/cut_ostler_dmg.sh` + `HR015/scripts/release_pipeline.sh`:**
   always pass the tag-derived `--version` / forward `VERSION` to
   `make -C gui … ship` (today `cut_ostler_dmg.sh` only forwards it when
   `--version` is supplied, and `release_pipeline.sh` does not forward its
   `VERSION` at all).

This is a build + cross-repo (HR015) change and was deliberately **not** made as
part of #171 to avoid a blind build/cut refactor; it is the eventual fix that
makes the manual bump checklist above obsolete.

## Recovering from a `pinned_artefact_freshness` fail

CM051 downloads pre-built artefacts at cut time (the daemon tarball via
`DAEMON_VERSION`, the RemoteCapture app via `OSTLER_REMOTECAPTURE_VERSION`).
If a source-repo fix merged after the pinned tag was cut, that fix cannot ride
in the DMG. The v1.0.13 near-miss (2026-07-30): `DAEMON_VERSION = 0.4.39`
resolved to `hub-v0.4.39` tagged at oa/main `16687ed6`; five subsequent
`crates/*` commits including task #148 (`has_ever_paid` sticky bit, launch
blocker) never reached the pinned tarball. The cut manifest's
`pinned_artefact_freshness` primitive (see `cut-manifests/README.md` #10) now
catches this class of failure before signing. When it fails you'll see:

```
FAIL  permanent-daemon-freshness  pinned daemon tarball must contain all merged crates/* changes on oa/main
        pinned daemon (ostler-assistant) v0.4.39 (@16687ed6) is stale vs main HEAD (a2d2d23f); N diverging commit(s) touch ['crates/**']:
            9528520a feat(subscription): has_ever_paid sticky bit  [crates/**]
            a2d2d23f build(release): hub-vX.Y.Z tag push wiring    [crates/**]
        Recovery: cut a new release from source HEAD; bump the pin in gui/Makefile; rebuild.
```

The runbook:

1. Confirm the source repo (from the entry's `source_repo`) is at the SHA the
   gate reports. If `oa/main` genuinely has landing-ready work you want in the
   cut, proceed. Otherwise, revert or park the commits before re-running.
2. Cut a new source-repo release from the current default-branch HEAD. For
   `ostler-ai/ostler-assistant`, that is `bash scripts/tag_release.sh
   hub-v<new-version>` in the daemon repo (or the workflow equivalent),
   which publishes the tarball + `.sha256` sidecar.
3. Wait for the release workflow to finish and the tarball URL to become
   fetchable (curl-probe the `.tar.gz` URL returning 200).
4. In CM051, bump the pin file:
   - Daemon: edit `gui/Makefile`, set `DAEMON_VERSION` to the new version and
     `DAEMON_SHA256` to the value from the new `.sha256` sidecar. Then run
     `make -C gui download-daemon` to prove the cached tarball SHA matches.
   - RemoteCapture: edit `install.sh`, set the `OSTLER_REMOTECAPTURE_VERSION`
     default to the new version.
5. Commit the pin bump on the cut branch and re-run
   `./scripts/verify_cut_manifest.sh` to confirm the gate goes green.
6. Resume the cut (`make -C gui ship`).

The gate needs `gh` API access to the source repo, resolved via
`GH_TOKEN=$(gh auth token --user <owner>)` where `<owner>` is the slug before
the `/` in `source_repo`. If it reports "could not resolve gh token for owner
'ostler-ai'", run `gh auth login --user ostler-ai` and retry.
