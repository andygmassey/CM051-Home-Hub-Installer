# ostler_security

Local security module for Ostler. Provides:

- **Passkey-primary authentication** via macOS 15+
  AuthenticationServices (Touch ID / Face ID with PRF extension)
- **BIP39 recovery phrase** as the last-resort fallback for
  new-device bootstrap
- **SQLCipher at-rest encryption** of every Ostler database
- **FileVault awareness** at setup time
- **Local audit log** of every unlock / lock / unlock-failure event
- **Rate-limiting** primitives with constant-time comparison
- **Diagnostic-service payload sanitisation** for cloud exports
- **Auto-lock** with secure key zeroing on timeout

The module is **Apple-only by construction** – passkey + iCloud
Keychain sync is the core UX story. See
[`SECURITY_MODEL.md`](SECURITY_MODEL.md) §1 for why.

## If you just inherited this

**Read these four files in order; the whole thing takes ~30 minutes.**

1. [`SECURITY_MODEL.md`](SECURITY_MODEL.md) – 15-minute threat-model
   + key-hierarchy + scrub-audit document. §0 is a one-lunch
   orientation paragraph.
2. [`SHARED_AUTH_SPEC.md`](../SHARED_AUTH_SPEC.md) – normative
   cross-platform contract with the iOS Companion (CM031). Every
   HKDF constant, AES-KW parameter, and wire format byte lives
   here. Do NOT change any string in §1 / §2 / §3 without a
   matching iOS-side change and a spec re-sign.
3. [`DEPLOYMENT_NOTES.md`](DEPLOYMENT_NOTES.md) – the code-signing
   and packaging gap that blocks real Touch ID smoke-testing on
   ad-hoc-signed dev builds. Owned by Phase 4 installer work.
4. [`DAY_ZERO_AUDIT.md`](DAY_ZERO_AUDIT.md) – original scope,
   test-count baseline, integration-point map. Written before
   Day 1; archival.

Then skim the code:

- [`passkey.py`](passkey.py) – the orchestrator (setup / unlock /
  recover / rebind). 4 public functions.
- [`webauthn_client.py`](webauthn_client.py) – subprocess driver
  for the Swift helper. Fixed `PRF_EVAL_INPUT` + `RP_ID` constants.
- [`key_derivation.py`](key_derivation.py) – HKDF-SHA256 + AES-KW
  + BIP39 wordlist. Each HKDF call maps directly to a
  `SHARED_AUTH_SPEC.md` §1 row.
- [`keychain.py`](keychain.py) – thin Python client for the Swift
  helper's Security.framework ops.
- [`auto_lock.py`](auto_lock.py) – session lifecycle, timeout,
  memory scrub on lock. See `reunlock()` / `reunlock_or_raise()`
  for the re-authentication hook.
- [`errors.py`](errors.py) – typed exception hierarchy. One
  subclass per error-code string; `exception_for_code()` dispatch.
- [`setup_wizard.py`](setup_wizard.py) – first-run CLI flow.
  Passkey primary, BIP39 phrase for recovery.
- [`recovery_cli.py`](recovery_cli.py) – new-device bootstrap via
  recovery phrase.
- [`_memory.py`](_memory.py) – `zeroize()` + `scrub_on_exit()`
  context manager. Shared scrub primitive.

Pre-passkey legacy code still ships for reference:

- [`passphrase.py`](passphrase.py) – original PBKDF2-based
  passphrase flow. No longer called by `setup_wizard`; kept in
  place so downstream consumers that still import it don't break
  during the transition.

## Public API – what downstream consumers use

Out-of-tree consumers (CM048 `ingest.py`, CM041 `assistant_api` +
`whatsapp_bridge`) import exactly one symbol:

```python
from ostler_security.database import get_db_connection
```

That signature – `get_db_connection(db_path, encryption_key_hex)` –
is **frozen**. It returns an SQLCipher-backed `sqlite3.Connection`
when `HAS_SQLCIPHER` is true, falls back to plain sqlite3 otherwise
(with a warning). The internal path that produces the hex key has
changed from PBKDF2(passphrase) → HKDF(passkey PRF) across this
workstream, but callers don't see that.

## Running tests

```bash
cd HR015-Gaming-PC/
python3 -m pytest ostler_security/tests/ -q
```

Expected: 299 tests pass in ~38s on a Python 3.11 virtualenv with
`cryptography`, `phonenumbers`, `mnemonic`, and `pysqlcipher3`
installed. The `test_database.py` file is skipped if `pysqlcipher3`
isn't available.

### Testing the Swift helper without Touch ID

