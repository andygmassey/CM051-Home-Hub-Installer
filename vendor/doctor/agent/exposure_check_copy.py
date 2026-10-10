"""Customer-facing strings for the Doctor "If this Mac were taken" check.

Rule 0.9: every sentence the customer reads lives here, not inline in the
logic. British English. No em dashes. Calm, plain, never alarming. The word
"recording" is not used anywhere in customer copy; this check does not touch
captured audio at all.

Each check has four lines:

    title      what is being looked at
    thief      "what someone holding this Mac could do", only shown on a risk
    fix        one concrete step the owner can take
    found_*    what was measured (counts and places, never contents)
"""
from __future__ import annotations

PAGE_TITLE = "If this Mac were taken"
PAGE_LEAD = (
    "A calm look at what someone could reach in their first ten minutes with "
    "this Mac. It only counts settings and points to places. It never opens "
    "or shows a password, key or token, and nothing leaves this Mac."
)
RUN_BUTTON = "Check this Mac now"
RUNNING = "Checking, this takes a few seconds"
NEVER_RUN = "Not run yet. Press the button to look."
DISABLED_DETAIL = "feature_disabled"
FOOTER_LINK_TEXT = "If this Mac were taken"

SCORE_LABEL = "Exposure score"
SCORE_NONE = "Not enough could be measured to give a score"
TOP_FIXES_HEADING = "Your top three fixes"
NO_FIXES = "Nothing urgent. Everything we could measure looks well covered."
UNMEASURED_NOTE = (
    "{n} check(s) could not be measured here. macOS keeps some things behind "
    "Full Disk Access or needs an administrator. They are left out of the "
    "score rather than guessed."
)

SUMMARY_STRONG = "This Mac is well protected against someone who picks it up."
SUMMARY_FAIR = "A few small changes would make this Mac much harder to get into."
SUMMARY_WEAK = (
    "Several easy changes would make a real difference. Each has a short step below."
)

VERDICT_LABEL = {"OK": "Looks fine", "risk": "Worth fixing", "CANNOT-CHECK": "Could not check"}

