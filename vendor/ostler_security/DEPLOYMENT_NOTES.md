# Ostler Security – Deployment Notes

Things the production install / packaging pipeline needs to get right
for Ostler's passkey-primary auth to function. These are not code
correctness issues inside `ostler_security/`; they are packaging
requirements that surface only when the real Swift helper binary
runs against Apple's framework machinery on a real Mac.

## Swift helper binary – code-signing is load-bearing

The Swift helper at `ostler_security/bin/lifeline-passkey-helper`
MUST be:

- **Code-signed with the Creative Machines Developer ID certificate.**
  Ad-hoc signed (`codesign --sign -`) binaries are silently refused
  by Apple's `AuthenticationServices` – no Touch ID prompt appears,
  no error is returned to the helper, the call just never completes.
  This was diagnosed on Andy's hardware 2026-04-23 during the Day 2
  smoke test.
- **Bundled alongside a valid `Info.plist`.** Minimum keys:
  `CFBundleIdentifier` (matching the Developer ID team prefix),
  `CFBundleName`, `CFBundlePackageType = "APPL"` for the CLI, plus
  a `LSMinimumSystemVersion = "15.0"` matching the runtime gate.
- **Signed with an entitlements file** including
  `com.apple.developer.associated-domains = ["webcredentials:creativemachines.ai"]`
  so the OS treats calls to `ASAuthorizationPlatformPublicKeyCredentialProvider`
  with `rp_id = "creativemachines.ai"` as trusted.
- **Accompanied by an AASA (Apple App Site Association) file served
  at `https://creativemachines.ai/.well-known/apple-app-site-association`**
  with `Content-Type: application/json` and a `webcredentials` entry
  pointing to the helper's bundle ID. Without this, the cross-device
  sync of the passkey via iCloud Keychain cannot map back to the
  helper on a new device.

### What works today without full signing

Ad-hoc signed dev builds CAN invoke the `keychain_*` ops –
`keychain_exists` was smoke-tested against the real macOS Keychain on
2026-04-23 and returned the expected `{ok: true, exists: false}`
response via `Security.framework`. That path does not involve
`AuthenticationServices`, so the entitlements gate does not apply.

### What does NOT work without full signing

The `register` and `assert` ops (the passkey path) silently fail –
no Touch ID prompt, no error return – on ad-hoc signed binaries.
Real end-to-end validation of the passkey register/assert path is
gated on the production packaging pipeline being in place.

### Ownership

Production install / signing / AASA hosting lives with Phase 4
packaging (or whichever installer workstream picks up distribution
plumbing). `ostler_security/` is correct at the code level; the
remaining work is entirely packaging.

Until Phase 4 ships:
- CI tests cover the Python side via the mock helper at
  `tests/fakes/mock_passkey_helper.py` (see `test_passkey.py` etc.).
- Keychain-only ops can be smoke-tested against a real machine with
  an ad-hoc signed helper.
- Full register/assert cannot be manually smoke-tested until the
  signed build lands – which is fine because the cross-impl test
  vectors in `SHARED_AUTH_SPEC.md` §1.4 / §4.4 are computed at the
  Python layer and do not require a real passkey to produce.

## macOS version requirement

- `ostler_security/bin/src/Package.swift` targets `macOS(.v15)`.
- `webauthn_client.py`'s `ERROR_OS_TOO_OLD` is the user-facing surface
  if a pre-15 Mac invokes the helper.
- The `setup_wizard` refuses to begin on a pre-15 Mac with a clear
  error – no silent fallback to passphrase-only auth, since the spec
  (SHARED_AUTH_SPEC.md §0) bans non-PRF fallback.

## Service-to-service auth env vars (#200)

Two environment variables are load-bearing for the v1.1 localhost
service-token mechanism described in `SECURITY_MODEL.md` §4.

### `JWT_SECRET`

HS256 signing secret. Must be the same value in **every** Ostler
service process on the Hub – the gateway (`services/gateway`), the
wiki compiler, the conversation publisher, the contact syncer, the
meeting syncer, the identity resolver, the history loader. Different
values across processes mean publishers mint tokens the gateway
cannot verify; you get 401 on every call.

- **Generated:** by the installer at first run. Random 32+ bytes,
  base64-encoded.
- **Stored:** in the user's Keychain. Exported to the env at
  launchd-startup of each service process. Never written to disk
  outside Keychain.
- **Rotated:** by rewriting the Keychain entry and restarting the
  services. There is no "accept either of two secrets" window – the
  publishers re-mint within their 5-minute auto-refresh cadence, so
  full rotation completes inside a 5-minute downtime envelope. Brief
  downtime is the v1.1 choice; multi-secret support is deferred.

### `PWG_GATEWAY_URL`

When set, every publisher routes its inner-store calls through this
URL with a Bearer token. When empty, publishers fall back to direct
calls (legacy path, dev only).

- **Customer installs:** always set to `http://localhost:8000` by
  the installer. The auth boundary is active by default.
- **Dev / tests:** leave empty to skip the gateway and call the
  inner stores directly. Tests that need to exercise the gateway
  path set the env var explicitly per-test.

Don't log either value. Don't echo them in error messages. Don't
include them in support-bundle exports.

## Gateway audit log

