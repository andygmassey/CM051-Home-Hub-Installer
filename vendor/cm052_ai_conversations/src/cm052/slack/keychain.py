"""Slack user token in the login Keychain, via ``/usr/bin/security``.

There is no shared Python Keychain helper in the PWG repos (searched
CM048, CM052, CM041, CM046, CM019 for ``generic-password`` / ``keyring``:
zero hits; the only Keychain writer is install.sh's Swift helper for the
recovery key). This module is that helper for the importers.

Rules it keeps, each from an incident:

- The token is NEVER on argv (install.sh v1.0.109: ``security
  add-generic-password -w <key>`` put a secret in ``ps`` output). Writes go
  through ``security -i``, which reads the command from STDIN.
- ``security -i`` exits 0 even when its command fails (measured for
  install.sh), so a write is only reported saved after a read-back returns
  the identical value.
- The token is validated against a strict shape before it is written, which
  also means it cannot carry a quote or newline into the ``-i`` command line.
- Reads use ``find-generic-password -w``: the value comes back on stdout.

Known gap for review: ``security`` cannot set
``kSecAttrAccessibleWhenUnlockedThisDeviceOnly``; the Swift helper in
install.sh can. The item is in the login Keychain, not synchronised.

Tests never touch a real Keychain: ``runner`` is injectable, and the PATH
stub test replaces ``security`` itself.
"""
from __future__ import annotations

import re
import subprocess
from collections.abc import Callable

SERVICE = "Ostler Slack Token"
SECURITY = "security"

_TOKEN_SHAPE = re.compile(r"^xoxp-[A-Za-z0-9-]{20,250}$")
_ACCOUNT_SHAPE = re.compile(r"^[TE][A-Z0-9]{2,20}$")

Runner = Callable[..., subprocess.CompletedProcess]


class SecretStoreError(Exception):
    pass


def valid_token(token: str) -> bool:
    return bool(_TOKEN_SHAPE.match(token or ""))


def _check_account(team_id: str) -> None:
    if not _ACCOUNT_SHAPE.match(team_id or ""):
        raise SecretStoreError("workspace id has an unexpected shape")


def store_token(team_id: str, token: str, runner: Runner = subprocess.run) -> None:
    if not valid_token(token):
        # Never echo the value back, not even a prefix.
        raise SecretStoreError(
            "that does not look like a Slack user token (expected xoxp-...)"
        )
    _check_account(team_id)
    command = (
        f'add-generic-password -U -s "{SERVICE}" -a "{team_id}" -w "{token}"\n'
    )
    proc = runner(
        [SECURITY, "-i"], input=command, capture_output=True, text=True, check=False
    )
    if proc.returncode != 0:
        raise SecretStoreError("Keychain write failed")
    if load_token(team_id, runner=runner) != token:
        raise SecretStoreError("Keychain write could not be verified by read-back")


def load_token(team_id: str, runner: Runner = subprocess.run) -> str | None:
    _check_account(team_id)
    proc = runner(
        [SECURITY, "find-generic-password", "-s", SERVICE, "-a", team_id, "-w"],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        return None
    value = (proc.stdout or "").strip()
    return value or None
