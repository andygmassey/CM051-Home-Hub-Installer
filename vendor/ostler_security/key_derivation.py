"""Passkey-derived key derivation + AES Key Wrap for the Ostler DEK.

All constants in this module are mirrored in SHARED_AUTH_SPEC.md and
MUST remain byte-identical with the iOS Companion implementation in
CM031. Changing any salt, info string, or primitive here without a
spec bump silently breaks cross-platform compatibility. See
`SHARED_AUTH_SPEC.md §1` for the normative definitions.

Architecture
------------

    passkey (Secure Enclave, iCloud-Keychain-synced)
       │
       │  WebAuthn PRF extension, eval input = "creativemachines/prf/v1"
       ▼  (32 B output per invocation, deterministic per-credential)
    derive_primary_kek()   →  HKDF-SHA256 → 32-byte KEK
       │
       ▼
    aes_kw_wrap(DEK, KEK)  →  40-byte wrapped DEK (stored in Keychain)
       │
       ▼  (at unlock)
    aes_kw_unwrap(wrapped, KEK)  →  32-byte DEK
       │
       ▼
    SQLCipher PRAGMA key

Recovery path takes a BIP39 12-word phrase → 16-byte native entropy
→ HKDF with a distinct info string → 32-byte recovery KEK. The same
DEK is wrapped twice at setup – once under the primary KEK, once
under the recovery KEK – so either path can unwrap it independently.

Per-thread DEK hook
-------------------
The HKDF `info` parameter carries a `thread_id` that's validated
against `[a-z0-9_]{1,32}` and hardcoded to `"default"` in v1
(SHARED_AUTH_SPEC.md §5). v2 cloud-sync will vary it for per-thread
scoping without changing any primitive.

Why HKDF not PBKDF2
-------------------
Both primary-path (PRF output: 256 bits of Secure-Enclave entropy)
and recovery-path (BIP39 native entropy: 128 bits) inputs are
already high-entropy. PBKDF2's iteration cost defends against
low-entropy inputs (user-chosen passwords). Applying it here would
slow unlock without adding security. This is the opposite of
`passphrase.py`, which DOES use PBKDF2 because user-chosen
passphrases need the slow-down.

**DO NOT "fix" this by adding iterations.** See SHARED_AUTH_SPEC.md
Appendix B – this is explicitly listed as a MUST-NOT-HAPPEN
deviation because it would produce different bytes on Hub vs iOS.
Andy decided 2026-04-23.

BIP39 wordlist
--------------
The standard English BIP39 wordlist (2048 words) is required for
recovery-phrase validation. The wordlist file ships as
`ostler_security/bip39_english.txt` – a canonical file whose
SHA-256 both sides cross-check at spec signoff.
"""
from __future__ import annotations

import hashlib
import os
import re
import secrets
import unicodedata
from pathlib import Path
from typing import List, Tuple

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.keywrap import aes_key_unwrap, aes_key_wrap


# ── Sizes ────────────────────────────────────────────────────────────

DEK_LENGTH = 32
KEK_LENGTH = 32
REALM_KEY_LENGTH = 64  # Realm.Configuration.encryptionKey requires 64
RECOVERY_SEED_LENGTH = 16  # BIP39 12-word native entropy
WRAPPED_DEK_LENGTH = DEK_LENGTH + 8  # RFC 3394


# ── Spec constants (SHARED_AUTH_SPEC.md §1) ──────────────────────────

# §1.2 HKDF extract-salt, shared across all derivations.
HKDF_SALT = b"creativemachines/auth/v1"

