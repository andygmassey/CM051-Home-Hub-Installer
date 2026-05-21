# Ostler Security Model – Hub Side

**Scope.** macOS Hub. Passkey-primary authentication, SQLCipher
at-rest encryption, BIP39 recovery path. See CM031 for the iOS
Companion side and `SHARED_AUTH_SPEC.md` for the cross-platform
wire contract.

**Audience.** 15-minute reviewer – designed so a security consultant
or an external auditor can assess the Hub's auth story without
reading the code first. Cross-references point to the authoritative
spec + deployment docs for the detailed parts.

**Status.** Current as of 2026-04-23 (agent/passkey-auth branch).

---

## 0. 15-minute reviewer orientation

If you have a lunch hour and want to leave with a crisp sense of
the system without opening the code, read the four paragraphs
below and then jump to the section that matches your concern.

**The threat model in one paragraph.** Ostler stores the user's
plaintext data on a single Mac (the "Hub"). All at-rest data is
SQLCipher-encrypted with a 32-byte DEK. The DEK is generated
locally, never leaves the machine in plaintext, and is wrapped
twice in the macOS Keychain: once under a KEK derived from a
WebAuthn passkey's PRF output (day-to-day unlock via Touch ID),
once under a KEK derived from a 12-word BIP39 recovery phrase the
user writes on paper (last-resort recovery after device loss).
The passkey itself lives in the Secure Enclave and syncs across
the user's Apple devices via iCloud Keychain – that's how the
iOS Companion participates. Attackers with the Keychain extract
alone get no plaintext; attackers with code execution inside the
unlocked Ostler process get everything (documented to the user,
not mitigated). All crypto constants are company-namespaced
(`creativemachines/*` rather than the product name) so a future
rebrand doesn't invalidate every existing user's key material.

**The deferred items that matter most.** (1) The Swift passkey
helper binary needs Developer-ID code-signing + AASA hosting
before production deployment – ad-hoc signed dev builds
silently fail `register`/`assert` under macOS's
AuthenticationServices framework. Scoped to Phase 4 packaging.
(2) Python cannot scrub immutable `bytes` objects. We scrub
where we hold long-lived bytearrays (the AutoLock session key);
we document the gap everywhere else. See §3. (3) Cross-platform
support (Linux/Windows) is explicitly deferred; the passkey +
iCloud-Keychain stack is Apple-only by construction.

**The audit-relevant trade-offs you should know about.** We chose
HKDF not PBKDF2 for the recovery-phrase KDF because 128-bit BIP39
entropy doesn't benefit from iteration slowing. We chose AES-KW
RFC 3394 unpadded (not RFC 5649 padded) because our DEK is
already an 8-byte-multiple. We chose to return the freshly-
generated DEK out of the install wizard rather than force a
second Touch ID prompt on the user – with explicit
caller-responsibility docstrings on the return type. We chose
to have a single shared HKDF extract-salt with per-purpose
`info` strings (RFC 5869 canonical) over per-purpose salts.
None of these are novel; all are reviewer-friendly once the
reasoning is visible.

**My five open questions for you.** Pre-populated so you see them
in context, not at the end. Each cross-refs the section of this
doc that sets them up.

| # | Question | Section |
|---|---|---|
| Q1 | Is the BIP39 recovery phrase sufficiently strong as the sole fallback, or should we also support a printed Ed25519 key / smart card? | §1 (threat model "not defended" row on catastrophic loss) |
| Q2 | Python's inability to reliably scrub immutable `bytes` – is it worth a Rust extension or a shared-memory Swift↔Python path for the PRF/KEK/DEK hot paths? | §3 (scrub audit) |
| Q3 | Apple-only-forever sign-off. Cross-platform support would require dropping passkey + iCloud Keychain sync. We chose not to. Does that match your read of the product's long-term shape? | §1 ("not defended" – Apple lock-in), §6 (deferred items) |
| Q4 | Does passkey + Secure Enclave create audit-trail problems for SOC 2 (or similar)? Confidant is pursuing SOC 2; worth knowing if we'll hit the same blockers. | §1 (defended table – audit log exists, but structured differently to passphrase-based systems) |
| Q5 | What have we missed in the threat model? User-cooperative attacks, supply-chain, anything else we should be flagging explicitly rather than assuming is out of scope? | §1 ("not defended" – the explicit list, intended to surface gaps rather than hide them) |

