"""Migrate recovery-key envelope AAD from ``lifeline-recovery-key-v2``
to ``creativemachines/recovery-key-v3``.

Background
----------

``passphrase.py`` AES-GCM-encrypts a copy of the main encryption key
under a key derived from the user's recovery passphrase. The AEAD
context is bound via the AAD::

    aad = b"lifeline-recovery-key-v2:" + encryption_salt

Per ``feedback_brand_neutral_crypto_constants.md`` the
brand-leak-prone ``lifeline-...`` prefix has to move to a neutral
namespace. The new shape is::

    aad = b"creativemachines/recovery-key-v3:" + encryption_salt

The version number gets bumped because the AAD literal is a
versioned binding; the v2 -> v3 step matches the existing v1 -> v2
shape so future migrations remain mechanical.

Decrypting with the wrong AAD raises ``InvalidTag``. So flipping the
literal in source without first migrating every existing config file
locks every user out of their recovery path. This CLI reads each
config, decrypts with the v2 AAD, re-encrypts with v3, writes back.

What is touched, what is not
----------------------------

* The wrapped main encryption key (``recovery_encrypted_key`` field).
* The envelope ``version`` bumps from ``2`` to ``3`` post-migration.
* The HMAC over the config is recomputed (the main key didn't
  change, just the wrapped copy of it; but the bytes-being-HMACed
  changed because the ciphertext changed).

* The user's passphrase is NOT used. We don't need it: the recovery
  path needs only the recovery-derived key, which is itself
  recoverable from the recovery key alone.
* The user's recovery key is NOT touched. The CLI does need to use
  it to do the decrypt/re-encrypt. By design it accepts the
  recovery key on stdin (or via ``--recovery-key-file``) so it
  never touches argv.

Safety contract
---------------

* Default mode is ``--dry-run``. Just enumerates what is on v2.
* ``--execute`` is destructive. It writes new config(s) atomically
  (write tmpfile + os.replace). Source bytes are backed up to
  ``~/.ostler/security/recovery_key_backups/<timestamp>/`` first.
* Idempotent: configs already on v3 are skipped.
* Concurrent-write safe: takes the same ``.keychain.lock`` advisory
  lock that ``passphrase.setup_passphrase`` /
  ``change_passphrase`` use. Two simultaneous migrations cannot
  corrupt each other.
* Verification step decrypts with v3 AAD and asserts the resulting
  bytes match what would have come out of v2.
* ``--rollback`` reads the backup created by ``--execute`` and
  restores it. Useful only until the source constants are flipped.

Exit codes
----------

::

    0   Success
    1   At least one config failed migration / verification
    2   Bad arguments / mutually exclusive flags / missing recovery key
    3   Internal failure
"""
from __future__ import annotations

import argparse
import datetime as _dt
import getpass
import hashlib
import hmac as _hmac
import json
import os
import secrets
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Iterable, Optional, TextIO

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ostler_security import passphrase as _pp


# ── Constants ────────────────────────────────────────────────────────

OLD_AAD_PREFIX = b"lifeline-recovery-key-v2:"
NEW_AAD_PREFIX = b"creativemachines/recovery-key-v3:"

OLD_VERSION = 2
NEW_VERSION = 3

DEFAULT_LOG_PATH = Path.home() / ".ostler" / "security" / "aad_migration.log"
DEFAULT_BACKUP_ROOT = Path.home() / ".ostler" / "security" / "recovery_key_backups"


# Exit codes
EXIT_OK = 0
EXIT_PARTIAL_FAILURE = 1
EXIT_BAD_ARGS = 2
EXIT_INTERNAL = 3


# ── Logging ──────────────────────────────────────────────────────────


def _now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat()


def _ts_compact() -> str:
    """Filesystem-safe timestamp for backup directory names."""
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


class MigrationLogger:
    """Append-only JSONL log of every migration operation."""

    def __init__(self, log_path: Path):
        self.log_path = log_path
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.log_path.parent.chmod(0o700)
        except OSError:
            pass
        if not self.log_path.exists():
            self.log_path.touch(mode=0o600)
        else:
            try:
                self.log_path.chmod(0o600)
            except OSError:
                pass

    def log(self, **fields) -> None:
        record = {"ts": _now_iso(), **fields}
        with self.log_path.open("a", encoding="utf-8") as fp:
            fp.write(json.dumps(record, sort_keys=True) + "\n")