CHECKS = {
    "filevault": {
        "title": "Disk encryption (FileVault)",
        "thief": (
            "With FileVault off, someone can remove the drive or boot from another "
            "disk and read your files without ever knowing your password."
        ),
        "fix": "System Settings > Privacy & Security > FileVault > Turn On.",
        "ok": "FileVault is on, so the disk is scrambled until you log in.",
        "risk": "FileVault is off.",
        "cannot": "Could not read the FileVault state on this system.",
    },
    "screen_lock": {
        "title": "Password after sleep or screen saver",
        "thief": (
            "If the Mac does not ask for a password straight away, anyone who opens "
            "the lid within that time is already signed in as you."
        ),
        "fix": (
            "System Settings > Lock Screen > Require password after screen saver "
            "begins or display is turned off > Immediately."
        ),
        "ok": "A password is required immediately after sleep or the screen saver.",
        "risk_off": "No password is required after sleep or the screen saver.",
        "risk_delay": "A password is only required after a delay of {n} seconds.",
        "cannot": "Could not read the screen lock setting here.",
    },
    "auto_login": {
        "title": "Automatic login",
        "thief": (
            "With automatic login on, switching the Mac on is enough. There is no "
            "login screen to get past."
        ),
        "fix": "System Settings > Users & Groups > Automatically log in as > Off.",
        "ok": "Automatic login is off.",
        "risk": "Automatic login is on.",
        "risk_file": "A saved automatic-login password file is present.",
        "cannot": "Could not read the automatic login setting here.",
    },
    "find_my": {
        "title": "Find My Mac and Activation Lock",
        "thief": (
            "Without Find My, you cannot locate, lock or erase this Mac remotely, "
            "and a thief can reset and resell it."
        ),
        "fix": "System Settings > [your name] > iCloud > Find My Mac > On.",
        "ok": "Find My Mac is on.",
        "risk": "Find My Mac looks to be off.",
        "cannot": "Could not tell whether Find My Mac is on from here.",
    },
    "firmware": {
        "title": "Firmware password (Intel Macs)",
        "thief": (
            "Without a firmware password, someone can start the Mac from another "
            "disk or reach recovery tools."
        ),
        "fix": "Restart into Recovery > Utilities > Startup Security Utility > Turn On Firmware Password.",
        "ok": "A firmware password is set.",
        "ok_na": "Not applicable: this Mac uses Apple silicon, which has its own startup protection.",
        "risk": "No firmware password is set.",
        "cannot": "Could not read the firmware password state without administrator rights.",
    },
    "ssh_keys": {
        "title": "SSH keys without a passphrase",
        "thief": (
            "An SSH key with no passphrase works as-is. Whoever has the Mac can log "
            "in to every server or code host that trusts it."
        ),
        "fix": "In Terminal run ssh-keygen -p -f <key file> to add a passphrase, then store it in the Keychain with ssh-add --apple-use-keychain.",
        "ok_none": "No private SSH keys were found.",
        "ok": "{n} private SSH key(s) found, all protected by a passphrase or a hardware key.",
        "risk": "{bad} of {n} private SSH key(s) have no passphrase.",
        "cannot": "Could not read the SSH folder.",
        "type_open": "no passphrase",
        "type_locked": "passphrase set",
        "type_hw": "hardware key",
    },
    "ssh_agent_forwarding": {
        "title": "SSH agent forwarding",
        "thief": (
            "Agent forwarding to every host lets a compromised server borrow your "
            "keys while you are connected."
        ),
        "fix": "In ~/.ssh/config remove ForwardAgent yes under Host *, and keep it only for hosts you trust.",
        "ok": "SSH agent forwarding is not switched on for every host.",
        "risk": "SSH agent forwarding is switched on for every host.",
        "type_all": "agent forwarding for all hosts",
        "cannot": "Could not read the SSH configuration.",
    },
    "plaintext_credentials": {
        "title": "Credential files lying around in plain text",
        "thief": (
            "A file that holds a live key in plain text can be copied and used from "
            "anywhere, including to run up bills or reach your accounts."
        ),
        "fix": "Move each flagged key into the Keychain or a password manager, rotate it, and delete the plain-text copy.",
        "ok": "{n} credential-style file(s) found, none look like they hold a live key.",
        "ok_none": "No credential-style files were found in your development folders.",
        "risk": "{bad} of {n} credential-style file(s) look like they hold a live key.",
        "note_truncated": "The search stopped at its safety limit, so part of your folders was not looked at.",
        "cannot": "Could not search your home folder.",
    },
    "browsers": {
        "title": "Browsers with saved passwords and signed-in sessions",
        "thief": (
            "Browsers that stay signed in can open your email, banking and shopping "
            "sites straight away once the Mac is unlocked."
        ),
        "fix": (
            "Lock the Mac quickly (see the screen lock check), turn on a primary "
            "password where your browser has one, and prefer a password manager."
        ),
        "ok_none": "No saved browser passwords or sessions were found.",
        "ok": "Browsers hold saved logins or sessions, covered by your Mac login.",
        "risk": "Browsers hold saved logins or sessions and the Mac does not lock quickly.",
        "cannot_firefox": "Firefox holds saved logins and its primary password cannot be read from outside Firefox.",
        "cannot_safari": "Safari data needs Full Disk Access to inspect.",
        "type_logins": "{n} saved login(s)",
        "type_sessions": "{n} session cookie row(s)",
        "type_no_primary": "no primary password option",
    },
    "keychain": {
        "title": "Login Keychain lock settings",
        "thief": (
            "A Keychain that stays unlocked while the Mac sleeps gives whoever "
            "wakes it access to the passwords saved there."
        ),
        "fix": "Open Keychain Access > right-click login > Change Settings for Keychain > tick Lock when sleeping.",
        "ok": "The login Keychain locks when the Mac sleeps or after a timeout.",
        "risk": "The login Keychain stays unlocked while the Mac sleeps.",
        "cannot": "Could not read the login Keychain settings here.",
    },
    "messages_mail_apps": {
        "title": "Messages, Mail and banking apps",
        "thief": (
            "These apps open without asking again, so whoever gets past the login "
            "screen can read your messages and mail and see your accounts."
        ),
        "fix": "Fix the screen lock first. Turn on any app-level lock a banking app offers (Touch ID or a passcode).",
        "ok": "These apps sit behind your Mac login, which is locked promptly.",
        "risk": "These apps open without asking again and the Mac does not lock quickly.",
        "cannot": "Messages and Mail data need Full Disk Access to inspect.",
        "note_inapp": "Whether a banking app has its own lock cannot be read from outside the app.",
        "type_messages": "Messages history present",
        "type_mail": "Mail data present",
        "type_finance": "finance app",
    },
    "touch_id_sudo": {
        "title": "Administrator commands (sudo)",
        "thief": "If sudo needs no password, anyone at the Terminal has full control of the Mac.",
        "fix": "Remove any pam_permit or NOPASSWD rule for sudo. Optionally turn on Touch ID for sudo in /etc/pam.d/sudo_local.",
        "ok_tid": "sudo asks for Touch ID or your password.",
        "ok": "sudo asks for your password.",
        "risk": "sudo is set up to run without a password.",
        "cannot": "Could not read the sudo settings here.",
    },
}
