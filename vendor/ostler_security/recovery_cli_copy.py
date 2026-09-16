"""Customer-facing copy for the Ostler recovery-path CLI.

Per PRODUCTISATION_CHECKLIST.md Rule 0.9 (locked 2026-05-19):
every customer-facing string lives in an extractable catalogue
from day one. v1.0 ships English-only; v1.2 lifts these to a
proper i18n catalogue (gettext or similar) without touching call
sites. Until then, treat this module as the source-of-truth for
every string the recovery CLI shows the customer.

The recovery CLI is what a customer runs after restoring Time
Machine onto a fresh Mac. They have ~15-30 minutes to enter their
12-word BIP39 recovery phrase, register a new passkey on the new
device, and re-wrap the data-encryption key under it. Every
sentence here is read by a stressed customer at a difficult
moment, so the voice stays calm and direct.

Conventions:
- British English throughout.
- No em-dashes (project brand rule). Use en-dash with spaces
  ( – ) or a comma where a pause is needed.
- Apple-Restraint voice: observational, not punitive.
- Multi-line paragraphs that the CLI prints line-by-line are
  stored as one constant per physical visible line. This mirrors
  the existing call structure 1:1 so translators see exactly
  what the customer sees.
- Format-string placeholders use named ``.format()`` interpolation
  so translators can re-order placeholders.
- Prompts passed to ``input()`` are catalogue entries too.
- argparse ``prog`` / ``description`` / per-flag ``help`` strings
  are catalogue entries -- ``--help`` output is customer-facing.

This module is imported by ``recovery_cli.py``. Adding a new
string: define the constant here, import and reference from the
call site; never inline.
"""

from __future__ import annotations


# ── Header banner ─────────────────────────────────────────────────────


HEADER_LINE = (
    "Ostler recovery – unlock with your 12-word recovery phrase."
)
IMPORTANT_HEADER = "IMPORTANT:"
IMPORTANT_LINE_1 = "  - The phrase will be visible as you type."
IMPORTANT_LINE_2 = "  - Ensure no one is looking at your screen."
IMPORTANT_LINE_3 = (
    "  - If you paste, check that no extra characters snuck in."
)


# ── Per-attempt prompt ────────────────────────────────────────────────


ATTEMPT_PROMPT_FMT = "Recovery phrase (attempt {attempt}/{max_attempts}): "


# ── Cancellation ──────────────────────────────────────────────────────


CANCELLED_LINE = "\nCancelled."


# ── No recovery-wrapped DEK in Keychain ───────────────────────────────


NO_RECOVERY_DEK_FMT = (
    "No recovery-wrapped DEK found on this machine: {message}"
)
NO_RECOVERY_DEK_DETAIL = (
    "This usually means Ostler has never been set up "
    "on this machine and no Time Machine restore has "
    "brought the Keychain item across. Restore from "
    "Time Machine first, then try again."
)


# ── Invalid phrase, will retry ────────────────────────────────────────


INVALID_PHRASE_ARROW_FMT = "  → {message}"
TRY_AGAIN_LINE = "  Try again."


# ── Internal failure ──────────────────────────────────────────────────


INTERNAL_ERROR_FMT = "Internal error: {code} – {message}"


# ── Attempts exhausted ────────────────────────────────────────────────


EXCEEDED_ATTEMPTS_FMT = "\nExceeded {max_attempts} attempts. Aborting."


# ── Phrase accepted, registering new passkey ──────────────────────────


PHRASE_ACCEPTED_LINE = (
    "✓ Recovery phrase accepted. Registering a new passkey "
    "on this device now – Touch ID prompt will appear."
)


# ── Passkey registration failure ──────────────────────────────────────


PASSKEY_REGISTER_FAILED_FMT = (
    "Failed to register new passkey: {code} – {message}"
)
PASSKEY_REGISTER_FAILED_DETAIL = (
    "The DEK was unwrapped successfully (your data is safe "
    "and still decrypt-able with the recovery phrase) but "
    "no new passkey was set up on this device. Re-run this "
    "command to try again."
)


# ── Success ───────────────────────────────────────────────────────────


PASSKEY_REGISTERED_FMT = (
    "✓ New passkey registered: credential_id = {credential_id}"
)
RECOVERY_COMPLETE_LINE = (
    "✓ Recovery complete. Future unlocks on this device will "
    "use the new passkey."
)


# ── Wrong subsystem for this installation ─────────────────────────────
#
# Read this block as the customer who needs it: someone who has lost
# their passphrase, is holding the recovery key Ostler showed them, and
# has reached for the command with "recovery" in its name. Everything
# they see here has to be true, has to name the command that will
# actually work, and must not send them anywhere else.
#
# What they used to get instead was "No recovery-wrapped DEK found on
# this machine", followed by advice to restore from Time Machine first.
# On a correctly installed Mac that is a confident wrong answer at the
# worst possible moment: it tells a customer whose install is fine that
# Ostler was never set up here.


WRONG_SUBSYSTEM_HEADER = (
    "This command cannot unlock Ostler on this Mac."
)
WRONG_SUBSYSTEM_LINE_1 = (
    "Nothing is wrong and nothing has been lost. Ostler on this Mac is "
    "protected by the passphrase you chose when you installed it. This "
    "command only opens installations that were set up a different way."
)
WRONG_SUBSYSTEM_LINE_2 = "Run this instead:"
WRONG_SUBSYSTEM_COMMAND = "    ostler-unlock --recovery-key"
WRONG_SUBSYSTEM_LINE_3 = (
    "It asks for the recovery key Ostler showed you at the end of the "
    "install, the one made of short blocks of letters and numbers "
    "separated by dashes. Type it exactly as it was shown to you."
)
WRONG_SUBSYSTEM_LINE_4 = (
    "If you still remember your passphrase, ostler-unlock --passphrase "
    "will unlock it just as well."
)


# ── argparse strings ──────────────────────────────────────────────────


CLI_PROG_NAME = "ostler-recovery"
CLI_DESCRIPTION = (
    "Recover Ostler on a new device using your BIP39 "
    "recovery phrase."
)
CLI_USER_NAME_HELP = (
    "Display name for the new passkey (default: $USER or "
    "'ostler-user')."
)
CLI_MAX_ATTEMPTS_HELP = "Phrase retries before giving up (default 3)."
CLI_THREAD_ID_HELP = "Thread ID (v1: must be 'default')."
