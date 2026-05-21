"""Ostler Security – encryption, authentication, and audit logging.

Central security module used by all Ostler components (CM041, CM048,
the diagnostic service, the assistant API). Provides:

- Passphrase-based key derivation (PBKDF2)
- SQLCipher database connections (encrypted SQLite)
- Recovery key generation and validation
- FileVault status checking
- Audit log writing
- Diagnostic-service payload transparency

Usage:
    from ostler_security import get_db_connection, setup_passphrase

All functions are designed to work on macOS with Apple Silicon.
"""
from .passphrase import (
    change_passphrase,
    derive_key,
    derive_key_hex,
    generate_recovery_key,
    hash_passphrase,
    setup_passphrase,
    unlock,
    unlock_with_recovery_key,
    validate_passphrase_strength,
    verify_passphrase,
)
from .database import get_db_connection, migrate_to_encrypted
from .filevault import check_filevault_status
from .audit_log import AuditLog, log_event
from .rate_limiter import RateLimiter
from .auto_lock import AutoLock
from .payload_viewer import PayloadViewer, sanitise_payload
# Passkey auth (additive – doesn't replace the passphrase path yet;
# the setup_wizard rewire is gated on Andy's Touch ID smoke test).
from . import errors
from . import key_derivation
from . import keychain
from . import passkey
from . import recovery_cli
from . import webauthn_client

# A7+A8 (region-aware consent for Article 9, WhatsApp tickbox, EU
# voice gate). Pure stdlib – no extra deps – so always safe to import.
from . import consent
from . import region