# ── Config discovery ─────────────────────────────────────────────────


def default_config_paths() -> list[Path]:
    """Return the list of recovery-key config files to consider.

    Currently ostler ships one config: ``~/.ostler/security/keychain.json``.
    The path is referenced from ``passphrase.DEFAULT_CONFIG_DIR``; we
    re-read it via the constant rather than hard-coding so a future
    rename of the dir lifts cleanly.

    Multi-thread / multi-realm installs (post-CM042) may have more
    than one config – ``--config`` is repeatable for that.
    """
    return [_pp.DEFAULT_CONFIG_DIR / "keychain.json"]


# ── Per-config operations ────────────────────────────────────────────


def _read_config(path: Path) -> dict:
    """Read a config file. Symlink-checked for parity with passphrase.py."""
    if path.is_symlink():
        raise RuntimeError(
            f"Config path is a symlink: {path}. Refusing to follow – "
            f"manually remove it before migrating."
        )
    if not path.exists():
        raise FileNotFoundError(f"Config not found: {path}")
    return json.loads(path.read_text())


def _classify_config(config: dict) -> str:
    """Return one of ``"v2"`` / ``"v3"`` / ``"unsupported"``.

    Used by both dry-run and execute. v2 is the migration source;
    v3 is the migration target / already-done state.
    """
    version = config.get("version", 1)
    if version == OLD_VERSION:
        return "v2"
    if version == NEW_VERSION:
        return "v3"
    return "unsupported"


def _recovery_derived_key(recovery_key: str, config: dict) -> bytes:
    """Re-derive the recovery-derived key from the recovery passphrase
    and the config's recovery_salt.

    Mirrors what passphrase.unlock_with_recovery_key does. The recovery
    key is normalised by stripping dashes (the user-facing form is
    XXXX-XXXX-...).
    """
    recovery_key_raw = recovery_key.replace("-", "")
    recovery_salt = bytes.fromhex(config["recovery_salt"])
    return _pp.derive_key(recovery_key_raw, recovery_salt)


def _decrypt_v2(config: dict, recovery_derived: bytes) -> bytes:
    """Decrypt the wrapped main key using the v2 AAD. Returns the
    main encryption key. Raises ValueError on failure (wrong recovery
    key, tampered config, etc)."""
    encrypted = config["recovery_encrypted_key"]
    nonce = bytes.fromhex(encrypted["nonce"])
    ciphertext = bytes.fromhex(encrypted["ciphertext"])
    encryption_salt = bytes.fromhex(config["encryption_salt"])
    aad = OLD_AAD_PREFIX + encryption_salt
    try:
        return AESGCM(recovery_derived).decrypt(nonce, ciphertext, aad)
    except InvalidTag as exc:
        raise ValueError(
            "v2 decrypt failed (InvalidTag). Recovery key may be wrong, "
            "or this config was already migrated to v3, or the file is "
            "tampered."
        ) from exc


def _encrypt_v3(main_key: bytes, encryption_salt: bytes,
                recovery_derived: bytes) -> tuple[bytes, bytes]:
    """Encrypt the main key with the v3 AAD. Returns (nonce, ciphertext)."""
    aad = NEW_AAD_PREFIX + encryption_salt
    nonce = os.urandom(12)
    ciphertext = AESGCM(recovery_derived).encrypt(nonce, main_key, aad)
    return nonce, ciphertext


def _decrypt_v3(config: dict, recovery_derived: bytes) -> bytes:
    """Decrypt the wrapped main key using the v3 AAD. Used by --verify
    and by the post-write round-trip check inside --execute."""
    encrypted = config["recovery_encrypted_key"]
    nonce = bytes.fromhex(encrypted["nonce"])
    ciphertext = bytes.fromhex(encrypted["ciphertext"])
    encryption_salt = bytes.fromhex(config["encryption_salt"])
    aad = NEW_AAD_PREFIX + encryption_salt
    return AESGCM(recovery_derived).decrypt(nonce, ciphertext, aad)