# §1.3 HKDF info string templates. `{thread_id}` is substituted
# before use (the literal characters "{thread_id}" must never appear
# in the bytes fed to HKDF). Literal `/` and `:` are ASCII bytes per
# §1.3's "Literal characters" note; they are not syntactic.
#
# Prefix is the company namespace `creativemachines/`, never any
# product brand (e.g. `<product>/...`). Crypto-derived material gets
# baked into wrapped DEKs and per-device handles at install time, so
# changing the prefix later silently invalidates every existing
# install. See SHARED_AUTH_SPEC.md Appendix E.6 / E.7 for the
# 2026-04-23 rename rationale and Appendix B's MUST-NOT-HAPPEN list.
_INFO_PRIMARY_TEMPLATE = "creativemachines/kek/primary/v1/{thread_id}"
_INFO_RECOVERY_TEMPLATE = "creativemachines/kek/recovery/v1/{thread_id}"
_INFO_REALM_TEMPLATE = "creativemachines/realm/v1/{thread_id}:realm_dek_expand"

# §5.2 `thread_id` validation (reject anything not matching this pattern).
_THREAD_ID_RE = re.compile(r"\A[a-z0-9_]{1,32}\Z")

# Convenience – the only legal thread_id in v1.
DEFAULT_THREAD_ID = "default"


# ── Thread id validation ─────────────────────────────────────────────

def _validate_thread_id(thread_id: str) -> None:
    if not isinstance(thread_id, str):
        raise TypeError(f"thread_id must be str, got {type(thread_id).__name__}")
    if not _THREAD_ID_RE.match(thread_id):
        raise ValueError(
            f"thread_id {thread_id!r} does not match [a-z0-9_]{{1,32}}"
        )


# ── DEK / random generation ──────────────────────────────────────────

def generate_dek() -> bytes:
    """Generate a fresh 32-byte Data Encryption Key from the OS CSPRNG."""
    return os.urandom(DEK_LENGTH)


# ── HKDF helpers ─────────────────────────────────────────────────────

def _hkdf(ikm: bytes, info: bytes, length: int) -> bytes:
    """HKDF-SHA256 with the spec-fixed extract-salt."""
    return HKDF(
        algorithm=hashes.SHA256(),
        length=length,
        salt=HKDF_SALT,
        info=info,
    ).derive(ikm)


# ── Primary KEK (passkey PRF → KEK) ──────────────────────────────────

def derive_primary_kek(
    prf_output: bytes,
    *,
    thread_id: str = DEFAULT_THREAD_ID,
) -> bytes:
    """HKDF the 32-byte WebAuthn PRF output into a 32-byte primary KEK.

    The PRF output is what the passkey returns when evaluated against
    the fixed PRF input from `webauthn_client.PRF_EVAL_INPUT`
    (SHARED_AUTH_SPEC.md §1.1). Both sides MUST call this function
    with the same `thread_id` to derive byte-identical KEKs.
    """
    if len(prf_output) != 32:
        raise ValueError(f"PRF output must be 32 bytes, got {len(prf_output)}")
    _validate_thread_id(thread_id)
    info = _INFO_PRIMARY_TEMPLATE.format(thread_id=thread_id).encode("ascii")
    return _hkdf(prf_output, info, KEK_LENGTH)


# ── Recovery KEK (BIP39 phrase → seed → KEK) ─────────────────────────

def derive_recovery_kek(
    recovery_seed: bytes,
    *,
    thread_id: str = DEFAULT_THREAD_ID,
) -> bytes:
    """HKDF a 16-byte BIP39 native-entropy seed into a 32-byte recovery KEK.

    `recovery_seed` is the output of `bip39_phrase_to_seed()` – NOT a
    BIP39-PBKDF2 seed (see SHARED_AUTH_SPEC.md §4.2 for why the
    PBKDF2 mnemonic-to-seed algorithm is deliberately skipped).
    """
    if len(recovery_seed) != RECOVERY_SEED_LENGTH:
        raise ValueError(
            f"recovery_seed must be {RECOVERY_SEED_LENGTH} bytes, "
            f"got {len(recovery_seed)}"
        )
    _validate_thread_id(thread_id)
    info = _INFO_RECOVERY_TEMPLATE.format(thread_id=thread_id).encode("ascii")
    return _hkdf(recovery_seed, info, KEK_LENGTH)


# ── Realm encryption key (sync DEK → 64 B Realm key) ─────────────────

