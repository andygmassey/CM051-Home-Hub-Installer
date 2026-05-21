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

The CLI writes the unwrapped DEK (64-char hex) to stdout on success
so a calling shell script can pipe it into whatever needs it
(SQLCipher PRAGMA, etc). All other output goes to stderr so stdout
is a clean channel.
"""
from __future__ import annotations

import argparse
import os
import sys
from typing import Callable, Optional, TextIO

from ostler_security import passkey as _passkey
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
)


# Exit codes – documented above.
EXIT_OK = 0
EXIT_AUTH_FAILED = 1
EXIT_NO_RECOVERY_ITEM = 2
EXIT_INTERNAL = 3


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
) -> int:
    """Run the recovery flow. Returns an exit code.

    Dependency-injected phrase reader and output streams so unit
    tests can drive the flow without touching stdin / stdout.
    """
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