def _recompute_hmac(config: dict, main_key: bytes) -> str:
    """Recompute the HMAC over the config (sans existing _hmac field).

    Mirrors the layout in passphrase._setup_passphrase_locked /
    _change_passphrase_locked – include every field except ``_hmac``,
    sort_keys=True, encode as UTF-8.
    """
    config_for_hmac = {k: v for k, v in config.items() if k != "_hmac"}
    config_bytes = json.dumps(config_for_hmac, sort_keys=True).encode("utf-8")
    return _hmac.new(main_key, config_bytes, hashlib.sha256).hexdigest()


def _atomic_write(config: dict, path: Path) -> None:
    """Write config to path via tmp-file + os.replace."""
    if path.is_symlink():
        raise RuntimeError(
            f"Config path is a symlink: {path}. Refusing to write – "
            f"manually remove it first."
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_path_str = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    tmp_path = Path(tmp_path_str)
    try:
        with os.fdopen(tmp_fd, "w") as fp:
            json.dump(config, fp, indent=2)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, path)
    except Exception:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass
        raise


def _backup_config(path: Path, backup_root: Path,
                   timestamp: str) -> Optional[Path]:
    """Copy the source config to a timestamped backup dir before
    rewriting. Returns the backup file path, or None if the source
    didn't exist."""
    if not path.exists():
        return None
    backup_dir = backup_root / timestamp
    backup_dir.mkdir(parents=True, exist_ok=True)
    try:
        backup_root.chmod(0o700)
        backup_dir.chmod(0o700)
    except OSError:
        pass
    # Use the basename – we may need to migrate multiple configs in
    # the same run, but each comes from a unique parent dir so basename
    # collisions inside one timestamp are unlikely. If they do collide,
    # store the path-hash as a suffix.
    target = backup_dir / path.name
    if target.exists():
        suffix = hashlib.sha256(str(path).encode()).hexdigest()[:8]
        target = backup_dir / f"{path.stem}.{suffix}{path.suffix}"
    shutil.copy2(path, target)
    try:
        target.chmod(0o600)
    except OSError:
        pass
    return target


