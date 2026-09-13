"""``ostler-unlock`` -- redeem a v1.0 recovery key, or unlock with the passphrase.

WHY THIS FILE EXISTS
====================

Every customer is shown an ``XXXX-XXXX-XXXX-XXXX-XXXX-XXXX`` recovery key
at install, minted by ``passphrase.setup_passphrase()``. install.sh calls
it "your only way back in if you ever lose your passphrase".

The function that redeems it, ``passphrase.unlock_with_recovery_key()``,
had ZERO call sites. Measured on this tree before this file landed, with
positive controls on the same search shape:

    unlock_with_recovery_key    0 callers
    unlock                      0 callers
    derive_key                 11 callers      <- control, the query works
    setup_passphrase            7 callers      <- control, the query works
    verify_passphrase           3 callers      <- control, the query works

The only shipped recovery tool, ``recovery_cli.py`` (``ostler-recovery``),
is built entirely for the Touch ID passkey subsystem: it calls
``passkey.unlock_with_recovery()`` against a BIP39 phrase and a
Keychain-wrapped DEK. install.sh disables that subsystem for v1.0 (the
passphrase-primary decision at the Phase 3.6 mint site), so
``ostler-recovery`` exits 2 on every v1.0 install: there is no
Keychain-wrapped recovery DEK to find. The repo already says so out loud,
in ``scripts/box_walk_probes/probes/the_recovery_key_reached_the_customer.sh``:
"ostler-recovery ships and can never succeed for it".

So the shipped state was: mint a key, print it, tell the customer it is
their way back in, and ship nothing that can accept it. A customer who
forgot their passphrase was locked out of their own data permanently, and
no later release could give it back, because the recovery key is the only
surviving secret and nothing could consume it.

This file is the consumer. It is the redeemer for the v1.0
passphrase-primary config (``~/.ostler/security/keychain.json``), and it
is deliberately a separate entry point from ``ostler-recovery`` rather
than a branch inside it: the two operate on different config artefacts,
different key material and different subsystems, and folding the working
path into the broken one would make the broken one look fixed.

WHAT IT DOES
============

Reads the recovery key (or the passphrase), turns it into the 32-byte
database encryption key, and hands that key over in the form the rest of
the product consumes: 64 hex characters, identical to what
``ostler-migrate-dbs`` documents for ``OSTLER_DB_KEY`` and to what
``db_key.resolve_db_key()`` reads out of the protected key file.

    # forgot the passphrase, want the services working again
    ostler-unlock --recovery-key --install-key-file

    # know the passphrase, just want a one-off key on stdout
    ostler-unlock --passphrase > /dev/null

Invocation::

    python -m ostler_security.passphrase_recovery_cli [options]

stdout carries the key and NOTHING else, so a caller can capture it.
Every other line goes to stderr.

SECRETS NEVER TOUCH ARGV
========================

There is no ``--recovery-key VALUE`` and there will not be one. ``ps(1)``
shows argv to every local user, and install.sh already pays for this rule
at the setup site (it passes the passphrase through the environment for
exactly this reason). The key arrives on stdin, from a file, or from an
interactive prompt. Same discipline as ``migrate_recovery_key_aad.py``.

Exit codes
----------

    0   Unlocked. The key is on stdout.
    1   Wrong recovery key / wrong passphrase, or attempts exhausted.
    2   Nothing to unlock: no config, or the config has no recovery key
        configured. Retrying will not help.
    3   Unexpected internal failure.
    4   Unlocked, but --install-key-file could not write the key file.
        The key IS on stdout and is not lost; only the handoff failed.
"""
from __future__ import annotations

import argparse
import getpass
import os
import stat
import sys
import tempfile
from pathlib import Path
from typing import Callable, Optional, TextIO

from ostler_security import db_key as _db_key
from ostler_security import passphrase as _pp


PROG_NAME = "ostler-unlock"

EXIT_OK = 0
EXIT_AUTH_FAILED = 1
EXIT_NOTHING_TO_UNLOCK = 2
EXIT_INTERNAL = 3
EXIT_KEY_FILE_WRITE_FAILED = 4

SecretReader = Callable[[str], str]


def _err(stream: TextIO, msg: str = "") -> None:
    stream.write(msg + "\n")
    stream.flush()


def visible_reader(prompt: str) -> str:
    """Read a recovery key with the characters VISIBLE.

    Same reasoning ``recovery_cli.default_phrase_reader`` writes down for
    BIP39: a 26-character key the customer is copying off paper is one a
    typo destroys, and asterisks make the typo impossible to spot. The
    documented caveat is the same one: run this in a private terminal.
    """
    sys.stderr.write(prompt)
    sys.stderr.flush()
    return sys.stdin.readline()


def hidden_reader(prompt: str) -> str:
    """Read a passphrase with echo off.

    The opposite call from the reader above, on purpose. A passphrase is
    remembered rather than transcribed, so hiding it costs nothing and
    keeps it off a shoulder-surfer's screen.
    """
    return getpass.getpass(prompt, stream=sys.stderr)


