# Design note: hardware-cap fail-open on network failure

Status: OPEN product decision. NOT changed by the licence-gate bypass fix
(branch `fix/licence-gate-bypasses`). Written up here so it is not lost.

## What the monetisation audit flagged

`InstallerCoordinator.runDeviceRegistration(claims:)` registers this Mac's
hardware fingerprint with the CM050 appcast Worker to enforce the
per-licence `max_hardware_fingerprints` cap (typically 3 Macs). On a
`.networkFailure` result (transport error or 5xx) the installer
**fails open**: it logs a warning, writes a pending fingerprint via
`FingerprintState.writePending`, and lets the install proceed. The
Hub-side scheduler (`deferred-register-device.sh`) is expected to close
the loop later.

Consequence: a customer who runs the installer with the Worker
unreachable (or who blocks `appcast.ostler.ai` at the network layer) is
never counted against the device cap at install time. Repeated offline
installs can exceed the licensed Mac count until/unless the deferred
registration ever succeeds.

## Why we did NOT simply fail closed

Naively failing closed would refuse the install whenever the Worker is
briefly down or the Mac is genuinely offline (airplane mode, captive
portal, flaky hotel wifi, corporate egress filtering). That breaks
**legitimate** installs for a paying customer to prevent a
comparatively low-value abuse (sharing one licence across a handful of
extra Macs). At install time that trade is bad: a hard refusal when our
server is unreachable is a worse customer outcome than the licence
sharing it would prevent. This matches the fail-open policy already
documented in `runDeviceRegistration`'s header comment.

So this is a genuine product decision, not a clear-cut bug like the two
bypasses fixed on this branch. It needs Andy's call before any code
change.

## Options to weigh (for the product decision)

1. **Grace window.** Fail open now, but bound it: the deferred
   registration must succeed within N days or the Hub degrades
   (e.g. auto-update gated, or a persistent "confirm your licence"
   nag). Turns an unbounded hole into a bounded one without ever
   blocking an offline install.

2. **Deferred registration with teeth.** Keep the install proceeding,
   but have the Hub-side scheduler treat a persistently-failing
   registration as a real state (surface it in Doctor, retry with
   backoff, escalate) rather than best-effort-and-forget. Pair with (1).

3. **Signed offline attestation.** At install time, when the Worker is
   unreachable, record a signed local record of (licence_id,
   fingerprint, timestamp). On the next successful contact the Worker
   reconciles the backlog and can detect over-provisioning after the
   fact. Preserves offline installs; makes abuse detectable, not
   preventable, at install time.

4. **Leave as-is (accept the risk).** Document that the cap is
   best-effort under network failure and that reconciliation is
   eventual. Cheapest; leaves the audit finding open by choice.

## Recommendation (for discussion, not a decision)

Option 1 + 2 together: keep the install fail-open (never block an
offline customer), but make the deferred registration a first-class,
bounded, observable state with a grace window, so the cap becomes
eventually-enforced rather than silently skippable. Cryptographic
offline attestation (option 3) is the strongest but is more work and
touches CM050 Worker + Hub scheduler as well as the installer.

Relevant code:
- `gui/OstlerInstaller/InstallerCoordinator.swift` -> `runDeviceRegistration`
  (the `.networkFailure` case, fail-open branch).
- `gui/OstlerInstaller/Auth/DeviceRegistration.swift` (maps transport /
  5xx to `.networkFailure`).
- `gui/OstlerInstaller/Auth/FingerprintState.swift` (pending-write for
  deferred retry).
- Hub-side `deferred-register-device.sh` (the retry leg).
