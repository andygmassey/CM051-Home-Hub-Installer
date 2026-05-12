# OstlerInstaller (Mac GUI)

SwiftUI wrapper around the CM051 Hub installer. Ships as a notarised DMG.

## One-shot release

```bash
cd gui
export NOTARY_PROFILE=ostler-installer   # your notarytool keychain alias
make ship
```

Output: `/tmp/ostler-installer-dist-<user>/OstlerInstaller-<version>.dmg` – Developer ID signed, notarised, stapled.

> Build artefacts default to `/tmp/ostler-installer-build-<user>` and `/tmp/ostler-installer-dist-<user>` so they sit OUTSIDE the iCloud-synced `~/Documents/Projects/` tree. This avoids a race where iCloud's FileProvider asynchronously tags freshly-built files with `com.apple.FinderInfo` xattrs AFTER the in-build "Strip xattrs" phase runs, causing codesign to fail with `resource fork, Finder information, or similar detritus not allowed`. Override at make-time if you want the old in-tree behaviour: `make BUILD_DIR=build DIST_DIR=dist ship`.

## Step-by-step

```bash
make release    # archive + Developer ID export → $(DIST_DIR)/OstlerInstaller.app
make package    # signed DMG  → $(DIST_DIR)/OstlerInstaller-<version>.dmg
make notarise   # submit to Apple, wait, staple, verify with spctl
```

## Other targets

- `make debug`   – Debug build, opens the .app from DerivedData
- `make staple`  – Re-staple a previously-notarised DMG
- `make clean`   – Wipe `$(BUILD_DIR)` and `$(DIST_DIR)`
- `make regen`   – Regenerate `.xcodeproj` from `project.yml` (needs `xcodegen`)
- `make print-version` – Print the current version string from `Info.plist`

## One-time setup

1. Install full Xcode (not just CLT) and the **Developer ID Application: Creative Machines Limited (V95N2B8X7A)** cert in the login keychain.
2. Store notary credentials once:
   ```bash
   xcrun notarytool store-credentials ostler-installer \
       --apple-id <your-apple-id> --team-id V95N2B8X7A
   ```

If `make notarise` fails, the submission ID is printed; diagnose with `xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE`.