def derive_realm_key(
    sync_dek: bytes,
    *,
    thread_id: str = DEFAULT_THREAD_ID,
) -> bytes:
    """HKDF the 32-byte sync DEK into a 64-byte Realm encryption key.

    Hub doesn't currently run Realm – this lives here for cross-impl
    parity with CM031 so the test-vectors in SHARED_AUTH_SPEC.md §1.4
    can be cross-checked byte-for-byte.
    """
    if len(sync_dek) != DEK_LENGTH:
        raise ValueError(f"sync_dek must be {DEK_LENGTH} bytes, got {len(sync_dek)}")
    _validate_thread_id(thread_id)
    info = _INFO_REALM_TEMPLATE.format(thread_id=thread_id).encode("ascii")
    return _hkdf(sync_dek, info, REALM_KEY_LENGTH)


# ── BIP39 phrase handling ────────────────────────────────────────────
#
# Per SHARED_AUTH_SPEC.md §4.2: we use BIP39's native 128-bit entropy
# extraction, NOT its PBKDF2 mnemonic-to-seed derivation. The algorithm:
#
# 1. Validate the 12-word phrase against the English BIP39 wordlist +
#    checksum.
# 2. Concatenate the 11-bit indices of the 12 words → 132 bits total.
# 3. First 128 bits are the entropy; last 4 bits are the checksum
#    (must equal SHA256(entropy_bytes)[0] >> 4).
# 4. Return the 16-byte entropy as the `recovery_seed`.

_BIP39_WORDLIST_PATH = Path(__file__).parent / "bip39_english.txt"
_BIP39_WORDS: List[str] = []
_BIP39_WORD_TO_INDEX: dict = {}


def _load_bip39_wordlist() -> None:
    """Lazy-load the 2048-word BIP39 English wordlist."""
    global _BIP39_WORDS, _BIP39_WORD_TO_INDEX
    if _BIP39_WORDS:
        return
    if not _BIP39_WORDLIST_PATH.exists():
        raise FileNotFoundError(
            f"BIP39 wordlist missing at {_BIP39_WORDLIST_PATH}. "
            "This file ships with the ostler_security package."
        )
    words = _BIP39_WORDLIST_PATH.read_text(encoding="utf-8").split()
    if len(words) != 2048:
        raise ValueError(
            f"BIP39 wordlist must contain exactly 2048 words, "
            f"found {len(words)} at {_BIP39_WORDLIST_PATH}"
        )
    _BIP39_WORDS = words
    _BIP39_WORD_TO_INDEX = {w: i for i, w in enumerate(words)}


def bip39_wordlist_sha256() -> str:
    """SHA-256 of the loaded wordlist file (for cross-impl verification
    against the iOS Companion's copy)."""
    _load_bip39_wordlist()
    return hashlib.sha256(
        _BIP39_WORDLIST_PATH.read_bytes()
    ).hexdigest()


def normalise_bip39_phrase(raw: str) -> str:
    """Convert user input to canonical BIP39 form.

    Tolerant on input – strips surrounding whitespace, collapses
    internal whitespace to single spaces, lowercases, NFC-normalises
    Unicode, strips control characters. Does NOT validate against the
    wordlist; that's `bip39_phrase_to_seed()`'s job.

    Per Andy 2026-04-23: "be tolerant on input, strict on what gets
    fed to HKDF." Users paste with weird whitespace and mixed case;
    we canonicalise before validation so the error messages are about
    real wordlist mismatches rather than whitespace artefacts.
    """
    if not isinstance(raw, str):
        raise TypeError(f"BIP39 phrase must be str, got {type(raw).__name__}")
    # NFC normalisation, strip nulls + Cc/Cf control characters
    # (zero-width spaces, RTL marks, BOM) except common whitespace.
    s = unicodedata.normalize("NFC", raw)
    s = s.replace("\x00", "")
    s = "".join(
        c for c in s
        if unicodedata.category(c) not in ("Cc", "Cf")
        or c in ("\n", "\t", " ")
    )
    # Collapse all whitespace runs to a single space, strip ends,
    # lowercase.
    s = " ".join(s.split()).lower()
    return s


