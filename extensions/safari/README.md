# Ostler Safari extension -- pre-launch placeholder

The Safari Web Extension that captures browsing context for the Ostler
hub lives as a Swift / Xcode project in the upstream
`safari-history-extension` repo. Building it requires Xcode, a
Developer ID team, and code signing -- too much setup for an
installer step.

For v0.1, the installer:

- bundles + sideloads the Chrome extension (it ships as unpacked
  source and Chrome can load it directly in Developer Mode).
- offers Safari but does NOT auto-install it. The customer either
  (a) waits for the v0.2 launch, when a pre-built notarised app
  ships via GitHub Releases the same way `ostler-assistant` does,
  or (b) clones the upstream repo and builds it themselves.

This file is a placeholder so the bundled-source-fallback path in
`install.sh:Phase 3.x` finds something at `${SCRIPT_DIR}/extensions/safari/`
and surfaces a clear "Safari coming in v0.2" message rather than a
silent skip.

## Manual build (advanced users only)

If you want the Safari extension running today, clone the upstream
repo and build it from Xcode:

```sh
git clone https://github.com/andygmassey/safari-history-extension.git
cd safari-history-extension/Xcode/SafariHistoryExtMultiplatform
open SafariHistoryExt.xcodeproj
# Select the macOS target, set your team in Signing & Capabilities,
# build + run, then enable in Safari Settings > Extensions.
```

The Chrome extension that ships in `extensions/chrome/` covers the
same backend ingest endpoint, so you can sideload Chrome today and
get parity for browsing-context capture across both browsers when
Safari ships.
