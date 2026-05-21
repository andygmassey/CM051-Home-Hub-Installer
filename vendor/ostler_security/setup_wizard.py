"""First-run security setup wizard – passkey-primary CLI flow.

Walks the user through:

1. FileVault check (disk-at-rest encryption underneath everything)
2. macOS 15.0+ version check (passkey PRF extension requirement)
3. Passkey registration via `passkey.setup()` – Touch ID prompt,
   DEK generated, wrapped under the passkey-derived KEK AND under
   a freshly-generated BIP39 recovery-phrase-derived KEK, both
   stored in the Keychain.
4. Recovery phrase display with a written-down confirmation step.
5. Return the DEK to the caller so it can immediately open SQLCipher
   without prompting Touch ID a second time.

Replaces the pre-2026-04-23 passphrase-primary flow entirely. The
passphrase module (`passphrase.py`) is NOT invoked from this wizard;
its remaining role is the recovery path's user-chosen-passphrase
variant (if one is ever added – v1 uses BIP39-generated phrases only).

Designed to run during `ostler-install` or standalone via:

    python -m ostler_security.setup_wizard

All output is to stdout/stderr. No web dependencies.

Return dict
-----------

`run_wizard()` returns:

    {
        "config_dir":        str – config directory path
        "recovery_phrase":   str – 12-word BIP39 phrase
        "credential_id":     str – base64url passkey handle
        "dek":               bytes – 32-byte DEK, for immediate DB init
        "setup_complete":    True
    }

Note the `dek` key – this is a deliberate break from the previous
passphrase-flow wizard which deliberately omitted the encryption key
from its return dict (BH-4 fix). Reason for the break: the passkey
flow's alternative is to prompt Touch ID twice in quick succession
(once for register, once for a follow-up assert just to unwrap what
was just wrapped), which is needless UX friction. Instead, we take
responsibility for NOT logging the return dict – callers that need
a printable summary should build one explicitly.
"""
from __future__ import annotations

import platform
import sys
from pathlib import Path
from typing import Callable, Optional, TextIO

from .audit_log import EVENT_UNLOCK, log_event
from .filevault import check_filevault_status
from . import passkey as _passkey
from . import wizard_copy as _copy


# ── Output helpers ───────────────────────────────────────────────────

def _h(text: str, *, out: TextIO) -> None:
    out.write(f"\n{'=' * 60}\n")
    out.write(f"  {text}\n")
    out.write(f"{'=' * 60}\n\n")


def _warn(text: str, *, out: TextIO) -> None:
    out.write(f"\n  ⚠  {text}\n\n")


def _ok(text: str, *, out: TextIO) -> None:
    out.write(f"\n  ✓  {text}\n\n")


def _info(text: str, *, out: TextIO) -> None:
    out.write(f"  {text}\n")


# ── Version check ────────────────────────────────────────────────────

def _macos_meets_minimum() -> bool:
    """Return True iff we're on macOS 15.0 or later.

    Passkey PRF extension (via AuthenticationServices native API)
    requires macOS 15. Per SHARED_AUTH_SPEC.md §0 there is no
    non-PRF fallback; a pre-15 Mac can't run Ostler's passkey
    auth at all.

    Non-Darwin platforms return False – Ostler is Apple-only
    (Lester agenda item 2026-04-27; decision pending but v1 is
    effectively Apple-scoped by virtue of the passkey + iCloud
    Keychain stack).
    """
    if sys.platform != "darwin":
        return False
    try:
        release, _versioninfo, _machine = platform.mac_ver()
        major = int(release.split(".", 1)[0])
        return major >= 15
    except (ValueError, IndexError):
        return False


# ── Wizard entry ────────────────────────────────────────────────────

