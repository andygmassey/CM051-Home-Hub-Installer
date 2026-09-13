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

``vendor/ostler_security/SECURITY_MODEL.md`` lists "Time-Machine backup
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
import stat
from pathlib import Path
from typing import NamedTuple, Optional


# Source labels. These flow into posture.py's `key_source` field, whose
# docstring already names "OSTLER_DB_KEY" as the recommended value; this
# adds the second one rather than replacing it.
SOURCE_ENV = "OSTLER_DB_KEY"
SOURCE_KEY_FILE = "OSTLER_DB_KEY_FILE"

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

    return read_key_file(key_file_path())
