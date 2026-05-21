"""Encrypted database connections using SQLCipher.

Provides a drop-in replacement for sqlite3.connect() that
transparently encrypts the database with the user's derived key.

Usage:
    from ostler_security.database import get_db_connection

    conn = get_db_connection("/path/to/coach.db", encryption_key_hex)
    conn.execute("SELECT * FROM observations")

Migration:
    migrate_to_encrypted() converts an existing plaintext SQLite
    database to an encrypted one without data loss.
"""
from __future__ import annotations

import logging
import re
import shutil
import sqlite3
import tempfile
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

# Try to import SQLCipher; fall back to plain sqlite3 with a warning
try:
    from pysqlcipher3 import dbapi2 as sqlcipher
    HAS_SQLCIPHER = True
except ImportError:
    sqlcipher = None  # type: ignore
    HAS_SQLCIPHER = False
    logger.warning(
        "pysqlcipher3 not installed. Databases will NOT be encrypted. "
        "Install with: pip install pysqlcipher3"
    )


def get_db_connection(
    db_path: str | Path,
    encryption_key_hex: Optional[str] = None,
) -> sqlite3.Connection:
    """Open a database connection, encrypted if key is provided.

    Args:
        db_path: Path to the SQLite database file.
        encryption_key_hex: Hex-encoded 256-bit key from passphrase.derive_key_hex().
            If None, opens without encryption (plain sqlite3).

    Returns:
        A database connection (sqlite3.Connection compatible).
        For SQLCipher connections, the PRAGMA key has already been set.
    """
    db_path = str(db_path)

    if encryption_key_hex and HAS_SQLCIPHER:
        # BT8-1: validate hex key format to prevent PRAGMA injection
        if not re.fullmatch(r'[0-9a-f]{64}', encryption_key_hex):
            raise ValueError(
                "Invalid encryption key format: must be exactly 64 hex characters"
            )
        conn = sqlcipher.connect(db_path)
        # Set the encryption key. SQLCipher expects the key as a hex blob.
        conn.execute(f"PRAGMA key = \"x'{encryption_key_hex}'\"")
        # Verify the key works by reading the database
        try:
            conn.execute("SELECT count(*) FROM sqlite_master")
        except Exception:
            conn.close()
            raise ValueError(
                "Failed to open encrypted database. Wrong passphrase?"
            )
        return conn

    if encryption_key_hex and not HAS_SQLCIPHER:
        # Caller supplied a key, which means they expect encryption.
        # Silently degrading to plaintext is the silent-fallback
        # pattern the 2026-04-28 fixes removed from CM048 and the
        # other two downstream services -- propagating the same
        # discipline here so the security boundary holds even when
        # ostler_security itself is the package missing pysqlcipher3.
        # If the operator genuinely wants plaintext, they should call
        # this function with encryption_key_hex=None.
        raise RuntimeError(
            f"pysqlcipher3 is not installed but an encryption key was "
            f"provided for {db_path!r}. Refusing to open the database "
            f"in plaintext mode -- this would silently leak encrypted-"
            f"-at-rest expectations. Install with: "
            f"pip install pysqlcipher3, or call get_db_connection "
            f"without an encryption_key_hex if plaintext is intentional."
        )

    return sqlite3.connect(db_path)


def migrate_to_encrypted(
    db_path: str | Path,
    encryption_key_hex: str,
    backup: bool = True,
) -> bool:
    """Migrate a plaintext SQLite database to SQLCipher encryption.

    The migration process:
    1. Open the plaintext database with sqlite3
    2. Create a new encrypted database with SQLCipher
    3. Copy all data using sqlcipher_export
    4. Replace the original with the encrypted version

    Args:
        db_path: Path to the existing plaintext database.
        encryption_key_hex: The encryption key to use.
        backup: If True, keep a .bak copy of the original.

    Returns:
        True if migration succeeded, False if skipped (already encrypted
        or SQLCipher not available).
    """
    if not HAS_SQLCIPHER:
        logger.error("Cannot migrate: pysqlcipher3 not installed")
        return False

    db_path = Path(db_path)
    if not db_path.exists():
        logger.info("Database %s does not exist yet, skipping migration", db_path)
        return False

    # Check if already encrypted by trying to open with plain sqlite3
    try:
        test_conn = sqlite3.connect(str(db_path))
        test_conn.execute("SELECT count(*) FROM sqlite_master")
        test_conn.close()
    except sqlite3.DatabaseError:
        logger.info("Database %s appears already encrypted, skipping", db_path)
        return False

    logger.info("Migrating %s to encrypted format...", db_path)

    # Create encrypted copy
    encrypted_path = db_path.with_suffix(".encrypted")

    try:
        # Use plain sqlite3 to read the source, then create an encrypted
        # copy via SQLCipher. We can't open a plaintext DB with sqlcipher
        # using an empty key – instead we create the encrypted DB first,
        # then dump/load the data.

        # Step 1: Dump all SQL from plaintext DB
        plain_conn = sqlite3.connect(str(db_path))
        sql_dump = list(plain_conn.iterdump())
        plain_conn.close()

        # Step 2: Create encrypted DB and replay the dump
        # BT8-1: validate hex key format in migration path too
        if not re.fullmatch(r'[0-9a-f]{64}', encryption_key_hex):
            raise ValueError(
                "Invalid encryption key format: must be exactly 64 hex characters"
            )

        enc_conn = sqlcipher.connect(str(encrypted_path))
        enc_conn.execute(f"PRAGMA key = \"x'{encryption_key_hex}'\"")
        # iterdump() emits BEGIN/COMMIT – use executescript which handles them
        enc_conn.executescript(";\n".join(sql_dump))
        enc_conn.close()

        # Verify the encrypted database
        verify_conn = sqlcipher.connect(str(encrypted_path))
        verify_conn.execute(f"PRAGMA key = \"x'{encryption_key_hex}'\"")
        count = verify_conn.execute(
            "SELECT count(*) FROM sqlite_master"
        ).fetchone()[0]
        verify_conn.close()
        logger.info("Encrypted database verified: %d tables/indexes", count)

        # Backup original (temporary – deleted after verification)
        backup_path = db_path.with_suffix(".db.plaintext.bak")
        if backup:
            shutil.copy2(str(db_path), str(backup_path))
            logger.info("Temporary backup at %s", backup_path)

        # Replace original with encrypted version
        encrypted_path.replace(db_path)
        logger.info("Migration complete: %s is now encrypted", db_path)

        # Securely delete the plaintext backup (RT-5 fix)
        if backup and backup_path.exists():
            # Overwrite with zeros before deleting
            size = backup_path.stat().st_size
            with open(str(backup_path), "wb") as f:
                f.write(b"\x00" * size)
            backup_path.unlink()
            logger.info("Plaintext backup securely deleted")

        return True

    except Exception as exc:
        logger.error("Migration failed: %s", exc)
        # Clean up partial encrypted file
        if encrypted_path.exists():
            encrypted_path.unlink()
        raise