def _read_secret_from_file(path: Path) -> str:
    """Read a secret out of a file. '-' means stdin."""
    if str(path) == "-":
        return sys.stdin.read()
    return path.read_text(encoding="utf-8")


def _looks_like_pre_rename_envelope(
    config_dir: Path, recovery_key: str,
) -> bool:
    """Answer, by MEASUREMENT, whether this config predates the AAD rename.

    ``unlock_with_recovery_key`` verifies the recovery key against
    ``recovery_verification`` BEFORE it attempts any decryption. So if we
    are here, the key itself was accepted and the AEAD open still failed.
    The one benign explanation is an envelope written under the old
    ``lifeline-recovery-key-v2`` AAD, which ``ostler-migrate-aad`` exists
    to convert.

    Rather than GUESS at that (the tempting hint is "your config is
    version 2, run the migrator" -- and it is wrong, because
    ``setup_passphrase`` writes ``version: 2`` while already using the v3
    AAD, so every fresh v1.0 install would be told to run a migration it
    must not run), this opens the envelope with the old AAD and reports
    what happened.

    Reuses the migrator's own helpers rather than re-implementing the v2
    shape, so there is one definition of what "v2" means.

    Returns False on any error. This is a diagnostic that improves an
    error message; it must never be able to turn a failure into a
    success, and it must never raise.
    """
    try:
        import json

        from ostler_security import migrate_recovery_key_aad as _aad

        config = json.loads((config_dir / "keychain.json").read_text())
        recovery_derived = _aad._recovery_derived_key(recovery_key, config)
        _aad._decrypt_v2(config, recovery_derived)
        return True
    except Exception:
        return False


