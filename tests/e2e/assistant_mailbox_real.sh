#!/usr/bin/env bash
#
# tests/e2e/assistant_mailbox_real.sh  (v1.0.108)
#
# The REAL provider round trip: a real iCloud or Gmail account for the assistant,
# a human sending the owner's mail. Prepared, not yet run: it needs accounts
# only Andy can create. The password is read from the environment, never echoed,
# never put on a command line, and only ever written to a TEMPORARY keychain.
#
#   OSTLER_REAL_PROVIDER=icloud            # or gmail
#   OSTLER_REAL_ADDRESS=<the new assistant account address>
#   OSTLER_REAL_OWNER=<the address you will send the test mail FROM>
#   read -rs OSTLER_REAL_PASSWORD; export OSTLER_REAL_PASSWORD    # paste the app password, press Enter
#   OSTLER_E2E_DAEMON=/path/to/zeroclaw bash tests/e2e/assistant_mailbox_real.sh
#
# WHAT YOU MUST CREATE FIRST
#   1. ONE new account just for the assistant: iCloud (create a new Apple Account
#      at account.apple.com, with its iCloud Mail address) or Gmail. Not an
#      existing mailbox: the installer step refuses an inbox with more than 200
#      messages or any older than 14 days without a second confirmation.
#   2. Switch two-step verification ON for that account, then create an
#      APP-SPECIFIC PASSWORD (Apple: account.apple.com > Sign-In and Security >
#      App-Specific Passwords; Google: myaccount.google.com/apppasswords). Only
#      that password is used, never the account password.
#   3. Decide the OWNER address: the mailbox you will send the test mail FROM
#      (a different address from the assistant's). It must be a provider that
#      DKIM-signs outgoing mail (iCloud, Gmail and Outlook all do).
#   4. A daemon binary built from ostler-assistant v108/assistant-own-email-daemon.
# Exit 0 pass, 1 a check failed, 2 CANNOT-RUN (a skipped step is never a pass).
set -uo pipefail
set +x
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

for v in OSTLER_REAL_PROVIDER OSTLER_REAL_ADDRESS OSTLER_REAL_OWNER OSTLER_REAL_PASSWORD; do
    [ -n "${!v:-}" ] || { echo "CANNOT-RUN: $v is not set (see the header of this script)"; exit 2; }
done
[ "$(uname -s)" = Darwin ] || { echo "CANNOT-RUN: needs macOS (the security tool and Keychain)"; exit 2; }
command -v security >/dev/null || { echo "CANNOT-RUN: security tool not found"; exit 2; }
PY="${OSTLER_E2E_PYTHON:-}"
if [ -z "$PY" ]; then
    for c in python3.11 python3.12 python3.13 python3; do command -v "$c" >/dev/null && { PY="$(command -v "$c")"; break; }; done
fi
[ -n "$PY" ] || { echo "CANNOT-RUN: no python3"; exit 2; }
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || { echo "CANNOT-RUN: python >= 3.9 needed ($PY)"; exit 2; }
[ -n "${OSTLER_E2E_DAEMON:-}" ] && [ -x "${OSTLER_E2E_DAEMON}" ] \
    || { echo "CANNOT-RUN: set OSTLER_E2E_DAEMON to the daemon binary (built from ostler-assistant v108/assistant-own-email-daemon)"; exit 2; }

tmp="$(mktemp -d)"
KC="$tmp/e2e.keychain-db"
KC_PW="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 24)"
before_list="$(security list-keychains -d user 2>&1)"
cleanup() {
    security delete-keychain "$KC" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT
security create-keychain -p "$KC_PW" "$KC" >/dev/null 2>&1 || { echo "CANNOT-RUN: could not create a temporary keychain"; exit 2; }
security set-keychain-settings "$KC" >/dev/null 2>&1
security unlock-keychain -p "$KC_PW" "$KC" >/dev/null 2>&1 || { echo "CANNOT-RUN: could not unlock the temporary keychain"; exit 2; }
echo "temporary keychain: $KC (not added to any search list)"

export OSTLER_E2E_KEYCHAIN="$KC"
"$PY" -I "$HERE/assistant_mailbox_real_run.py"
rc=$?

after_list="$(security list-keychains -d user 2>&1)"
if [ "$before_list" = "$after_list" ]; then
    echo "ok:   the user's keychain search list is unchanged"
else
    echo "FAIL: the user's keychain search list changed"; rc=1
fi
exit "$rc"
