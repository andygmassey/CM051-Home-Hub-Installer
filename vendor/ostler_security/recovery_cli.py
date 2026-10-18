"""Recovery-path CLI – unlock on a new device via BIP39 phrase.

Use case: user lost their Mac, restored from Time Machine onto a
fresh Mac. The restored Keychain carries the recovery-wrapped DEK
(SHARED_AUTH_SPEC.md §4) but NOT the primary-wrapped DEK (that one
was `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so it didn't
travel in the backup). User runs this CLI, types their 12-word
recovery phrase, a new passkey is registered on the new Mac, and
the DEK is re-wrapped under it.

Invocation
----------

    python -m ostler_security.recovery_cli

Optional args:
    --user-name NAME        Display name for the new passkey (default:
                            $USER or "ostler-user"). Cosmetic –
                            shown in the Touch ID prompt.
    --max-attempts N        How many phrase retries before giving up
                            (default 3).
    --thread-id ID          Reserved; v1 only accepts "default".

Exit codes
----------

    0   Recovery succeeded, new passkey registered
    1   User exhausted attempts or cancelled
    2   Stored wrapped recovery DEK not found in Keychain (no prior
        install on this machine, or Time Machine restore didn't
        carry it across)
    3   Unexpected internal failure
    4   Wrong subsystem: this Mac is a passphrase-primary install, so
        this command cannot open it and says which one can. Refused
        before any prompt, so nothing was typed and nothing was read.

WHY EXIT 4 EXISTS
-----------------

install.sh disables the passkey subsystem for v1.0, so every v1.0
install is passphrase-primary and this command can never succeed on
one. It stays registered because the subsystem returns in v1.0.1.

Left alone, though, it did not merely fail: it asked for a 12-word
phrase (the wrong credential entirely, since a v1.0 customer holds a
short dashed recovery key), then reported that no recovery item was
found and advised restoring from Time Machine first. A customer whose
install is perfectly healthy was told Ostler had never been set up on
that machine, and sent off to a backup they do not need, at the one
moment they are least able to argue with it.

So the refusal below happens BEFORE the banner and BEFORE the first
prompt, and it names `ostler-unlock`, which is the command that can
actually spend their recovery key. A passkey-primary install is not
affected: the check requires a passphrase config to be present AND a
passkey handle to be absent, which is the same discriminator
`scripts/box_walk_probes/probes/the_recovery_key_reached_the_customer.sh`
uses to tell the two subsystems apart.

The CLI writes the unwrapped DEK (64-char hex) to stdout on success
so a calling shell script can pipe it into whatever needs it
(SQLCipher PRAGMA, etc). All other output goes to stderr so stdout
is a clean channel.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Callable, Optional, TextIO

from ostler_security import passkey as _passkey
from ostler_security import passphrase as _passphrase
from ostler_security import webauthn_client as _wac
from ostler_security.recovery_cli_copy import (
    ATTEMPT_PROMPT_FMT,
    CANCELLED_LINE,
    CLI_DESCRIPTION,
    CLI_MAX_ATTEMPTS_HELP,
    CLI_PROG_NAME,
    CLI_THREAD_ID_HELP,
    CLI_USER_NAME_HELP,
    EXCEEDED_ATTEMPTS_FMT,
    HEADER_LINE,
    IMPORTANT_HEADER,
    IMPORTANT_LINE_1,
    IMPORTANT_LINE_2,
    IMPORTANT_LINE_3,
    INTERNAL_ERROR_FMT,
    INVALID_PHRASE_ARROW_FMT,
    NO_RECOVERY_DEK_DETAIL,
    NO_RECOVERY_DEK_FMT,
    PASSKEY_REGISTERED_FMT,
    PASSKEY_REGISTER_FAILED_DETAIL,
    PASSKEY_REGISTER_FAILED_FMT,
    PHRASE_ACCEPTED_LINE,
    RECOVERY_COMPLETE_LINE,
    TRY_AGAIN_LINE,
    WRONG_SUBSYSTEM_COMMAND,
    WRONG_SUBSYSTEM_HEADER,
    WRONG_SUBSYSTEM_LINE_1,
    WRONG_SUBSYSTEM_LINE_2,
    WRONG_SUBSYSTEM_LINE_3,
    WRONG_SUBSYSTEM_LINE_4,
)


# Exit codes – documented above.
EXIT_OK = 0
EXIT_AUTH_FAILED = 1
EXIT_NO_RECOVERY_ITEM = 2
EXIT_INTERNAL = 3
EXIT_WRONG_SUBSYSTEM = 4


# Type alias for the phrase-reader. Injected for test.
PhraseReader = Callable[[str], str]


def default_phrase_reader(prompt: str) -> str:
    """Default CLI phrase reader.

    Uses `input()` not `getpass.getpass()` – users need to see a
    12-word phrase to catch typos, and hiding it behind asterisks
    makes typos impossible to recover from. Documented caveat is
    "run this in a private terminal"; same model as hardware-wallet
    recovery flows.
    """
    return input(prompt)


def is_passphrase_primary(config_dir: Optional[Path] = None) -> bool:
    """Is this Mac protected by a passphrase rather than by Touch ID?

    THE DISCRIMINATOR IS NOT NEW AND MUST NOT BE. It is the one
    `scripts/box_walk_probes/probes/the_recovery_key_reached_the_customer.sh`
    already uses to keep the two subsystems apart, stated in code:
    a passphrase config is present (`keychain.json`, which
    `setup_passphrase()` writes and which `passphrase_recovery_cli`
    reads) and a passkey handle is absent (`passkey.json`, resolved
    through `passkey.handle_file()` so its test override is honoured
    here too). Two ways of deciding the same thing would be a second
    defect, not a second opinion.

    FAILS TOWARDS THE OLD BEHAVIOUR ON PURPOSE. Anything other than
    "config present AND handle absent" returns False and the command
    runs exactly as it did before. A guard that cannot read the disk
    must not lock a passkey customer out of the only tool that helps
    them.

    `config_dir` is read at call time rather than bound at import, so
    a test can point it at a fixture without the caller's real home
    directory deciding the answer.
    """
    directory = Path(config_dir) if config_dir else _passphrase.DEFAULT_CONFIG_DIR
    try:
        if not (directory / "keychain.json").exists():
            return False
        return not _passkey.handle_file().exists()
    except OSError:
        return False


def _err(writer: TextIO, msg: str) -> None:
    writer.write(msg + "\n")
    writer.flush()


def run(
    *,
    phrase_reader: PhraseReader = default_phrase_reader,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
    user_name: Optional[str] = None,
    max_attempts: int = 3,
    thread_id: str = "default",
    config_dir: Optional[Path] = None,
) -> int:
    """Run the recovery flow. Returns an exit code.

    Dependency-injected phrase reader and output streams so unit
    tests can drive the flow without touching stdin / stdout.
    """
    # BEFORE THE BANNER AND BEFORE THE FIRST PROMPT, which is the whole
    # point. The old code asked for a 12-word phrase first and only then
    # discovered it could not help, so a customer holding a valid recovery
    # key had already been told their credential was the wrong shape before
    # being told, wrongly, that Ostler had never been set up here.
    #
    # This sits at the top of run() rather than inside main() so that
    # `python -m ostler_security.recovery_cli` and every direct caller are
    # covered by the same guard. run() is the first thing main() does, so
    # "before any prompt" holds either way, and putting it here keeps the
    # refusal drivable by a test with injected streams.
    if is_passphrase_primary(config_dir):
        _err(stderr, WRONG_SUBSYSTEM_HEADER)
        _err(stderr, "")
        _err(stderr, WRONG_SUBSYSTEM_LINE_1)
        _err(stderr, "")
        _err(stderr, WRONG_SUBSYSTEM_LINE_2)
        _err(stderr, "")
        _err(stderr, WRONG_SUBSYSTEM_COMMAND)
        _err(stderr, "")
        _err(stderr, WRONG_SUBSYSTEM_LINE_3)
        _err(stderr, "")
        _err(stderr, WRONG_SUBSYSTEM_LINE_4)
        return EXIT_WRONG_SUBSYSTEM

    user_name = user_name or os.environ.get("USER") or "ostler-user"

    _err(stderr, HEADER_LINE)
    _err(stderr, "")
    _err(stderr, IMPORTANT_HEADER)
    _err(stderr, IMPORTANT_LINE_1)
    _err(stderr, IMPORTANT_LINE_2)
    _err(stderr, IMPORTANT_LINE_3)
    _err(stderr, "")

    dek: Optional[bytes] = None
    attempts_used = 0

    for attempt in range(1, max_attempts + 1):
        attempts_used = attempt
        try:
            phrase = phrase_reader(
                ATTEMPT_PROMPT_FMT.format(
                    attempt=attempt, max_attempts=max_attempts,
                ),
            )
        except (EOFError, KeyboardInterrupt):
            _err(stderr, CANCELLED_LINE)
            return EXIT_AUTH_FAILED

        # unlock_with_recovery handles BIP39 validation + unwrap +
        # surfaces a clean error for each failure mode.
        unlock_result = _passkey.unlock_with_recovery(
            phrase, thread_id=thread_id
        )

        if unlock_result.ok:
            dek = unlock_result.dek
            break

        code = unlock_result.error_code

        # Fast-exit on "no recovery item in Keychain" – retrying won't
        # help.
        if code in ("KEYCHAIN_NOT_FOUND", "KEYCHAIN_DENIED"):
            _err(stderr, NO_RECOVERY_DEK_FMT.format(
                message=unlock_result.message,
            ))
            _err(stderr, "")
            _err(stderr, NO_RECOVERY_DEK_DETAIL)
            return EXIT_NO_RECOVERY_ITEM

        if code == _wac.ERROR_INVALID_REQUEST:
            _err(stderr, INVALID_PHRASE_ARROW_FMT.format(
                message=unlock_result.message,
            ))
            if attempt < max_attempts:
                _err(stderr, TRY_AGAIN_LINE)
                _err(stderr, "")
            continue

        # Any other code is a surprise – don't pretend we can recover.
        _err(stderr, INTERNAL_ERROR_FMT.format(
            code=code, message=unlock_result.message,
        ))
        return EXIT_INTERNAL

    if dek is None:
        _err(stderr, EXCEEDED_ATTEMPTS_FMT.format(max_attempts=max_attempts))
        return EXIT_AUTH_FAILED

    _err(stderr, "")
    _err(stderr, PHRASE_ACCEPTED_LINE)

    rebind_result = _passkey.rebind_after_recovery(
        dek, user_name, thread_id=thread_id
    )
    if not rebind_result.ok:
        _err(stderr, PASSKEY_REGISTER_FAILED_FMT.format(
            code=rebind_result.error_code,
            message=rebind_result.message,
        ))
        _err(stderr, "")
        _err(stderr, PASSKEY_REGISTER_FAILED_DETAIL)
        return EXIT_AUTH_FAILED

    _err(stderr, "")
    _err(stderr, PASSKEY_REGISTERED_FMT.format(
        credential_id=rebind_result.credential_id,
    ))
    _err(stderr, RECOVERY_COMPLETE_LINE)
    _err(stderr, "")

    # Unwrapped DEK on stdout so callers can capture it.
    stdout.write(dek.hex() + "\n")
    stdout.flush()
    return EXIT_OK


def main() -> int:
    parser = argparse.ArgumentParser(
        prog=CLI_PROG_NAME,
        description=CLI_DESCRIPTION,
    )
    parser.add_argument(
        "--user-name", type=str, default=None,
        help=CLI_USER_NAME_HELP,
    )
    parser.add_argument(
        "--max-attempts", type=int, default=3,
        help=CLI_MAX_ATTEMPTS_HELP,
    )
    parser.add_argument(
        "--thread-id", type=str, default="default",
        help=CLI_THREAD_ID_HELP,
    )
    args = parser.parse_args()

    return run(
        user_name=args.user_name,
        max_attempts=args.max_attempts,
        thread_id=args.thread_id,
    )


if __name__ == "__main__":
    sys.exit(main())
