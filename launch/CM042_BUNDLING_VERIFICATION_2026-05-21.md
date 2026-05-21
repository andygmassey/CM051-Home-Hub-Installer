---
title: CM042 RemoteCapture bundling verification – task #249
date: 2026-05-21
status: PASS-WITH-CAVEAT
tracker: task #249
dmg: /tmp/ostler-installer-dist-andy/OstlerInstaller-1.0.0.dmg
---

# CM042 RemoteCapture bundling verification

## Verdict: PASS-WITH-CAVEAT

The DMG ships **no RemoteCapture binary** in `Contents/Resources/`. This is correct as designed: install.sh Phase 3.14f downloads RemoteCapture from a GitHub release at install time, then code-signs + LaunchAgent-bootstraps it on the customer Mac.

**Caveat:** the install flow is gated on the existence of a real release tag at `ostler-ai/ostler-remote-capture` v1.0.0. The default `OSTLER_REMOTECAPTURE_VERSION=1.0.0` is documented in install.sh:5969 as a "placeholder; Andy bumps this when the first real release tag is cut". If that release tag does not exist by launch, RemoteCapture install fails warn-only and customers get a working Ostler minus the menubar transcription app.

## What was verified

1. **DMG inspection.** `find "/Volumes/Install Ostler/" -name "RemoteCapture*"` returned zero matches. No bundled `.app`, no bundled tarball, no bundled installer payload. This matches the F20 Phase E "download-at-install" approach.

2. **install.sh Phase 3.14f exists and is complete.** Lines 5968-6050+ (commit `881e76a` "Ostler RemoteCapture .app install + LaunchAgent") cover the eight-step install path:
   - TCC pre-prompt (customer-rendered, Rule 0.9 catalogue strings)
   - Resolve release URL + SHA-256 sidecar
   - Download both into temp dir
   - SHA-256 verify (hard fail on mismatch)
   - Extract tarball into /Applications
   - `codesign --verify --deep --strict` + `spctl --assess --type execute`
   - Clear `com.apple.quarantine`
   - Render + bootstrap `~/Library/LaunchAgents/com.creativemachines.ostler-remotecapture.plist`

3. **Apple Silicon gating.** Phase 3.14f detects `uname -m` and warn-skips on Intel (Phase C release workflow only builds arm64 — correct).

4. **Uninstall hooks.** install.sh:5010-5035 cover the symmetric removal path (`launchctl bootout`, plist delete, `/Applications/Ostler RemoteCapture.app` removal). Mirror of the install path. Clean.

5. **Env-overridable** `OSTLER_REMOTECAPTURE_VERSION` + `OSTLER_REMOTECAPTURE_REPO` for beta cuts or forks. Productisation rule respected.

## Outstanding pre-launch action for Andy

**Confirm the `ostler-ai/ostler-remote-capture` v1.0.0 release tag exists at github.com.** Without it, the install warn-skips. To check from a non-auth shell:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  "https://github.com/ostler-ai/ostler-remote-capture/releases/tag/v1.0.0"
```

Expect `200`. Anything else (404 / 302 to /releases / etc.) means the release tag has not been cut yet — bump it before the next DMG cut, or accept the warn-skip on first install.

## Premise drift vs the brief

Brief said: *"Confirm RemoteCapture.app or its installer payload is present in Contents/Resources/ (or wherever F20 Phase E parked it)."*

Reality: F20 Phase E parked it **nowhere on disk** — it's downloaded at install time, code-signed, and unpacked into /Applications. The brief's "wherever F20 Phase E parked it" implies a bundled artefact; in fact the parking is a release URL plus SHA-256 sidecar at install time. Functionally equivalent (the customer ends up with a code-signed `.app` on their Mac); architecturally different (network-required at install rather than offline-bundle).

## Next steps

- Close task #249 in the HR015 tracker (the wiring is complete; the release-tag-exists-on-GitHub check is downstream).
- Add the `curl` check above to a launch-readiness smoke script if not already covered.