`SECURITY_MODEL.md` §4 names a gateway audit log as the forensic
half of the §4 mitigation: if an Ostler process is compromised and
mints tokens, the audit log is what tells the operator (or an
auditor) which service identity made which calls.

### Destination

The gateway emits audit lines through a dedicated `pwg.audit`
logger (Python `logging`). Default destination is the gateway's
existing stderr stream (`logging.basicConfig` in
`services/gateway/src/main.py`). Operators who want a dedicated
file destination can attach a `FileHandler` to `pwg.audit` via
the standard logging config – for example, a `logging.conf`
file picked up by `logging.config.fileConfig` at gateway startup,
or a programmatic `logging.getLogger("pwg.audit").addHandler(...)`
at the top of `main.py`.

Tail the audit stream:

```
journalctl -u ostler-gateway | grep "pwg.audit"
# or, if you've configured a FileHandler:
tail -f /var/log/ostler/gateway-audit.log
```

### Fields

Each audit line carries exactly four structured fields. They are
inlined into the log message string (so they survive any Formatter,
including the default `basicConfig` `%(message)s`) AND attached via
the standard logging `extra=` kwarg (so a structured-JSON Formatter
like `python-json-logger` on a forwarding handler can pick them up
structurally). No special Formatter configuration is required.

| Field | Source | Notes |
|---|---|---|
| `sub` | JWT `sub` claim | Service identity (e.g. `service-conversations`, `service-cli`, or a CM031 device-id for Companion tokens). Control chars are sanitised; field is capped at 200 chars. |
| `method` | HTTP method | `GET` / `POST` / `PUT` / etc. |
| `path` | Request URL path | E.g. `/sparql/query`, `/qdrant/collections/preferences/points/search`. |
| `compartment_level` | JWT `compartment_level` claim | 0-4. Trusted band is L0-L2. |

Rendered output (default `basicConfig` Formatter) looks like:

```
2026-05-19 12:00:00 - pwg.audit - INFO - audit sub=service-conversations method=POST path=/sparql/query compartment_level=4
```

### What is NOT in the audit log

The audit log is itself a potential L3 surface. It is read by
operators, may be shipped to a central log aggregator, and is
retained for forensics. The following MUST NOT pass through the
audit logger:

- **Query bodies.** A SPARQL UPDATE body or a Qdrant POST body is
  exactly the data the gateway is trying to protect. Logging it
  would defeat the §4 mitigation.
- **Bearer values.** Even partial bearer values (first / last N
  chars) leak entropy and are not required for forensic
  attribution – the `sub` field is the durable identity.
- **`JWT_SECRET`.** Never appears anywhere in any log surface.
- **Header dumps.** The full request header set may include the
  bearer; only emit the fields named above.

### Retention guidance

There is no automatic rotation today. For v1.0 the operator should:

- Default destination (stderr to journald / launchd's log): trust
  the OS log rotation. `journalctl --vacuum-time=30d` etc. is fine
  for v1.

- File destination (operator-configured `FileHandler`): use
  `logging.handlers.RotatingFileHandler` or `TimedRotatingFileHandler`.
  Suggested defaults: rotate daily, keep 30 days, total cap ~1 GB.

Once a central log shipper is in place (post-launch), the audit
stream should be redirected there with the standard "do not log
bodies / bearers" rules applied at the shipper-side filter.

### Test coverage

`services/gateway/tests/test_audit_log.py` covers:

- Audit emission on every gated SPARQL + Qdrant route.
- Negative coverage: bearer values and query bodies do NOT appear
  in any audit field or message.
- 401-before-audit: an unauthenticated request never reaches the
  audit-emit call (the `require_auth` dependency raises first).

If you add a new gated route to the gateway, the v1.0 contract is:
emit one `_emit_audit(auth, request)` line at the top of the
handler, after `Depends(require_auth)` resolves, using the helper
already defined in `services/gateway/src/routes/sparql.py` (or the
mirror in `qdrant.py`). Add a test that asserts the line lands
with the four canonical fields.

## Keychain access controls

Every item the helper writes gets:

- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` – only readable when
  the Mac is unlocked; does NOT travel in Time Machine backups or
  migrate to a new Mac via Migration Assistant.
- `kSecAttrSynchronizable = false` – does NOT sync via iCloud
  Keychain.

These attributes are load-bearing for the threat model (the wrapped
DEK is device-scoped even though the passkey itself is cross-device).
They cannot be set via the `/usr/bin/security` CLI – this is the
reason Ostler routes Keychain writes through the Swift helper.

## BIP39 wordlist integrity

`ostler_security/bip39_english.txt` must ship with the Python
package and must hash to

    2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda

(SHA-256). `key_derivation.bip39_wordlist_sha256()` computes this at
runtime and a test asserts the expected value. If the package build
accidentally strips a trailing newline, re-encodes the file, or
substitutes a locale-variant wordlist, the cross-implementation
test vectors with iOS will diverge. The iOS Companion must ship the
same 2048-word file with the same SHA-256.

## Handle file location

The public `passkey.json` handle file lives at
`$HOME/.lifeline/security/passkey.json` by default. Overridable via
`OSTLER_PASSKEY_HANDLE_FILE` env var (tests use this). The file
contains `credential_id`, `user_handle`, and `rp_id` – none of which
are secret. Secrecy is entirely in the Keychain-stored wrapped DEK.
The handle file can be backed up freely; the wrapped DEK cannot leave
the device.
