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
#   8. The pin is WELL FORMED -- exactly the sentinel, or exactly 64
#      lowercase hex characters. Nothing else, ever.
#   9. When a built tarball exists, the pin equals that tarball's ACTUAL
#      digest, recomputed here.
#
# ── WHY THIS WAS REWRITTEN, 2026-09-23 ───────────────────────────────────────
#
# Check 8 used to be the real supply-chain assertion and it was gated:
#
#     if [[ "${OSTLER_CHECK_RELEASE_SHA:-0}" == "1" ]]; then
#
# MEASURED: OSTLER_CHECK_RELEASE_SHA is set in ZERO executable files in this
# repository. Its only other appearance anywhere is a sentence in RELEASE.md
# telling a human to set it. Control for that search: OSTLER_EMERGENCY_CUT,
# which IS set, appears in two real files -- so the search finds env vars where
# they exist and the zero was real. The branch had therefore never run, and the
# test printed "SKIP: sentinel check skipped" on every execution since it was
# written. A check nobody can reach is not a weak check, it is no check.
#
# THE OTHER HALF WAS WEAKER THAN IT LOOKED. Check 10 compared the pin against
# dist/install.tar.gz.sha256 -- a sidecar FILE, not the tarball. A stale sidecar
# and a stale pin agree with each other perfectly. The digest is now RECOMPUTED
# from the tarball bytes, and the sidecar is checked against that too.
#
# THE GATE NOW DECIDES FROM WHAT IS ON DISK, WHICH CANNOT BE FORGOTTEN:
#   - no tarball built  -> the pin cannot be verified here. Said out loud as
#     NOT VERIFIED, with the command that would verify it. Not a pass, not a
#     failure, and never a silent SKIP that reads like a pass.
#   - tarball built      -> the pin MUST equal its recomputed digest. Hard fail.
# There is no environment variable to remember and none to forget.
#
# The presence checks (2 to 7) now read a COMMENT-STRIPPED copy of install.sh.
# They previously matched their own strings inside a comment, which is the same
# defect one layer down: a commented-out shasum verification would have read as
# a present shasum verification.

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

# A line that is commented out is not code. Every presence check below reads
# this stripped copy, never install.sh itself.
#
# Trailing comments count, not just whole-line ones. The mutation that forced
# this is realistic and leaves install.sh parsing cleanly:
#     actual_sha="$expected_sha"   # shasum -a 256 "${BOOTSTRAP_TMPDIR}/..."
# The supply-chain digest is then never computed and the comparison always
# succeeds, while a whole-line-only stripper still reports the shasum block
# PRESENT. So the '#' that ends a line is found with quote state tracked, and
# a '#' inside a quoted span or mid-token is left alone.
LIVE="$(mktemp -t bootstrap-live.XXXXXX)"
UNVERIFIED=0
cleanup_live() { rm -f "$LIVE"; }
trap cleanup_live EXIT
awk '
    {
        line = $0
        probe = line
        sub(/^[[:space:]]+/, "", probe)
        if (substr(probe, 1, 1) == "#") next
        n = length(line); sq = 0; dq = 0; out = line
        for (k = 1; k <= n; k++) {
            ch = substr(line, k, 1)
            if (ch == "\\" && sq == 0) { k++; continue }
            if (ch == "\047" && dq == 0) { sq = 1 - sq; continue }
            if (ch == "\"" && sq == 0) { dq = 1 - dq; continue }
            if (ch == "#" && sq == 0 && dq == 0) {
                prev = (k == 1) ? " " : substr(line, k - 1, 1)
                if (prev == " " || prev == "\t") { out = substr(line, 1, k - 1); break }
            }
        }
        print out
    }
' "$INSTALL_SCRIPT" > "$LIVE"
if [[ ! -s "$LIVE" ]]; then
    echo "CANNOT-RUN: comment stripping emptied install.sh; the stripper is broken." >&2
    exit 2
fi

# ── 1. Parse check ────────────────────────────────────────────────────────────
if bash -n "$INSTALL_SCRIPT" 2>/dev/null; then
    pass "install.sh parses cleanly (bash -n)"
else
    fail "install.sh fails bash -n parse check"
fi

