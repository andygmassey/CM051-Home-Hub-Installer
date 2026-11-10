"""Resolve the database encryption key for a headless Ostler service.

WHY THIS FILE EXISTS
====================

``install.sh`` mints a DEK at Phase 3.6 and every service that opens an
encrypted database read it from ONE place: the ``OSTLER_DB_KEY``
environment variable.

Measured on this tree before this module landed, with a positive control
on the same search shape:

    OSTLER_DB_KEY        17 mentions, 3 readers, 0 setters
    OSTLER_AI_CONVERSATIONS_DIR / OSTLER_AI_CONV_GIST_PRIVACY
                         set in a rendered plist by the same query

So the setter query works, and nothing set the key. Nothing in any
plist, no export, no ``launchctl setenv``. Both services therefore took
their plaintext fallback on every install ever shipped, while the
installer printed a line saying the databases were encrypted.

WHY NOT PUT THE KEY IN THE PLIST
================================

The obvious repair is an ``EnvironmentVariables`` entry in
``~/Library/LaunchAgents/com.ostler.ical-server.plist``. It is the wrong
one, and the reason is written down in this repo already:

``SECURITY_MODEL.md``, beside this file, lists "Time-Machine backup
theft" as a threat the product DEFENDS AGAINST, and names the defence:
the wrapped DEK is pinned to ``kSecAttrAccessibleWhenUnlockedThisDeviceOnly``
so "it doesn't travel in backups". ``install.sh`` pays for that property
at the recovery-key save site, shelling out to swift purely because the
``security`` CLI cannot set that attribute.

``~/Library/LaunchAgents`` is backed up by Time Machine by default. A DEK
in a plist there would put the unwrapped key into every backup, beside a
copy of the database it opens, and silently delete a defence the security
model claims. That is a worse outcome than the bug being fixed.

Two further reasons, both about surfaces that are not the filesystem:

  * ``launchctl print gui/<uid>/<label>`` renders ``EnvironmentVariables``
    in full. That is a command people run while debugging and paste into
    support threads. A path is safe to paste. A key is not.
  * The installer's own log-hygiene gates exist because rendered config
    ends up in diagnostics. A file path survives that; a key does not.

WHAT THIS DOES INSTEAD
======================

The key file lives in the directory ``install.sh`` already creates and
locks down for exactly this class of material: ``${OSTLER_DIR}/security``,
mode 0700, alongside ``keychain.json`` at 0600. The plist carries the
PATH (``OSTLER_DB_KEY_FILE``), never the value.

BE HONEST ABOUT WHAT THIS BUYS AND WHAT IT DOES NOT
===================================================

A DEK at rest in a 0600 file is not the endgame posture. Anything running
as the customer's own user can read it, so the passphrase stops being a
gate against that attacker once the file exists. What it IS:

  * strictly better than what ships today, which is no key at all and
    therefore plaintext databases;
  * still closed against a second local account on the same Mac (0700
    directory, 0600 file, both asserted below rather than assumed);
  * still closed against a stolen Time Machine backup, because
    ``install.sh`` excludes the file with ``tmutil addexclusion`` at the
    write site;
  * still resting on FileVault for device theft, which is the boundary
    SECURITY_MODEL.md already names for at-rest data.

The endgame is an interactive unlock at login (or a Keychain item with an
ACL that names the service binary) so the key never sits on disk at all.
That is a product decision with a UX cost, not something to improvise
inside a bug fix, and it is NOT what this module implements. Nothing here
should be read as a claim that it is.

FAIL CLOSED ON THE FILE, PASS THROUGH ON THE ENV
================================================

A key file that is group- or world-readable defeats the only property
that makes this acceptable, so it is REFUSED rather than read, and the
refusal names the mode it saw. The caller gets ``None`` plus a machine
readable reason, so its warning can say "a key file exists and I would
not read it" instead of "no key set" -- two conditions that must never
print identically.

The ``OSTLER_DB_KEY`` environment path is passed through EXACTLY as it
behaves today, unvalidated. It is the documented interface of
``ostler-migrate-dbs`` and of every test harness in the estate, and
tightening it here would be a silent behaviour change riding along in an
unrelated fix.
"""
from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
from pathlib import Path
from typing import NamedTuple, Optional