These are the questions Andy was going to ask you at lunch.
Seeing them in this doc means you can react to paper rather
than argue with slides – pick whichever of the five you want to
drive the conversation on, or add a sixth.

---

## 1. Threat model

### What we defend against

| Threat | Defence |
|---|---|
| Device-at-rest theft without user passcode | FileVault (setup wizard checks + warns) + per-item Keychain access control (`WhenUnlockedThisDeviceOnly`) |
| Attacker with full Keychain extract, no passkey | Wrapped DEK unusable without the Secure Enclave's passkey-derived KEK |
| LAN attacker on Hub↔Companion sync | Tailscale (or LAN+TLS) with pinned self-signed cert (`SHARED_AUTH_SPEC.md` §3.6) |
| Time-Machine backup theft | Wrapped DEK has `AccessibleWhenUnlockedThisDeviceOnly` – doesn't travel in backups. Only the recovery-wrapped DEK does, and it's protected by the BIP39 phrase which the user keeps on paper. |
| Product rebrand invalidating existing user data | Every HKDF salt / info string and the WebAuthn PRF input uses the `creativemachines/` company namespace, not `lifeline/`. See `SHARED_AUTH_SPEC.md` Appendix B. |
| Wrong-passkey DEK theft (e.g. Keychain item swap) | AES-KW (RFC 3394) integrity check detects wrong-KEK unwrap as `InvalidUnwrap` rather than returning garbage plaintext |
| BIP39 typo on recovery | Checksum validation + visible phrase entry (typos catchable before submit) |
| Timing side-channel on rate-limiter token comparison | `secrets.compare_digest` with dummy-fallback path; see `rate_limiter.py` |

### What we do NOT defend against

| Threat | Why |
|---|---|
| User-cooperative attacks (coercion, phishing-induced pair) | Out of scope for v1 – requires user education, not code. Lester Q1 (2026-04-27 lunch). |
| Malware with code execution inside the unlocked Ostler process | Reads the DEK from memory after we unwrap it. No defence feasible in a userspace process. Documented to the user. |
| Simultaneous loss of Hub + Companion + no Time Machine + no recovery phrase | Terminal data loss by design. Recovery phrase is the last-resort key; if it's gone too, nothing can recover. |
| Apple platform supply-chain compromise | Secure Enclave, AuthenticationServices framework, Keychain Services are all Apple trust roots. Out of v1 scope. |
| Timing / cache side-channels on the key-derivation path | We use the `cryptography` library; timing-side-channel resistance on its HKDF/AES-KW paths is the library's contract, not ours. |
| Cold-boot / RAM-imaging attacks | Python bytes objects persist until GC. See §3 for the scrub audit. |
| Apple-ecosystem lock-in | Deliberate – Lester Q3 topic. Cross-platform support would require dropping passkey-PRF + iCloud Keychain sync; we chose not to. |

### What about `cryptography` library bugs?

The Hub relies on `cryptography.hazmat.primitives.kdf.hkdf.HKDF` and
`cryptography.hazmat.primitives.keywrap.aes_key_{wrap,unwrap}`. These
are the canonical PyCA implementations vetted at the Python ecosystem
level. A remotely-exploitable bug in either is below the v1 threat
model's floor. A memory-leak-style bug (keys persisting in process
memory longer than intended) is entirely possible and is addressed
in §3.

---

## 2. Key hierarchy

```
passkey credential (Secure Enclave, iCloud Keychain)
  │
  │  ASAuthorizationPlatformPublicKeyCredentialProvider
  │  + PRF extension with salt = "creativemachines/prf/v1"
  ▼
PRF output (32 bytes)
  │
  │  HKDF-SHA256
  │    salt = "creativemachines/auth/v1"
  │    info = "creativemachines/kek/primary/v1/{thread_id}"
  ▼
primary KEK (32 bytes)
  │
  │  AES-KW (RFC 3394 unpadded)
  ▼
wrapped DEK (40 bytes, stored in macOS Keychain)
  │
  │  AES-KW unwrap
  ▼
DEK (32 bytes)
  │
  │  SQLCipher PRAGMA key (as 64-char hex)
  ▼
encrypted database files
```

Recovery path (only consulted on new-device restore):

