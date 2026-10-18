#!/usr/bin/env bash
#
# tests/e2e/assistant_mailbox_real.sh  (v1.0.108)
#
# The REAL provider round trip: a real iCloud or Gmail account for the assistant,
# a human sending the owner's mail. Prepared, not yet run: it needs accounts
# only Andy can create. The password is read from the environment, never echoed,
# never put on a command line, and only ever held by the `security` stand-in
# (tests/e2e/fakebin/security, a 0600 file in a temp dir removed at exit). No
# real keychain is created, read or unlocked, not even a throwaway one.
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
#   4. A daemon binary built from ostler-assistant v110/assistant-own-email-daemon.
# Exit 0 pass, 1 a check failed, 2 CANNOT-RUN (a skipped step is never a pass).
set -uo pipefail
set +x
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

for v in OSTLER_REAL_PROVIDER OSTLER_REAL_ADDRESS OSTLER_REAL_OWNER OSTLER_REAL_PASSWORD; do
    [ -n "${!v:-}" ] || { echo "CANNOT-RUN: $v is not set (see the header of this script)"; exit 2; }
done
PY="${OSTLER_E2E_PYTHON:-}"
if [ -z "$PY" ]; then
    for c in python3.11 python3.12 python3.13 python3; do command -v "$c" >/dev/null && { PY="$(command -v "$c")"; break; }; done
fi
[ -n "$PY" ] || { echo "CANNOT-RUN: no python3"; exit 2; }
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || { echo "CANNOT-RUN: python >= 3.9 needed ($PY)"; exit 2; }
[ -n "${OSTLER_E2E_DAEMON:-}" ] && [ -x "${OSTLER_E2E_DAEMON}" ] \
    || { echo "CANNOT-RUN: set OSTLER_E2E_DAEMON to the daemon binary (built from ostler-assistant v110/assistant-own-email-daemon)"; exit 2; }

umask 077
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
export PATH="$HERE/fakebin:$PATH"
export FAKE_SECURITY_STORE="$tmp/fake-keychain.json" FAKE_SECURITY_LOG="$tmp/fake-security.log"
: > "$FAKE_SECURITY_LOG"
[ "$(command -v security)" = "$HERE/fakebin/security" ] \
    || { echo "CANNOT-RUN: the security stand-in is not first on PATH ($(command -v security))"; exit 2; }
KC="$tmp/e2e.keychain-db"; : > "$KC"
echo "security: stand-in $HERE/fakebin/security (no real keychain touched)"

export OSTLER_E2E_KEYCHAIN="$KC"
"$PY" -I "$HERE/assistant_mailbox_real_run.py"
rc=$?
if grep -q UNSUPPORTED "$FAKE_SECURITY_LOG"; then
    echo "FAIL: a security call the stand-in does not model:"; grep UNSUPPORTED "$FAKE_SECURITY_LOG"; rc=1
fi
exit "$rc"