def bip39_phrase_to_seed(phrase: str) -> bytes:
    """Validate a 12-word BIP39 phrase and return its 16-byte native entropy.

    Raises ValueError on any validation failure: wrong word count,
    unknown word, checksum mismatch. The returned 16 bytes is the
    `recovery_seed` IKM for `derive_recovery_kek()`.
    """
    _load_bip39_wordlist()
    words = normalise_bip39_phrase(phrase).split()
    if len(words) != 12:
        raise ValueError(
            f"BIP39 phrase must be exactly 12 words, got {len(words)}"
        )
    unknown = [w for w in words if w not in _BIP39_WORD_TO_INDEX]
    if unknown:
        raise ValueError(
            f"BIP39 phrase contains words not in the English wordlist: "
            f"{unknown!r}"
        )

    # Concatenate 11-bit indices into 132 bits.
    bits = 0
    for w in words:
        bits = (bits << 11) | _BIP39_WORD_TO_INDEX[w]
    # 132 bits total: top 128 = entropy, bottom 4 = checksum.
    checksum = bits & 0b1111
    entropy_int = bits >> 4
    entropy = entropy_int.to_bytes(RECOVERY_SEED_LENGTH, "big")

    # Verify checksum = top 4 bits of SHA256(entropy).
    expected_checksum = hashlib.sha256(entropy).digest()[0] >> 4
    if checksum != expected_checksum:
        raise ValueError(
            "BIP39 phrase failed checksum validation – is the last "
            "word correct?"
        )
    return entropy


def generate_bip39_phrase() -> str:
    """Generate a fresh 12-word BIP39 phrase from 16 bytes of CSPRNG entropy.

    Used at setup time to give the user a recovery phrase to write down.
    """
    _load_bip39_wordlist()
    entropy = secrets.token_bytes(RECOVERY_SEED_LENGTH)
    # Checksum: top 4 bits of SHA256(entropy).
    checksum = hashlib.sha256(entropy).digest()[0] >> 4
    # Combine into 132-bit integer, entropy in high bits, checksum in low.
    combined = (int.from_bytes(entropy, "big") << 4) | checksum
    # Extract 12 × 11-bit indices, MSB first.
    words = []
    for i in range(11, -1, -1):
        idx = (combined >> (i * 11)) & 0b11111111111
        words.append(_BIP39_WORDS[idx])
    return " ".join(words)


# ── AES-KW wrap / unwrap (RFC 3394 unpadded, §2) ─────────────────────

def wrap_dek(dek: bytes, kek: bytes) -> bytes:
    """AES-KW (RFC 3394 unpadded) wrap the DEK with the KEK → 40 bytes.

    Deterministic: same (dek, kek) always produces the same bytes.
    The RFC 3394 fixed IV `A6A6A6A6A6A6A6A6` is implicit and checked
    on unwrap.
    """
    if len(dek) != DEK_LENGTH:
        raise ValueError(f"DEK must be {DEK_LENGTH} bytes, got {len(dek)}")
    if len(kek) != KEK_LENGTH:
        raise ValueError(f"KEK must be {KEK_LENGTH} bytes, got {len(kek)}")
    return aes_key_wrap(kek, dek)


def unwrap_dek(wrapped: bytes, kek: bytes) -> bytes:
    """Unwrap. Raises `InvalidUnwrap` if the wrapped bytes were produced
    with a different KEK or tampered with in storage."""
    if len(wrapped) != WRAPPED_DEK_LENGTH:
        raise ValueError(
            f"Wrapped DEK must be {WRAPPED_DEK_LENGTH} bytes, "
            f"got {len(wrapped)}"
        )
    if len(kek) != KEK_LENGTH:
        raise ValueError(f"KEK must be {KEK_LENGTH} bytes, got {len(kek)}")
    return aes_key_unwrap(kek, wrapped)