```
BIP39 12-word phrase  (user-written on paper)
  │
  │  index to BIP39 wordlist, extract first 128 bits of entropy
  ▼
recovery seed (16 bytes)
  │
  │  HKDF-SHA256
  │    salt = "creativemachines/auth/v1"   (same shared salt)
  │    info = "creativemachines/kek/recovery/v1/{thread_id}"
  ▼
recovery KEK (32 bytes)
  │
  │  AES-KW unwrap against a separately-stored wrapped copy
  │  of the same DEK
  ▼
DEK (32 bytes, same as primary path)
```

**v1 constraint.** `{thread_id}` is always `"default"` in v1. The
template is plumbed through every derivation so v2 cloud-sync can
add per-thread DEK scoping without re-architecting.

### Why both wraps of the same DEK?

At setup, the wizard generates one random 32-byte DEK and wraps
it twice:

1. Under the primary KEK (passkey-derived) → stored in Keychain
   with `AccessibleWhenUnlockedThisDeviceOnly`. Used for day-to-day
   unlock.
2. Under the recovery KEK (BIP39-derived) → stored in Keychain as
   a *separate* item, also device-scoped. Recoverable via Time
   Machine restore; protected by the BIP39 phrase.

Either wrap decrypts the same DEK. They are cryptographically
independent – one side leaking its wrap doesn't compromise the
other. Tested as an architectural invariant in
`test_key_derivation.py::TestEndToEnd::test_primary_and_recovery_independent`.

---

## 3. Memory-scrub audit

Python cannot scrub immutable `bytes` or `str` objects. We do what
we can; the table documents what that "can" is for every
sensitive-material site in the Hub code.

**Legend**
- **Guaranteed cleared** – `bytearray` + `_memory.zeroize()` runs
  before reference drop. ctypes.memset + indexed-fallback; see
  `_memory.py`.
- **Best-effort** – immutable `bytes` or `str`; GC eventually
  reclaims, timing not controlled. Caller-scrubbable by copying
  into a bytearray and calling zeroize (documented for DEK fields
  that callers hold).
- **Can't be cleared** – library internal, beyond our API.

### Hub-side variables holding secret material

| Variable | File:Function | Type | Lifetime | Scrub status |
|---|---|---|---|---|
| `AutoLock._encryption_key` (held DEK) | `auto_lock.py:unlock()` → `lock()` | bytearray | Until `lock()` or auto-timeout | **Guaranteed cleared** – `_memory.zeroize()` on lock |
| `dek` local | `passkey.py:setup()` | bytes (immutable) | Function scope | Best-effort |
| `dek` local | `passkey.py:unlock_with_passkey()` | bytes | Function scope (returned to caller) | Best-effort; caller responsibility after return |
| `dek` local | `passkey.py:unlock_with_recovery()` | bytes | Function scope (returned to caller) | Best-effort; caller responsibility after return |
| `primary_kek` / `recovery_kek` locals | `passkey.py` orchestrator | bytes | Until wrap/unwrap completes | Best-effort |
| `recovery_seed` local | `passkey.py:setup()`, `unlock_with_recovery()` | bytes | One-shot | Best-effort |
| `prf_output` on `RegisterResult` / `AssertResult` | `webauthn_client.py` | bytes (in frozen dataclass) | Until result dropped | Best-effort |
| `phrase` (BIP39) | `passkey.py:setup()`; `recovery_cli.py` | str (immutable) | User-visible phrase lifetime | **Can't be cleared** (Python str) |
| DEK bytes inside `SetupResult.dek` | `passkey.py` return | bytes (in frozen dataclass) | Until caller drops result | **Caller responsibility** – docstring-warned |
| Wrapped DEK (ciphertext) | Keychain; `passkey.py` locals during wrap | bytes (40 B) | Persistent | Not secret – protected by KEK; no scrub needed |
| PBKDF2-derived passphrase key (legacy path) | `passphrase.py:derive_key()` | bytes | Function scope | Best-effort (legacy path – no longer called by wizard) |
| Internal `cryptography` library temporaries | HKDF.derive() / aes_key_unwrap() | bytes (lib-internal) | Library scope | **Can't be cleared** – not exposed |

### Why most cells say "best-effort"

Python's `bytes` is immutable. The only way to scrub is to copy into
a `bytearray`, then scrub the bytearray. But the ORIGINAL `bytes`
object persists until the garbage collector releases it – at an
unpredictable time, which can be after crash-dump capture, after a
memory pressure event, or potentially never if held by a cycle.