Python-side tests drive the full subprocess IPC through a mock
helper at [`tests/fakes/mock_passkey_helper.py`](tests/fakes/mock_passkey_helper.py).
The `OSTLER_PASSKEY_HELPER` env var tells `webauthn_client.py`
where to find the helper binary; pointing at the mock bypasses
Touch ID entirely.

Tests auto-wire the mock via pytest fixtures – see
`test_webauthn_client.py::_point_at_mock`.

### Testing against the real Swift helper

On a Mac with Xcode installed:

```bash
cd ostler_security/bin/src/
swift build -c release
./.build/release/ostler-passkey-helper <<< '{"op":"keychain_exists","service":"lifeline","account":"none"}'
```

You should see `{"exists":false,"ok":true}`. That's a real
`Security.framework` call – if it works, the build is good.

**Touch ID / passkey ops do NOT work on ad-hoc-signed dev builds.**
`AuthenticationServices` silently refuses unsigned binaries – no
Touch ID prompt appears, no error. See
[`DEPLOYMENT_NOTES.md`](DEPLOYMENT_NOTES.md) for the full story.

## Where things are wired

```
┌─── First-run install ──────────────────────────────────┐
│                                                         │
│   setup_wizard.run_wizard()                             │
│     → passkey.setup(user_name)                          │
│         → webauthn_client.register()  [Swift helper]    │
│         → key_derivation.derive_primary_kek()           │
│         → key_derivation.generate_bip39_phrase()        │
│         → key_derivation.derive_recovery_kek()          │
│         → key_derivation.wrap_dek()  [AES-KW × 2]       │
│         → keychain.store_wrapped_dek()                  │
│         → keychain.store_wrapped_recovery()             │
│     → (recovery-phrase-on-paper confirmation)           │
│   returns {dek, recovery_phrase, credential_id, ...}    │
│                                                         │
└─────────────────────────────────────────────────────────┘

┌─── Day-to-day unlock ──────────────────────────────────┐
│                                                         │
│   passkey.unlock_with_passkey()                         │
│     → keychain.load_wrapped_dek()                       │
│     → webauthn_client.assert_()  [Touch ID]             │
│     → key_derivation.derive_primary_kek()               │
│     → key_derivation.unwrap_dek()                       │
│   returns UnlockResult(dek=…)                           │
│                                                         │
│   caller: AutoLock.unlock(dek)                          │
│                                                         │
└─────────────────────────────────────────────────────────┘

┌─── Recovery on new device ─────────────────────────────┐
│                                                         │
│   recovery_cli.run()                                    │
│     → (user types 12-word phrase)                       │
│     → passkey.unlock_with_recovery(phrase)              │
│         → key_derivation.bip39_phrase_to_seed()         │
│         → keychain.load_wrapped_recovery()              │
│         → key_derivation.derive_recovery_kek()          │
│         → key_derivation.unwrap_dek()                   │
│     → passkey.rebind_after_recovery(dek, …)             │
│         → webauthn_client.register()  [Touch ID]        │
│         → key_derivation.wrap_dek()                     │
│         → keychain.store_wrapped_dek()                  │
│                                                         │
└─────────────────────────────────────────────────────────┘

┌─── Auto-lock cycle ────────────────────────────────────┐
│                                                         │
│   AutoLock(timeout=900, reunlock_callback=…)            │
│     unlock(dek)         – stored as bytearray           │
│     touch()             – on every API request          │
│     check()             – triggered by is_locked access │
│     lock()              – zeroes via _memory.zeroize()  │
│     reunlock()          – bool path                     │
│     reunlock_or_raise() – typed exception path          │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## Contributing changes

**Before modifying any constant that crosses the iOS boundary:**
re-read `SHARED_AUTH_SPEC.md` Appendix B (MUST-NOT-HAPPEN list).
Changes to PRF input, HKDF salts/info strings, AES-KW variant,
BIP39 derivation, or rp_id break every existing user's key material
silently. The spec has a signoff process – use it.

**Before adding a new sensitive-material variable:** update
`SECURITY_MODEL.md` §3's scrub audit table with the new variable's
file:function, type, lifetime, and scrub status. Lester's
review heuristic: a sensitive variable not in that table is a
bug.

**Before adding a new error code:** add an exception subclass in
`errors.py`, register it in `_CODE_TO_EXCEPTION`, and update the
taxonomy table in `SECURITY_MODEL.md` §4.

## Version requirements

- macOS 15.0+ (runtime-enforced; no non-PRF fallback per spec §0)
- Python 3.11+ (3.9 works locally but CI targets 3.11 for the
  strict-concurrency Swift helper's compatibility matrix)
- Swift 6.0+ for building the passkey helper (arm64+x86_64 universal)

## License

See top-level `LICENSE`. This module is part of HR015 and inherits
its terms.