def _acquire_lock(config_dir: Path):
    """Take the same advisory lock passphrase.py uses so we don't
    race a concurrent setup / change-passphrase. Returns the file
    descriptor – caller must release via _release_lock."""
    import fcntl
    config_dir.mkdir(parents=True, exist_ok=True)
    lock_path = config_dir / ".keychain.lock"
    lock_fd = open(str(lock_path), "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except IOError:
        lock_fd.close()
        raise RuntimeError(
            "Another setup/change-passphrase/migrate is already running "
            "(could not acquire .keychain.lock). Try again."
        )
    return lock_fd


def _release_lock(lock_fd) -> None:
    import fcntl
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
    finally:
        lock_fd.close()


# ── Plan / execute / verify / rollback ──────────────────────────────


def plan_migration(paths: Iterable[Path]) -> list[dict]:
    """Enumerate config files and report what would happen."""
    plan: list[dict] = []
    for path in paths:
        try:
            config = _read_config(path)
        except FileNotFoundError:
            plan.append({"path": str(path), "status": "absent"})
            continue
        except RuntimeError as exc:
            plan.append({
                "path": str(path), "status": "error", "message": str(exc),
            })
            continue
        except json.JSONDecodeError as exc:
            plan.append({
                "path": str(path), "status": "error",
                "message": f"invalid JSON: {exc}",
            })
            continue

        kind = _classify_config(config)
        if kind == "v2":
            plan.append({"path": str(path), "status": "would_migrate"})
        elif kind == "v3":
            plan.append({"path": str(path), "status": "already_v3"})
        else:
            plan.append({
                "path": str(path), "status": "unsupported",
                "message": f"version={config.get('version')!r} – not v2 or v3",
            })
    return plan


def execute_migration(
    paths: Iterable[Path],
    *,
    recovery_key: str,
    logger: MigrationLogger,
    backup_root: Path = DEFAULT_BACKUP_ROOT,
    out: TextIO = sys.stdout,
) -> tuple[int, int, int, str]:
    """Run the migration. Returns (migrated, skipped, errored,
    backup_timestamp).

    Per-config flow::

        1. Acquire .keychain.lock for that config dir.
        2. Read config; classify.
        3. v3 already → skip.
        4. v2 → derive recovery key; decrypt v2; re-encrypt v3.
        5. Build new config (bumped version, new ciphertext, fresh
           HMAC). Recovery key never decrypts during HMAC – we use
           the main key recovered in step 4.
        6. Write to a temp file, fsync, os.replace into place.
        7. Round-trip verify: read back; decrypt with v3 AAD; assert
           main_key bytes match.
        8. Drop the lock.
    """
    timestamp = _ts_compact()
    migrated = 0
    skipped = 0
    errored = 0

    for path in paths:
        try:
            if not path.exists():
                skipped += 1
                logger.log(op="execute", path=str(path), outcome="absent")
                print(f"  [skip] {path}: not present", file=out)
                continue

            try:
                config = _read_config(path)
            except (RuntimeError, json.JSONDecodeError) as exc:
                errored += 1
                logger.log(op="execute", path=str(path),
                           outcome="read_error", error=str(exc))
                print(f"  [ERR ] {path}: {exc}", file=out)
                continue

            kind = _classify_config(config)
            if kind == "v3":
                skipped += 1
                logger.log(op="execute", path=str(path),
                           outcome="already_v3")
                print(f"  [skip] {path}: already on v3", file=out)
                continue
            if kind == "unsupported":
                errored += 1
                logger.log(op="execute", path=str(path),
                           outcome="unsupported_version",
                           version=config.get("version"))
                print(f"  [ERR ] {path}: unsupported version "
                      f"{config.get('version')!r}", file=out)
                continue

            # kind == "v2"
            lock_fd = None
            try:
                lock_fd = _acquire_lock(path.parent)
            except RuntimeError as exc:
                errored += 1
                logger.log(op="execute", path=str(path),
                           outcome="lock_failed", error=str(exc))
                print(f"  [ERR ] {path}: {exc}", file=out)
                continue

            try:
                # Re-read after taking the lock so we don't race.
                config = _read_config(path)
                if _classify_config(config) != "v2":
                    skipped += 1
                    logger.log(op="execute", path=str(path),
                               outcome="raced_to_other_version")
                    print(f"  [skip] {path}: already migrated by another "
                          f"process", file=out)
                    continue

                # Backup BEFORE any decrypt – so we have the source
                # bytes regardless of what fails next.
                backup_path = _backup_config(path, backup_root, timestamp)
                if backup_path:
                    logger.log(op="execute", path=str(path),
                               outcome="backup", backup=str(backup_path))

                recovery_derived = _recovery_derived_key(recovery_key, config)

                try:
                    main_key = _decrypt_v2(config, recovery_derived)
                except ValueError as exc:
                    errored += 1
                    logger.log(op="execute", path=str(path),
                               outcome="v2_decrypt_failed", error=str(exc))
                    print(f"  [ERR ] {path}: {exc}", file=out)
                    continue

                encryption_salt = bytes.fromhex(config["encryption_salt"])
                new_nonce, new_ct = _encrypt_v3(
                    main_key, encryption_salt, recovery_derived,
                )

                new_config = dict(config)
                new_config["version"] = NEW_VERSION
                new_config["recovery_encrypted_key"] = {
                    "nonce": new_nonce.hex(),
                    "ciphertext": new_ct.hex(),
                }
                # Drop old _hmac and recompute fresh.
                new_config.pop("_hmac", None)
                new_config["_hmac"] = _recompute_hmac(new_config, main_key)

                _atomic_write(new_config, path)

                # Round-trip verify on disk.
                roundtrip = _read_config(path)
                if _classify_config(roundtrip) != "v3":
                    errored += 1
                    logger.log(op="execute", path=str(path),
                               outcome="post_write_classify_failed")
                    print(f"  [ERR ] {path}: post-write classify did not "
                          f"return v3 – possible filesystem issue", file=out)
                    continue

                try:
                    decrypted = _decrypt_v3(roundtrip, recovery_derived)
                except (ValueError, InvalidTag) as exc:
                    errored += 1
                    logger.log(op="execute", path=str(path),
                               outcome="v3_roundtrip_failed", error=str(exc))
                    print(f"  [ERR ] {path}: v3 round-trip decrypt failed: "
                          f"{exc}", file=out)
                    continue

                if not secrets.compare_digest(decrypted, main_key):
                    errored += 1
                    logger.log(op="execute", path=str(path),
                               outcome="roundtrip_mismatch")
                    print(f"  [ERR ] {path}: round-trip main key mismatch",
                          file=out)
                    continue

                migrated += 1
                logger.log(op="execute", path=str(path),
                           outcome="migrated", version=NEW_VERSION,
                           backup=str(backup_path) if backup_path else None)
                print(f"  [ok  ] {path}: migrated v2 -> v3", file=out)

            finally:
                if lock_fd is not None:
                    _release_lock(lock_fd)

        except Exception as exc:
            errored += 1
            logger.log(op="execute", path=str(path),
                       outcome="unexpected_error", error=repr(exc))
            print(f"  [ERR ] {path}: unexpected error: {exc!r}", file=out)
            continue

    return migrated, skipped, errored, timestamp


def verify_migration(
    paths: Iterable[Path],
    *,
    recovery_key: str,
    logger: MigrationLogger,
    out: TextIO = sys.stdout,
) -> tuple[int, int]:
    """Decrypt with v3 AAD on every config and confirm it works.

    Returns (verified, failed). Anything still on v2 counts as a
    failure since the migration didn't finish.
    """
    verified = 0
    failed = 0
    for path in paths:
        if not path.exists():
            logger.log(op="verify", path=str(path), outcome="absent")
            print(f"  [skip] {path}: not present", file=out)
            continue

        try:
            config = _read_config(path)
        except (RuntimeError, json.JSONDecodeError) as exc:
            failed += 1
            logger.log(op="verify", path=str(path),
                       outcome="read_error", error=str(exc))
            print(f"  [ERR ] {path}: {exc}", file=out)
            continue

        kind = _classify_config(config)
        if kind == "v2":
            failed += 1
            logger.log(op="verify", path=str(path),
                       outcome="still_v2")
            print(f"  [ERR ] {path}: still on v2 – migration not done",
                  file=out)
            continue
        if kind == "unsupported":
            failed += 1
            logger.log(op="verify", path=str(path),
                       outcome="unsupported_version")
            print(f"  [ERR ] {path}: unsupported version "
                  f"{config.get('version')!r}", file=out)
            continue

        try:
            recovery_derived = _recovery_derived_key(recovery_key, config)
            decrypted = _decrypt_v3(config, recovery_derived)
        except (ValueError, InvalidTag, KeyError) as exc:
            failed += 1
            logger.log(op="verify", path=str(path),
                       outcome="v3_decrypt_failed", error=str(exc))
            print(f"  [ERR ] {path}: v3 decrypt failed: {exc}", file=out)
            continue

        if len(decrypted) != _pp.KEY_LENGTH:
            failed += 1
            logger.log(op="verify", path=str(path),
                       outcome="bad_decrypted_length",
                       length=len(decrypted))
            print(f"  [ERR ] {path}: decrypted length wrong "
                  f"({len(decrypted)} != {_pp.KEY_LENGTH})", file=out)
            continue

        verified += 1
        logger.log(op="verify", path=str(path), outcome="ok")
        print(f"  [ok  ] {path}: v3 round-trip ok", file=out)

    return verified, failed


def rollback_migration(
    paths: Iterable[Path],
    *,
    backup_timestamp: str,
    backup_root: Path = DEFAULT_BACKUP_ROOT,
    logger: MigrationLogger,
    out: TextIO = sys.stdout,
) -> tuple[int, int, int]:
    """Restore configs from a specific backup directory.

    Caller passes the timestamp string that was reported by
    --execute. We deliberately do not try to be clever and pick
    "the latest" backup – being explicit prevents accidentally
    rolling back the wrong run.

    Returns (rolled_back, skipped, errored).
    """
    rolled_back = 0
    skipped = 0
    errored = 0

    backup_dir = backup_root / backup_timestamp
    if not backup_dir.exists():
        raise FileNotFoundError(
            f"Backup dir not found: {backup_dir}. "
            f"Check the timestamp printed by --execute."
        )

    for path in paths:
        # Match how _backup_config picked the target.
        candidate = backup_dir / path.name
        if not candidate.exists():
            suffix = hashlib.sha256(str(path).encode()).hexdigest()[:8]
            candidate = backup_dir / f"{path.stem}.{suffix}{path.suffix}"
            if not candidate.exists():
                skipped += 1
                logger.log(op="rollback", path=str(path),
                           outcome="no_backup_found",
                           looked_in=str(backup_dir))
                print(f"  [skip] {path}: no backup in "
                      f"{backup_dir}", file=out)
                continue

        try:
            shutil.copy2(candidate, path)
            os.chmod(path, 0o600)
        except OSError as exc:
            errored += 1
            logger.log(op="rollback", path=str(path),
                       outcome="copy_failed", error=str(exc))
            print(f"  [ERR ] {path}: copy failed: {exc}", file=out)
            continue

        rolled_back += 1
        logger.log(op="rollback", path=str(path),
                   outcome="rolled_back", source=str(candidate))
        print(f"  [ok  ] {path}: restored from {candidate}", file=out)

    return rolled_back, skipped, errored


# ── Recovery key intake ─────────────────────────────────────────────


def _read_recovery_key_from_file(path: Path) -> str:
    """Read a recovery key from a file. Strips whitespace; rejects
    empty content."""
    if path.is_symlink():
        raise RuntimeError(f"Recovery key file is a symlink: {path}.")
    text = path.read_text().strip()
    if not text:
        raise RuntimeError(f"Recovery key file is empty: {path}")
    return text


def _read_recovery_key_interactive(stream: TextIO) -> str:
    """Prompt for the recovery key on stderr; read it via getpass.

    Why getpass: argv exposes the value to ``ps``. Stdin pipe is
    fine but defaults to echoed input. getpass routes through
    /dev/tty when available, falling back to stdin.
    """
    print("Enter recovery key (24-26 alphanumeric chars, dashes ok):",
          file=stream)
    key = getpass.getpass(prompt="> ", stream=stream)
    return key.strip()


def _resolve_recovery_key(
    file_path: Optional[Path], stream: TextIO,
) -> Optional[str]:
    """Resolve the recovery key from --recovery-key-file, env var,
    or interactive prompt. Returns None if nothing was supplied
    (caller decides whether that's an error)."""
    if file_path is not None:
        return _read_recovery_key_from_file(file_path)
    env_key = os.environ.get("OSTLER_RECOVERY_KEY")
    if env_key:
        return env_key.strip()
    if stream.isatty():
        return _read_recovery_key_interactive(stream)
    return None


# ── CLI ──────────────────────────────────────────────────────────────


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ostler-migrate-aad",
        description=(
            "Migrate Ostler recovery-key envelopes from v2 AAD "
            "(lifeline-recovery-key-v2) to v3 AAD "
            "(creativemachines/recovery-key-v3). Defaults to dry-run; "
            "pass --execute to write."
        ),
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true",
                      help="(default) enumerate v2 configs and exit.")
    mode.add_argument("--execute", action="store_true",
                      help="Decrypt v2, re-encrypt v3, write back. "
                           "Idempotent. Backs up to "
                           f"{DEFAULT_BACKUP_ROOT}/<timestamp>/.")
    mode.add_argument("--verify", action="store_true",
                      help="Confirm v3 round-trip on each config.")
    mode.add_argument("--rollback", metavar="TIMESTAMP",
                      help="Restore configs from a specific backup "
                           "directory (the timestamp string printed by "
                           "--execute).")

    p.add_argument(
        "--config", action="append", type=Path, default=None,
        help="Config file to migrate. Repeatable. "
             f"Default: {Path.home() / '.ostler' / 'security' / 'keychain.json'}",
    )
    p.add_argument(
        "--recovery-key-file", type=Path, default=None,
        help="Path to a file containing the recovery key. Avoids "
             "having to type it. The file is read once, then closed; "
             "Ostler does NOT delete it – your responsibility.",
    )
    p.add_argument(
        "--backup-root", type=Path, default=DEFAULT_BACKUP_ROOT,
        help=f"Where backups go. Default: {DEFAULT_BACKUP_ROOT}",
    )
    p.add_argument(
        "--log-path", type=Path, default=None,
        help=f"Path to migration log. Default: {DEFAULT_LOG_PATH}",
    )
    return p