We could, on every internal call, bytes→bytearray→scrub-at-end. For
the Hub's architecture that adds code complexity without much
security benefit because:

1. The Hub is long-running by design only inside its server
   processes (assistant agent API, etc.); the auto-lock DEK is held as
   bytearray there, and IS scrubbed on lock. The session lifetime
   is the real exposure window, and it's covered.
2. Short-lived CLI flows (setup wizard, recovery CLI) die shortly
   after use. The bytes objects' lifetime is bounded by process
   lifetime, not by GC.
3. The scrub we CAN do (`bytearray` + `_memory.zeroize()`) would
   still leave intermediate immutable bytes from the cryptography
   library uncovered. Closing half the gap without closing the
   other half is a false assurance.

**What this means for Lester:** we're honest about the gap, we
scrub where it matters most (long-lived server sessions via
AutoLock), we provide the helper for future opt-in use, and we
document the Python-runtime limit rather than claiming it's solved.

### Future work

- **Swift helper boundary.** The PRF output arrives from the Swift
  helper as hex on a pipe. The Python-side decode produces an
  immutable `bytes`. Arguably we could instead have Swift write
  the raw bytes into a shared memory region that Python can
  `bytearray`-wrap and scrub. Low-priority; flagged because
  Lester's lunch topic on memory scrubbing will likely surface it.
- **Rust extension for KDF / wrap / unwrap.** A Rust-backed
  implementation could expose zeroize-on-drop semantics. Not a v1
  requirement.

---

## 4. Service-to-service auth on the Hub (#200)

§§1-3 cover at-rest secrets and the wrapped-DEK chain. This
section covers the runtime path: how the live Ostler processes on
the Hub talk to the inner personal-data stores (Oxigraph + Qdrant)
without trusting "we're all on localhost" as the access-control
story.

### Threat covered

Assume one or more processes running as the user's UID become
compromised: a malicious browser extension, a misbehaving Electron
app, a developer's experimental script. Without a gateway, every
such process can open a TCP connection to `localhost:7878`
(Oxigraph) or `localhost:6333` (Qdrant) and read or write the
user's personal graph. The inner stores ship without
authentication of their own – their access-control story has
historically been "you're on localhost, you're trusted". That
assumption no longer holds in a multi-process consumer-software
environment.

The auth-gated gateway closes that gap. Every Ostler publisher
mints a short-lived JWT and routes its inner-store calls through
the gateway. The gateway verifies the JWT and forwards to the
inner store. An unauthenticated localhost process hits 401 and
never reaches the data.

### Mechanism

- **Signing.** HS256, 1-hour TTL, 5-minute auto-refresh on the
  publisher side. Per-publisher in-process token cache; never
  written to disk.
- **Secret.** `JWT_SECRET` env var, populated from the Keychain at
  service-process startup. See `DEPLOYMENT_NOTES.md` §
  "Service-to-service auth env vars (#200)" for lifecycle.
- **Routing.** `PWG_GATEWAY_URL` env var, set to
  `http://localhost:8000` on customer installs. Empty default
  preserves the legacy direct-store path for dev and tests.
- **Service identities.** Eight distinct `sub` claims, one per
  publisher: `service-cm044-compiler` (wiki),
  `service-cm048-publisher` (conversation processor),
  `service-cm041-meeting-syncer`,
  `service-cm041-identity-resolver`,
  `service-cm041-contact-syncer` (also covers the DedupDetector),
  `service-cm041-history-loader`,
  `service-cm041-whatsapp-bridge`,
  `service-cm041-relationship-decay`. Gateway audit log records
  `(timestamp, sub, method, path)` on every call.
- **Write gate.** SPARQL UPDATE and Qdrant PUT/POST writes
  require `compartment_level <= 2` on the token. SPARQL queries
  and Qdrant searches accept any compartment.

### What this does and doesn't do

This is a localhost-process boundary, not a kernel- or
hypervisor-level isolation. An attacker with code execution
inside an *Ostler* process still has access to that process's
JWT_SECRET (read from env at startup) and so can mint tokens. The
mitigation is meaningful against compromise of *other* processes
running as the same user – the much larger surface – not against
compromise of Ostler itself, which is already covered by §1's
"Malware with code execution inside the unlocked Ostler process"
row.

### Vendored helper inventory (post-launch dedup)