# Source labels. These flow into posture.py's `key_source` field, whose
# docstring already names "OSTLER_DB_KEY" as the recommended value; this
# adds the second one rather than replacing it.
SOURCE_ENV = "OSTLER_DB_KEY"
SOURCE_KEY_FILE = "OSTLER_DB_KEY_FILE"
SOURCE_KEYCHAIN = "keychain"

# Reasons. These flow into posture.py's `reason` field when no key could
# be used. "no_key" is the pre-existing value and keeps its meaning:
# nothing was configured at all. The rest are new and each one means a key
# WAS configured and was deliberately not used.
REASON_NO_KEY = "no_key"
REASON_KEY_FILE_UNSAFE_MODE = "key_file_unsafe_mode"
REASON_KEY_FILE_UNSAFE_DIR = "key_file_unsafe_dir"
REASON_KEY_FILE_SYMLINK = "key_file_symlink"
REASON_KEY_FILE_MALFORMED = "key_file_malformed"
REASON_KEY_FILE_UNREADABLE = "key_file_unreadable"
REASON_KEYCHAIN_UNAVAILABLE = "keychain_unavailable"
REASON_KEYCHAIN_MALFORMED = "keychain_malformed"

# 32 bytes, hex encoded. Matches what ostler-migrate-dbs documents and
# what passphrase.derive_key().hex() produces.
_HEX_KEY_RE = re.compile(r"\A[0-9a-fA-F]{64}\Z")

DEFAULT_KEY_FILE_NAME = "db_key"


class DbKey(NamedTuple):
    """The outcome of one key resolution.

    key      the key as the services want it (hex string), or None
    source   which mechanism supplied it, or None
    reason   why there is no key, or None when there is one
    detail   human-readable specifics for the service's warning; None
             when there is nothing extra to say
    """

    key: Optional[str]
    source: Optional[str]
    reason: Optional[str]
    detail: Optional[str]


def default_key_file() -> Path:
    """Where install.sh writes the key file.

    Honours OSTLER_HOME the same way posture.py does, so a test or a
    non-default install home moves both together.
    """
    base = Path(os.environ.get("OSTLER_HOME", os.path.expanduser("~/.ostler")))
    return base / "security" / DEFAULT_KEY_FILE_NAME


def key_file_path() -> Path:
    """The key file this process will look at.

    OSTLER_DB_KEY_FILE wins so the plist can point at a non-default
    install home without this module having to re-derive it.
    """
    override = os.environ.get("OSTLER_DB_KEY_FILE")
    if override:
        return Path(override)
    return default_key_file()


# ---------------------------------------------------------------------------
# KEYCHAIN (v1.0.129). The key no longer rests as hex in a file.
#
# The login Keychain holds it under service "Ostler DB Key". The file
# (~/.ostler/security/db_key) is now ONLY a migration source: the first
# resolve that finds it and no Keychain item moves it, reads it back, and
# deletes the file. What this buys, and nothing more: the key is not a
# plaintext file in the home folder or in a copy of it. It is NOT a gate
# against another process running as the same user (it can ask `security`
# for the item too), and the boundary for a stolen Mac stays FileVault.
#
# The Keychain is reached through /usr/bin/security, not a framework, so
# the same code runs from a LaunchAgent (measured: a gui/<uid> agent reads
# an item written by `security -i`) and the key never appears in argv: the
# write goes in on stdin via `security -i`.
#
# Isolation: the Keychain is consulted only for the DEFAULT install home. An
# explicit OSTLER_DB_KEY_FILE, or a non-default OSTLER_HOME, keeps the old
# file-only behaviour so a test or a one-off run can never read, overwrite or
# delete the real item. OSTLER_DB_KEY_KEYCHAIN_SERVICE opts a harness back in
# under a service name of its own.
# ---------------------------------------------------------------------------
KEYCHAIN_SERVICE_DEFAULT = "Ostler DB Key"
KEYCHAIN_ACCOUNT = "ostler-db-key"
_SECURITY_BIN = "/usr/bin/security"
_KEYCHAIN_NOT_FOUND_RC = 44  # errSecItemNotFound, as exit status


