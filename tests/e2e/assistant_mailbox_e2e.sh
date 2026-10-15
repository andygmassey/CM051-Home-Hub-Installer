#!/usr/bin/env bash
#
# tests/e2e/assistant_mailbox_e2e.sh  (v1.0.108)
#
# The assistant's own email address, installer half and daemon half together,
# with REAL components: the install.sh step, the Doctor module, the daemon
# binary, the macOS `security` tool (a TEMPORARY keychain only), and a loopback
# mail provider that stamps Authentication-Results on delivery.
#
#   OSTLER_E2E_DAEMON=/path/to/ostler-assistant-binary \
#       bash tests/e2e/assistant_mailbox_e2e.sh
#
# Build the daemon from ostler-assistant branch v108/assistant-own-email-daemon:
#   cargo build --release --bin zeroclaw      (binary: target/release/zeroclaw)
#
# Exit 0 pass, 1 a check failed, 2 CANNOT-RUN (and says why). A walk must treat
# 2 as "not measured", never as a pass.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

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
"$PY" -I "$HERE/assistant_mailbox_e2e.py"
rc=$?

after_list="$(security list-keychains -d user 2>&1)"
if [ "$before_list" = "$after_list" ]; then
    echo "ok:   the user's keychain search list is unchanged"
else
    echo "FAIL: the user's keychain search list changed"; rc=1
fi
exit "$rc"
