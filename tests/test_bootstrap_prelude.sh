#!/usr/bin/env bash
#
# tests/test_bootstrap_prelude.sh
#
# Verifies that the bootstrap prelude block in install.sh is present and
# correctly structured. The prelude is the supply-chain SHA guard that runs
# before any installation work: it downloads the installer tarball, verifies
# the SHA-256 digest, and re-execs the inner install.sh from the verified tree.
#
# Why this test exists:
#
#   The CM055 Cloudflare Worker (which carried an earlier version of this
#   guard) is INERT in production: Cloudflare Pages takes precedence over
#   the Worker route and serves a 302 redirect directly to GitHub raw. That
#   means the Worker's prelude never reaches customers. Without this test
#   and the corresponding code change, every customer fetch bypasses the
#   supply-chain guard entirely.
#
#   See memory/reference_ostler_install_sh_delivery_path.md for the full
#   delivery-path analysis and the regression history.
#
# What we verify:
#
#   1. install.sh parses cleanly (bash -n).
#   2. DEFAULT_INSTALLER_TARBALL_SHA256 constant is present and non-sentinel.
#      In the repo (pre-release) this is REPLACE_AT_RELEASE_TIME; after
#      release.sh runs the two-pass build and the release engineer patches
#      the standalone install.sh it will be a 64-character hex digest.
#   3. INSTALLER_TARBALL_SHA256 variable is wired from the env-var override
#      falling back to the default constant.
#   4. The SHA verification block is present (shasum + mismatch check).
#   5. The network preflight block is present (github.com reachability probe).
#   6. The 3-retry fetch loop is present.
#   7. OSTLER_INSTALLER_TARBALL_SHA256 is documented in --help.
#   8. The sentinel value REPLACE_AT_RELEASE_TIME does NOT appear in a
#      released build -- i.e. the constant has been patched. This check
#      is gated by an env var so CI (which runs against the repo, not a
#      release build) can skip it.
#
# Environment variables:
#
#   OSTLER_CHECK_RELEASE_SHA=1
#     When set, check (7) fails if DEFAULT_INSTALLER_TARBALL_SHA256 is still
#     the sentinel REPLACE_AT_RELEASE_TIME. Set this in release-gate CI only;
#     never in development CI where the sentinel is the expected repo state.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FATAL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

# ── 1. Parse check ────────────────────────────────────────────────────────────
if bash -n "$INSTALL_SCRIPT" 2>/dev/null; then
    pass "install.sh parses cleanly (bash -n)"
else
    fail "install.sh fails bash -n parse check"
fi

# ── 2. DEFAULT_INSTALLER_TARBALL_SHA256 constant present ─────────────────────
if grep -qE '^DEFAULT_INSTALLER_TARBALL_SHA256="' "$INSTALL_SCRIPT"; then
    pass "DEFAULT_INSTALLER_TARBALL_SHA256 constant is present"
else
    fail "DEFAULT_INSTALLER_TARBALL_SHA256 constant not found -- bootstrap prelude block may be missing"
fi

# ── 3. INSTALLER_TARBALL_SHA256 wired from env-var override ──────────────────
if grep -qE '^INSTALLER_TARBALL_SHA256="\$\{OSTLER_INSTALLER_TARBALL_SHA256:-\$\{DEFAULT_INSTALLER_TARBALL_SHA256\}\}"' "$INSTALL_SCRIPT"; then
    pass "INSTALLER_TARBALL_SHA256 wired from OSTLER_INSTALLER_TARBALL_SHA256 env override"
else
    fail "INSTALLER_TARBALL_SHA256 not wired from env override -- supply-chain guard cannot be overridden by operator"
fi

# ── 4. SHA verification block present ────────────────────────────────────────
if grep -q 'shasum -a 256 "\${BOOTSTRAP_TMPDIR}/install.tar.gz"' "$INSTALL_SCRIPT"; then
    pass "SHA verification (shasum) block present in curl|bash bootstrap branch"
else
    fail "shasum verification block not found in curl|bash bootstrap branch"
fi

if grep -q 'Tarball SHA-256 mismatch. Refusing to extract.' "$INSTALL_SCRIPT"; then
    pass "SHA mismatch hard-fail message present"
else
    fail "SHA mismatch hard-fail message not found -- guard may silently pass on mismatch"
fi

# ── 5. Network preflight block present ───────────────────────────────────────
if grep -q 'Cannot reach github.com from this Mac.' "$INSTALL_SCRIPT"; then
    pass "Network preflight block present (github.com reachability probe)"
else
    fail "Network preflight block not found -- customers on broken networks get cryptic curl errors"
fi

# ── 6. 3-retry fetch loop present ────────────────────────────────────────────
if grep -q 'for attempt in 1 2 3; do' "$INSTALL_SCRIPT"; then
    pass "3-attempt retry fetch loop present"
else
    fail "3-attempt retry fetch loop not found -- transient CDN failures will abort installs"
fi

if grep -q 'Attempt \${attempt}/3 failed; retrying in \${backoff}s' "$INSTALL_SCRIPT"; then
    pass "Retry backoff message present"
else
    fail "Retry backoff message not found"
fi

# ── 7. OSTLER_INSTALLER_TARBALL_SHA256 documented in --help ──────────────────
if grep -q '"  OSTLER_INSTALLER_TARBALL_SHA256"' "$INSTALL_SCRIPT"; then
    pass "OSTLER_INSTALLER_TARBALL_SHA256 documented in --help env-var section"
else
    fail "OSTLER_INSTALLER_TARBALL_SHA256 not documented in --help -- operators cannot discover the override"
fi

# ── 8. Sentinel not present in release build (optional, gated by env var) ────
if [[ "${OSTLER_CHECK_RELEASE_SHA:-0}" == "1" ]]; then
    SENTINEL_LINE="$(grep '^DEFAULT_INSTALLER_TARBALL_SHA256=' "$INSTALL_SCRIPT" || true)"
    if echo "$SENTINEL_LINE" | grep -q 'REPLACE_AT_RELEASE_TIME'; then
        fail "DEFAULT_INSTALLER_TARBALL_SHA256 is still the sentinel REPLACE_AT_RELEASE_TIME -- release.sh two-pass build and standalone install.sh patch have not been applied"
    else
        PINNED_SHA="$(echo "$SENTINEL_LINE" | sed -E 's/.*"([0-9a-f]{64})".*/\1/')"
        if [[ ${#PINNED_SHA} -eq 64 ]]; then
            pass "DEFAULT_INSTALLER_TARBALL_SHA256 is a 64-char hex digest (${PINNED_SHA:0:16}...)"
        else
            fail "DEFAULT_INSTALLER_TARBALL_SHA256 is neither sentinel nor a valid 64-char hex digest: ${SENTINEL_LINE}"
        fi
    fi
else
    echo "SKIP: sentinel check skipped (set OSTLER_CHECK_RELEASE_SHA=1 in release-gate CI)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Bootstrap prelude test summary: ${PASS} passed, ${FAIL} failed"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
