"""Customer-facing copy for the first-run security setup wizard.

Per PRODUCTISATION_CHECKLIST.md Rule 0.9 (locked 2026-05-19):
every customer-facing string lives in an extractable catalogue
from day one. v1.0 ships English-only; v1.2 lifts these to a
proper i18n catalogue (gettext or similar) without touching call
sites. Until then, treat this module as the source-of-truth for
every string the security setup wizard shows the customer.

This is the FIRST customer touchpoint after install: the passkey
+ recovery-phrase wizard at ``ostler_security/setup_wizard.py``.
Every sentence here is critical.

Conventions:
- British English throughout.
- No em-dashes (project brand rule). Use en-dash with spaces
  ( – ) or a comma where a pause is needed.
- Apple-Restraint voice: observational, not punitive.
- Multi-line paragraphs that the wizard hand-wraps for terminal
  width are stored as one constant per physical visible line.
  This mirrors the existing call structure 1:1 so translators
  see exactly what the customer sees.
- Interpolated lines use named-placeholder format strings
  (``"Found {model} ..."``) applied with ``.format(model=...)``
  at the call site. NO f-strings at the catalogue value, since
  these need to be inert strings a translator can edit.
- Confirm-prompt strings (passed to ``input()`` / ``confirm()``)
  are catalogue entries too.

This module is imported by ``setup_wizard.py``. Adding a new
wizard line: define the string here, import it, and reference
from the call site; never inline strings in the wizard body.
"""

from __future__ import annotations


# ── Top banner ───────────────────────────────────────────────────────


SETUP_HEADER = "Ostler Security Setup"


# ── Intro paragraph ──────────────────────────────────────────────────
# Hand-wrapped for terminal width; one constant per physical line so
# the rendered output is byte-identical to the pre-lift wizard.


INTRO_LINE_1 = "Ostler will hold your entire digital life on this device."
INTRO_LINE_2 = "Setup creates a passkey (Touch ID) for day-to-day unlock"
INTRO_LINE_3 = "and a 12-word recovery phrase for the loss-of-device case."
INTRO_LINE_4 = "If you lose BOTH the passkey (iCloud Keychain) AND the"
INTRO_LINE_5 = "recovery phrase, your data cannot be recovered. By anyone."
INTRO_LINE_6 = "Ever. That is the price of real privacy."


# ── Step 1: FileVault ────────────────────────────────────────────────


STEP1_HEADER = "Step 1: Full Disk Encryption"

STEP1_FILEVAULT_OK = (
    "FileVault is enabled. Your disk is encrypted at rest."
)

STEP1_FILEVAULT_MISSING_WARN = "FileVault is NOT enabled."
STEP1_FILEVAULT_MISSING_RECOMMEND = (
    "We strongly recommend enabling FileVault before continuing."
)
STEP1_FILEVAULT_MISSING_PATH = (
    "Go to: System Settings → Privacy & Security → FileVault"
)

STEP1_FILEVAULT_CONTINUE_PROMPT = "  Continue without FileVault? (y/N): "

STEP1_FILEVAULT_REFUSED_EXIT = (
    "\n  Enable FileVault first, then re-run this setup.\n"
)


# ── Step 2: macOS version ────────────────────────────────────────────


STEP2_HEADER = "Step 2: macOS Version Check"

STEP2_VERSION_TOO_OLD_WARN = (
    "Ostler passkey auth requires macOS 15.0 or later."
)
STEP2_VERSION_TOO_OLD_DETAIL = (
    "Your current version does not meet this requirement."
)
STEP2_VERSION_TOO_OLD_FIX = (
    "Upgrade macOS to 15.0+ and re-run this setup."
)

STEP2_VERSION_OK = "macOS version is supported."


# ── Step 3: Passkey registration ─────────────────────────────────────


STEP3_HEADER = "Step 3: Create a Passkey"

STEP3_INTRO_LINE_1 = (
    "macOS will now prompt for Touch ID (or Face ID) to create"
)
STEP3_INTRO_LINE_2 = "a Ostler passkey. This passkey will:"
STEP3_INTRO_BULLET_1 = (
    "  • sync across your Macs and iOS devices via iCloud Keychain"
)
STEP3_INTRO_BULLET_2 = (
    "  • never leave Apple's Secure Enclave – Ostler cannot read it"
)
STEP3_INTRO_BULLET_3 = (
    "  • be the key that unlocks your data day-to-day"
)

STEP3_REGISTER_FAILED_WARN = "Passkey registration failed."
# Interpolated. Apply with:
#     STEP3_REGISTER_FAILED_REASON.format(
#         error_code=result.error_code, message=result.message
#     )
STEP3_REGISTER_FAILED_REASON = "Reason: {error_code} – {message}"

STEP3_PASSKEY_CREATED_OK = (
    "Passkey created. Touch ID is now your day-to-day unlock."
)


# ── Step 4: Recovery phrase ──────────────────────────────────────────


STEP4_HEADER = "Step 4: Write Down Your Recovery Phrase"

STEP4_INTRO_LINE_1 = (
    "The 12 words below are your only way to recover your data"
)
STEP4_INTRO_LINE_2 = (
    "if you ever lose access to this passkey (e.g. you lose this"
)
STEP4_INTRO_LINE_3 = (
    "Mac AND your iOS device AND your iCloud Keychain sync is"
)
STEP4_INTRO_LINE_4 = "gone)."

STEP4_WRITE_DOWN_LINE_1 = (
    "WRITE THIS DOWN ON PAPER. Do not type it into a password"
)
STEP4_WRITE_DOWN_LINE_2 = (
    "manager. Do not take a screenshot. Do not email it to"
)
STEP4_WRITE_DOWN_LINE_3 = (
    "yourself. Write it on paper and put the paper somewhere"
)
STEP4_WRITE_DOWN_LINE_4 = (
    "safe. A fireproof safe or safety-deposit box is ideal; a"
)
STEP4_WRITE_DOWN_LINE_5 = "desk drawer is a starting point."

STEP4_PHRASE_SHOWN_ONCE_WARN = (
    "This phrase is shown ONCE and is not recoverable if lost."
)

STEP4_WROTE_DOWN_PROMPT = (
    "  I have written down my recovery phrase (yes/no): "
)

STEP4_PLEASE_WRITE_DOWN_WARN = "Please write it down before continuing."
STEP4_PRESS_ENTER_PROMPT = (
    "  Press Enter when you have written it down: "
)


# ── Completion ───────────────────────────────────────────────────────


COMPLETE_HEADER = "Security Setup Complete"

# Interpolated. Apply with:
#     COMPLETE_PASSKEY_REGISTERED.format(credential_id=result.credential_id)
COMPLETE_PASSKEY_REGISTERED = "Passkey registered: {credential_id}"

COMPLETE_PHRASE_GENERATED = (
    "Recovery phrase generated and (we trust) written down."
)

# Interpolated. Apply with:
#     COMPLETE_CONFIG_STORED.format(config_dir=config_dir)
COMPLETE_CONFIG_STORED = "Config stored at: {config_dir}"

COMPLETE_FUTURE_LAUNCHES = (
    "Future Ostler launches will prompt Touch ID to unlock."
)
COMPLETE_RECOVER_HINT = "If you ever need to recover on a new device:"
COMPLETE_RECOVER_COMMAND = "  python -m ostler_security.recovery_cli"


# ── CLI main() summary ───────────────────────────────────────────────


CLI_MAIN_DONE = "\n  Security setup complete. Ostler is ready.\n"