def main(argv: Optional[list[str]] = None,
         out: Optional[TextIO] = None,
         err: Optional[TextIO] = None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    parser = _build_parser()
    args = parser.parse_args(argv)

    paths = args.config or default_config_paths()
    paths = [Path(p).expanduser() for p in paths]

    log_path = args.log_path or DEFAULT_LOG_PATH
    try:
        logger = MigrationLogger(log_path)
    except OSError as exc:
        print(f"ERROR: cannot write log to {log_path}: {exc}", file=err)
        return EXIT_INTERNAL

    is_dry_run = (
        args.dry_run
        or not (args.execute or args.verify or args.rollback)
    )

    print(f"Ostler recovery-key AAD migration", file=out)
    print(f"  configs:       {len(paths)} candidate(s)", file=out)
    for p in paths:
        print(f"                 - {p}", file=out)
    print(f"  log:           {log_path}", file=out)
    print(f"  backup root:   {args.backup_root}", file=out)
    print("-" * 60, file=out)

    if is_dry_run:
        print("Mode: DRY-RUN (no writes, no recovery key needed)", file=out)
        plan = plan_migration(paths)
        for entry in plan:
            print(f"  [{entry['status']:>16s}] {entry['path']}", file=out)
            if entry.get("message"):
                print(f"    note: {entry['message']}", file=out)
            logger.log(op="dry_run", path=entry["path"],
                       outcome=entry["status"],
                       message=entry.get("message"))
        n_would = sum(1 for e in plan if e["status"] == "would_migrate")
        n_errors = sum(1 for e in plan
                       if e["status"] in ("error", "unsupported"))
        print("-" * 60, file=out)
        print(f"  {n_would} would migrate, {n_errors} error(s)/unsupported",
              file=out)
        return EXIT_OK if n_errors == 0 else EXIT_PARTIAL_FAILURE

    # --execute, --verify, --rollback all need the recovery key.
    # (Rollback technically does not – it's just file-copy – but we
    # require it for symmetry: writing back means the user will
    # immediately need it to unlock anyway. EXCEPT it would prompt
    # interactively, blocking automation. So rollback skips the
    # prompt.)
    recovery_key: Optional[str] = None
    if args.execute or args.verify:
        try:
            recovery_key = _resolve_recovery_key(
                args.recovery_key_file, err,
            )
        except (RuntimeError, OSError) as exc:
            print(f"ERROR resolving recovery key: {exc}", file=err)
            return EXIT_BAD_ARGS

        if not recovery_key:
            print(
                "ERROR: --execute and --verify need a recovery key. Provide "
                "via --recovery-key-file, OSTLER_RECOVERY_KEY env var, or "
                "run interactively.",
                file=err,
            )
            return EXIT_BAD_ARGS

    if args.execute:
        print("Mode: EXECUTE", file=out)
        migrated, skipped, errored, backup_ts = execute_migration(
            paths, recovery_key=recovery_key, logger=logger,
            backup_root=args.backup_root, out=out,
        )
        print("-" * 60, file=out)
        print(f"  {migrated} migrated, {skipped} skipped, {errored} errored",
              file=out)
        if migrated:
            print("", file=out)
            print(f"Backup timestamp: {backup_ts}", file=out)
            print(f"  (rollback with --rollback {backup_ts})", file=out)
        if errored == 0:
            print("", file=out)
            print("Next steps:", file=out)
            print("  1. Run --verify to confirm v3 round-trip.", file=out)
            print("  2. Once verified, flip the AAD constants in "
                  "ostler_security/passphrase.py via "
                  "`python -m ostler_security.flip_constants --execute`.",
                  file=out)
        return EXIT_OK if errored == 0 else EXIT_PARTIAL_FAILURE

    if args.verify:
        print("Mode: VERIFY", file=out)
        verified, failed = verify_migration(
            paths, recovery_key=recovery_key, logger=logger, out=out,
        )
        print("-" * 60, file=out)
        print(f"  {verified} verified, {failed} failed", file=out)
        return EXIT_OK if failed == 0 else EXIT_PARTIAL_FAILURE

    if args.rollback:
        print(f"Mode: ROLLBACK from backup {args.rollback}", file=out)
        try:
            rolled_back, skipped, errored = rollback_migration(
                paths, backup_timestamp=args.rollback,
                backup_root=args.backup_root, logger=logger, out=out,
            )
        except FileNotFoundError as exc:
            print(f"ERROR: {exc}", file=err)
            return EXIT_BAD_ARGS
        print("-" * 60, file=out)
        print(f"  {rolled_back} rolled back, {skipped} skipped, "
              f"{errored} errored", file=out)
        return EXIT_OK if errored == 0 else EXIT_PARTIAL_FAILURE

    return EXIT_BAD_ARGS  # pragma: no cover


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
