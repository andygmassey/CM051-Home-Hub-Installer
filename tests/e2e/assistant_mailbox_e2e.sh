#!/usr/bin/env bash
#
# tests/e2e/assistant_mailbox_e2e.sh  (v1.0.108)
#
# The assistant's own email address, installer half and daemon half together,
# with REAL components: the install.sh step, the Doctor module, the daemon
# binary, and a loopback mail provider that stamps Authentication-Results on
# delivery. The ONE stand-in is the macOS `security` tool: tests/e2e/fakebin/
# security goes first on PATH, so no real keychain is created, read or
# unlocked (a throwaway one still put a password dialog in front of the owner).
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

PY="${OSTLER_E2E_PYTHON:-}"
if [ -z "$PY" ]; then
    for c in python3.11 python3.12 python3.13 python3; do command -v "$c" >/dev/null && { PY="$(command -v "$c")"; break; }; done
fi
[ -n "$PY" ] || { echo "CANNOT-RUN: no python3"; exit 2; }
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || { echo "CANNOT-RUN: python >= 3.9 needed ($PY)"; exit 2; }
[ -n "${OSTLER_E2E_DAEMON:-}" ] && [ -x "${OSTLER_E2E_DAEMON}" ] \
    || { echo "CANNOT-RUN: set OSTLER_E2E_DAEMON to the daemon binary (built from ostler-assistant v108/assistant-own-email-daemon)"; exit 2; }

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
export PATH="$HERE/fakebin:$PATH"
export FAKE_SECURITY_STORE="$tmp/fake-keychain.json" FAKE_SECURITY_LOG="$tmp/fake-security.log"
: > "$FAKE_SECURITY_LOG"
[ "$(command -v security)" = "$HERE/fakebin/security" ] \
    || { echo "CANNOT-RUN: the security stand-in is not first on PATH ($(command -v security))"; exit 2; }
# The seam path the Doctor and daemon pass as the keychain: a name for the stub,
# never a real keychain file.
KC="$tmp/e2e.keychain-db"; : > "$KC"
echo "security: stand-in $HERE/fakebin/security (no real keychain touched)"

export OSTLER_E2E_KEYCHAIN="$KC"
"$PY" -I "$HERE/assistant_mailbox_e2e.py"
rc=$?
if grep -q UNSUPPORTED "$FAKE_SECURITY_LOG"; then
    echo "FAIL: a security call the stand-in does not model:"; grep UNSUPPORTED "$FAKE_SECURITY_LOG"; rc=1
fi
exit "$rc"