def run_wizard(
    config_dir: Optional[Path] = None,
    *,
    skip_filevault: bool = False,
    skip_version_check: bool = False,
    user_name: Optional[str] = None,
    user_display_name: Optional[str] = None,
    confirmer: Optional[Callable[[str], str]] = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> dict:
    """Run the interactive security setup wizard.

    Args:
        config_dir: Where to store Ostler config. Defaults to
            ``~/.ostler/security``. The passkey handle file
            (`passkey.json`) lives inside this directory.
        skip_filevault: Bypass the FileVault enabled check. Test-only.
        skip_version_check: Bypass the macOS 15+ gate. Test-only –
            tests run on hosts that may not be macOS 15.
        user_name: Identity shown in the Touch ID prompt. Defaults
            to `$USER` or `"ostler-user"`.
        user_display_name: Display name shown alongside user_name.
            Defaults to `user_name`.
        confirmer: Callback to prompt the user for a confirmation
            string (e.g., "y" to continue, or typing back one word
            of the recovery phrase). Defaults to `input(prompt)`.
            Dependency-injected for tests.
        stdout / stderr: Output streams. Default to the process's
            stdio; test-injected streams make the flow pure.

    Returns:
        The dict documented at the top of this module.

    Raises:
        SystemExit: on critical failure (pre-15 Mac, FileVault
            refused, passkey register failure post-prompt).
    """
    import os

    config_dir = config_dir or (Path.home() / ".ostler" / "security")
    user_name = user_name or os.environ.get("USER") or "ostler-user"
    user_display_name = user_display_name or user_name
    confirm = confirmer or input

    _h(_copy.SETUP_HEADER, out=stderr)

    _info(_copy.INTRO_LINE_1, out=stderr)
    _info(_copy.INTRO_LINE_2, out=stderr)
    _info(_copy.INTRO_LINE_3, out=stderr)
    _info("", out=stderr)
    _info(_copy.INTRO_LINE_4, out=stderr)
    _info(_copy.INTRO_LINE_5, out=stderr)
    _info(_copy.INTRO_LINE_6, out=stderr)
    stderr.write("\n")

    # ── Step 1: FileVault ───────────────────────────────────────────

    if not skip_filevault:
        _h(_copy.STEP1_HEADER, out=stderr)
        fv = check_filevault_status()
        if fv["enabled"]:
            _ok(_copy.STEP1_FILEVAULT_OK, out=stderr)
        else:
            _warn(_copy.STEP1_FILEVAULT_MISSING_WARN, out=stderr)
            _info(_copy.STEP1_FILEVAULT_MISSING_RECOMMEND, out=stderr)
            _info(_copy.STEP1_FILEVAULT_MISSING_PATH, out=stderr)
            _info("", out=stderr)
            response = confirm(_copy.STEP1_FILEVAULT_CONTINUE_PROMPT)
            if response.strip().lower() != "y":
                stderr.write(_copy.STEP1_FILEVAULT_REFUSED_EXIT)
                raise SystemExit(1)

    # ── Step 2: macOS version ──────────────────────────────────────

    if not skip_version_check:
        _h(_copy.STEP2_HEADER, out=stderr)
        if not _macos_meets_minimum():
            _warn(_copy.STEP2_VERSION_TOO_OLD_WARN, out=stderr)
            _info(_copy.STEP2_VERSION_TOO_OLD_DETAIL, out=stderr)
            _info(_copy.STEP2_VERSION_TOO_OLD_FIX, out=stderr)
            raise SystemExit(1)
        _ok(_copy.STEP2_VERSION_OK, out=stderr)

    # ── Step 3: Passkey registration ──────────────────────────────

    _h(_copy.STEP3_HEADER, out=stderr)
    _info(_copy.STEP3_INTRO_LINE_1, out=stderr)
    _info(_copy.STEP3_INTRO_LINE_2, out=stderr)
    _info(_copy.STEP3_INTRO_BULLET_1, out=stderr)
    _info(_copy.STEP3_INTRO_BULLET_2, out=stderr)
    _info(_copy.STEP3_INTRO_BULLET_3, out=stderr)
    _info("", out=stderr)

    result = _passkey.setup(
        user_name, user_display_name,
    )
    if not result.ok:
        _warn(_copy.STEP3_REGISTER_FAILED_WARN, out=stderr)
        _info(
            _copy.STEP3_REGISTER_FAILED_REASON.format(
                error_code=result.error_code,
                message=result.message,
            ),
            out=stderr,
        )
        raise SystemExit(2)

    _ok(_copy.STEP3_PASSKEY_CREATED_OK, out=stderr)

    # ── Step 4: Recovery phrase ────────────────────────────────────

    _h(_copy.STEP4_HEADER, out=stderr)
    _info(_copy.STEP4_INTRO_LINE_1, out=stderr)
    _info(_copy.STEP4_INTRO_LINE_2, out=stderr)
    _info(_copy.STEP4_INTRO_LINE_3, out=stderr)
    _info(_copy.STEP4_INTRO_LINE_4, out=stderr)
    _info("", out=stderr)
    _info(_copy.STEP4_WRITE_DOWN_LINE_1, out=stderr)
    _info(_copy.STEP4_WRITE_DOWN_LINE_2, out=stderr)
    _info(_copy.STEP4_WRITE_DOWN_LINE_3, out=stderr)
    _info(_copy.STEP4_WRITE_DOWN_LINE_4, out=stderr)
    _info(_copy.STEP4_WRITE_DOWN_LINE_5, out=stderr)
    _info("", out=stderr)
    stderr.write("\n")
    stderr.write(f"    {result.recovery_phrase}\n")
    stderr.write("\n")
    _warn(_copy.STEP4_PHRASE_SHOWN_ONCE_WARN, out=stderr)
    _info("", out=stderr)

    response = confirm(_copy.STEP4_WROTE_DOWN_PROMPT)
    if response.strip().lower() not in ("yes", "y"):
        stderr.write("\n")
        stderr.write(f"    {result.recovery_phrase}\n")
        stderr.write("\n")
        _warn(_copy.STEP4_PLEASE_WRITE_DOWN_WARN, out=stderr)
        confirm(_copy.STEP4_PRESS_ENTER_PROMPT)

    # ── Done ──────────────────────────────────────────────────────

    _h(_copy.COMPLETE_HEADER, out=stderr)
    _ok(
        _copy.COMPLETE_PASSKEY_REGISTERED.format(
            credential_id=result.credential_id,
        ),
        out=stderr,
    )
    _ok(_copy.COMPLETE_PHRASE_GENERATED, out=stderr)
    _ok(
        _copy.COMPLETE_CONFIG_STORED.format(config_dir=config_dir),
        out=stderr,
    )
    _info("", out=stderr)
    _info(_copy.COMPLETE_FUTURE_LAUNCHES, out=stderr)
    _info(_copy.COMPLETE_RECOVER_HINT, out=stderr)
    _info(_copy.COMPLETE_RECOVER_COMMAND, out=stderr)

    # Audit log
    log_event(
        EVENT_UNLOCK,
        source="setup_wizard",
        details={"action": "passkey_setup", "credential_id": result.credential_id},
        db_path=config_dir / "audit.db",
    )

    return {
        "config_dir": str(config_dir),
        "recovery_phrase": result.recovery_phrase,
        "credential_id": result.credential_id,
        # Raw 32-byte DEK for immediate DB initialisation.
        #
        # CALLER RESPONSIBILITY. Once the install flow consumes the
        # DEK (opens SQLCipher / hands it to AutoLock.unlock()), the
        # caller is responsible for scrubbing. The fact that this
        # wizard returns it does NOT grant permission to keep it
        # around. Do NOT log, serialise, or persist this dict. The
        # recommended pattern is:
        #
        #     result = run_wizard(...)
        #     try:
        #         dek = result["dek"]
        #         # use dek immediately – open SQLCipher, etc.
        #     finally:
        #         # drop the local reference + the dict entry
        #         result["dek"] = None
        #         del dek
        #
        # Python cannot scrub immutable bytes. For defence-in-depth,
        # copy into a bytearray and call
        # ostler_security._memory.zeroize() after use. See
        # SECURITY_MODEL.md for the complete scrub-status audit.
        "dek": result.dek,
        "setup_complete": True,
    }


# ── CLI entry point ─────────────────────────────────────────────────

def main() -> int:
    """CLI entry point. Run the wizard, print a final summary, exit."""
    try:
        run_wizard()
    except SystemExit as exc:
        return int(exc.code) if isinstance(exc.code, int) else 1
    print(_copy.CLI_MAIN_DONE, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