Eight copies of the `mint_service_token` helper currently live in
the Ostler tree: one per publisher consumer (CM044 wiki compiler,
CM048 conversation publisher, CM041 meeting syncer, identity
resolver, contact syncer, history loader, WhatsApp bridge,
relationship-decay sweeper). Each is identical to the canonical
helper in `services/common/auth/service_token.py` modulo the
`SERVICE_NAME` constant. A SHA-256 hash table per copy is to be
added here once the v1.1 feature branches carrying the vendored
copies merge, so the audit-time invariant is machine-checkable.
Pip-installable extraction so all eight can collapse is filed as
post-launch follow-up.

### Cross-references

- `OSTLER_ARCHITECTURE.md` §4.1 (customer-facing summary + flow
  diagram).
- `DEPLOYMENT_NOTES.md` § "Service-to-service auth env vars
  (#200)" (JWT_SECRET + PWG_GATEWAY_URL operations).
- CM019 `services/gateway/CLAUDE.md` § "Auth model" (gateway-side
  verifier internals).

---

## 5. Error-code taxonomy

See `errors.py` for the typed exception hierarchy. Every
auth-failure path in the Hub maps to exactly one error code, and
every error code has a matching typed exception:

| Code | Exception | Meaning / caller action |
|---|---|---|
| `USER_CANCELED` | `UserCanceledError` | User dismissed Touch ID. Recoverable: re-prompt or exit. |
| `NO_CREDENTIAL` | `NoCredentialError` | No passkey on device. Route to recovery flow. |
| `PRF_UNSUPPORTED` | `PRFUnsupportedError` | Authenticator lacks PRF (shouldn't happen on macOS 15+ / iCloud Keychain). Tell user to switch providers. |
| `OS_TOO_OLD` | `OSTooOldError` | Pre-macOS-15. Hard stop. |
| `INVALID_REQUEST` | `InvalidRequestError` | Malformed input – typically BIP39 typo. Re-prompt. |
| `HELPER_NOT_FOUND` | `HelperNotFoundError` | Swift helper binary missing. Deployment bug. |
| `TIMEOUT` | `AuthTimeoutError` | Helper exceeded 120s waiting for user. Recoverable. |
| `INTERNAL` | `InternalError` | Catch-all. Log + investigate. |
| `KEYCHAIN_NOT_FOUND` | `KeychainNotFoundError` | Keychain item absent. |
| `KEYCHAIN_DUPLICATE` | `KeychainDuplicateError` | Add-only collision (our `set_item` upserts, shouldn't surface). |
| `KEYCHAIN_DENIED` | `KeychainDeniedError` | User denied Keychain access or ACL blocked. |

Unknown codes map to `InternalError` – defensive so an upstream-
added code doesn't silently pass as success.

---

## 6. Deferred items (post-v1)

Captured here so reviewers can see what was intentionally left out
vs oversights.

- **Cross-platform support (non-Apple).** Requires dropping the
  iCloud-Keychain-synced passkey or building a separate auth
  stack for Linux/Windows. Lester Q3 2026-04-27.
- **Developer-ID code-signing of the Swift helper.** See
  `DEPLOYMENT_NOTES.md`. Blocks real Touch ID smoke testing on
  unsigned dev builds; Phase 4 installer pipeline owns this.
- **Per-thread DEK scoping.** Plumbed through HKDF info strings
  (`thread_id` parameter), hardcoded to `"default"` in v1. Fills
  out in v2 cloud-sync.
- **Zeroize-on-drop via Rust / shared-memory Swift↔Python path.**
  See §3 "Future work".
- **Binary framing for sync-wire version byte.** `spec_version`
  currently carried as JSON integer per `SHARED_AUTH_SPEC.md` §6.3.
  v2 can add binary framing.
- **Rotatable recovery phrase.** v1 treats the recovery phrase as
  stable across the lifetime of the user's data. A "generate new
  phrase, migrate DEK" flow is possible but not in v1.

---

## 7. Reference documents

- `SHARED_AUTH_SPEC.md` – normative cross-platform spec (Hub + iOS
  Companion). Constants, wire formats, test vectors.
- `DEPLOYMENT_NOTES.md` – packaging requirements (code-signing,
  entitlements, AASA, macOS version).
- `DAY_ZERO_AUDIT.md` – test inventory and integration-point map
  from the start of this workstream.
- `errors.py` – typed exception source of truth.
- `_memory.py` – scrub helper source.
