---
title: WSA-003 verification – Sparkle SUFeedURL + SUPublicEDKey in shipping DMG
date: 2026-05-21
status: PASS
tracker: task #405
dmg: /tmp/ostler-installer-dist-andy/OstlerInstaller-1.0.0.dmg
---

# WSA-003 verification – Sparkle keys in shipping DMG

## Verdict: PASS

Both Sparkle keys are present, correctly typed, and match the production keystore.

## Method

1. Mounted today's canonical DMG at `/tmp/ostler-installer-dist-andy/OstlerInstaller-1.0.0.dmg`.
2. Extracted `Info.plist` from the embedded Ostler.app at the path:
   `/Volumes/Install Ostler/OstlerInstaller.app/Contents/Resources/Ostler.app/Contents/Info.plist`
3. Read Sparkle keys via `PlistBuddy`:
   ```
   SUAutomaticallyUpdate = false
   SUFeedURL = https://appcast.ostler.ai/appcast.xml
   SUPublicEDKey = kfOIhVR6EIUEuTbmDFe9QghitBBGdhCz5d4LvXLmtdQ=
   ```
4. Compared SUPublicEDKey against the production public key in HR015 keystore:
   `HR015 - Gaming PC/launch/keys/hub_signing_public_2026-05-16.pem`
   ```
   -----BEGIN PUBLIC KEY-----
   MCowBQYDK2VwAyEAkfOIhVR6EIUEuTbmDFe9QghitBBGdhCz5d4LvXLmtdQ=
   -----END PUBLIC KEY-----
   ```
   The 44-character base64 substring `kfOIhVR6EIUEuTbmDFe9QghitBBGdhCz5d4LvXLmtdQ=` is the raw 32-byte Ed25519 public key (the bytes following the 12-byte ASN.1 SubjectPublicKeyInfo prefix `30 2a 30 05 06 03 2b 65 70 03 21 00`). It matches the embedded SUPublicEDKey verbatim.

## Cross-check against CM050 production posture

CM050 docs (`appcast-server/docs/APPCAST_XML.md` line 96, `RELEASE_MANIFEST.md`) confirm that the Sparkle EdDSA verification key embedded in the Hub binary signs the release artefacts that flow through `appcast.ostler.ai/appcast.xml`. The keypair tracked in `hub_signing_public_2026-05-16.pem` is the active hub-signing keypair (status: ACTIVE per its sibling README; matching private key is held in the `HUB_SIGNING_PRIVATE_KEY` Cloudflare Worker secret on the `ostler-appcast` Worker).

## What was NOT verified (out of scope)

- The private-key custody chain (paper backup + encrypted USB per CM050 docs).
- The Worker's actual current `HUB_SIGNING_PRIVATE_KEY` secret value (out of scope; would require `wrangler` access).
- The notarisation status of the Ostler.app bundle (separate concern; `codesign --verify` was not run as part of this audit but is run inside install.sh Phase 3.14f for the sibling RemoteCapture.app).

## Premise drift vs the original brief

The brief suggested PR #124's `embed-sparkle.sh` may have used a placeholder dev key. It did not: the value embedded matches the active production key tracked at the `hub_signing_public_2026-05-16` path. No fix PR required.

## Next steps

- Close task #405 (WSA-003) in the HR015 tracker.
- This verification covers v1.0.0 only. Re-run the same check whenever the DMG is recut (an automated assertion in `release.sh` would make this an exit-code gate rather than a manual audit; flagged as a post-launch chore).

## Tools used (auditable)

- `hdiutil attach` to mount the DMG read-only.
- `/usr/libexec/PlistBuddy` to read Info.plist values.
- `grep` / `find` against CM050 + HR015 source trees.

No write actions. No auth prompts. No external network calls.