def install_key_file(key_hex: str, path: Optional[Path] = None) -> Path:
    """Write the DEK where ``db_key.resolve_db_key()`` will find it.

    Mode discipline mirrors what ``setup_passphrase`` does for
    ``keychain.json``: the directory is 0700 BEFORE anything is written
    into it (the BT9-1 ordering), the file is written to a temp file in
    the same directory, chmod 0600 while it is still private, and only
    then renamed into place. A key file that exists for even a moment at
    the default umask is a key file another local account could have read.

    Raises OSError on failure. The caller turns that into exit code 4 and
    keeps the key on stdout, because a failed handoff must not also
    destroy the thing being handed off.
    """
    path = path or _db_key.key_file_path()
    directory = path.parent
    directory.mkdir(parents=True, exist_ok=True)
    directory.chmod(0o700)

    if path.is_symlink():
        raise OSError(
            f"{path} is a symlink. Refusing to write a database key through "
            "it to an unknown target. Remove it manually."
        )

    fd, tmp_path = tempfile.mkstemp(dir=str(directory), suffix=".tmp")
    try:
        os.fchmod(fd, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(key_hex + "\n")
        os.replace(tmp_path, str(path))
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise
    return path


def run(
    *,
    mode: str,
    config_dir: Path,
    secret_file: Optional[Path] = None,
    recovery_reader: SecretReader = visible_reader,
    passphrase_reader: SecretReader = hidden_reader,
    max_attempts: int = 3,
    write_key_file: bool = False,
    key_file: Optional[Path] = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    """Run one unlock. Returns an exit code.

    Readers and streams are injected so a test can drive the whole flow
    without a terminal. That is not decoration: the defect this file
    fixes is that nothing ever exercised the redeemer, so the redeemer
    has to be exercisable.
    """
    config_path = config_dir / "keychain.json"
    if not config_path.exists():
        _err(stderr, f"No Ostler security config at {config_path}.")
        _err(stderr, "Nothing to unlock. Run the installer first.")
        return EXIT_NOTHING_TO_UNLOCK

    if mode == "recovery":
        label = "recovery key"
        reader = recovery_reader
        # Deliberately does NOT spell a fixed group count. The docstring
        # on generate_recovery_key() says XXXX-XXXX-XXXX-XXXX-XXXX-XXXX
        # and RECOVERY_KEY_LENGTH is 26, so the key it actually mints is
        # seven groups with a short last one. A prompt that shows the
        # wrong shape teaches a locked-out customer to doubt a correct key.
        prompt = "Recovery key (groups of 4, dashes optional): "
    else:
        label = "passphrase"
        reader = passphrase_reader
        prompt = "Passphrase: "

    # A secret supplied non-interactively gets exactly one attempt. There
    # is nobody at the keyboard to correct a typo, and looping on the same
    # file contents would just burn PBKDF2 iterations three times.
    if secret_file is not None:
        attempts = 1
    else:
        attempts = max(1, max_attempts)

    key: Optional[bytes] = None
    last_message = ""

    for attempt in range(1, attempts + 1):
        if secret_file is not None:
            try:
                secret = _read_secret_from_file(secret_file)
            except OSError as exc:
                _err(stderr, f"Could not read {secret_file}: {exc}")
                return EXIT_INTERNAL
        else:
            try:
                secret = reader(prompt)
            except (EOFError, KeyboardInterrupt):
                _err(stderr, "")
                _err(stderr, "Cancelled.")
                return EXIT_AUTH_FAILED

        secret = secret.strip()
        if not secret:
            last_message = f"No {label} was entered."
            _err(stderr, last_message)
            continue

        try:
            if mode == "recovery":
                key = _pp.unlock_with_recovery_key(secret, config_dir=config_dir)
            else:
                key = _pp.unlock(secret, config_dir=config_dir)
            break
        except FileNotFoundError as exc:
            _err(stderr, str(exc))
            return EXIT_NOTHING_TO_UNLOCK
        except ValueError as exc:
            last_message = str(exc)

            # "No recovery key configured" is a property of the config,
            # not of what was typed. Retrying cannot change it, and
            # asking the customer to type the key twice more while the
            # answer is already known is the opposite of helpful.
            if "No recovery key configured" in last_message:
                _err(stderr, last_message)
                _err(
                    stderr,
                    "This install has no recovery envelope, so no recovery "
                    "key can open it. Unlock with the passphrase instead: "
                    f"{PROG_NAME} --passphrase",
                )
                return EXIT_NOTHING_TO_UNLOCK

            if mode == "recovery" and "decryption failed" in last_message:
                if _looks_like_pre_rename_envelope(config_dir, secret):
                    _err(stderr, "")
                    _err(
                        stderr,
                        "Your recovery key IS correct. This install's recovery "
                        "envelope predates the key-namespace change and has to "
                        "be converted once before it can be opened:",
                    )
                    _err(stderr, "")
                    _err(stderr, "    ostler-migrate-aad --execute")
                    _err(stderr, "")
                    _err(stderr, "Then run this command again.")
                    return EXIT_AUTH_FAILED

            _err(stderr, f"Attempt {attempt} of {attempts}: {last_message}")
            continue
        except Exception as exc:  # pragma: no cover - defensive
            _err(stderr, f"Internal error: {exc.__class__.__name__}: {exc}")
            return EXIT_INTERNAL

    if key is None:
        _err(stderr, "")
        _err(stderr, f"Could not unlock with that {label}.")
        if last_message:
            _err(stderr, f"Last error: {last_message}")
        return EXIT_AUTH_FAILED

    key_hex = key.hex()

    _err(stderr, "")
    _err(stderr, "Unlocked.")

    rc = EXIT_OK
    if write_key_file:
        try:
            written = install_key_file(key_hex, key_file)
        except OSError as exc:
            _err(stderr, "")
            _err(stderr, f"Could not write the key file: {exc}")
            _err(
                stderr,
                "The key itself is on stdout and is NOT lost. Capture it "
                "before this window closes.",
            )
            rc = EXIT_KEY_FILE_WRITE_FAILED
        else:
            _err(stderr, f"Database key written to {written} (mode 0600).")
            _err(
                stderr,
                "Restart the Hub services to pick it up: "
                "launchctl kickstart -k gui/$(id -u)/com.ostler.ical-server",
            )

    # stdout is the clean channel. Nothing else is ever written to it.
    stdout.write(key_hex + "\n")
    stdout.flush()
    return rc


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=PROG_NAME,
        description=(
            "Turn your recovery key or your passphrase into the Ostler "
            "database encryption key."
        ),
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--recovery-key",
        dest="mode",
        action="store_const",
        const="recovery",
        help=(
            "Unlock with the XXXX-XXXX-XXXX-XXXX-XXXX-XXXX recovery key you "
            "were shown at install. This is the default."
        ),
    )
    mode.add_argument(
        "--passphrase",
        dest="mode",
        action="store_const",
        const="passphrase",
        help="Unlock with the passphrase you chose at install.",
    )
    parser.set_defaults(mode="recovery")
    parser.add_argument(
        "--secret-file",
        type=Path,
        default=None,
        metavar="PATH",
        help=(
            "Read the recovery key or passphrase from PATH instead of "
            "prompting. '-' means stdin. There is deliberately no flag that "
            "takes the secret itself: argv is visible to every local user."
        ),
    )
    parser.add_argument(
        "--config-dir",
        type=Path,
        default=None,
        metavar="PATH",
        help="Security config directory (default: ~/.ostler/security).",
    )
    parser.add_argument(
        "--install-key-file",
        action="store_true",
        help=(
            "Also write the unlocked key to the protected key file the Hub "
            "services read (0600, inside the 0700 security directory), so "
            "they stop opening databases in plaintext."
        ),
    )
    parser.add_argument(
        "--key-file",
        type=Path,
        default=None,
        metavar="PATH",
        help="Override where --install-key-file writes.",
    )
    parser.add_argument(
        "--max-attempts",
        type=int,
        default=3,
        help="Interactive retries before giving up (default 3).",
    )
    return parser


def main(argv: Optional[list] = None) -> int:
    args = build_parser().parse_args(argv)
    config_dir = args.config_dir or _pp.DEFAULT_CONFIG_DIR
    return run(
        mode=args.mode,
        config_dir=config_dir,
        secret_file=args.secret_file,
        max_attempts=args.max_attempts,
        write_key_file=args.install_key_file,
        key_file=args.key_file,
    )


if __name__ == "__main__":
    sys.exit(main())