# ── 2. DEFAULT_INSTALLER_TARBALL_SHA256 constant present ─────────────────────
if grep -qE '^DEFAULT_INSTALLER_TARBALL_SHA256="' "$LIVE"; then
    pass "DEFAULT_INSTALLER_TARBALL_SHA256 constant is present"
else
    fail "DEFAULT_INSTALLER_TARBALL_SHA256 constant not found -- bootstrap prelude block may be missing"
fi

# ── 3. INSTALLER_TARBALL_SHA256 wired from env-var override ──────────────────
if grep -qE '^INSTALLER_TARBALL_SHA256="\$\{OSTLER_INSTALLER_TARBALL_SHA256:-\$\{DEFAULT_INSTALLER_TARBALL_SHA256\}\}"' "$LIVE"; then
    pass "INSTALLER_TARBALL_SHA256 wired from OSTLER_INSTALLER_TARBALL_SHA256 env override"
else
    fail "INSTALLER_TARBALL_SHA256 not wired from env override -- supply-chain guard cannot be overridden by operator"
fi

# ── 4. SHA verification block present ────────────────────────────────────────
if grep -q 'shasum -a 256 "\${BOOTSTRAP_TMPDIR}/install.tar.gz"' "$LIVE"; then
    pass "SHA verification (shasum) block present in curl|bash bootstrap branch"
else
    fail "shasum verification block not found in curl|bash bootstrap branch"
fi

if grep -q 'Tarball SHA-256 mismatch. Refusing to extract.' "$LIVE"; then
    pass "SHA mismatch hard-fail message present"
else
    fail "SHA mismatch hard-fail message not found -- guard may silently pass on mismatch"
fi

# ── 5. Network preflight block present ───────────────────────────────────────
if grep -q 'Cannot reach github.com from this Mac.' "$LIVE"; then
    pass "Network preflight block present (github.com reachability probe)"
else
    fail "Network preflight block not found -- customers on broken networks get cryptic curl errors"
fi

# ── 6. 3-retry fetch loop present ────────────────────────────────────────────
if grep -q 'for attempt in 1 2 3; do' "$LIVE"; then
    pass "3-attempt retry fetch loop present"
else
    fail "3-attempt retry fetch loop not found -- transient CDN failures will abort installs"
fi

if grep -q 'Attempt \${attempt}/3 failed; retrying in \${backoff}s' "$LIVE"; then
    pass "Retry backoff message present"
else
    fail "Retry backoff message not found"
fi

# ── 7. OSTLER_INSTALLER_TARBALL_SHA256 documented in --help ──────────────────
if grep -q '"  OSTLER_INSTALLER_TARBALL_SHA256"' "$LIVE"; then
    pass "OSTLER_INSTALLER_TARBALL_SHA256 documented in --help env-var section"
else
    fail "OSTLER_INSTALLER_TARBALL_SHA256 not documented in --help -- operators cannot discover the override"
fi

# ── 8. The pin is WELL FORMED. Unconditional, no env var. ────────────────────
#
# Exactly the sentinel, or exactly 64 lowercase hex. A truncated, upper-cased
# or half-patched pin is neither, and used to pass unnoticed because the only
# branch that looked at the VALUE was switched off.
SENTINEL_LINE="$(grep '^DEFAULT_INSTALLER_TARBALL_SHA256=' "$LIVE" | head -1)"
PINNED_SHA="$(printf '%s' "$SENTINEL_LINE" | sed -E 's/^[^"]*"([^"]*)".*/\1/')"

if [[ -z "$SENTINEL_LINE" ]]; then
    fail "no DEFAULT_INSTALLER_TARBALL_SHA256 assignment survives comment stripping -- the prelude is commented out or gone"
elif [[ "$PINNED_SHA" == "REPLACE_AT_RELEASE_TIME" ]]; then
    pass "pin is the sentinel REPLACE_AT_RELEASE_TIME (unreleased tree)"
elif [[ "$PINNED_SHA" =~ ^[0-9a-f]{64}$ ]]; then
    pass "pin is a well-formed 64-char hex digest (${PINNED_SHA:0:16}...)"
else
    fail "pin is neither the sentinel nor a 64-char lowercase hex digest: ${SENTINEL_LINE}"
fi