def keychain_service() -> str:
    return os.environ.get("OSTLER_DB_KEY_KEYCHAIN_SERVICE") or KEYCHAIN_SERVICE_DEFAULT


def keychain_available() -> bool:
    """True when the macOS `security` tool exists on this host."""
    return os.path.exists(_SECURITY_BIN)


def keychain_enabled() -> bool:
    """Whether this process should use the Keychain for the DB key."""
    if not keychain_available():
        return False
    if os.environ.get("OSTLER_DB_KEY_KEYCHAIN_SERVICE"):
        return True
    if os.environ.get("OSTLER_DB_KEY_FILE") or os.environ.get("OSTLER_HOME"):
        return False
    return True


def read_keychain_key() -> DbKey:
    """Read the key from the login Keychain. Never raises.

    "No item" is REASON_NO_KEY (the caller may then migrate the file).
    Anything else that stops the read (locked keychain, no session, a
    value that is not 64 hex) is REASON_KEYCHAIN_UNAVAILABLE or
    REASON_KEYCHAIN_MALFORMED, and the caller must NOT fall through to
    plaintext on it.
    """
    try:
        proc = subprocess.run(
            [_SECURITY_BIN, "find-generic-password",
             "-s", keychain_service(), "-a", KEYCHAIN_ACCOUNT, "-w"],
            capture_output=True, text=True, timeout=20,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return DbKey(None, None, REASON_KEYCHAIN_UNAVAILABLE,
                     f"could not run security: {exc.__class__.__name__}")
    if proc.returncode == _KEYCHAIN_NOT_FOUND_RC:
        return DbKey(None, None, REASON_NO_KEY, None)
    if proc.returncode != 0:
        return DbKey(None, None, REASON_KEYCHAIN_UNAVAILABLE,
                     f"security exited {proc.returncode}: "
                     f"{(proc.stderr or '').strip()[:160]}")
    raw = (proc.stdout or "").strip()
    if not _HEX_KEY_RE.match(raw):
        return DbKey(None, None, REASON_KEYCHAIN_MALFORMED,
                     f"the Keychain item is not 64 hex characters ({len(raw)})")
    return DbKey(raw.lower(), SOURCE_KEYCHAIN, None,
                 f'Keychain item "{keychain_service()}"')


def write_keychain_key(key_hex: str) -> None:
    """Store the key in the login Keychain and read it back.

    Raises OSError if the write fails or the read-back does not match. The
    key travels on stdin to `security -i`, never in argv.
    """
    if not _HEX_KEY_RE.match(key_hex or ""):
        raise OSError("refusing to store a key that is not 64 hex characters")
    if not keychain_available():
        raise OSError("the macOS security tool is not present")
    cmd = (f'add-generic-password -U -s "{keychain_service()}" '
           f'-a "{KEYCHAIN_ACCOUNT}" -w {key_hex.lower()}\n')
    try:
        proc = subprocess.run([_SECURITY_BIN, "-i"], input=cmd,
                              capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as exc:
        raise OSError(f"could not run security: {exc.__class__.__name__}")
    back = read_keychain_key()
    if back.key != key_hex.lower():
        raise OSError(
            f"Keychain write did not verify (rc={proc.returncode}, "
            f"read-back: {back.reason or 'mismatch'})"
        )


def migrate_key_file_to_keychain(path: Path) -> DbKey:
    """Move the key file's key into the Keychain, then delete the file.

    The file is deleted ONLY after the Keychain read-back matched. On any
    failure the file is left exactly as it was and the returned DbKey is
    the file's, so a failed move never costs the customer their key.
    Safe to race: two services doing this at once write the same value.
    """
    fk = read_key_file(path)
    if not fk.key:
        return fk
    try:
        write_keychain_key(fk.key)
    except OSError as exc:
        return DbKey(fk.key, fk.source, None,
                     f"{fk.detail}; Keychain move failed: {exc}")
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        return DbKey(fk.key, SOURCE_KEYCHAIN, None,
                     f"in the Keychain; could not delete {path}: {exc}")
    return DbKey(fk.key, SOURCE_KEYCHAIN, None,
                 f'moved from {path} to Keychain item "{keychain_service()}"')


def _mode_bits(path: Path) -> int:
    return stat.S_IMODE(path.lstat().st_mode)


def read_key_file(path: Path) -> DbKey:
    """Read one key file, refusing anything that is not safely locked down.

    Separate from resolve_db_key() so a test can drive the permission
    arms directly without touching the environment.
    """
    try:
        if path.is_symlink():
            return DbKey(
                None,
                None,
                REASON_KEY_FILE_SYMLINK,
                f"{path} is a symlink; refusing to follow it to an unknown target",
            )
        if not path.exists():
            return DbKey(None, None, REASON_NO_KEY, None)
        if not path.is_file():
            return DbKey(
                None,
                None,
                REASON_KEY_FILE_UNREADABLE,
                f"{path} exists but is not a regular file",
            )

        # The directory matters as much as the file: a 0600 file inside a
        # world-writable directory can be replaced wholesale.
        parent = path.parent
        parent_mode = _mode_bits(parent)
        if parent_mode & (stat.S_IRWXG | stat.S_IRWXO):
            return DbKey(
                None,
                None,
                REASON_KEY_FILE_UNSAFE_DIR,
                f"{parent} is mode {parent_mode:04o}; it must be 0700 so no "
                "other local account can read or replace the key",
            )

        mode = _mode_bits(path)
        if mode & (stat.S_IRWXG | stat.S_IRWXO):
            return DbKey(
                None,
                None,
                REASON_KEY_FILE_UNSAFE_MODE,
                f"{path} is mode {mode:04o}; it must be 0600. Refusing to "
                "read a database key another local account can read",
            )

        raw = path.read_text(encoding="utf-8", errors="strict").strip()
    except OSError as exc:
        return DbKey(
            None,
            None,
            REASON_KEY_FILE_UNREADABLE,
            f"{path} could not be read: {exc.__class__.__name__}",
        )
    except UnicodeDecodeError:
        return DbKey(
            None,
            None,
            REASON_KEY_FILE_MALFORMED,
            f"{path} is not UTF-8 text",
        )

    if not raw:
        return DbKey(
            None,
            None,
            REASON_KEY_FILE_MALFORMED,
            f"{path} is empty. An empty key file is a failed write, not a "
            "request to run unencrypted",
        )
    if not _HEX_KEY_RE.match(raw):
        # Deliberately does NOT echo the content. A malformed key is still
        # a secret-shaped value.
        return DbKey(
            None,
            None,
            REASON_KEY_FILE_MALFORMED,
            f"{path} does not hold 64 hex characters (a 256-bit key); it is "
            f"{len(raw)} character(s)",
        )

    return DbKey(raw.lower(), SOURCE_KEY_FILE, None, str(path))


def resolve_db_key() -> DbKey:
    """Resolve the DEK for a service that opens an encrypted database.

    Order, and the order is load-bearing:

      1. OSTLER_DB_KEY in the environment. Unchanged, unvalidated, still
         the documented interface for ostler-migrate-dbs and for anyone
         driving a service by hand. An explicit environment override must
         beat a file on disk, or there is no way to run a one-off against
         a different key.

      2. The key file. This is the install path.

    Never raises. A service that cannot start because its key resolver
    threw would be a worse failure than the one being fixed.
    """
    env_key = os.environ.get("OSTLER_DB_KEY")
    if env_key:
        return DbKey(env_key, SOURCE_ENV, None, None)

    if not keychain_enabled():
        return read_key_file(key_file_path())

    kc = read_keychain_key()
    if kc.key:
        # A file left behind by a crash between write and delete is a
        # plaintext copy of a key that is already protected: remove it.
        leftover = key_file_path()
        try:
            if leftover.is_file() and read_key_file(leftover).key == kc.key:
                leftover.unlink()
        except OSError:
            pass
        return kc
    if kc.reason != REASON_NO_KEY:
        # The Keychain exists and would not give the key up (locked, no
        # session, malformed). Do not guess and do not read the file.
        return kc
    return migrate_key_file_to_keychain(key_file_path())
