"""Passphrase management – key derivation, recovery keys, validation.

The user's passphrase is the root of all encryption in Ostler.
It derives the database encryption key via PBKDF2. The passphrase
itself is never stored – only a verification hash.

Security properties:
- PBKDF2 with 600,000 iterations (OWASP 2023 recommendation for SHA-256)
- 32-byte (256-bit) derived keys for AES-256
- 16-byte random salt per installation
- Recovery key: 24-character alphanumeric, shown once at setup
- Passphrase hash stored for verification (bcrypt-like: salt + hash)
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import string
import unicodedata
from pathlib import Path
from typing import Optional

from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes


# ── Configuration ────────────────────────────────────────────────────

PBKDF2_ITERATIONS = 600_000
KEY_LENGTH = 32  # 256 bits for AES-256
SALT_LENGTH = 16  # 128-bit salt
RECOVERY_KEY_LENGTH = 26  # 26 alphanumeric characters (>128 bits entropy)
MIN_PASSPHRASE_LENGTH = 16
MAX_PASSPHRASE_LENGTH = 1024  # BT10-2: cap to prevent CPU DoS via PBKDF2
MIN_DICEWARE_WORDS = 4

# Default paths (configurable via environment)
DEFAULT_CONFIG_DIR = Path.home() / ".ostler" / "security"


# ── Passphrase normalization ─────────────────────────────────────────


def _normalize_passphrase(passphrase: str) -> str:
    """Normalize a passphrase for consistent key derivation.

    BT10-1: Unicode NFC normalization prevents different byte representations
    of the same visual string (e.g. e + combining acute vs. precomposed e-acute)
    from producing different keys. Critical on macOS where input methods vary.

    BT10-3: Strips null bytes (C boundary truncation) and Unicode control
    characters (zero-width spaces, RTL marks) that are invisible but change
    the derived key.
    """
    # NFC normalization – canonical decomposition then canonical composition
    passphrase = unicodedata.normalize("NFC", passphrase)
    # Strip null bytes (C boundary safety)
    passphrase = passphrase.replace("\x00", "")
    # Strip Unicode control characters (Cc = control, Cf = format)
    passphrase = "".join(
        c for c in passphrase
        if unicodedata.category(c) not in ("Cc", "Cf")
        or c in ("\n", "\t", " ")  # preserve common whitespace
    )
    return passphrase


# ── Key derivation ───────────────────────────────────────────────────


def derive_key(passphrase: str, salt: bytes) -> bytes:
    """Derive a 256-bit encryption key from a passphrase using PBKDF2.

    Args:
        passphrase: The user's passphrase (plaintext).
        salt: A 16-byte random salt (unique per installation).

    Returns:
        32 bytes suitable for AES-256 encryption.
    """
    # BT10-1: normalize before encoding to prevent Unicode inconsistencies
    passphrase = _normalize_passphrase(passphrase)
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=KEY_LENGTH,
        salt=salt,
        iterations=PBKDF2_ITERATIONS,
    )
    return kdf.derive(passphrase.encode("utf-8"))


def derive_key_hex(passphrase: str, salt: bytes) -> str:
    """Derive key and return as hex string (for SQLCipher PRAGMA key)."""
    return derive_key(passphrase, salt).hex()


# ── Passphrase validation ────────────────────────────────────────────


def validate_passphrase_strength(passphrase: str) -> tuple[bool, str]:
    """Check if a passphrase meets minimum strength requirements.

    Returns:
        (is_valid, message) – message explains what's wrong if invalid.
    """
    # BT10-2: reject excessively long passphrases (CPU DoS via PBKDF2)
    if len(passphrase) > MAX_PASSPHRASE_LENGTH:
        return False, f"Passphrase too long (max {MAX_PASSPHRASE_LENGTH} characters)."

    # BT10-3: reject null bytes (C boundary truncation risk)
    if "\x00" in passphrase:
        return False, "Passphrase must not contain null bytes."

    # Reject whitespace-only
    if not passphrase.strip():
        return False, "Passphrase cannot be empty or whitespace-only."

    # Reject low-entropy character sets (e.g. "aaaaaaaaaaaaaaaa", "abcabcabcabc")
    if len(set(passphrase)) <= 4:
        return False, "Passphrase is too simple – uses too few distinct characters (minimum 5)."

    # Reject sequential patterns (abc..., 123..., any starting point)
    lower = passphrase.lower()
    _is_sequential_alpha = all(
        ord(lower[i]) == ord(lower[i-1]) + 1
        for i in range(1, len(lower))
    ) if len(lower) >= MIN_PASSPHRASE_LENGTH and lower.isalpha() else False
    _is_sequential_num = all(
        lower[i] == str((int(lower[i-1]) + 1) % 10)
        for i in range(1, len(lower))
    ) if len(lower) >= MIN_PASSPHRASE_LENGTH and lower.isdigit() else False
    if _is_sequential_alpha or _is_sequential_num:
        return False, "Passphrase is a sequential pattern."

    # Reject common keyboard walks
    _KEYBOARD_WALKS = {
        "qwertyuiopasdfgh", "qwertyuiop123456", "1234567890abcdef",
        "abcdefghijklmnop", "asdfghjklzxcvbnm", "zxcvbnmasdfghjkl",
    }
    if lower in _KEYBOARD_WALKS or lower in _WEAK_PASSPHRASES:
        return False, "This passphrase is too common or predictable."

    # BT8-10: reject repeated-word passphrases ("test test test test")
    words = passphrase.strip().split()
    if len(words) >= 2 and len(set(w.lower() for w in words)) == 1:
        return False, "Passphrase must not repeat the same word."

    # BT8-10 + BT9-2: reject substring repetition ("abcdabcdabcdabcd", "HelloHelloHelloH")
    # Check ALL pattern lengths – a repeated pattern is weak regardless of char diversity
    for pattern_len in range(2, len(passphrase) // 2 + 1):
        pattern = passphrase[:pattern_len]
        repeats = len(passphrase) // pattern_len
        if repeats >= 3 and pattern * repeats == passphrase[:pattern_len * repeats]:
            return False, "Passphrase is a repeating pattern."

    # Check total length first – any passphrase >= 16 chars is accepted
    if len(passphrase) >= MIN_PASSPHRASE_LENGTH:
        return True, "Passphrase meets requirements."

    # Short passphrase – check if it's a diceware phrase (4+ words, each 4+ chars)
    words = passphrase.strip().split()
    if len(words) >= MIN_DICEWARE_WORDS:
        short_words = [w for w in words if len(w) < 4]
        if short_words:
            return False, (
                f"Diceware words must be at least 4 characters each. "
                f"'{short_words[0]}' is too short."
            )
        return True, "Diceware passphrase accepted."

    # Too short and not enough words
    if len(passphrase) < MIN_PASSPHRASE_LENGTH:
        return False, (
            f"Passphrase must be at least {MIN_PASSPHRASE_LENGTH} characters, "
            f"or a phrase of {MIN_DICEWARE_WORDS}+ words. "
            f"Current length: {len(passphrase)}."
        )

    return False, (
        f"Passphrase must be at least {MIN_PASSPHRASE_LENGTH} characters, "
        f"or a phrase of {MIN_DICEWARE_WORDS}+ words. "
        f"Current length: {len(passphrase)}."
    )


_WEAK_PASSPHRASES = {
    "1234567890123456",
    "abcdefghijklmnop",
    "passwordpassword",
    "changemechangeme",
    "pleaseletmeinplease",
}


# ── Passphrase storage (verification hash only) ─────────────────────


def hash_passphrase(passphrase: str) -> dict:
    """Create a verification hash for the passphrase.

    This is NOT the encryption key – it's a separate hash used only
    to verify the user entered the correct passphrase at startup.
    The actual encryption key is derived separately via derive_key().

    Returns a dict with salt (hex) and hash (hex) for storage.
    """
    # BT10-1: normalize before hashing
    passphrase = _normalize_passphrase(passphrase)
    verify_salt = os.urandom(SALT_LENGTH)
    verify_hash = hashlib.pbkdf2_hmac(
        "sha256",
        passphrase.encode("utf-8"),
        verify_salt,
        iterations=PBKDF2_ITERATIONS,
    )
    return {
        "salt": verify_salt.hex(),
        "hash": verify_hash.hex(),
        "iterations": PBKDF2_ITERATIONS,
        "algorithm": "pbkdf2_sha256",
    }


def verify_passphrase(passphrase: str, stored: dict) -> bool:
    """Verify a passphrase against its stored hash.

    Args:
        passphrase: The passphrase to check.
        stored: Dict with salt, hash, iterations from hash_passphrase().

    Returns:
        True if the passphrase matches.
    """
    # BT10-1: normalize before verifying
    passphrase = _normalize_passphrase(passphrase)
    verify_salt = bytes.fromhex(stored["salt"])
    iterations = stored.get("iterations", PBKDF2_ITERATIONS)
    expected_hash = bytes.fromhex(stored["hash"])

    actual_hash = hashlib.pbkdf2_hmac(
        "sha256",
        passphrase.encode("utf-8"),
        verify_salt,
        iterations=iterations,
    )
    # Constant-time comparison to prevent timing attacks
    return secrets.compare_digest(actual_hash, expected_hash)


# ── Recovery key ─────────────────────────────────────────────────────


def generate_recovery_key() -> str:
    """Generate a 24-character alphanumeric recovery key.

    This key can decrypt the database independently of the passphrase.
    It is shown to the user ONCE at setup and must be stored safely.

    Format: XXXX-XXXX-XXXX-XXXX-XXXX-XXXX (groups of 4 for readability)
    """
    chars = string.ascii_uppercase + string.digits
    # Remove ambiguous characters (0/O, 1/I/L)
    chars = chars.replace("0", "").replace("O", "").replace("1", "").replace("I", "").replace("L", "")
    raw = "".join(secrets.choice(chars) for _ in range(RECOVERY_KEY_LENGTH))
    # Format as groups of 4
    groups = [raw[i:i+4] for i in range(0, len(raw), 4)]
    return "-".join(groups)


# ── Setup flow ───────────────────────────────────────────────────────


def setup_passphrase(
    passphrase: str,
    config_dir: Optional[Path] = None,
) -> dict:
    """Complete first-run passphrase setup.

    1. Validates passphrase strength
    2. Generates encryption salt
    3. Derives encryption key
    4. Generates recovery key
    5. Stores verification hash + salt (NOT the key or passphrase)

    Args:
        passphrase: The user's chosen passphrase.
        config_dir: Where to store security config. Default: ~/.ostler/security/

    Returns:
        Dict with recovery_key (SHOW TO USER ONCE) and config_path.

    Raises:
        ValueError: If passphrase is too weak.
    """
    is_valid, message = validate_passphrase_strength(passphrase)
    if not is_valid:
        raise ValueError(message)

    config_dir = config_dir or DEFAULT_CONFIG_DIR
    config_dir.mkdir(parents=True, exist_ok=True)
    # BT9-1: set directory permissions BEFORE writing any files
    config_dir.chmod(0o700)

    # BT10-7: file-level locking to prevent concurrent setup_passphrase
    import fcntl
    lock_path = config_dir / ".keychain.lock"
    lock_fd = open(str(lock_path), "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except IOError:
        lock_fd.close()
        raise ValueError("Another setup is in progress. Try again.")

    try:
        return _setup_passphrase_locked(passphrase, config_dir)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()


def _setup_passphrase_locked(
    passphrase: str,
    config_dir: Path,
) -> dict:
    """Internal implementation of setup_passphrase, called under file lock."""

    # BT8-4/BT8-5: reject symlinks and prevent overwrite of existing config
    config_path_check = config_dir / "keychain.json"
    if config_path_check.is_symlink():
        raise ValueError(
            "Config path is a symlink – possible attack. Remove it manually."
        )
    if config_path_check.exists():
        raise ValueError(
            "Security config already exists. Use change_passphrase() to change "
            "your passphrase, or delete the config manually if you want to start over."
        )

    # Generate encryption salt (used for database key derivation)
    encryption_salt = os.urandom(SALT_LENGTH)

    # Generate recovery key
    recovery_key = generate_recovery_key()

    # Derive the encryption key from the recovery key too
    # (so either passphrase OR recovery key can unlock)
    recovery_salt = os.urandom(SALT_LENGTH)
    recovery_key_raw = recovery_key.replace("-", "")
    recovery_derived = derive_key(recovery_key_raw, recovery_salt)

    # Store a verification hash of the recovery key
    recovery_verification = hash_passphrase(recovery_key_raw)

    # Store verification hash (for passphrase check at startup)
    verification = hash_passphrase(passphrase)

    # Verify that both passphrase and recovery key derive the SAME
    # encryption key by storing the recovery-derived key encrypted
    # with itself (the recovery key re-derives the main key via XOR)
    # Actually, simpler: store the main encryption key encrypted with
    # the recovery-derived key. On recovery, derive recovery key →
    # decrypt → get main key.
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    main_key = derive_key(passphrase, encryption_salt)
    aesgcm = AESGCM(recovery_derived)
    nonce = os.urandom(12)
    # BT8-6: bind ciphertext to context via AAD (prevents cross-install transplant)
    aad = b"creativemachines/recovery-key-v3:" + encryption_salt
    encrypted_main_key = aesgcm.encrypt(nonce, main_key, aad)

    # Build config (stored on disk)
    config = {
        "version": 2,
        "encryption_salt": encryption_salt.hex(),
        "recovery_salt": recovery_salt.hex(),
        "recovery_verification": recovery_verification,
        "recovery_encrypted_key": {
            "nonce": nonce.hex(),
            "ciphertext": encrypted_main_key.hex(),
        },
        "verification": verification,
        "created_at": _now_iso(),
        "key_derivation": {
            "algorithm": "pbkdf2_sha256",
            "iterations": PBKDF2_ITERATIONS,
            "key_length": KEY_LENGTH,
        },
    }

    # HMAC the config to detect tampering (RT-2 fix)
    import hmac as _hmac
    config_bytes = json.dumps(config, sort_keys=True).encode("utf-8")
    config_hmac = _hmac.new(
        derive_key(passphrase, encryption_salt),
        config_bytes,
        hashlib.sha256,
    ).hexdigest()
    config["_hmac"] = config_hmac

    # Atomic write: write to temp file then rename (NF-6 fix)
    import tempfile as _tempfile
    config_path = config_dir / "keychain.json"

    # BT8-4: reject symlinks to prevent arbitrary file overwrite
    if config_path.is_symlink():
        raise ValueError(
            "Config path is a symlink – possible attack. Remove it manually."
        )

    tmp_fd, tmp_path = _tempfile.mkstemp(dir=str(config_dir), suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w") as f:
            json.dump(config, f, indent=2)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, str(config_path))
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise

    # BT10-4: don't return encryption_salt (consistent with BH-4/R7-3 –
    # crypto material should not be in return dicts that callers might log)
    return {
        "recovery_key": recovery_key,
        "config_path": str(config_path),
    }


def unlock(
    passphrase: str,
    config_dir: Optional[Path] = None,
) -> bytes:
    """Unlock Ostler by verifying passphrase and returning the encryption key.

    Args:
        passphrase: The user's passphrase.
        config_dir: Where security config is stored.

    Returns:
        The 32-byte encryption key for database access.

    Raises:
        ValueError: If passphrase is incorrect.
        FileNotFoundError: If setup hasn't been run.
    """
    config_dir = config_dir or DEFAULT_CONFIG_DIR
    config_path = config_dir / "keychain.json"

    # BT9-4: reject symlinks on read path too
    if config_path.is_symlink():
        raise ValueError(
            "Config path is a symlink – possible attack. Remove it manually."
        )

    if not config_path.exists():
        raise FileNotFoundError(
            "Ostler security not set up. Run the installer first."
        )

    config = json.loads(config_path.read_text())
    verification = config["verification"]

    if not verify_passphrase(passphrase, verification):
        raise ValueError("Incorrect passphrase.")

    encryption_salt = bytes.fromhex(config["encryption_salt"])
    key = derive_key(passphrase, encryption_salt)

    # AV-1 fix: reject any config version < 2. All production configs are v2+.
    # A v1 config has no HMAC protection, so accepting it would bypass all
    # integrity checks. Version downgrade = tampering.
    config_version = config.get("version", 1)
    if config_version < 2:
        raise ValueError(
            "Config version too old (v1). This may indicate tampering "
            "(version downgrade attack). Re-run security setup."
        )

    # Verify config integrity via HMAC
    # BT9-6: don't mutate config dict – extract HMAC and build clean copy
    stored_hmac = config.get("_hmac")
    if not stored_hmac:
        raise ValueError(
            "Security config integrity check missing (HMAC field absent). "
            "This config file may have been tampered with."
        )
    import hmac as _hmac
    config_without_hmac = {k: v for k, v in config.items() if k != "_hmac"}
    config_bytes = json.dumps(config_without_hmac, sort_keys=True).encode("utf-8")
    expected_hmac = _hmac.new(key, config_bytes, hashlib.sha256).hexdigest()
    if not secrets.compare_digest(stored_hmac, expected_hmac):
        raise ValueError(
            "Security config has been tampered with. The encryption salt "
            "may have been modified. Do NOT continue – your data could be "
            "corrupted. Use your recovery key to unlock instead."
        )

    return key


def unlock_with_recovery_key(
    recovery_key: str,
    config_dir: Optional[Path] = None,
) -> bytes:
    """Unlock Ostler using the recovery key instead of the passphrase.

    The recovery key decrypts a copy of the main encryption key that
    was stored during setup. This allows data recovery when the
    passphrase is forgotten.

    Args:
        recovery_key: The recovery key (format: XXXX-XXXX-XXXX-XXXX-XXXX-XXXX).
        config_dir: Where security config is stored.

    Returns:
        The 32-byte encryption key for database access.

    Raises:
        ValueError: If recovery key is incorrect or config is v1 (no recovery support).
        FileNotFoundError: If setup hasn't been run.
    """
    config_dir = config_dir or DEFAULT_CONFIG_DIR
    config_path = config_dir / "keychain.json"

    # BT9-4: reject symlinks on read path too
    if config_path.is_symlink():
        raise ValueError(
            "Config path is a symlink – possible attack. Remove it manually."
        )

    if not config_path.exists():
        raise FileNotFoundError(
            "Ostler security not set up. Run the installer first."
        )

    config = json.loads(config_path.read_text())

    # AV-1 fix: reject v1 configs (version downgrade = tampering)
    if config.get("version", 1) < 2:
        raise ValueError(
            "Config version too old (v1). This may indicate tampering "
            "(version downgrade attack). Re-run security setup."
        )

    # BH-2 fix: verify HMAC before trusting any config field
    # BT9-6: don't mutate config dict
    stored_hmac = config.get("_hmac")
    if not stored_hmac:
        raise ValueError(
            "Config integrity check missing (HMAC absent). "
            "This config file may have been tampered with."
        )
    # We can't verify HMAC without the main key, which we're trying to
    # recover. BUT we CAN verify it AFTER decryption – if the decrypted
    # key doesn't produce a matching HMAC, the config was tampered with.
    # Store config bytes for post-decryption verification.
    config_without_hmac = {k: v for k, v in config.items() if k != "_hmac"}
    config_bytes_for_hmac = json.dumps(config_without_hmac, sort_keys=True).encode("utf-8")
    stored_hmac_value = stored_hmac

    # Verify recovery key
    recovery_verification = config.get("recovery_verification")
    if not recovery_verification:
        raise ValueError("No recovery key configured.")

    recovery_key_raw = recovery_key.replace("-", "")
    if not verify_passphrase(recovery_key_raw, recovery_verification):
        raise ValueError("Incorrect recovery key.")

    # Derive the recovery encryption key
    recovery_salt = bytes.fromhex(config["recovery_salt"])
    recovery_derived = derive_key(recovery_key_raw, recovery_salt)

    # Decrypt the main encryption key
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    encrypted_data = config["recovery_encrypted_key"]
    nonce = bytes.fromhex(encrypted_data["nonce"])
    ciphertext = bytes.fromhex(encrypted_data["ciphertext"])

    aesgcm = AESGCM(recovery_derived)
    try:
        # BT8-6: use AAD to bind ciphertext to this installation's salt
        encryption_salt = bytes.fromhex(config["encryption_salt"])
        aad = b"creativemachines/recovery-key-v3:" + encryption_salt
        main_key = aesgcm.decrypt(nonce, ciphertext, aad)
    except Exception:
        # BT8-7: generic error message – don't leak crypto internals
        raise ValueError("Recovery key decryption failed. The key may be incorrect.")

    # BH-2 fix: post-decryption HMAC verification.
    # Now that we have the main key, verify the config HMAC to detect tampering.
    import hmac as _hmac
    expected_hmac = _hmac.new(
        main_key, config_bytes_for_hmac, hashlib.sha256
    ).hexdigest()
    if not secrets.compare_digest(stored_hmac_value, expected_hmac):
        raise ValueError(
            "Config integrity check failed after recovery. The config file "
            "may have been tampered with. The decrypted key does not match "
            "the stored HMAC."
        )

    return main_key


def change_passphrase(
    old_passphrase: str,
    new_passphrase: str,
    recovery_key: str,
    config_dir: Optional[Path] = None,
) -> dict:
    """Change the passphrase. Requires the recovery key to re-encrypt
    the recovery blob with the new main key.

    Args:
        old_passphrase: Current passphrase (must be correct).
        new_passphrase: New passphrase (must pass validation).
        recovery_key: The recovery key (needed to re-encrypt the blob).
        config_dir: Where security config is stored.

    Returns:
        Dict with config_path and new_key.

    Raises:
        ValueError: If old passphrase is wrong, recovery key is wrong,
            or new passphrase is weak.
    """
    config_dir = config_dir or DEFAULT_CONFIG_DIR
    config_path = config_dir / "keychain.json"

    if not config_path.exists():
        raise FileNotFoundError("Ostler security not set up.")

    # AV-4 fix: file-level locking to prevent concurrent change_passphrase
    import fcntl
    lock_path = config_dir / ".keychain.lock"
    lock_fd = open(str(lock_path), "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except IOError:
        lock_fd.close()
        raise ValueError("Another passphrase change is in progress. Try again.")

    try:
        return _change_passphrase_locked(
            old_passphrase, new_passphrase, recovery_key, config_dir, config_path
        )
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()


def _change_passphrase_locked(
    old_passphrase: str,
    new_passphrase: str,
    recovery_key: str,
    config_dir: Path,
    config_path: Path,
) -> dict:
    """Internal implementation of change_passphrase, called under file lock."""

    # BT9R3-2: symlink check on read path (consistency with unlock/recovery)
    if config_path.is_symlink():
        raise ValueError(
            "Config path is a symlink – possible attack. Remove it manually."
        )

    # BH-1 fix: load config ONCE, validate, use same copy throughout.
    config = json.loads(config_path.read_text())

    # R7-1 fix: reject version downgrade (same check as unlock)
    if config.get("version", 1) < 2:
        raise ValueError(
            "Config version too old (v1). This may indicate tampering."
        )

    # Verify HMAC on this config copy
    # BT9-6: don't mutate config dict
    stored_hmac = config.get("_hmac")
    if not stored_hmac:
        raise ValueError("Config integrity check missing (HMAC absent).")
    encryption_salt_old = bytes.fromhex(config["encryption_salt"])
    old_key = derive_key(old_passphrase, encryption_salt_old)

    import hmac as _hmac
    config_without_hmac = {k: v for k, v in config.items() if k != "_hmac"}
    config_bytes = json.dumps(config_without_hmac, sort_keys=True).encode("utf-8")
    expected_hmac = _hmac.new(old_key, config_bytes, hashlib.sha256).hexdigest()
    if not secrets.compare_digest(stored_hmac, expected_hmac):
        raise ValueError("Config has been tampered with.")
    # Passphrase implicitly verified by HMAC check above (wrong key = wrong HMAC).

    # Verify recovery key
    recovery_verification = config.get("recovery_verification")
    if not recovery_verification:
        raise ValueError("No recovery key configured.")
    recovery_key_raw = recovery_key.replace("-", "")
    if not verify_passphrase(recovery_key_raw, recovery_verification):
        raise ValueError("Incorrect recovery key.")

    # Validate new passphrase
    is_valid, message = validate_passphrase_strength(new_passphrase)
    if not is_valid:
        raise ValueError(message)

    # Generate new encryption salt and derive new key
    new_encryption_salt = os.urandom(SALT_LENGTH)
    new_key = derive_key(new_passphrase, new_encryption_salt)

    # Re-encrypt the NEW main key with the recovery-derived key
    recovery_salt = bytes.fromhex(config["recovery_salt"])
    recovery_key_raw = recovery_key.replace("-", "")
    recovery_derived = derive_key(recovery_key_raw, recovery_salt)

    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    aesgcm = AESGCM(recovery_derived)
    nonce = os.urandom(12)
    # BT8-6: bind to new salt via AAD
    aad = b"creativemachines/recovery-key-v3:" + new_encryption_salt
    encrypted_new_key = aesgcm.encrypt(nonce, new_key, aad)

    # Update config
    config["encryption_salt"] = new_encryption_salt.hex()
    config["verification"] = hash_passphrase(new_passphrase)
    config["recovery_encrypted_key"] = {
        "nonce": nonce.hex(),
        "ciphertext": encrypted_new_key.hex(),
    }

    # Re-HMAC the config with the new key (exclude old _hmac from computation)
    import hmac as _hmac
    config_for_hmac = {k: v for k, v in config.items() if k != "_hmac"}
    config_bytes = json.dumps(config_for_hmac, sort_keys=True).encode("utf-8")
    config["_hmac"] = _hmac.new(
        new_key, config_bytes, hashlib.sha256,
    ).hexdigest()

    # BT8-4: reject symlinks before writing
    if config_path.is_symlink():
        raise ValueError(
            "Config path is a symlink – possible attack. Remove it manually."
        )

    # Atomic write: write to temp file then rename (NF-6 fix)
    import tempfile
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=str(config_dir), suffix=".tmp"
    )
    try:
        with os.fdopen(tmp_fd, "w") as f:
            json.dump(config, f, indent=2)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, str(config_path))
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise

    try:
        from .audit_log import AuditLog, EVENT_PASSPHRASE_CHANGE
        audit = AuditLog(config_dir / "audit.db")
        audit.log(EVENT_PASSPHRASE_CHANGE, source="change_passphrase")
    except Exception:
        pass  # Audit log failure should not block passphrase change

    # R7-3: don't return key in dict (same principle as BH-4)
    return {
        "config_path": str(config_path),
        "changed": True,
    }


def _now_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()