# ── 9. Built tarball: inner install.sh stays at sentinel (Finding 2 invariant)
#
# After release.sh runs, dist/install.tar.gz exists. The inner install.sh
# inside that tarball must carry the sentinel value, not a 64-char hex digest.
# If a power user extracts and runs the inner install.sh standalone with
# BASH_SOURCE unset, the sentinel triggers the "skip with WARNING" path
# rather than a stale-digest hard-fail. Skipped when no dist artefacts exist.
DIST_TARBALL="${REPO_ROOT}/dist/install.tar.gz"
if [[ -f "$DIST_TARBALL" ]]; then
    EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cm051-tarball-check-XXXXXX")"
    trap 'rm -rf "${EXTRACT_DIR}"' EXIT
    if tar -xzf "$DIST_TARBALL" -C "$EXTRACT_DIR" 2>/dev/null; then
        INNER_INSTALL_SH="$(find "$EXTRACT_DIR" -maxdepth 3 -name install.sh -type f -print -quit)"
        if [[ -n "$INNER_INSTALL_SH" ]]; then
            INNER_LINE="$(grep '^DEFAULT_INSTALLER_TARBALL_SHA256=' "$INNER_INSTALL_SH" || true)"
            if grep -q 'REPLACE_AT_RELEASE_TIME' <<<"$INNER_LINE"; then
                pass "tarball-inner install.sh carries the sentinel (Finding 2 invariant holds)"
            else
                fail "tarball-inner install.sh does NOT carry the sentinel: ${INNER_LINE}"
            fi
        else
            fail "tarball-inner install.sh not found after extraction"
        fi
    else
        fail "could not extract ${DIST_TARBALL}"
    fi
else
    echo "SKIP: tarball-inner sentinel check skipped (no ${DIST_TARBALL}; run release.sh first)"
fi

# ── 9b. The pin equals the tarball's ACTUAL digest, recomputed here ──────────
#
# The old version of this compared the pin against dist/install.tar.gz.sha256.
# That sidecar is written by the same release.sh run that writes the pin, so a
# stale pair agrees with itself and proves nothing about the bytes a customer
# downloads. shasum the tarball instead, and hold the sidecar to the same
# answer.
#
# WHEN THERE IS NO TARBALL the pin is NOT VERIFIED here. That is not a pass.
# It is an absence of instrumentation, and the command that would close it is
# printed rather than implied.
if [[ -f "$DIST_TARBALL" ]]; then
    ACTUAL_SHA="$(shasum -a 256 "$DIST_TARBALL" | awk '{print $1}')"
    if [[ "$PINNED_SHA" == "REPLACE_AT_RELEASE_TIME" ]]; then
        fail "dist/install.tar.gz exists but the repo-root pin is still the sentinel -- release.sh built the tarball and did not patch install.sh"
    elif [[ "$PINNED_SHA" == "$ACTUAL_SHA" ]]; then
        pass "pin matches the recomputed digest of dist/install.tar.gz (${ACTUAL_SHA:0:16}...)"
    else
        fail "pin (${PINNED_SHA:0:16}...) does NOT match the recomputed digest of dist/install.tar.gz (${ACTUAL_SHA:0:16}...) -- every customer fetch would abort"
    fi

    SIDECAR="${REPO_ROOT}/dist/install.tar.gz.sha256"
    if [[ -f "$SIDECAR" ]]; then
        SIDECAR_SHA="$(awk '{print $1}' "$SIDECAR")"
        if [[ "$SIDECAR_SHA" == "$ACTUAL_SHA" ]]; then
            pass "sidecar agrees with the recomputed digest"
        else
            fail "sidecar (${SIDECAR_SHA:0:16}...) disagrees with the recomputed digest (${ACTUAL_SHA:0:16}...) -- the sidecar is stale"
        fi
    fi
elif [[ "$PINNED_SHA" != "REPLACE_AT_RELEASE_TIME" ]]; then
    UNVERIFIED=$((UNVERIFIED+1))
    echo "NOT VERIFIED: install.sh pins ${PINNED_SHA:0:16}... and there is no dist/install.tar.gz"
    echo "              to check it against, so nothing here measured the supply-chain pin."
    echo "              To instrument it:  ./release.sh   then re-run this test."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Bootstrap prelude test summary: ${PASS} passed, ${FAIL} failed, ${UNVERIFIED} not verified"
if [[ $UNVERIFIED -gt 0 ]]; then
    echo "  ${UNVERIFIED} check(s) had no artefact to measure. Not a pass. See NOT VERIFIED above."
fi

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
