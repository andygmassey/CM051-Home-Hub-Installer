# Passkey Auth – Day-Zero Audit

**Branch:** `agent/passkey-auth`
**Date:** 2026-04-23
**Owner:** TNM
**Status:** groundwork only – no production code modified yet.

This document captures the read-only investigation output that Andy and Lester
asked for before Day 1 implementation begins. It records (1) the actual
existing-test baseline, (2) the integration-point map, and (3) the Swift helper
binary's JSON-RPC interface. Day 1 work starts from this document.

---

## 1. Existing-test baseline

The brief cites "109 existing tests". Actual count on `origin/main` is **120
tests, 120/120 passing** (runtime ~37s). The brief predates security
sweep #2 (`b38fc82`) which added +7 tests, so the drift is expected.

| File | Tests | Notes |
|------|-------|-------|
| `test_passphrase.py` | 51 | Heaviest: key derivation, verification, recovery, change-passphrase, Unicode edge cases, timing-side-channel coverage. Every passkey refactor must leave every one of these passing – the existing `derive_key`/`verify_passphrase` public API keeps working, even though its *role* in the system changes. |
| `test_payload_viewer.py` | 15 | Unrelated to auth path, should stay green untouched. |
| `test_audit_log.py` | 13 | Needs +1 event type for `EVENT_PASSKEY_REGISTER` and +1 for `EVENT_PASSKEY_ASSERT_FAILED`. Existing tests unaffected. |
| `test_auto_lock.py` | 12 | Unlock-key-storage-and-zeroing coverage. The passkey work adds a re-unwrap-on-unlock step but the AutoLock class itself already takes a `bytes` encryption key – no API break. |
| `test_database.py` | 10 | Skipped locally without pysqlcipher3; unaffected by passkey work. |
| `test_rate_limiter.py` | 9 | Unrelated to key path. |
| `test_tls_setup.py` | 7 | Unrelated to key path. |
| `test_filevault.py` | 3 | Unrelated to key path. |
| **Total** | **120** | **Baseline** |

**Promise:** passkey-auth lands with **120 + ~30-40 = 150-160 tests, zero
regressions**. If any of the 120 existing tests need modification (not just
extension), that gets called out explicitly in the PR.

---

## 2. Integration-point map

`ostler_security/` is imported by three out-of-tree consumers (checked in
CM048, CM041 × 2). All three use a **single public symbol**:

```python
from ostler_security.database import get_db_connection as _secure_connect
```

That function's signature – `get_db_connection(db_path, encryption_key_hex)` –
**must not change**. The internal path that produces `encryption_key_hex` is
free to be rebuilt; the caller supplies a 64-char hex DEK and gets back a
SQLCipher connection.

### Module-by-module map

