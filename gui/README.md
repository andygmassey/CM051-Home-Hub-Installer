# OstlerInstaller (Mac GUI)

SwiftUI wrapper around the CM051 Hub installer. Ships as a notarised DMG.

## One-shot release

```bash
cd gui
export NOTARY_PROFILE=ostler-installer   # your notarytool keychain alias
make ship
```

Output: `gui/dist/OstlerInstaller-<version>.dmg` – Developer ID signed, notarised, stapled.

## Step-by-step

```bash
make release    # archive + Developer ID export → dist/OstlerInstaller.app
make package    # signed DMG  → dist/OstlerInstaller-<version>.dmg
make notarise   # submit to Apple, wait, staple, verify with spctl
```

## Other targets

- `make debug`   – Debug build, opens the .app from DerivedData
- `make staple`  – Re-staple a previously-notarised DMG
- `make clean`   – Wipe `build/` and `dist/`
- `make regen`   – Regenerate `.xcodeproj` from `project.yml` (needs `xcodegen`)

## One-time setup

1. Install full Xcode (not just CLT) and the **Developer ID Application: Creative Machines Limited (V95N2B8X7A)** cert in the login keychain.
2. Store notary credentials once:
   ```bash
   xcrun notarytool store-credentials ostler-installer \
       --apple-id <your-apple-id> --team-id V95N2B8X7A
   ```

If `make notarise` fails, the submission ID is printed; diagnose with `xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE`.