| Module | Role today | Role under passkey | Breaking change? |
|--------|-----------|--------------------|------------------|
| `passphrase.py` | Primary auth – PBKDF2(user passphrase) → key | Repurposed: BIP39-style recovery-phrase management. Switches PBKDF2 → **HKDF-SHA256** (per Andy 2026-04-23: high-entropy system-generated phrase doesn't benefit from iterations). Keeps all existing public symbols (`derive_key`, `setup_passphrase`, `unlock`, `verify_passphrase`, `unlock_with_recovery_key`, `change_passphrase`, `generate_recovery_key`) but the `unlock`/`setup_passphrase` variants become the *recovery* path, not the primary. Docstring gets an explicit note so the next agent doesn't "restore" PBKDF2. | No – all public symbols retained, callers who pass a passphrase get the same behaviour (it now lives on the recovery rail, but the API shape is identical). Downstream consumers (`database.get_db_connection`) don't call passphrase at all. |
| `keychain.py` (NEW) | – | Stores wrapped DEK + wrapped recovery-copy DEK as macOS Keychain items. Attributes: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable=false`. Uses `security` CLI for writes (avoids PyObjC dependency in hot path). | N/A – new module. |
| `key_derivation.py` (NEW) | – | HKDF-SHA256(PRF output) → KEK; AES-KW (RFC 3394) wrap/unwrap of the 32-byte DEK. Pure `cryptography` library, no Apple framework dep. | N/A – new module. |
| `webauthn_client.py` (NEW) | – | Python side of the Swift helper IPC. Subprocess `Popen` of `bin/lifeline-passkey-helper`, sends one JSON request on stdin, reads one JSON response on stdout, exits. See §3. | N/A – new module. |
| `setup_wizard.py` | CLI: FileVault → passphrase → recovery key → DEK | Rewired: FileVault → macOS version check (≥15.0 required for PRF) → passkey register (Swift helper Touch ID prompt) → show recovery phrase → wrap DEK with both KEKs → persist to Keychain. Existing `run_wizard()` signature preserved; it still returns `{encryption_key_hex, config_dir, recovery_key}`. | No – return dict keys stable. |
| `auto_lock.py` | Holds bytes DEK in memory, zeros on lock/timeout | Same. On **unlock**, caller now passes a DEK obtained by a fresh passkey assertion (Touch ID) rather than by passphrase derivation. The AutoLock class is auth-source-agnostic – no change required. | No. |
| `database.py` | SQLCipher connection from hex DEK | Unchanged. | No. |
| `filevault.py` | FileVault status check | Unchanged. | No. |
| `audit_log.py` | Audit events | +2 new event types (`EVENT_PASSKEY_REGISTER`, `EVENT_PASSKEY_ASSERT_FAILED`). Existing events untouched. | No. |
| `rate_limiter.py` | Brute-force protection on passphrase attempts | Still applies to the recovery-phrase path. Passkey path itself has no brute-force surface (Secure Enclave enforces that). | No. |
| `payload_viewer.py` | diagnostic payload sanitiser | Unchanged. | No. |
| `tls_setup.py` | Cert generation | Unchanged. | No. |

### Call-flow changes – before vs after

**Today (passphrase)**:
```
setup_wizard → passphrase.setup_passphrase(user_input)
             → passphrase.derive_key(passphrase, salt)  # PBKDF2 600k
             → database.get_db_connection(path, key_hex)
```

**After (passkey primary, recovery-phrase fallback)**:
```
setup_wizard → webauthn_client.register(rp_id, user_id, prf_salt)
             → key_derivation.hkdf_sha256(prf_output, context="dek_kek")
             → os.urandom(32)                           # random DEK
             → key_derivation.aes_kw_wrap(DEK, KEK)
             → keychain.store_wrapped_dek(wrapped)
             → passphrase.generate_recovery_key()       # keeps existing function
             → key_derivation.hkdf_sha256(recovery_phrase_bytes, context="recovery_kek")
             → key_derivation.aes_kw_wrap(DEK, recovery_KEK)
             → keychain.store_wrapped_recovery_dek(wrapped_recovery)
             → database.get_db_connection(path, DEK.hex())   # unchanged
```

**On app launch**:
```
webauthn_client.assert_(credential_id, prf_salt)
  → key_derivation.hkdf_sha256(prf_output, context="dek_kek")
  → keychain.read_wrapped_dek()
  → key_derivation.aes_kw_unwrap(wrapped, KEK) → DEK
  → auto_lock.unlock(DEK)
  → database.get_db_connection(path, DEK.hex())
```

**On recovery (new Mac, no iCloud Keychain sync)**:
```
prompt for recovery phrase (passphrase.py CLI path – existing)
  → key_derivation.hkdf_sha256(recovery_phrase_bytes, context="recovery_kek")
  → keychain.read_wrapped_recovery_dek()
  → key_derivation.aes_kw_unwrap(wrapped_recovery, recovery_KEK) → DEK
  → webauthn_client.register(...)   # register new passkey on this device
  → key_derivation.aes_kw_wrap(DEK, new_KEK) → re-wrap with new passkey
  → keychain.store_wrapped_dek(new_wrapped)
```

### Per-thread DEK hook (confirmed future, not v1)

Per Andy 2026-04-23: v1 ships a single DEK. `key_derivation` exposes both
helpers with a `thread_id: str = "default"` parameter plumbed through – so when
v2 cloud-sync lands, per-thread KEKs derive from the same passkey PRF by
varying the HKDF `info` parameter: `info = f"dek_kek:{thread_id}"`. No
rearchitect needed, just widen the caller.

---

## 3. Swift helper binary – JSON-RPC interface spec

### Binary shape

- **Name:** `lifeline-passkey-helper`
- **Location in repo:** `ostler_security/bin/src/` (Swift source); compiled
  universal binary ships at `ostler_security/bin/lifeline-passkey-helper`
  (checked in for v1; CI rebuild later).
- **Build:** `swift build -c release --arch arm64 --arch x86_64 --product lifeline-passkey-helper`
- **Stdlib only + AuthenticationServices framework.** No third-party Swift
  packages – keeps the build trivial and auditable.
- **Invocation:** one-shot. Python spawns the process, writes one JSON line
  to stdin, reads one JSON line from stdout, process exits. No long-running
  daemon, no persistent state. Each Touch ID prompt = one process launch.
- **Exit code:** 0 on success (including auth failures that produced a
  well-formed error JSON), non-zero only on unrecoverable internal errors
  that couldn't produce a response. Python treats non-zero exit as
  `{"ok": false, "error_code": "INTERNAL", ...}`.

### Wire format

Each message is a single line of UTF-8 JSON, terminated by `\n`. No
multiplexing, no streaming, no binary framing. Keeps the Python side
trivial (`subprocess.communicate`).

### Command: `register`

**Request (Python → Swift):**

```json
{
  "op": "register",
  "rp_id": "lifeline.local",
  "user_id": "<base64url of 16 random bytes>",
  "user_name": "<string – shown in Touch ID UI>",
  "user_display_name": "<string>",
  "request_prf": true,
  "prf_salt": "<hex – 32 bytes – fixed per installation>"
}
```

**Response (success):**

```json
{
  "ok": true,
  "credential_id": "<base64url – opaque handle to the passkey, store this>",
  "public_key": "<base64url – COSE-encoded EC P-256 public key, store this>",
  "prf_output": "<hex – 32 bytes – feeds HKDF → KEK>",
  "rp_id": "lifeline.local",
  "attestation": "<base64url – FIDO attestation object, optional storage>"
}
```

**Response (failure):**

```json
{"ok": false, "error_code": "USER_CANCELED", "message": "User cancelled Touch ID prompt"}
```

### Command: `assert`

**Request:**

```json
{
  "op": "assert",
  "rp_id": "lifeline.local",
  "credential_id": "<base64url – from register>",
  "challenge": "<base64url – 32 random bytes generated by Python each call>",
  "request_prf": true,
  "prf_salt": "<hex – same 32 bytes as register>"
}
```

**Response (success):**

```json
{
  "ok": true,
  "credential_id": "<base64url – confirms which passkey was used>",
  "signature": "<base64url – ignore for v1, future verification>",
  "client_data_json": "<base64url – ignore for v1>",
  "prf_output": "<hex – 32 bytes – feeds HKDF → KEK – the thing that matters>"
}
```

**Response (failure):** same error shape as `register`.

### Error codes

| Code | Meaning |
|------|---------|
| `USER_CANCELED` | User dismissed Touch ID prompt. Non-fatal. |
| `NO_CREDENTIAL` | No passkey in Keychain matching `credential_id` (e.g. user wiped Keychain). Python falls back to recovery-phrase path. |
| `PRF_UNSUPPORTED` | Authenticator doesn't support the PRF extension. Shouldn't happen on macOS 15+ iCloud Keychain passkeys; treat as setup-time failure. |
| `OS_TOO_OLD` | Pre-macOS-15.0 or pre-iOS-17.4. Refuse setup with clear message (per Andy 2026-04-23: no non-PRF fallback path). |
| `INVALID_REQUEST` | Malformed JSON or missing required fields. |
| `INTERNAL` | Catch-all for bugs. Includes Swift exception message in `message`. |

### Why one-shot vs persistent daemon

Touch ID UX is already ~1-second human latency. A cold-start Swift process
adds ≤100ms. Persistent daemon would save that latency but introduces:
- Process lifecycle management (supervisor, restart on crash)
- Cross-process key material in memory longer than needed
- IPC security surface (socket permissions, handshake)

Net: one-shot is simpler, slightly slower, and equally secure. Revisit only
if latency becomes a real UX problem.

### Python side (`webauthn_client.py`) sketch

```python
def register(rp_id: str, user_id: bytes, user_name: str, prf_salt: bytes) -> RegisterResult:
    req = {"op": "register", "rp_id": rp_id, ...}
    proc = subprocess.Popen(
        [HELPER_PATH],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    out, err = proc.communicate(input=(json.dumps(req) + "\n").encode(), timeout=120)
    if proc.returncode != 0:
        return _internal_error(err.decode(errors="replace"))
    return _parse_response(out)
```

The Swift helper's 120s timeout matches macOS's own Touch ID dialog timeout.

### Versioning

Response includes an implicit `schema_version: 1` that Swift adds and Python
ignores in v1. Bump when we add fields.

---

## 4. Residual unknowns

Items I'd normally have answers on before coding. None blocks Day 1 but
surface them to Lester if the topic comes up.

1. **`rp_id` choice.** WebAuthn's "relying party ID" should be the domain the
   user recognises. For a local CLI tool there's no domain. Options:
   `lifeline.local`, `app.lifeline.io` (reserved future domain), or the user's
   own `<hostname>.local`. Leaning `lifeline.local` for now; confirm before
   Day 1 since `rp_id` is part of the credential and can't be changed without
   re-registering.
2. **Credential ID persistence.** `credential_id` must be stored somewhere
   Python can read without authentication (Keychain item with no access
   control, or plain file in `~/.lifeline/security/passkey.json`). Latter is
   simpler and the ID is not secret – it's only a handle to "which passkey do
   I want to use". Going with the plain file unless there's an objection.
3. **Recovery-phrase format.** Brief says "existing module", so BIP39-style
   26-char alphanumeric. Confirmed – `passphrase.generate_recovery_key()`
   already emits the right shape; we just change what it feeds into (HKDF not
   PBKDF2).
4. **Test infra for Swift helper.** Day 1 needs a mock-helper Python fixture
   that pretends to be `lifeline-passkey-helper`. Plan: ship a small
   `tests/fakes/mock_passkey_helper.py` that reads JSON from stdin and writes
   a deterministic response. CI wires it in via env var
   `LIFELINE_PASSKEY_HELPER_PATH=./tests/fakes/mock_passkey_helper.py`. Real
   Swift helper only exercised on macOS developer machines + release builds.
5. **`webauthn_client.py` error → recovery-phrase handoff.** When `assert`
   returns `NO_CREDENTIAL` (or OS lost the passkey somehow), setup_wizard's
   post-first-run unlock flow needs to offer the recovery path automatically
   rather than erroring out. Ergonomic detail; will design in Day 3.

---

## 5. Apple-only-forever – Lester agenda item

Per Andy 2026-04-23: add to Monday lunch. The passkey architecture locks
Ostler to Apple's ecosystem far harder than the passphrase scheme did.
Passphrase ports trivially to any platform with a KDF library. Passkey +
iCloud-Keychain-synced wrapping key does not. Leaving Apple means:

- Recovery-phrase unlock only (new platform has no iCloud Keychain sync of
  the existing passkey).
- New-device registration is a whole ceremony: recovery phrase → unwrap DEK →
  register new WebAuthn credential (via whichever platform's WebAuthn
  authenticator) → re-wrap DEK with new KEK. Feasible but a visible UX
  break.

This is worth an explicit security-design sign-off rather than a drift into
Apple-exclusivity by default.

---

## 6. What happens in Day 1

With Day 0 groundwork banked, Day 1 opens with concrete plumbing work:

1. Create `ostler_security/bin/src/` with the Swift package skeleton and a
   minimal `register` implementation that compiles and returns a canned JSON
   response (doesn't call AuthenticationServices yet – just proves the IPC).
2. Create `ostler_security/webauthn_client.py` with subprocess plumbing and
   a mock-helper-driven test suite (~6 tests: happy path, canceled, OS_TOO_OLD
   simulated, timeout, non-zero exit, malformed JSON).
3. Add `key_derivation.py` with HKDF-SHA256 + AES-KW (RFC 3394) + roundtrip
   test coverage (~5 tests). Pure `cryptography` library – no framework deps.
4. Extend `audit_log.py` with the two new event types. ~2 tests.

End-of-Day-1 target: ~15 new tests passing, 120 existing tests still green,
Swift helper binary builds locally (even if its production implementation is
stubbed). PR draft opened.
